#!/bin/bash
# Download by immutable ID and fail on digest mismatch (never a warning-only gate).
set -euo pipefail
umask 077
fail() { printf 'download-release-artifact: %s\n' "$*" >&2; exit 1; }
[[ $# == 4 ]] || fail 'Usage: download-release-artifact.sh ID SHA256_DIGEST KIND DESTINATION'
id=$1 digest=$2 kind=$3 destination=$4
[[ $id =~ ^[1-9][0-9]*$ && $digest =~ ^sha256:[0-9a-f]{64}$ ]] || fail 'Invalid immutable artifact binding.'
[[ ${GITHUB_REPOSITORY:-} =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail 'Missing destination repository.'
[[ ! -e $destination && ! -L $destination ]] || fail 'Destination must be fresh.'
work=$(mktemp -d "${TMPDIR:-/tmp}/cadence-download.XXXXXX")
trap 'rm -rf "$work"' EXIT
gh api "repos/$GITHUB_REPOSITORY/actions/artifacts/$id" > "$work/metadata.json"
jq -e --argjson id "$id" --arg digest "$digest" '.id == $id and .expired == false and .digest == $digest' "$work/metadata.json" >/dev/null \
    || fail 'Artifact metadata changed or custody expired.'
gh api "repos/$GITHUB_REPOSITORY/actions/artifacts/$id/zip" > "$work/artifact.zip"
actual=$(shasum -a 256 < "$work/artifact.zip"); actual=${actual%% *}
[[ "sha256:$actual" == "$digest" ]] || fail 'Downloaded artifact digest differs from the immutable API binding.'
unzip -Z1 "$work/artifact.zip" > "$work/members"
case $kind in publication) expected_count=1 ;; checkpoint) expected_count=3 ;; build|distribution) expected_count=4 ;; *) fail 'Unknown artifact kind.' ;; esac
count=$(wc -l < "$work/members" | tr -d ' ')
unique_count=$(LC_ALL=C sort -u "$work/members" | wc -l | tr -d ' ')
[[ $count == "$expected_count" && $unique_count == "$count" ]] || fail 'Artifact members are missing or duplicated.'
layout='' package_version=''
while IFS= read -r member; do
    [[ -n $member && $member != *$'\r'* ]] || fail 'Unsafe artifact member.'
    prefix='' name=$member
    if [[ $member == */* ]]; then
        # upload-artifact retains the directory after CI's first wildcard:
        # dist/packages/*-universal-local/*. Permit only that single build root.
        [[ $kind == build && $member =~ ^([0-9]+\.[0-9]+\.[0-9]+)-universal-local/([^/]+)$ ]] \
            || fail 'Unexpected artifact directory.'
        package_version=${BASH_REMATCH[1]}
        prefix="$package_version-universal-local/" name=${member##*/}
        case $name in
            "Cadence-App-$package_version-universal-local.zip"|"Cadence-Installer-$package_version-universal-local.dmg"|build-manifest.json|SHA256SUMS) ;;
            *) fail 'Build package directory and member version differ.' ;;
        esac
    fi
    if [[ -z $layout ]]; then layout="${prefix:-flat}"; fi
    [[ $layout == "${prefix:-flat}" ]] || fail 'Mixed artifact directories.'
    case $kind:$name in
        publication:publication-receipts.json) ;;
        checkpoint:checkpoint.json|checkpoint:state.tar.gz|checkpoint:SHA256SUMS) ;;
        build:Cadence-App-*-universal-local.zip|build:Cadence-Installer-*-universal-local.dmg|build:build-manifest.json|build:SHA256SUMS) ;;
        distribution:Cadence-App-*-universal.zip|distribution:Cadence-Installer-*-universal.dmg|distribution:distribution.json|distribution:SHA256SUMS) ;;
        *) fail 'Unexpected artifact member.' ;;
    esac
done < "$work/members"
ditto -x -k "$work/artifact.zip" "$work/extracted"
payload="$work/extracted"
if [[ $layout != flat ]]; then
    payload="$payload/${layout%/}"
    [[ -d $payload && ! -L $payload ]] || fail 'Build package directory is not regular.'
fi
for member in "$payload/"*; do
    [[ -f $member && ! -L $member ]] || fail 'Artifact contains a link or nonregular file.'
done
mkdir -p "$destination"
mv "$payload/"* "$destination/"

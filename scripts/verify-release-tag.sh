#!/bin/bash
# Read-only provider preflight. No signing, submissions, tags, or releases created.
set -euo pipefail
cd "$(dirname "$0")/.."
fail() { printf 'verify-release-tag: %s\n' "$*" >&2; exit 1; }
tag=${GITHUB_REF_NAME:-}
commit=${GITHUB_SHA:-}
repository=${GITHUB_REPOSITORY:-}
[[ ${GITHUB_REF_TYPE:-} == tag && ${GITHUB_REF:-} == "refs/tags/$tag" ]] || fail 'Run this workflow on a version tag, not a branch.'
[[ $tag =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || fail 'Production tags must use vMAJOR.MINOR.PATCH.'
[[ $commit =~ ^[0-9a-f]{40}$ ]] || fail 'A full workflow commit SHA is required.'
[[ $repository =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail 'GITHUB_REPOSITORY is required.'
[[ $(git rev-parse --verify HEAD) == "$commit" ]] || fail 'Checkout differs from the workflow commit.'
[[ $(git rev-parse --verify "refs/tags/$tag^{commit}") == "$commit" ]] || fail 'Local tag differs from the workflow commit.'
version=$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist)
[[ $tag == "v$version" ]] || fail 'Tag does not match the app version in Resources/Info.plist.'
# Fetch current main without changing the checkout or persisting credentials.
git fetch --no-tags origin main
git merge-base --is-ancestor "$commit" FETCH_HEAD || fail 'Tagged commit is not on current main.'
remote_refs=$(git ls-remote --exit-code origin "refs/tags/$tag" "refs/tags/$tag^{}")
object='' peeled=''
while read -r sha ref extra; do
    [[ $sha =~ ^[0-9a-f]{40}$ && -z $extra ]] || fail 'Malformed remote tag response.'
    case "$ref" in
        "refs/tags/$tag") [[ -z $object ]] || fail 'Duplicate remote tag.'; object=$sha ;;
        "refs/tags/$tag^{}") [[ -z $peeled ]] || fail 'Duplicate peeled tag.'; peeled=$sha ;;
        *) fail 'Unexpected remote tag reference.' ;;
    esac
done <<< "$remote_refs"
[[ -n $object && ${peeled:-$object} == "$commit" ]] || fail 'Remote tag moved or does not identify the workflow commit.'
work=$(mktemp -d "${TMPDIR:-/tmp}/cadence-release-preflight.XXXXXX")
trap 'rm -rf "$work"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# A list request must succeed. Auth/network failures cannot masquerade as no release.
gh api --paginate --slurp "repos/$repository/releases?per_page=100" > "$work/releases.json"
jq -e 'type == "array" and all(.[]; type == "array" and all(.[];
    type == "object" and (.tag_name | type == "string") and
    (.draft | type == "boolean") and (.prerelease | type == "boolean")))' "$work/releases.json" >/dev/null \
    || fail 'Malformed GitHub release list.'
jq -e --arg tag "$tag" 'all(.[][]; .tag_name != $tag)' "$work/releases.json" >/dev/null \
    || fail 'A release or draft already exists for this tag. Reconcile it before retrying.'
# Compare decimal components as strings, avoiding integer overflow on large versions.
version_newer() {
    local candidate=$1 previous=$2 left right index
    local candidate_parts previous_parts
    IFS=. read -r -a candidate_parts <<< "$candidate"
    IFS=. read -r -a previous_parts <<< "$previous"
    for index in 0 1 2; do
        left=${candidate_parts[$index]} right=${previous_parts[$index]}
        if [[ ${#left} -gt ${#right} ]]; then return 0; fi
        if [[ ${#left} -lt ${#right} ]]; then return 1; fi
        if [[ $left > $right ]]; then return 0; fi
        if [[ $left < $right ]]; then return 1; fi
    done
    return 1
}
jq -r '.[][] | select(.draft == false and .prerelease == false) | .tag_name |
    select(test("^v(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$"))' "$work/releases.json" > "$work/versions"
while IFS= read -r previous; do
    version_newer "$version" "${previous#v}" || fail "Version must be newer than published production release $previous."
done < "$work/versions"
printf 'Production preflight passed: %s at %s, on main, unused and newer than published versions.\n' "$tag" "$commit"

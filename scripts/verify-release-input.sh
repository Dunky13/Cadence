#!/bin/bash
# Verify the exact immutable artifact produced by this workflow before secrets.
set -euo pipefail
cd "$(dirname "$0")/.."
fail() { printf 'verify-release-input: %s\n' "$*" >&2; exit 1; }
[[ $# == 2 ]] || fail 'Usage: verify-release-input.sh INPUT_DIRECTORY EXTRACTION_DIRECTORY'
input=$1 destination=$2
[[ -d $input && ! -L $input ]] || fail 'Input directory is missing.'
[[ ! -e $destination && ! -L $destination ]] || fail 'Extraction directory already exists.'
version=$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist)
source_commit=$(git rev-parse --verify HEAD)
[[ ${SOURCE_COMMIT:-${GITHUB_SHA:-$source_commit}} == "$source_commit" ]] || fail 'Checkout differs from the selected source commit.'
archive="Cadence-App-$version-universal-local.zip"
image="Cadence-Installer-$version-universal-local.dmg"
[[ -f $input/SHA256SUMS && ! -L $input/SHA256SUMS ]] || fail 'Missing checksums.'
expected=$(printf '%s\n' "$archive" "$image" build-manifest.json | LC_ALL=C sort)
actual=''
while read -r digest filename extra; do
    [[ $digest =~ ^[0-9a-fA-F]{64}$ && -z $extra ]] || fail 'Malformed checksum entry.'
    case "$filename" in "$archive"|"$image"|build-manifest.json) ;; *) fail 'Unexpected checksum path.' ;; esac
    [[ -f $input/$filename && ! -L $input/$filename ]] || fail 'Missing regular artifact.'
    actual+="$filename"$'\n'
done < "$input/SHA256SUMS"
actual=$(printf '%s' "$actual" | LC_ALL=C sort)
[[ $actual == "$expected" ]] || fail 'Checksum manifest does not name exactly the expected artifacts.'
(cd "$input" && shasum -a 256 --check SHA256SUMS)
jq -e --arg version "$version" --arg commit "$source_commit" '
    .schema == "cadence/build/v1" and .version == $version and .architecture == "universal"
    and .source_commit == $commit and .source_dirty == false
    and .signing == "ad-hoc" and .notarization == "not attempted"' "$input/build-manifest.json" >/dev/null \
    || fail 'Artifact provenance does not match this clean source commit.'
mkdir -p "$destination"
ditto -x -k "$input/$archive" "$destination"
app="$destination/Cadence.app"
[[ -d $app && ! -L $app ]] || fail 'App is missing from the verified archive.'
if [[ -n ${BUILD_NUMBER:-} ]]; then
    [[ $BUILD_NUMBER =~ ^[1-9][0-9]*$ && $(plutil -extract CFBundleVersion raw "$app/Contents/Info.plist") == "$BUILD_NUMBER" ]] || fail 'Bundle build number differs from the selected CI run.'
fi
codesign --verify --deep --strict --all-architectures "$app"
for architecture in arm64 x86_64; do xcrun lipo "$app/Contents/MacOS/Cadence" -verify_arch "$architecture"; done
actual=$(xcrun lipo -archs "$app/Contents/MacOS/Cadence" | tr ' ' '\n' | LC_ALL=C sort)
[[ $actual == $'arm64\nx86_64' ]] || fail 'Artifact has unexpected architectures.'
printf 'Verified clean universal build for source %s.\n' "$source_commit"

#!/bin/bash
# Offline local/CI packages. Apple signing is a separate explicit workflow.
set -euo pipefail
cd "$(dirname "$0")/.."
architecture=${1:-universal}
[[ $# -le 1 ]] || { echo 'Usage: package-macos.sh [native|universal|arm64|x86_64]' >&2; exit 2; }
[[ $architecture != native ]] || architecture=$(uname -m)
case "$architecture" in arm64|x86_64|universal) ;; *) echo 'Invalid architecture.' >&2; exit 2 ;; esac
for tool in jq ditto shasum; do command -v "$tool" >/dev/null || { echo "Missing prerequisite: $tool" >&2; exit 1; }; done
./scripts/build-app.sh release "$architecture"
version=$(plutil -extract CFBundleShortVersionString raw dist/Cadence.app/Contents/Info.plist)
mkdir -p dist/packages
work=$(mktemp -d "$PWD/dist/packages/.cadence-local.XXXXXX")
output="$PWD/dist/packages/$version-$architecture-local"
cleanup() {
    result=$?
    trap - EXIT
    if [[ -d $work/previous && ! -e $output ]]; then mv "$work/previous" "$output" || result=1; fi
    rm -rf -- "$work" || result=1
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir "$work/output"
archive="Cadence-App-$version-$architecture-local.zip"
ditto -c -k --sequesterRsrc --keepParent dist/Cadence.app "$work/output/$archive"
image=$(./scripts/package-dmg.sh --app dist/Cadence.app --output-dir "$work/output" --version "$version" --architecture "$architecture")
./scripts/check-dmg.sh "$image" --architecture "$architecture" --version "$version"
source_commit=$(git rev-parse --verify HEAD 2>/dev/null) || source_commit=''
dirty=true
if [[ -n $source_commit && -z $(git status --porcelain) ]]; then dirty=false; fi
jq -n --arg version "$version" --arg architecture "$architecture" --arg commit "$source_commit" --argjson dirty "$dirty" --arg build "$(plutil -extract CFBundleVersion raw dist/Cadence.app/Contents/Info.plist)" \
    '{schema:"cadence/build/v1",version:$version,architecture:$architecture,
      source_commit:(if $commit == "" then null else $commit end),source_dirty:$dirty,build_number:$build,signing:"ad-hoc",notarization:"not attempted"}' \
    > "$work/output/build-manifest.json"
(
    cd "$work/output"
    shasum -a 256 "$archive" "${image##*/}" build-manifest.json > SHA256SUMS
    shasum -a 256 --check SHA256SUMS
)
if [[ -e $output || -L $output ]]; then
    [[ -d $output && ! -L $output ]] || { echo 'Refusing an unexpected package output path.' >&2; exit 1; }
    mv "$output" "$work/previous"
fi
mv "$work/output" "$output"
printf 'Local packages, ad-hoc signed and not notarized: %s\n' "$output"

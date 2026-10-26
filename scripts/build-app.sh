#!/bin/bash
set -euo pipefail
umask 022
cd "$(dirname "$0")/.."

configuration="${1:-release}"
architecture="${2:-native}"
if [[ $# -gt 2 || ( "$configuration" != "debug" && "$configuration" != "release" ) ]]; then
    echo "Usage: scripts/build-app.sh [debug|release] [native|universal|arm64|x86_64]" >&2
    exit 2
fi
[[ $(uname -s) == Darwin ]] || { echo 'Cadence requires macOS.' >&2; exit 1; }
if [[ $architecture == native ]]; then architecture=$(uname -m); fi
case "$architecture" in
    arm64|x86_64) architectures=("$architecture") ;;
    universal) architectures=(arm64 x86_64) ;;
    *) echo 'Architecture must be native, universal, arm64, or x86_64.' >&2; exit 2 ;;
esac
for tool in swift xcrun codesign ditto plutil; do
    command -v "$tool" >/dev/null || { echo "Missing prerequisite: $tool" >&2; exit 1; }
done
export MACOSX_DEPLOYMENT_TARGET=14.0
mkdir -p dist
work=$(mktemp -d "$PWD/dist/.cadence-build.XXXXXX")
cleanup() {
    result=$?
    trap - EXIT
    if [[ -d $work/previous.app && ! -e dist/Cadence.app ]]; then
        mv "$work/previous.app" dist/Cadence.app || result=1
    fi
    rm -rf -- "$work" || result=1
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
app="$work/Cadence.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

for arch in "${architectures[@]}"; do
    arguments=(--configuration "$configuration" --jobs 2 --triple "$arch-apple-macosx14.0" --scratch-path ".build/$arch")
    swift build "${arguments[@]}"
    binary_dir=$(swift build "${arguments[@]}" --show-bin-path)
    cp "$binary_dir/Cadence" "$work/Cadence-$arch"
    xcrun lipo "$work/Cadence-$arch" -verify_arch "$arch"
done
if [[ $architecture == universal ]]; then
    xcrun lipo -create "$work/Cadence-arm64" "$work/Cadence-x86_64" -output "$app/Contents/MacOS/Cadence"
else
    cp "$work/Cadence-$architecture" "$app/Contents/MacOS/Cadence"
fi
for arch in "${architectures[@]}"; do
    xcrun lipo "$app/Contents/MacOS/Cadence" -verify_arch "$arch"
done
expected=$(printf '%s\n' "${architectures[@]}" | LC_ALL=C sort)
actual=$(xcrun lipo -archs "$app/Contents/MacOS/Cadence" | tr ' ' '\n' | LC_ALL=C sort)
[[ $actual == "$expected" ]] || { echo 'Universal assembly has unexpected architectures.' >&2; exit 1; }
cp Resources/Info.plist "$app/Contents/Info.plist"
if [[ -n ${BUILD_NUMBER:-} ]]; then
    [[ $BUILD_NUMBER =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || { echo 'BUILD_NUMBER must be numeric.' >&2; exit 1; }
    plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$app/Contents/Info.plist"
fi
cp Resources/Cadence.icns "$app/Contents/Resources/Cadence.icns"
plutil -lint "$app/Contents/Info.plist"
chmod -R u+rwX,go+rX,go-w "$app"

# Ad-hoc signing creates a locally runnable bundle, without a Developer ID identity.
/usr/bin/codesign --force --sign - "$app"
/usr/bin/codesign --verify --strict "$app"
if [[ -e dist/Cadence.app || -L dist/Cadence.app ]]; then
    [[ -d dist/Cadence.app && ! -L dist/Cadence.app ]] || { echo 'Refusing an unexpected app output path.' >&2; exit 1; }
    mv dist/Cadence.app "$work/previous.app"
fi
mv "$app" dist/Cadence.app
echo "Built dist/Cadence.app ($architecture)"
echo "Open with: open dist/Cadence.app"

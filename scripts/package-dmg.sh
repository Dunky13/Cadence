#!/bin/bash
# Builds a drag-and-drop image from an already built app. No signing or uploads.
set -euo pipefail
umask 077

fail() { printf 'package-dmg: %s\n' "$*" >&2; exit 1; }
usage() {
    printf '%s\n' 'Usage: package-dmg.sh --app PATH.app --output-dir DIR --version X.Y.Z --architecture arm64|x86_64|universal [--release] [--force]'
}
need() { command -v "$1" >/dev/null 2>&1 || fail "Missing prerequisite: $1"; }
app='' output_dir='' version='' architecture='' release=false force=false
while [[ $# -gt 0 ]]; do
    case $1 in
        --app|--output-dir|--version|--architecture)
            [[ $# -ge 2 && -n $2 && $2 != --* ]] || fail "Missing value for $1"
            case $1 in
                --app) app=$2 ;;
                --output-dir) output_dir=$2 ;;
                --version) version=$2 ;;
                --architecture) architecture=$2 ;;
            esac
            shift 2 ;;
        --release) release=true; shift ;;
        --force) force=true; shift ;;
        --help|-h) usage; exit 0 ;;
        *) usage >&2; fail "Unknown argument: $1" ;;
    esac
done
[[ -n $app && -n $output_dir && -n $version && -n $architecture ]] || { usage >&2; exit 2; }
[[ $(uname -s) == Darwin ]] || fail 'macOS is required.'
[[ $version =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || fail 'Version must be numeric X.Y.Z without a v prefix.'
case $architecture in arm64|x86_64|universal) ;; *) fail 'Unsupported architecture.' ;; esac
for tool in codesign ditto hdiutil lipo plutil cmp mktemp; do need "$tool"; done
[[ $app == /* ]] || app="$PWD/$app"
[[ -d $app && ! -L $app && $app == *.app ]] || fail 'Input must be a nonsymlink app bundle.'
app="$(cd -P "$(dirname "$app")" && pwd)/$(basename "$app")"
info="$app/Contents/Info.plist"
binary="$app/Contents/MacOS/Cadence"
[[ -f $info && -f $binary && -x $binary && ! -L $binary ]] || fail 'App metadata or executable Cadence binary is missing.'
[[ $(plutil -extract CFBundleIdentifier raw -o - "$info") == dev.cadence.app ]] || fail 'Unexpected bundle identifier.'
[[ $(plutil -extract CFBundleExecutable raw -o - "$info") == Cadence ]] || fail 'Unexpected bundle executable.'
[[ $(plutil -extract CFBundleShortVersionString raw -o - "$info") == "$version" ]] || fail 'Bundle version does not match the requested version.'
actual=$(lipo -archs "$binary") || fail 'Cannot inspect executable architectures.'
read -r -a actual_architectures <<< "$actual"
if [[ $architecture == universal ]]; then
    [[ ${#actual_architectures[@]} == 2 && " $actual " == *' arm64 '* && " $actual " == *' x86_64 '* ]] || fail "Expected arm64 and x86_64; found: $actual"
else
    [[ ${#actual_architectures[@]} == 1 && ${actual_architectures[0]} == "$architecture" ]] || fail "Expected $architecture; found: $actual"
fi
codesign --verify --deep --strict --all-architectures "$app"
if [[ $release == true ]]; then
    need xcrun
    signature=$(codesign --display --verbose=4 "$app" 2>&1)
    [[ $signature == *'Authority=Developer ID Application: '* ]] || fail 'Release packaging requires a Developer ID Application signature.'
    xcrun stapler validate "$app" >&2
fi

[[ $output_dir == /* ]] || output_dir="$PWD/$output_dir"
mkdir -p "$output_dir"
output_dir=$(cd -P "$output_dir" && pwd)
suffix=-local
[[ $release == false ]] || suffix=
output="$output_dir/Cadence-Installer-$version-$architecture$suffix.dmg"
if [[ -e $output || -L $output ]]; then
    [[ $force == true ]] || fail "Output already exists (use --force to replace it): $output"
    [[ -f $output && ! -L $output ]] || fail 'Refusing to replace a directory, symlink, or nonregular output.'
fi

work=$(mktemp -d "$output_dir/.cadence-dmg.XXXXXX")
cleanup() {
    result=$?
    trap - EXIT
    rm -rf "$work" || result=1
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir "$work/image"
ditto --rsrc --extattr --qtn --acl "$app" "$work/image/Cadence.app"
ln -s /Applications "$work/image/Applications"
cp "$(cd "$(dirname "$0")/.." && pwd)/Resources/Install.txt" "$work/image/Install Cadence.txt"
codesign --verify --deep --strict --all-architectures "$work/image/Cadence.app"
sync

attempt=1
while :; do
    rm -f "$work/installer.dmg"
    if hdiutil create -quiet -nospotlight -fs HFS+ -format UDZO -volname Cadence \
        -srcfolder "$work/image" "$work/installer.dmg" >"$work/create.stdout" 2>"$work/create.stderr"; then
        break
    fi
    cat "$work/create.stdout" "$work/create.stderr" >&2
    # Compare the whole diagnostic, allowing only its normal optional final LF.
    if [[ $attempt -lt 3 && ! -s $work/create.stdout ]] && {
        cmp -s "$work/create.stderr" <(printf '%s\n' 'hdiutil: create failed - Resource busy') ||
        cmp -s "$work/create.stderr" <(printf '%s' 'hdiutil: create failed - Resource busy')
    }; then
        printf 'package-dmg: Resource busy, retrying (%s/3).\n' "$((attempt + 1))" >&2
        attempt=$((attempt + 1))
        sleep 2
    else
        fail "Disk image creation failed after $attempt attempt(s)."
    fi
done
[[ -f $work/installer.dmg && ! -L $work/installer.dmg ]] || fail 'hdiutil did not produce a regular disk image.'
hdiutil verify "$work/installer.dmg" >&2
if [[ $force == true ]]; then
    [[ ! -L $output && ! -d $output ]] || fail 'Output changed to a directory or symlink during packaging.'
    mv -f "$work/installer.dmg" "$output"
else
    # Both names are on the same filesystem. Exclusive linking preserves an
    # existing output even if another process created it after the first check.
    ln "$work/installer.dmg" "$output" || fail 'Output appeared during packaging; it was preserved.'
fi
printf '%s\n' "$output"

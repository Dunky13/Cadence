#!/bin/bash
# Checks the mounted installer and a temporary copy, without running user jobs.
set -euo pipefail
umask 077

fail() { printf 'check-dmg: %s\n' "$*" >&2; exit 1; }
usage() { printf '%s\n' 'Usage: check-dmg.sh IMAGE --architecture arm64|x86_64|universal [--version X.Y.Z] [--release]'; }
[[ $# -gt 0 ]] || { usage >&2; exit 2; }
[[ $1 != --help && $1 != -h ]] || { usage; exit 0; }
image=$1
shift
architecture='' version='' release=false
while [[ $# -gt 0 ]]; do
    case $1 in
        --architecture|--version)
            [[ $# -ge 2 && -n $2 && $2 != --* ]] || fail "Missing value for $1"
            case $1 in --architecture) architecture=$2 ;; --version) version=$2 ;; esac
            shift 2 ;;
        --release) release=true; shift ;;
        *) usage >&2; fail "Unknown argument: $1" ;;
    esac
done
[[ $(uname -s) == Darwin ]] || fail 'macOS is required.'
case $architecture in arm64|x86_64|universal) ;; *) fail 'Specify a supported architecture.' ;; esac
[[ $image == /* ]] || image="$PWD/$image"
[[ -f $image && ! -L $image ]] || fail 'Expected a regular disk image.'
for tool in codesign ditto hdiutil lipo plutil readlink mount mktemp; do
    command -v "$tool" >/dev/null 2>&1 || fail "Missing prerequisite: $tool"
done
if [[ $release == true ]]; then
    command -v xcrun >/dev/null 2>&1 || fail 'Missing prerequisite: xcrun'
    command -v spctl >/dev/null 2>&1 || fail 'Missing prerequisite: spctl'
    codesign --verify --strict "$image"
    image_signature=$(codesign --display --verbose=4 "$image" 2>&1)
    [[ $image_signature == *'Authority=Developer ID Application: '* ]] || fail 'Release image lacks a Developer ID Application signature.'
    xcrun stapler validate "$image"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$image"
fi
hdiutil verify "$image"
image="$(cd -P "$(dirname "$image")" && pwd)/$(basename "$image")"
work=$(mktemp -d "${TMPDIR:-/tmp}/cadence-dmg-check.XXXXXX")
work=$(cd -P "$work" && pwd)
mountpoint="$work/mounted"
attach_attempted=false

mounted_here() {
    local listing line
    listing=$(mount) || return 2
    while IFS= read -r line; do
        [[ $line != *" on $mountpoint ("* ]] || return 0
    done <<< "$listing"
    return 1
}
cleanup() {
    result=$?
    trap - EXIT
    if [[ $attach_attempted == true ]]; then
        if ! hdiutil detach "$mountpoint"; then
            mounted=0
            mounted_here || mounted=$?
            if [[ $mounted == 0 ]]; then
                # The mount point is newly created inside this private directory.
                # A forced detach is restricted to that confirmed owned mount.
                if ! hdiutil detach -force "$mountpoint"; then
                    printf 'check-dmg: Could not detach owned mount. Preserved workspace: %s\n' "$work" >&2
                    exit 1
                fi
            elif [[ $mounted != 1 ]]; then
                printf 'check-dmg: Cannot confirm mount cleanup. Preserved workspace: %s\n' "$work" >&2
                exit 1
            fi
        fi
    fi
    rm -rf "$work" || result=1
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir "$mountpoint" "$work/Applications"
attach_attempted=true
hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$mountpoint" "$image"
app="$mountpoint/Cadence.app"
[[ -d $app && ! -L $app ]] || fail 'Installer does not contain Cadence.app.'
[[ -L $mountpoint/Applications && $(readlink "$mountpoint/Applications") == /Applications ]] || fail 'Applications shortcut is missing or points elsewhere.'
info="$app/Contents/Info.plist"
binary="$app/Contents/MacOS/Cadence"
[[ -f $info && -f $binary && -x $binary && ! -L $binary ]] || fail 'App metadata or executable Cadence binary is missing.'
[[ $(plutil -extract CFBundleIdentifier raw -o - "$info") == dev.cadence.app ]] || fail 'Unexpected bundle identifier.'
[[ $(plutil -extract CFBundleExecutable raw -o - "$info") == Cadence ]] || fail 'Unexpected executable name.'
actual_version=$(plutil -extract CFBundleShortVersionString raw -o - "$info")
[[ $actual_version =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || fail 'Invalid app version.'
[[ -z $version || $version == "$actual_version" ]] || fail 'App version does not match the requested version.'
actual=$(lipo -archs "$binary")
read -r -a actual_architectures <<< "$actual"
if [[ $architecture == universal ]]; then
    [[ ${#actual_architectures[@]} == 2 && " $actual " == *' arm64 '* && " $actual " == *' x86_64 '* ]] || fail "Expected universal executable; found: $actual"
else
    [[ ${#actual_architectures[@]} == 1 && ${actual_architectures[0]} == "$architecture" ]] || fail "Expected $architecture; found: $actual"
fi
codesign --verify --deep --strict --all-architectures "$app"
ditto --rsrc --extattr --qtn --acl "$app" "$work/Applications/Cadence.app"
codesign --verify --deep --strict --all-architectures "$work/Applications/Cadence.app"
if [[ $release == true ]]; then
    app_signature=$(codesign --display --verbose=4 "$app" 2>&1)
    [[ $app_signature == *'Authority=Developer ID Application: '* ]] || fail 'Release app lacks a Developer ID Application signature.'
    xcrun stapler validate "$app"
    xcrun stapler validate "$work/Applications/Cadence.app"
    spctl --assess --type execute --verbose=2 "$work/Applications/Cadence.app"
fi
printf 'Verified Cadence %s (%s): mounted layout and copied app signature.\n' "$actual_version" "$architecture"

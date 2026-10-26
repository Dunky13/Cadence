#!/bin/bash
# Check the installed copy against the exact prepared, stapled app (including build).
set -euo pipefail
umask 077
fail() { printf 'verify-apple-dmg-binding: %s\n' "$*" >&2; exit 1; }
# shellcheck source=scripts/apple-stage-state.sh
source "$(dirname "$0")/apple-stage-state.sh"
[[ $# == 2 ]] || fail 'Usage: verify-apple-dmg-binding.sh IMAGE EXPECTED_APP'
image=$1 expected_app=$2
apple_regular "$image"
expected_tree=$(apple_tree_sha "$expected_app")
work=$(mktemp -d "${TMPDIR:-/tmp}/cadence-image-binding.XXXXXX")
work=$(cd "$work" && pwd -P)
mountpoint="$work/mounted"
attach_attempted=false
cleanup() {
    result=$?; trap - EXIT
    if [[ $attach_attempted == true ]]; then
        if ! hdiutil detach "$mountpoint"; then
            # Only force-detach a confirmed mount at our unique private path.
            listing=$(mount) || { printf 'Cannot inspect owned mount; retained: %s\n' "$work" >&2; exit 1; }
            if [[ $listing == *" on $mountpoint ("* ]]; then
                hdiutil detach -force "$mountpoint" || { printf 'Cannot detach owned mount; retained: %s\n' "$work" >&2; exit 1; }
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
[[ -d $mountpoint/Cadence.app && ! -L $mountpoint/Cadence.app ]] || fail 'Missing installer app.'
ditto --rsrc --extattr --qtn --acl "$mountpoint/Cadence.app" "$work/Applications/Cadence.app"
[[ $(apple_tree_sha "$work/Applications/Cadence.app") == "$expected_tree" ]] || fail 'Installed app differs from the bound version/build/signature.'
codesign --verify --deep --strict --all-architectures "$work/Applications/Cadence.app"
"$(dirname "$0")/validate-apple-ticket.sh" "$work/Applications/Cadence.app"
spctl --assess --type execute --verbose=4 "$work/Applications/Cadence.app"

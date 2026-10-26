#!/bin/bash
# Local-only final-byte, installed-app, signature, ticket, and Gatekeeper gates.
set -euo pipefail
umask 077
fail() { printf 'verify-apple-distribution: %s\n' "$*" >&2; exit 1; }
script_dir=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/apple-stage-state.sh
source "$script_dir/apple-stage-state.sh"
[[ $# == 5 ]] || fail 'Usage: verify-apple-distribution.sh DIRECTORY BINDING_JSON EXPECTED_APP APP_NAME DMG_NAME'
directory=$1 binding=$2 expected_app=$3 app_name=$4 dmg_name=$5
[[ -d $directory && ! -L $directory ]] || fail 'Expected a regular candidate directory.'
shopt -s nullglob dotglob
entries=("$directory/"*)
[[ ${#entries[@]} == 4 ]] || fail 'Candidate must contain exactly four public files.'
for name in "$app_name" "$dmg_name" distribution.json SHA256SUMS; do apple_regular "$directory/$name"; done
actual=''
while read -r digest name extra; do
    [[ $digest =~ ^[0-9a-f]{64}$ && -z $extra ]] || fail 'Malformed checksum manifest.'
    case $name in "$app_name"|"$dmg_name"|distribution.json) ;; *) fail 'Unexpected checksum path.' ;; esac
    actual+="$name"$'\n'
done < "$directory/SHA256SUMS"
[[ $(printf '%s' "$actual" | LC_ALL=C sort) == "$(printf '%s\n' "$app_name" "$dmg_name" distribution.json | LC_ALL=C sort)" ]] || fail 'Checksum entries differ from expected public files.'
(cd "$directory" && shasum -a 256 --check SHA256SUMS)
jq -se --argjson binding "$binding" --arg app "$app_name" --arg dmg "$dmg_name" '
    length == 1 and (.[0] | .schema == "cadence/distribution/v1"
    and ({source_commit,version,build_number,bundle_id,architecture,team_id,origin} == $binding)
    and .app_archive == $app and .installer == $dmg and .signing == "Developer ID"
    and .notarization == "Accepted" and .tickets == "stapled and validated")' "$directory/distribution.json" >/dev/null \
    || fail 'Distribution manifest differs from the bound candidate.'
work=$(mktemp -d "${TMPDIR:-/tmp}/cadence-distribution-check.XXXXXX")
trap 'rm -rf "$work"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
ditto -x -k "$directory/$app_name" "$work"
[[ -d $work/Cadence.app && ! -L $work/Cadence.app ]] || fail 'Final app ZIP is missing the app.'
[[ $(apple_tree_sha "$work/Cadence.app") == "$(apple_tree_sha "$expected_app")" ]] || fail 'Final ZIP app differs from the retained stapled app.'
codesign --verify --deep --strict --all-architectures "$work/Cadence.app"
"$(dirname "$0")/validate-apple-ticket.sh" "$work/Cadence.app"
spctl --assess --type execute --verbose=4 "$work/Cadence.app"
"$script_dir/check-dmg.sh" "$directory/$dmg_name" --architecture "$(jq -r .architecture <<< "$binding")" \
    --version "$(jq -r .version <<< "$binding")" --release --launch-demo
"$script_dir/verify-apple-dmg-binding.sh" "$directory/$dmg_name" "$expected_app"

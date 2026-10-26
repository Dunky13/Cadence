#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/cadence-checkpoint-test.XXXXXX")
trap 'rm -rf "$work"' EXIT
export SOURCE_COMMIT=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa BUILD_CI_RUN_ID=100 BUILD_ARTIFACT_ID=300
export BUILD_ARTIFACT_DIGEST=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
export GITHUB_RUN_ID=200 GITHUB_RUN_ATTEMPT=1
mkdir "$work/state"
printf 'signed bytes\n' > "$work/state/binary"
chmod +x "$work/state/binary"
printf '{"ci_run":{"id":"200","attempt":"1"},"attempted":false,"restored":false}\n' > "$work/state/app-universal-receipt.json"
helper="$root/scripts/checkpoint-state.sh"
bash "$helper" pack "$work/state" "$work/envelope"
bash "$helper" restore "$work/restored" "$work/envelope"
cmp "$work/state/binary" "$work/restored/binary"
[[ -x $work/restored/binary ]]
jq -e '.restored == true and .attempted == false and .ci_run.id == "200" and .ci_run.attempt == "1"' "$work/restored/app-universal-receipt.json" >/dev/null
if SOURCE_COMMIT=cccccccccccccccccccccccccccccccccccccccc bash "$helper" restore "$work/wrong-source" "$work/envelope" >/dev/null 2>&1; then exit 1; fi
if BUILD_ARTIFACT_ID=301 bash "$helper" restore "$work/wrong-artifact" "$work/envelope" >/dev/null 2>&1; then exit 1; fi
printf 'tampered bytes' >> "$work/envelope/state.tar.gz"
if bash "$helper" restore "$work/tampered" "$work/envelope" >/dev/null 2>&1; then exit 1; fi
ln -s /tmp "$work/state/unsafe"
if bash "$helper" pack "$work/state" "$work/unsafe" >/dev/null 2>&1; then exit 1; fi
rm "$work/state/unsafe"
printf 'private' > "$work/state/key.p8"
if bash "$helper" pack "$work/state" "$work/private" >/dev/null 2>&1; then exit 1; fi
printf '7 checkpoint contracts passed (synthetic only).\n'

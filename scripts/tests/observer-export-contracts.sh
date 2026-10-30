#!/bin/bash
# Synthetic private xcresult exports through the real allowlist collector.
set -euo pipefail
umask 077
root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/cadence-export-contracts.XXXXXX")
trap 'rm -r "$work"' EXIT
mkdir "$work/bin"
cat > "$work/bin/xcrun" <<'STUB'
#!/bin/bash
set -euo pipefail
[[ $# == 7 && $1 == xcresulttool && $2 == export && $3 == attachments && $4 == --path && $6 == --output-path ]] || exit 98
[[ ${FIXTURE_EXPORT_FAILURE:-false} != true ]] || exit 71
cp -R "$FIXTURE/export/." "$7/"
if [[ ${FIXTURE_LINK:-false} == true ]]; then
    rm "$7/first.json"
    ln -s "$FIXTURE/export/first.json" "$7/first.json"
fi
STUB
chmod +x "$work/bin/xcrun"
nonce=AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA
cases=0
new_case() {
    cases=$((cases+1)); fixture="$work/case-$cases"
    mkdir "$fixture" "$fixture/result.xcresult" "$fixture/export" "$fixture/evidence"
    jq -n --arg nonce "$nonce" '[{testIdentifier:"ObserverTests/testObserveExistingLaunch()",attachments:[
        {suggestedHumanReadableName:("CadenceObserver-"+$nonce+"-stage-0_0_BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB.json"),exportedFileName:"first.json"},
        {suggestedHumanReadableName:("CadenceObserver-"+$nonce+"-stage-7_0_CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC.json"),exportedFileName:"last.json"},
        {suggestedHumanReadableName:("CadenceObserver-"+$nonce+"-session_0_DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD.txt"),exportedFileName:"session.txt"},
        {suggestedHumanReadableName:"Automatic-Screenshot_0_EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE.png",exportedFileName:"private.png"}]}]' > "$fixture/export/manifest.json"
    printf '{"schema":"cadence/ui-bootstrap-stage/v1","stage":"protocolPathsReceived","read_only":true,"runtime_acceptance":false}\n' > "$fixture/export/first.json"
    printf '{"schema":"cadence/ui-bootstrap-stage/v1","stage":"ready","read_only":true,"runtime_acceptance":false}\n' > "$fixture/export/last.json"
    printf 'Observed: synthetic only\n' > "$fixture/export/session.txt"
    printf 'EXCLUDED synthetic private desktop/env marker\n' > "$fixture/export/private.png"
}
mutate() { jq "$1" "$fixture/export/manifest.json" > "$fixture/changed.json"; mv "$fixture/changed.json" "$fixture/export/manifest.json"; }
invoke() {
    result=0
    PATH="$work/bin:$PATH" FIXTURE="$fixture" "$root/scripts/collect-observer-evidence.sh" "$fixture/result.xcresult" "$fixture/evidence" "$nonce" > "$fixture/console" 2>&1 || result=$?
}
check_failure() {
    local files=("$fixture/evidence/"*)
    [[ $result != 0 && ${#files[@]} == 1 && ! -e ${files[0]} && ! -L ${files[0]} ]] || { cat "$fixture/console" >&2; exit 1; }
    local scratch=("$fixture/"observer-export.*)
    [[ ! -e ${scratch[0]} ]] || exit 1
}
new_case; invoke; [[ $result == 0 ]]
jq -e '.stage=="ready" and .runtime_acceptance==false' "$fixture/evidence/session-stage.json" >/dev/null
files=("$fixture/evidence/"*)
[[ ${#files[@]} == 2 && ! -e $fixture/evidence/private.png ]]
for change in '.[0].testIdentifier="Foreign/test()"' '.[0].attachments[0].suggestedHumanReadableName |= sub("AAAAAAAA";"11111111")' '.[0].attachments[0].exportedFileName="../outside.json"' '.[0].attachments[0].suggestedHumanReadableName |= sub("json$";"txt")' '.[0].attachments += [.[0].attachments[0]]'; do
    new_case; mutate "$change"; invoke; check_failure
done
new_case; printf 'not JSON\n' > "$fixture/export/first.json"; invoke; check_failure
new_case; jq '.stage="ready"' "$fixture/export/first.json" > "$fixture/changed.json"; mv "$fixture/changed.json" "$fixture/export/first.json"; invoke; check_failure
new_case; jq '.environment="EXCLUDED synthetic secret"' "$fixture/export/first.json" > "$fixture/changed.json"; mv "$fixture/changed.json" "$fixture/export/first.json"; invoke; check_failure
new_case; perl -e 'print " " x 1048577' > "$fixture/export/manifest.json"; invoke; check_failure
new_case; perl -e 'print "Observed:" . ("x" x 4096)' > "$fixture/export/session.txt"; invoke; check_failure
new_case; mutate '.[0].attachments += [{suggestedHumanReadableName:"CadenceObserver-AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA-system-0-100-0_0_FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF.png",exportedFileName:"invalid.png"}]'
printf 'not a PNG\n' > "$fixture/export/invalid.png"; invoke; check_failure
new_case; export FIXTURE_LINK=true; invoke; unset FIXTURE_LINK; check_failure
new_case; export FIXTURE_EXPORT_FAILURE=true; invoke; unset FIXTURE_EXPORT_FAILURE; check_failure
new_case; mutate '.[0].attachments |= map(select(.suggestedHumanReadableName | startswith("Automatic")))'; invoke; check_failure
new_case; printf 'retain\n' > "$fixture/evidence/session-stage.json"; invoke
[[ $result != 0 && $(cat "$fixture/evidence/session-stage.json") == retain && ! -e $fixture/evidence/session.txt ]]
new_case; mutate '.[0].attachments += [(.[0].attachments[2] | .exportedFileName="hold.txt" | .suggestedHumanReadableName |= sub("DDDDDDDD";"FFFFFFFF"))]'
printf 'HOLD: synthetic failure\n' > "$fixture/export/hold.txt"; invoke; [[ $result == 0 ]]
grep -qx 'HOLD: synthetic failure' "$fixture/evidence/session.txt"
printf '%s observer export contracts passed; unrelated/private artifacts excluded.\n' "$cases"

#!/bin/bash
# Real stop/finish/export with owned CLI clients and an inert monotonic-clock edge.
# No XCTest, native UI, product launch, Apple provider or permission mutation.
set -euo pipefail
umask 077
root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/cadence-finalization.XXXXXX")
trap 'rm -r -- "$work"' EXIT
mkdir "$work/bin"
cat > "$work/bin/xcrun" <<'STUB'
#!/bin/bash
set -euo pipefail
[[ $# == 7 && $1 == xcresulttool && $2 == export && $3 == attachments && $4 == --path && $6 == --output-path ]]
[[ -d $5/export ]]
cp -R "$5/export/." "$7/"
STUB
cat > "$work/bin/xcodebuild" <<'STUB'
#!/bin/bash
set -euo pipefail
[[ $1 == test-without-building && $2 == -xctestrun ]]
if [[ $FINALIZE_CASE == hung ]]; then trap '' TERM; fi
if [[ $FINALIZE_CASE != natural-no-done ]]; then
    nonce=$FINALIZE_NONCE
    if [[ $FINALIZE_CASE == foreign-done ]]; then nonce=BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB; fi
    printf 'CadenceObserverDone:%s:EndCadenceObserver\n' "$nonce"
    : > "$FINALIZE_FIXTURE/announced"
    if [[ $FINALIZE_CASE != completed-expired ]]; then
        while [[ ! -e $FINALIZE_FIXTURE/release ]]; do /bin/sleep 0.01; done
    fi
else
    : > "$FINALIZE_FIXTURE/announced"
fi
mkdir "$FINALIZE_FIXTURE/control/result.xcresult"
cp -R "$FINALIZE_FIXTURE/pending/export" "$FINALIZE_FIXTURE/control/result.xcresult/"
: > "$FINALIZE_FIXTURE/finished"
if [[ $FINALIZE_CASE == failed ]]; then exit 65; fi
STUB
chmod +x "$work/bin/xcrun" "$work/bin/xcodebuild"
awk '/^    observer_finalization_deadline=\$\(/ {print; count++} END {if(count!=1) exit 1}' \
    "$root/scripts/launch-ui-observer.sh" > "$work/deadline.sh"
cat > "$work/driver.sh" <<'DRIVER'
#!/bin/bash
set -uo pipefail
source "$OBSERVER_SCRIPT"
observer_control="$FINALIZE_FIXTURE/control"
observer_plan="$FINALIZE_FIXTURE/plan.xctestrun"
observer_id=$FINALIZE_NONCE
observer_ready=true
observer_evidence_owned=true
observer_cleanup_failed=false
observer_finalization_result=0
observer_bridge_pid=''
observer_bridge_result=0
observer_launcher=''
fixture_client_pid=''
cleanup_fixture() {
    fixture_pid=${observer_launcher:-$fixture_client_pid}
    if [[ -n $fixture_pid ]]; then
        arguments=$(ps -p "$fixture_pid" -o command= 2>/dev/null) || arguments=''
        if [[ $arguments == *"$FINALIZE_CLIENT test-without-building -xctestrun $observer_plan"* ]]; then
            builtin kill -KILL "$fixture_pid" 2>/dev/null || true
        fi
        wait "$fixture_pid" 2>/dev/null || true
    fi
}
trap cleanup_fixture EXIT
trap 'exit 124' ALRM
source "$DEADLINE_SCRIPT" || exit 1
# Exercise the real monotonic budget before substituting the fixture edge.
launch_ui_client_time_left || exit 1
saved_deadline=$observer_finalization_deadline
for invalid in '' NaN infinity -1 0 999999999999999999999999999999999999999999; do
    observer_finalization_deadline=$invalid
    if launch_ui_client_time_left; then exit 1; fi
done
observer_finalization_deadline=$(/usr/bin/perl -MTime::HiRes=clock_gettime,CLOCK_MONOTONIC -e 'print clock_gettime(CLOCK_MONOTONIC)+80')
if launch_ui_client_time_left; then exit 1; fi
observer_finalization_deadline=$saved_deadline
launch_ui_client_time_left() {
    printf 'budget\n' >> "$FINALIZE_FIXTURE/budget"
    if [[ $FINALIZE_CASE == hung || $FINALIZE_CASE == completed-expired ]]; then return 1; fi
    : > "$FINALIZE_FIXTURE/release"
    if [[ $FINALIZE_CASE == late-zero ]]; then
        for ((probe=0; probe<100; probe++)); do
            [[ ! -e $FINALIZE_FIXTURE/finished ]] || break
            /bin/sleep 0.01
        done
        [[ -e $FINALIZE_FIXTURE/finished ]]
        /bin/sleep 0.05
        return 1
    fi
}
launch_ui_owned_helpers() { return 0; }
sleep() { /bin/sleep 0.04; }
kill() {
    if [[ $* == '-s '* ]]; then printf '%s\n' "$*" >> "$FINALIZE_FIXTURE/signals"; fi
    builtin kill "$@"
}
# The fixture's six-second guard is not a production deadline.
perl -e 'alarm 6; exec @ARGV; die;' -- "$FINALIZE_CLIENT" test-without-building -xctestrun "$observer_plan" -destination platform=macOS \
    > "$observer_control/xcode-private.log" 2>&1 &
observer_launcher=$!
fixture_client_pid=$observer_launcher
LAUNCH_UI_BUILD_DIR="$FINALIZE_FIXTURE/build"
LAUNCH_UI_ALLOW_NORMAL_OPEN=true
export LAUNCH_UI_EVIDENCE_DIR="$FINALIZE_FIXTURE/evidence"
launch_ui_status READY 'Synthetic initialized client; no UI.'
# Synchronize the inert initialized client, rather than spending its accelerated
# stop grace on unrelated process-start scheduling.
for ((probe=0; probe<100; probe++)); do
    [[ ! -e $FINALIZE_FIXTURE/announced ]] || break
    /bin/sleep 0.01
done
[[ -e $FINALIZE_FIXTURE/announced ]] || exit 1
if [[ $FINALIZE_CASE == completed-expired ]]; then
    for ((probe=0; probe<100; probe++)); do
        [[ ! -e $FINALIZE_FIXTURE/finished ]] || break
        /bin/sleep 0.01
    done
    [[ -e $FINALIZE_FIXTURE/finished ]] || exit 1
    /bin/sleep 0.05
fi
result=0
launch_ui_finish 0 || result=$?
printf 'case=%s result=%s test=%s cleanup=%s finalization=%s\n' "$FINALIZE_CASE" "$result" "${observer_test_result:-unavailable}" "$observer_cleanup_failed" "$observer_finalization_result"
cat "$LAUNCH_UI_EVIDENCE_DIR/status.json"
cat "$observer_control/xcode-private.log"
case $FINALIZE_CASE in
    delayed|natural-no-done)
        [[ $result == 0 && $observer_test_result == 0 && $observer_finalization_result == 0 ]] || exit 1
        jq -e '.status == "OBSERVED" and .original_startup_exit == "0"' "$LAUNCH_UI_EVIDENCE_DIR/status.json" >/dev/null || exit 1
        [[ ! -s $FINALIZE_FIXTURE/signals && -s $LAUNCH_UI_EVIDENCE_DIR/first-open.json ]] || exit 1 ;;
    failed)
        [[ $result == 1 && $observer_test_result == 65 && $observer_finalization_result == 0 ]] || exit 1
        [[ ! -s $FINALIZE_FIXTURE/signals && -s $LAUNCH_UI_EVIDENCE_DIR/first-open.json ]] || exit 1 ;;
    hung|late-zero|completed-expired)
        [[ $result == 1 && $observer_finalization_result == 1 ]] || exit 1
        jq -e '.status == "HOLD" and (.reason | contains("finalization exit 1"))' "$LAUNCH_UI_EVIDENCE_DIR/status.json" >/dev/null || exit 1
        if [[ $FINALIZE_CASE != hung ]]; then [[ $observer_test_result == 0 ]] || exit 1; fi ;;
    foreign-done)
        [[ $result == 1 && $observer_test_result != 0 && ! -s $FINALIZE_FIXTURE/budget ]] || exit 1 ;;
esac
[[ $observer_cleanup_failed == false && -z $observer_launcher ]] || exit 1
if builtin kill -0 "$fixture_client_pid" 2>/dev/null; then exit 1; fi
if [[ $FINALIZE_CASE == natural-no-done ]]; then [[ ! -s $FINALIZE_FIXTURE/budget ]] || exit 1; fi
DRIVER
cases=0
for shell_mode in -e +e; do
    for scenario in delayed failed hung late-zero completed-expired foreign-done natural-no-done; do
        fixture="$work/$shell_mode-$scenario"
        mkdir -p "$fixture/control" "$fixture/evidence" "$fixture/pending/export" "$fixture/build"
        nonce=AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA
        printf 'SYNTHETIC plan\n' > "$fixture/plan.xctestrun"
        printf 'Observed: SYNTHETIC finalized client only\n' > "$fixture/pending/export/session.txt"
        jq -n --arg nonce "$nonce" '{action:"verified-normal-open",observation_id:$nonce}' > "$fixture/pending/export/open.json"
        jq -n --arg nonce "$nonce" '{binding:{bundleID:"dev.cadence.app",teamID:"SYNTHETIC0",version:"0.2.0",build:"15",executableSHA256:"synthetic",copiedPath:"/inert/Cadence.app",snapshotPath:"/inert/startup.png",observationID:$nonce},launcherPID:900,capturedUTC:"synthetic",ownedProcesses:[],windows:[],unavailableOwners:[],limited:false,complete:true,interpretation:"Synthetic only"}' > "$fixture/pending/export/observation.json"
        jq -n --arg nonce "$nonce" '[{testIdentifier:"ObserverTests/testObserveExistingLaunch()",attachments:[
            {suggestedHumanReadableName:("CadenceObserver-"+$nonce+"-session_0_CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC.txt"),exportedFileName:"session.txt"},
            {suggestedHumanReadableName:("CadenceObserver-"+$nonce+"-first-open_0_CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC.json"),exportedFileName:"open.json"},
            {suggestedHumanReadableName:("CadenceObserver-"+$nonce+"-observation-0_0_CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC.json"),exportedFileName:"observation.json"}]}]' > "$fixture/pending/export/manifest.json"
        PATH="$work/bin:$PATH" OBSERVER_SCRIPT="$root/scripts/launch-ui-observer.sh" DEADLINE_SCRIPT="$work/deadline.sh" \
            FINALIZE_CASE="$scenario" FINALIZE_FIXTURE="$fixture" FINALIZE_NONCE="$nonce" FINALIZE_CLIENT="$work/bin/xcodebuild" \
            perl -e 'alarm 8; exec @ARGV; die;' -- /bin/bash "$shell_mode" "$work/driver.sh" > "$fixture/private.log" 2>&1 || {
                printf 'Finalization contract failed: %s %s\n' "$shell_mode" "$scenario" >&2
                cat "$fixture/private.log" >&2; exit 1;
            }
        cases=$((cases + 1))
    done
done
printf 'Observer finalization: %s owned CLI/export/budget contracts passed; no native UI or provider calls.\n' "$cases"

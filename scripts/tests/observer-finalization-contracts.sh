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
[[ $# == 7 && $1 == xcresulttool && $2 == export && $3 == attachments && $4 == --path && $6 == --output-path ]] || exit 2
[[ -d $5/export ]] || exit 2
if [[ $FINALIZE_CASE == collection-cancelled ]]; then kill -s TERM "$FINALIZE_DRIVER_PID"; fi
cp -R "$5/export/." "$7/"
STUB
cat > "$work/bin/xcodebuild" <<'STUB'
#!/bin/bash
set -euo pipefail
[[ $1 == test-without-building && $2 == -xctestrun ]] || exit 2
if [[ $FINALIZE_CASE == hung ]]; then trap '' TERM; fi
case $FINALIZE_CASE in
    natural-no-done|zombie-unacknowledged) ;;
    *)
        nonce=$FINALIZE_NONCE
        if [[ $FINALIZE_CASE == foreign-done ]]; then nonce=BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB; fi
        printf 'CadenceObserverDone:%s:EndCadenceObserver\n' "$nonce" ;;
esac
: > "$FINALIZE_FIXTURE/announced"
case $FINALIZE_CASE in
    natural-no-done|completed-expired|completed-cancelled) ;;
    *) while [[ ! -e $FINALIZE_FIXTURE/release ]]; do /bin/sleep 0.01; done ;;
esac
# Outlive the accelerated poll so a missed zombie branch is observable.
case $FINALIZE_CASE in zombie-*) /bin/sleep 0.3 ;; esac
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
        arguments=$(/bin/ps -p "$fixture_pid" -o command= 2>/dev/null) || arguments=''
        if [[ $arguments == *"$FINALIZE_CLIENT test-without-building -xctestrun $observer_plan"* ]]; then
            builtin kill -KILL "$fixture_pid" 2>/dev/null || true
        fi
        wait "$fixture_pid" 2>/dev/null || true
    fi
}
trap cleanup_fixture EXIT
trap 'exit 124' ALRM
source "$DEADLINE_SCRIPT" || exit 1
result=0
export FINALIZE_DRIVER_PID=$$
eval "$(sed -n "s/^    \(trap '.*observer_cancelled=true' [A-Z]*\)$/\1/p" "$VERIFIER_SCRIPT")"
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
    printf '%s\n' "$observer_finalization_deadline" >> "$FINALIZE_FIXTURE/budget"
    case $FINALIZE_CASE in
        hung|completed-expired) return 1 ;;
        expires-polling) [[ $(wc -l < "$FINALIZE_FIXTURE/budget") -lt 2 ]]; return ;;
        # Deliver a real signal through the verifier's own cleanup-phase traps.
        cancelled-*) builtin kill -s "${FINALIZE_CASE#cancelled-}" "$$"; return 0 ;;
        zombie-wait) return 0 ;;
    esac
    : > "$FINALIZE_FIXTURE/release"
    if [[ $FINALIZE_CASE == late-zero ]]; then
        for ((probe=0; probe<100; probe++)); do
            [[ ! -e $FINALIZE_FIXTURE/finished ]] || break
            /bin/sleep 0.01
        done
        [[ -e $FINALIZE_FIXTURE/finished ]] || exit 1
        /bin/sleep 0.05
        return 1
    fi
}
case $FINALIZE_CASE in
    zombie-*)
        ps() {
            : > "$FINALIZE_FIXTURE/release"
            case $* in
                *stat=*) printf 'Z\n' ;;
                *command=*) printf '(xcodebuild)\n' ;;
            esac
        } ;;
esac
launch_ui_owned_helpers() {
    [[ -e $FINALIZE_FIXTURE/finished ]] || : > "$FINALIZE_FIXTURE/helpers-before-finish"
    return 0
}
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
if [[ $FINALIZE_CASE == completed-expired || $FINALIZE_CASE == completed-cancelled ]]; then
    for ((probe=0; probe<100; probe++)); do
        [[ ! -e $FINALIZE_FIXTURE/finished ]] || break
        /bin/sleep 0.01
    done
    [[ -e $FINALIZE_FIXTURE/finished ]] || exit 1
    /bin/sleep 0.05
fi
if [[ $FINALIZE_CASE == completed-cancelled ]]; then observer_cancelled=true; fi
finish_result=0
launch_ui_finish 0 || finish_result=$?
if [[ $FINALIZE_CASE == cancelled-* ]]; then [[ $result != 0 && $observer_cancelled == true ]] || exit 1; fi
result=$finish_result
printf 'case=%s result=%s test=%s cleanup=%s finalization=%s\n' "$FINALIZE_CASE" "$result" "${observer_test_result:-unavailable}" "$observer_cleanup_failed" "$observer_finalization_result"
cat "$LAUNCH_UI_EVIDENCE_DIR/status.json"
cat "$observer_control/xcode-private.log"
case $FINALIZE_CASE in
    delayed|natural-no-done|zombie-wait|zombie-unacknowledged)
        [[ $result == 0 && $observer_test_result == 0 && $observer_finalization_result == 0 ]] || exit 1
        jq -e '.status == "OBSERVED" and .original_startup_exit == "0"' "$LAUNCH_UI_EVIDENCE_DIR/status.json" >/dev/null || exit 1
        [[ ! -s $FINALIZE_FIXTURE/signals && -s $LAUNCH_UI_EVIDENCE_DIR/first-open.json ]] || exit 1 ;;
    failed)
        [[ $result == 1 && $observer_test_result == 65 && $observer_finalization_result == 0 ]] || exit 1
        [[ ! -s $FINALIZE_FIXTURE/signals && -s $LAUNCH_UI_EVIDENCE_DIR/first-open.json ]] || exit 1 ;;
    hung|late-zero|completed-expired|completed-cancelled|collection-cancelled|expires-polling|cancelled-*)
        [[ $result == 1 && $observer_finalization_result == 1 ]] || exit 1
        jq -e '.status == "HOLD" and (.reason | contains("finalization exit 1"))' "$LAUNCH_UI_EVIDENCE_DIR/status.json" >/dev/null || exit 1
        case $FINALIZE_CASE in
            late-zero|completed-expired|completed-cancelled|collection-cancelled) [[ $observer_test_result == 0 ]] || exit 1 ;;
            expires-polling) [[ -s $FINALIZE_FIXTURE/signals && $(wc -l < "$FINALIZE_FIXTURE/budget") -eq 2 ]] || exit 1 ;;
            cancelled-*) [[ -s $FINALIZE_FIXTURE/signals && $(wc -l < "$FINALIZE_FIXTURE/budget") -eq 1 ]] || exit 1 ;;
        esac ;;
    foreign-done)
        [[ $result == 1 && $observer_test_result != 0 && ! -s $FINALIZE_FIXTURE/budget ]] || exit 1 ;;
esac
# The deadline stamped at attachment is never replaced at Done or cleanup.
[[ ! -s $FINALIZE_FIXTURE/budget || $(sort -u "$FINALIZE_FIXTURE/budget") == "$saved_deadline" ]] || exit 1
case $FINALIZE_CASE in
    # The client's real exit is reaped before any helper teardown.
    delayed|failed|zombie-wait) [[ ! -e $FINALIZE_FIXTURE/helpers-before-finish ]] || exit 1 ;;
esac
if [[ $FINALIZE_CASE == zombie-wait ]]; then [[ $(wc -l < "$FINALIZE_FIXTURE/budget") -eq 2 ]] || exit 1; fi
[[ $observer_cleanup_failed == false && -z $observer_launcher ]] || exit 1
if builtin kill -0 "$fixture_client_pid" 2>/dev/null; then exit 1; fi
case $FINALIZE_CASE in natural-no-done|zombie-unacknowledged) [[ ! -s $FINALIZE_FIXTURE/budget ]] || exit 1 ;; esac
DRIVER
# Exit-phase traps cannot run in the driver, so pin their flag here.
[[ $(grep -cE "^trap 'observer_cancelled=true; exit [0-9]+' (HUP|INT|TERM)$" "$root/scripts/verify-demo-startup.sh") == 3 ]] || exit 1
# A failed stamp must leave an empty deadline and continue into owned setup.
grep -q "|| observer_finalization_deadline=''$" "$work/deadline.sh"
cases=0
for shell_mode in -e +e; do
    for scenario in delayed failed hung late-zero completed-expired foreign-done natural-no-done expires-polling cancelled-HUP cancelled-INT cancelled-TERM completed-cancelled collection-cancelled zombie-wait zombie-unacknowledged; do
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
        PATH="$work/bin:$PATH" OBSERVER_SCRIPT="$root/scripts/launch-ui-observer.sh" VERIFIER_SCRIPT="$root/scripts/verify-demo-startup.sh" DEADLINE_SCRIPT="$work/deadline.sh" \
            FINALIZE_CASE="$scenario" FINALIZE_FIXTURE="$fixture" FINALIZE_NONCE="$nonce" FINALIZE_CLIENT="$work/bin/xcodebuild" \
            perl -e 'alarm 8; exec @ARGV; die;' -- /bin/bash "$shell_mode" "$work/driver.sh" > "$fixture/private.log" 2>&1 || {
                printf 'Finalization contract failed: %s %s\n' "$shell_mode" "$scenario" >&2
                cat "$fixture/private.log" >&2; exit 1;
            }
        cases=$((cases + 1))
    done
done
printf 'Observer finalization: %s owned CLI/export/budget contracts passed; no native UI or provider calls.\n' "$cases"

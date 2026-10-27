#!/bin/bash
# Sourced optional telemetry adapter. No UI actions or security configuration.
# Private xcodebuild logs/xctestrun/control files never enter the evidence artifact.

launch_ui_status() {
    [[ ${observer_evidence_owned:-false} == true && -n ${LAUNCH_UI_EVIDENCE_DIR:-} && -d $LAUNCH_UI_EVIDENCE_DIR ]] || return 0
    jq -n --arg status "$1" --arg reason "$2" --arg result "${3:-pending}" \
        '{status:$status,reason:$reason,original_startup_exit:$result,read_only:true,runtime_acceptance:false}' \
        > "$LAUNCH_UI_EVIDENCE_DIR/status.json"
}

launch_ui_owned_helpers() {
    local listing pid executable
    listing=$(ps -axo pid=,comm=) || return 1
    while read -r pid executable; do
        if [[ $pid =~ ^[1-9][0-9]*$ &&
            ( $executable == "$LAUNCH_UI_BUILD_DIR/Build/Products/Debug/LaunchUIObserverTests-Runner.app/Contents/MacOS/LaunchUIObserverTests-Runner" ||
              $executable == "$LAUNCH_UI_BUILD_DIR/Build/Products/Debug/LaunchUIFixture.app/Contents/MacOS/LaunchUIFixture" ) ]]; then
            printf '%s\n' "$pid"
        fi
    done <<< "$listing"
}

launch_ui_stop() {
    local cleanup_result=0 helpers='' signal pid state='' arguments=''
    [[ -n ${observer_control:-} ]] || return 0
    : > "$observer_control/stop" || cleanup_result=1
    [[ -n ${observer_launcher:-} ]] || return "$cleanup_result"
    for ((observer_wait=0; observer_wait<5; observer_wait++)); do
        if ! kill -0 "$observer_launcher" 2>/dev/null; then break; fi
        sleep 1 || cleanup_result=1
    done
    for signal in TERM KILL; do
        if helpers=$(launch_ui_owned_helpers); then
            while read -r pid; do
                [[ -n $pid ]] || continue
                # Revalidate ownership immediately before signaling.
                arguments=$(ps -p "$pid" -o comm= 2>/dev/null) || arguments=''
                case $arguments in
                    "$LAUNCH_UI_BUILD_DIR/Build/Products/Debug/LaunchUIObserverTests-Runner.app/Contents/MacOS/LaunchUIObserverTests-Runner"|\
                    "$LAUNCH_UI_BUILD_DIR/Build/Products/Debug/LaunchUIFixture.app/Contents/MacOS/LaunchUIFixture")
                        if ! kill -s "$signal" "$pid" 2>/dev/null && kill -0 "$pid" 2>/dev/null; then cleanup_result=1; fi ;;
                    '') if kill -0 "$pid" 2>/dev/null; then cleanup_result=1; fi ;;
                    *) cleanup_result=1 ;; # Never signal a changed/reused process.
                esac
            done <<< "$helpers"
        else cleanup_result=1; fi
        if kill -0 "$observer_launcher" 2>/dev/null; then
            arguments=$(ps -p "$observer_launcher" -o command= 2>/dev/null) || arguments=''
            if [[ $arguments == *"xcodebuild test-without-building -xctestrun $observer_plan "* ]]; then
                if ! kill -s "$signal" "$observer_launcher" 2>/dev/null && kill -0 "$observer_launcher" 2>/dev/null; then cleanup_result=1; fi
            else cleanup_result=1; fi
        fi
        if [[ $signal == TERM ]]; then sleep 1 || cleanup_result=1; fi
    done
    # Verify helper absence; a failed discovery is not an empty process list.
    for ((observer_wait=0; observer_wait<5; observer_wait++)); do
        if ! helpers=$(launch_ui_owned_helpers); then cleanup_result=1; break; fi
        [[ -n $helpers ]] || break
        sleep 0.1 || cleanup_result=1
    done
    [[ -z $helpers ]] || cleanup_result=1
    if kill -0 "$observer_launcher" 2>/dev/null; then
        state=$(ps -p "$observer_launcher" -o stat= 2>/dev/null) || state=''
    fi
    if ! kill -0 "$observer_launcher" 2>/dev/null || [[ $state == Z* ]]; then
        observer_test_result=0
        wait "$observer_launcher" 2>/dev/null || observer_test_result=$?
    else
        observer_test_result=unavailable
        cleanup_result=1
    fi
    if [[ $cleanup_result == 0 ]]; then
        observer_launcher=''
        observer_cleanup_failed=false
    else
        observer_cleanup_failed=true
    fi
    return "$cleanup_result"
}

launch_ui_prepare() {
    local observer_app=$1 observer_work=$2
    observer_ready=false
    observer_evidence_owned=false
    observer_control=''
    observer_launcher=''
    observer_plan=''
    observer_test_result=unavailable
    observer_cleanup_failed=false
    [[ -n ${LAUNCH_UI_EVIDENCE_DIR:-} ]] || return 0
    [[ ! -e $LAUNCH_UI_EVIDENCE_DIR ]] || return 1
    mkdir -m 700 "$LAUNCH_UI_EVIDENCE_DIR" || return 1
    observer_evidence_owned=true
    launch_ui_status HOLD 'Preconfigured native test-control session not established.' || return 1
    observer_control="$observer_work/observer-control"
    mkdir -m 700 "$observer_control" || return 1
    # Explicit hosted-only gate: never execute these UI tests on a developer host.
    if [[ ${GITHUB_ACTIONS:-} != true || ${CI:-} != true || $(sw_vers -productVersion) != 15.* ||
        $(xcodebuild -version) != $'Xcode 26.3\n'* || -z ${LAUNCH_UI_BUILD_DIR:-} ||
        ! -d $LAUNCH_UI_BUILD_DIR || -L $LAUNCH_UI_BUILD_DIR ]]; then
        launch_ui_status HOLD 'Requires fresh hosted macOS 15 and selected Xcode 26.3 QA build.'; return 0
    fi
    launchctl print "gui/$(id -u)" >/dev/null 2>&1 || {
        launch_ui_status HOLD 'No existing GUI domain.'; return 0;
    }
    # Read-only status, NEVER -enable/-disable or any security/authentication flag.
    if ! automationmodetool > "$observer_control/automation-status-private.txt" 2>&1 ||
        ! grep -Eq '^[[:space:]]*This device DOES NOT REQUIRE user authentication to enable Automation Mode\.[[:space:]]*$' "$observer_control/automation-status-private.txt"; then
        launch_ui_status HOLD 'Current Automation Mode status does not prove no-authentication preconfiguration.'; return 0
    fi
    if [[ ! ${LAUNCH_UI_EXPECTED_SHA256:-} =~ ^[0-9a-f]{64}$ ||
        ! ${EXPECTED_TEAM_ID:-} =~ ^[A-Z0-9]{10}$ ||
        ! ${LAUNCH_UI_EXPECTED_VERSION:-} =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ||
        ! ${LAUNCH_UI_EXPECTED_BUILD:-} =~ ^[0-9]+$ ]]; then
        launch_ui_status HOLD 'Missing public-archive-derived candidate binding.'; return 0
    fi
    observer_id=$(uuidgen) || return 1
    jq -n --arg bundle dev.cadence.app --arg team "$EXPECTED_TEAM_ID" \
        --arg version "$LAUNCH_UI_EXPECTED_VERSION" --arg build "$LAUNCH_UI_EXPECTED_BUILD" \
        --arg sha "$LAUNCH_UI_EXPECTED_SHA256" --arg app "$observer_app" --arg snapshot "$observer_work/startup.png" --arg id "$observer_id" \
        '{bundleID:$bundle,teamID:$team,version:$version,build:$build,executableSHA256:$sha,copiedPath:$app,snapshotPath:$snapshot,observationID:$id}' \
        > "$observer_control/binding.json" || return 1
    cp "$observer_control/binding.json" "$LAUNCH_UI_EVIDENCE_DIR/binding.json" || return 1
    observer_plans=("$LAUNCH_UI_BUILD_DIR"/Build/Products/LaunchUIObserver_*.xctestrun)
    if [[ ${#observer_plans[@]} != 1 || ! -f ${observer_plans[0]} ]]; then
        launch_ui_status HOLD 'QA build-for-testing plan unavailable.'; return 0
    fi
    observer_plan="$LAUNCH_UI_BUILD_DIR/Build/Products/observer-session.xctestrun"
    cp "${observer_plans[0]}" "$observer_plan" || return 1
    # Xcode's generated format is checked rather than guessing the test target.
    if /usr/libexec/PlistBuddy -c 'Print :LaunchUIObserverTests' "$observer_plan" >/dev/null 2>&1; then
        observer_key=LaunchUIObserverTests.EnvironmentVariables
    elif [[ $(/usr/libexec/PlistBuddy -c 'Print :TestConfigurations:0:TestTargets:0:BlueprintName' "$observer_plan" 2>/dev/null) == LaunchUIObserverTests ]]; then
        observer_key=TestConfigurations.0.TestTargets.0.EnvironmentVariables
    else
        launch_ui_status HOLD 'Unsupported generated test-plan layout.'; return 0
    fi
    plutil -replace "$observer_key.CADENCE_OBSERVER_CONTROL" -string "$observer_control" "$observer_plan" || return 1
    plutil -replace "$observer_key.CADENCE_OBSERVER_EVIDENCE" -string "$LAUNCH_UI_EVIDENCE_DIR" "$observer_plan" || return 1
    perl -e 'alarm 100; exec @ARGV; die "Cannot execute QA session\n";' -- \
        xcodebuild test-without-building -xctestrun "$observer_plan" -destination 'platform=macOS' \
        -parallel-testing-enabled NO -test-timeouts-enabled YES \
        -default-test-execution-time-allowance 90 -maximum-test-execution-time-allowance 90 \
        > "$observer_control/xcode-private.log" 2>&1 &
    observer_launcher=$!
    for ((observer_wait=0; observer_wait<35; observer_wait++)); do
        if [[ -f $observer_control/ready && $(cat "$observer_control/ready") == "$observer_id" ]]; then
            observer_ready=true
            launch_ui_status READY 'Read-only XCTest session initialized before ordinary LaunchServices invocation.'
            return 0
        fi
        [[ -f $observer_control/done ]] && break
        kill -0 "$observer_launcher" 2>/dev/null || break
        sleep 1
    done
    launch_ui_stop
    launch_ui_status HOLD 'Native XCTest session did not establish readiness; no authentication or permission grant attempted.'
}

launch_ui_attach() {
    [[ ${observer_ready:-false} == true ]] || return 0
    jq -n --argjson pid "$1" '{launcherPID:$pid}' > "$observer_control/launch-pending.json" || return 1
    mv "$observer_control/launch-pending.json" "$observer_control/launch.json"
}

launch_ui_finish() {
    local cleanup_result=0 bootstrap_script="${BASH_SOURCE[0]%/*}/capture-observer-bootstrap.sh"
    launch_ui_stop || cleanup_result=1
    [[ ${observer_cleanup_failed:-false} != true ]] || cleanup_result=1
    [[ ${observer_evidence_owned:-false} == true && -n ${LAUNCH_UI_EVIDENCE_DIR:-} && -d $LAUNCH_UI_EVIDENCE_DIR ]] || return "$cleanup_result"
    # Only after verified stop, while private control/plan still exist. This
    # separate fingerprint cannot change readiness, teardown or product results.
    if [[ $cleanup_result == 0 && -n ${observer_control:-} &&
        ${observer_test_result:-unavailable} =~ ^(0|[1-9][0-9]{0,2})$ ]]; then
        "$bootstrap_script" "$observer_control/xcode-private.log" "${observer_plan:-}" "$observer_test_result" ||
            printf 'Bootstrap diagnostic unavailable; original launch and observer results preserved.\n' >&2
    else
        printf 'Bootstrap diagnostic unavailable: no verified reaped client; original results preserved.\n' >&2
    fi
    if [[ $cleanup_result == 0 && ${observer_ready:-false} == true && ${observer_test_result:-unavailable} == 0 &&
        -s $LAUNCH_UI_EVIDENCE_DIR/session.txt && -s $LAUNCH_UI_EVIDENCE_DIR/observation-0.json ]] &&
        grep -q '^Observed:' "$LAUNCH_UI_EVIDENCE_DIR/session.txt"; then
        launch_ui_status OBSERVED 'Read-only telemetry only; system UI causality unclassified.' "$1"
    else
        # Retain any earlier precise preflight reason as well as final status.
        if [[ -f $LAUNCH_UI_EVIDENCE_DIR/status.json ]]; then
            cp "$LAUNCH_UI_EVIDENCE_DIR/status.json" "$LAUNCH_UI_EVIDENCE_DIR/preflight.json" || return 1
        fi
        launch_ui_status HOLD "UI observation unavailable or incomplete; test exit ${observer_test_result:-unavailable}; cleanup exit $cleanup_result." "$1"
    fi
    return "$cleanup_result"
}

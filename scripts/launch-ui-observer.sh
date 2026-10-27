#!/bin/bash
# Sourced optional telemetry adapter. No UI actions or security configuration.
# Private xcodebuild logs/xctestrun/control files never enter the evidence artifact.

launch_ui_status() {
    [[ ${observer_evidence_owned:-false} == true && -n ${LAUNCH_UI_EVIDENCE_DIR:-} && -d $LAUNCH_UI_EVIDENCE_DIR ]] || return 0
    jq -n --arg status "$1" --arg reason "$2" --arg result "${3:-pending}" \
        '{status:$status,reason:$reason,original_startup_exit:$result,read_only:true,runtime_acceptance:false}' \
        > "$LAUNCH_UI_EVIDENCE_DIR/status.json"
}

launch_ui_stop() {
    [[ -n ${observer_control:-} ]] || return 0
    : > "$observer_control/stop"
    [[ -n ${observer_launcher:-} ]] || return 0
    # Give the test an opportunity to finish; its own allowance is also bounded.
    for ((observer_wait=0; observer_wait<5; observer_wait++)); do
        if ! kill -0 "$observer_launcher" 2>/dev/null; then break; fi
        sleep 1
    done
    # Xcode can launch its runner through a service. Never kill that shared
    # service: match only executables inside this unique private QA build.
    for observer_signal in TERM KILL; do
        while read -r observer_pid observer_executable; do
            if [[ $observer_pid =~ ^[1-9][0-9]*$ &&
                ( $observer_executable == "$LAUNCH_UI_BUILD_DIR/Build/Products/Debug/LaunchUIObserverTests-Runner.app/Contents/MacOS/LaunchUIObserverTests-Runner" ||
                  $observer_executable == "$LAUNCH_UI_BUILD_DIR/Build/Products/Debug/LaunchUIFixture.app/Contents/MacOS/LaunchUIFixture" ) ]]; then
                kill -s "$observer_signal" "$observer_pid" 2>/dev/null || true
            fi
        done < <(ps -axo pid=,comm=)
        if [[ -n ${observer_launcher:-} ]]; then
            observer_arguments=$(ps -p "$observer_launcher" -o command= 2>/dev/null) || observer_arguments=''
            if [[ $observer_arguments == *"xcodebuild test-without-building -xctestrun $observer_plan "* ]]; then
                kill -s "$observer_signal" "$observer_launcher" 2>/dev/null || true
            fi
        fi
        if [[ $observer_signal == TERM ]]; then sleep 1; fi
    done
    if [[ -n ${observer_launcher:-} ]]; then
        # KILL above makes this finite even if a test-control query hung.
        # A mismatched/reused PID is never waited or signaled.
        if ! kill -0 "$observer_launcher" 2>/dev/null; then
            observer_test_result=0
            wait "$observer_launcher" 2>/dev/null || observer_test_result=$?
        else
            observer_test_result=unavailable
        fi
    fi
    observer_launcher=''
}

launch_ui_prepare() {
    local observer_app=$1 observer_work=$2
    observer_ready=false
    observer_evidence_owned=false
    observer_control=''
    observer_launcher=''
    observer_test_result=unavailable
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
    launch_ui_stop || true
    [[ ${observer_evidence_owned:-false} == true && -n ${LAUNCH_UI_EVIDENCE_DIR:-} && -d $LAUNCH_UI_EVIDENCE_DIR ]] || return 0
    if [[ ${observer_ready:-false} == true && ${observer_test_result:-unavailable} == 0 &&
        -s $LAUNCH_UI_EVIDENCE_DIR/session.txt && -s $LAUNCH_UI_EVIDENCE_DIR/observation-0.json ]] &&
        grep -q '^Observed:' "$LAUNCH_UI_EVIDENCE_DIR/session.txt"; then
        launch_ui_status OBSERVED 'Read-only telemetry only; system UI causality unclassified.' "$1"
    else
        # Retain any earlier precise preflight reason as well as final status.
        if [[ -f $LAUNCH_UI_EVIDENCE_DIR/status.json ]]; then
            cp "$LAUNCH_UI_EVIDENCE_DIR/status.json" "$LAUNCH_UI_EVIDENCE_DIR/preflight.json" || return 1
        fi
        launch_ui_status HOLD "UI observation unavailable or incomplete; test exit ${observer_test_result:-unavailable}." "$1"
    fi
}

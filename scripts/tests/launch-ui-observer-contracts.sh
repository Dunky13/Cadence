#!/bin/bash
# Synthetic controllers/providers only. Never runs XCTest or the real product.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/cadence-ui-contracts.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"
cat > "$work/bin/xcodebuild" <<'STUB'
#!/bin/bash
set -euo pipefail
if [[ $1 == -version ]]; then
    if [[ $FIXTURE_CASE == wrong-xcode ]]; then printf 'Xcode 27.1\nBuild version synthetic\n';
    else printf 'Xcode 26.3\nBuild version synthetic\n'; fi
    exit
fi
[[ $1 == test-without-building && $2 == -xctestrun ]] || exit 98
printf 'session\n' >> "$FIXTURE/calls"
control=$(plutil -extract LaunchUIObserverTests.EnvironmentVariables.CADENCE_OBSERVER_CONTROL raw -o - "$3")
evidence=$(plutil -extract LaunchUIObserverTests.EnvironmentVariables.CADENCE_OBSERVER_EVIDENCE raw -o - "$3")
case $FIXTURE_CASE in
    session-fail) exit 71 ;;
    protocol-missing) printf 'Missing private observer protocol paths: FAKE_SECRET=private\n'; exit 65 ;;
    never-ready) while [[ ! -e $control/stop ]]; do /bin/sleep 0.01; done; exit 72 ;;
    wrong-ready) printf 'wrong-token' > "$control/ready"; while [[ ! -e $control/stop ]]; do /bin/sleep 0.01; done; exit 73 ;;
esac
jq -jr '.observationID' "$control/binding.json" > "$control/ready"
while [[ ! -e $control/launch.json && ! -e $control/stop ]]; do /bin/sleep 0.01; done
if [[ $FIXTURE_CASE == hung-session ]]; then
    trap '' TERM
    while true; do /bin/sleep 0.01; done
fi
if [[ $FIXTURE_CASE == permission-request ]]; then
    printf 'HOLD: synthetic permission request; no action\n' > "$evidence/session.txt"
    exit 74
fi
cp "$control/binding.json" "$evidence/observation-0.json"
printf 'Observed: SYNTHETIC only\n' > "$evidence/session.txt"
printf 'done\n' > "$control/done"
STUB
chmod +x "$work/bin/xcodebuild"
cat > "$work/driver.sh" <<'DRIVER'
#!/bin/bash
set -euo pipefail
# shellcheck source=scripts/launch-ui-observer.sh
source "$OBSERVER_SCRIPT"
sw_vers() { if [[ $FIXTURE_CASE == wrong-os ]]; then printf '27.0\n'; else printf '15.7\n'; fi; }
launchctl() { [[ $* == "print gui/$(id -u)" && $FIXTURE_CASE != no-gui ]]; }
automationmodetool() {
    [[ $# == 0 ]] || exit 98
    printf 'status\n' >> "$FIXTURE/calls"
    case $FIXTURE_CASE in
        status-fail) return 70 ;;
        auth-required) printf 'This device requires authentication to enable Automation Mode.\n' ;;
        *) printf ' Automation Mode is disabled.\n This device DOES NOT REQUIRE user authentication to enable Automation Mode.\n' ;;
    esac
}
sleep() { /bin/sleep 0.04; }
ps() {
    [[ $FIXTURE_CASE != ps-unavailable ]] || return 1
    case "$*" in
        '-axo pid=,comm=')
            [[ -e $FIXTURE/dead-1101 ]] || printf '1101 %s/Build/Products/Debug/LaunchUIObserverTests-Runner.app/Contents/MacOS/LaunchUIObserverTests-Runner\n' "$LAUNCH_UI_BUILD_DIR"
            [[ -e $FIXTURE/dead-1102 ]] || printf '1102 %s/Build/Products/Debug/LaunchUIFixture.app/Contents/MacOS/LaunchUIFixture\n' "$LAUNCH_UI_BUILD_DIR"
            printf '1103 /unrelated/LaunchUIObserverTests-Runner.app/Contents/MacOS/LaunchUIObserverTests-Runner\n'
            printf '1104 %s-extra/Build/Products/Debug/LaunchUIObserverTests-Runner.app/Contents/MacOS/LaunchUIObserverTests-Runner\n' "$LAUNCH_UI_BUILD_DIR" ;;
        '-p 1101 -o comm=') [[ ! -e $FIXTURE/dead-1101 ]] || return 1; printf '%s/Build/Products/Debug/LaunchUIObserverTests-Runner.app/Contents/MacOS/LaunchUIObserverTests-Runner\n' "$LAUNCH_UI_BUILD_DIR" ;;
        '-p 1102 -o comm=') [[ ! -e $FIXTURE/dead-1102 ]] || return 1; printf '%s/Build/Products/Debug/LaunchUIFixture.app/Contents/MacOS/LaunchUIFixture\n' "$LAUNCH_UI_BUILD_DIR" ;;
        *) /bin/ps "$@" ;;
    esac
}
kill() {
    if [[ $* == '-s '* && ${3:-} == 110* ]]; then
        printf '%s\n' "$*" >> "$FIXTURE/signals"
        [[ $FIXTURE_CASE != kill-errors ]] || return 1
        : > "$FIXTURE/dead-$3"
    elif [[ $* == '-0 1101' || $* == '-0 1102' ]]; then
        [[ ! -e $FIXTURE/dead-$2 ]]
    else builtin kill "$@"; fi
}

if [[ $FIXTURE_CASE == disabled ]]; then unset LAUNCH_UI_EVIDENCE_DIR; fi
if [[ $FIXTURE_CASE == local ]]; then GITHUB_ACTIONS=false; fi
if [[ $FIXTURE_CASE == missing-binding ]]; then unset LAUNCH_UI_EXPECTED_SHA256; fi
launch_ui_prepare "$FIXTURE/Cadence.app" "$FIXTURE/scratch"
if [[ $observer_ready == true ]]; then launch_ui_attach 900; fi
if [[ $FIXTURE_CASE == diagnostic-output-fail ]]; then mkdir "$FIXTURE/evidence/bootstrap.json"; fi
finish_result=0
launch_ui_finish 42 || finish_result=$?
if [[ $FIXTURE_CASE == kill-errors || $FIXTURE_CASE == ps-unavailable ]]; then
    [[ $finish_result == 1 && $observer_cleanup_failed == true && -n $observer_launcher ]]
else [[ $finish_result == 0 ]]; fi
if [[ $FIXTURE_CASE == disabled ]]; then [[ ! -d $FIXTURE/evidence ]]; exit; fi
jq -e '.original_startup_exit == "42" and .runtime_acceptance == false and .read_only == true' "$FIXTURE/evidence/status.json" >/dev/null
case $FIXTURE_CASE in
    success|diagnostic-output-fail|diagnostic-missing-reader)
        jq -e '.status == "OBSERVED"' "$FIXTURE/evidence/status.json" >/dev/null
        jq -e '.bundleID == "dev.cadence.app" and .build == "15" and .observationID != ""' "$FIXTURE/evidence/binding.json" >/dev/null
        jq -e '.launcherPID == 900' "$observer_control/launch.json" >/dev/null ;;
    *) jq -e '.status == "HOLD"' "$FIXTURE/evidence/status.json" >/dev/null ;;
esac
case $FIXTURE_CASE in
    success|diagnostic-output-fail|diagnostic-missing-reader|session-fail|protocol-missing|never-ready|wrong-ready|permission-request|hung-session|kill-errors|ps-unavailable)
        grep -q '^session$' "$FIXTURE/calls"
        # Only private fixture/runner executable paths can be signaled.
        ! grep -Eq '1103|1104' "$FIXTURE/signals" ;;
    *) ! grep -q '^session$' "$FIXTURE/calls" ;;
esac
# Verified teardown retains the actual reaped test exit and cannot qualify the
# product. Missing/failing diagnostics never change original result or status.
case $FIXTURE_CASE in
    success|session-fail|protocol-missing|never-ready|wrong-ready|permission-request|hung-session)
        jq -e --argjson code "$observer_test_result" '.client_exit == $code and .status == "HOLD" and .cause == "UNKNOWN" and
            .runtime_acceptance == false and .authority_established == false and .causality_established == false' \
            "$FIXTURE/evidence/bootstrap.json" >/dev/null ;;
    diagnostic-output-fail|diagnostic-missing-reader)
        grep -q -F 'Bootstrap diagnostic unavailable; original launch and observer results preserved.' "$FIXTURE/result.log" ;;
    *) [[ ! -e $FIXTURE/evidence/bootstrap.json ]] ;;
esac
if [[ $FIXTURE_CASE == protocol-missing ]]; then
    [[ $observer_test_result == 65 ]]
    jq -e '.signature_flags.missing_private_protocol_variables == true' "$FIXTURE/evidence/bootstrap.json" >/dev/null
    ! grep -Eq 'FAKE_SECRET|private$' "$FIXTURE/evidence/bootstrap.json"
fi
DRIVER
cases=0
for scenario in disabled local wrong-os wrong-xcode no-gui auth-required status-fail missing-binding missing-build session-fail protocol-missing never-ready wrong-ready permission-request hung-session kill-errors ps-unavailable diagnostic-output-fail diagnostic-missing-reader success; do
    fixture="$work/$scenario"
    mkdir -p "$fixture/Cadence.app" "$fixture/scratch" "$fixture/build/Build/Products"
    : > "$fixture/calls"
    : > "$fixture/signals"
    cat > "$fixture/build/Build/Products/LaunchUIObserver_fixture.xctestrun" <<'PLAN'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>LaunchUIObserverTests</key><dict><key>EnvironmentVariables</key><dict/></dict></dict></plist>
PLAN
    if [[ $scenario == missing-build ]]; then rm "$fixture/build/Build/Products/LaunchUIObserver_fixture.xctestrun"; fi
    observer_script="$root/scripts/launch-ui-observer.sh"
    if [[ $scenario == diagnostic-missing-reader ]]; then
        mkdir "$fixture/isolated"
        cp "$observer_script" "$fixture/isolated/launch-ui-observer.sh"
        observer_script="$fixture/isolated/launch-ui-observer.sh"
    fi
    PATH="$work/bin:$PATH" OBSERVER_SCRIPT="$observer_script" \
        FIXTURE="$fixture" FIXTURE_CASE="$scenario" GITHUB_ACTIONS=true CI=true \
        LAUNCH_UI_BUILD_DIR="$fixture/build" LAUNCH_UI_EVIDENCE_DIR="$fixture/evidence" \
        EXPECTED_TEAM_ID=U9GXK89565 LAUNCH_UI_EXPECTED_SHA256=7b08ca7003a48662e0087bea3c2777680286d6bc1c4f295523ed9d7ae21315a9 \
        LAUNCH_UI_EXPECTED_VERSION=0.2.0 LAUNCH_UI_EXPECTED_BUILD=15 \
        /bin/bash "$work/driver.sh" > "$fixture/result.log" 2>&1 || {
            printf 'Observer synthetic contract failed: %s\n' "$scenario" >&2
            cat "$fixture/result.log" >&2; exit 1;
        }
    cases=$((cases + 1))
done
# Real EXIT/signal teardown body, preserving both failure and cancellation.
awk '/^cleanup\(\) \{/ { copy=1 } copy { print } copy && /^\}/ { exit }' \
    "$root/scripts/verify-demo-startup.sh" > "$work/cleanup.sh"
cat > "$work/exit-driver.sh" <<'DRIVER'
#!/bin/bash
set -uo pipefail
# shellcheck source=scripts/launch-ui-observer.sh
source "$OBSERVER_SCRIPT"
source "$CLEANUP_SCRIPT"
app="$FIXTURE/Cadence.app"
work="$FIXTURE/scratch"
launcher=''
observer_control="$work/control"
observer_launcher=900
observer_plan="$FIXTURE/build/Build/Products/observer-session.xctestrun"
observer_test_result=unavailable
LAUNCH_UI_BUILD_DIR="$FIXTURE/build"
kill() {
    if [[ $* == '-0 900' ]]; then [[ ! -e $FIXTURE/client-gone ]];
    elif [[ $* == '-s TERM 900' || $* == '-s KILL 900' ]]; then : > "$FIXTURE/client-gone";
    else return 0; fi
}
ps() {
    if [[ $* == '-p 900 -o command=' ]]; then printf 'xcodebuild test-without-building -xctestrun %s -destination platform=macOS\n' "$observer_plan"; fi
}
wait() { return 0; }
sleep() {
    if [[ -n $FIXTURE_SIGNAL ]]; then
        builtin kill -s "$FIXTURE_SIGNAL" "$$"
        FIXTURE_SIGNAL=''
    fi
}
trap cleanup EXIT
exit "$FIXTURE_STATUS"
DRIVER
for shell_mode in -e +e; do
    for original in 0 42; do
        for signal_name in HUP INT TERM; do
            fixture="$work/signal-$shell_mode-$original-$signal_name"
            mkdir -p "$fixture/scratch/control"
            result=0
            OBSERVER_SCRIPT="$root/scripts/launch-ui-observer.sh" CLEANUP_SCRIPT="$work/cleanup.sh" \
                FIXTURE="$fixture" FIXTURE_STATUS="$original" FIXTURE_SIGNAL="$signal_name" \
                /bin/bash "$shell_mode" "$work/exit-driver.sh" > "$fixture/result.log" 2>&1 || result=$?
            expected=$original
            if [[ $original == 0 ]]; then
                case $signal_name in HUP) expected=129;; INT) expected=130;; TERM) expected=143;; esac
            fi
            [[ $result == "$expected" && ! -d $fixture/scratch ]] || { cat "$fixture/result.log" >&2; exit 1; }
            cases=$((cases + 1))
        done
    done
done
cat > "$work/failed-cleanup-driver.sh" <<'DRIVER'
#!/bin/bash
set -uo pipefail
source "$CLEANUP_SCRIPT"
app="$FIXTURE/Cadence.app"
work="$FIXTURE/scratch"
launcher=''
diagnostic_launcher=900
diagnostic_script="$FIXTURE/diagnostic.sh"
launch_ui_finish() { observer_cleanup_failed=true; return 1; }
ps() { return 0; }
trap cleanup EXIT
if [[ $FIXTURE_STATUS == 0 ]]; then
    printf 'SYNTHETIC startup snapshot\n' > "$INSTALL_EVIDENCE_DIR/startup-$(uname -m).png"
fi
exit "$FIXTURE_STATUS"
DRIVER
for shell_mode in -e +e; do
    for original in 0 42; do
        fixture="$work/failed-teardown-$shell_mode-$original"
        mkdir -p "$fixture/scratch" "$fixture/evidence"
        cat > "$fixture/diagnostic.sh" <<'STUB'
#!/bin/bash
printf 'SYNTHETIC startup failure\n' > "$INSTALL_EVIDENCE_DIR/startup-failure-$(uname -m).txt"
STUB
        chmod +x "$fixture/diagnostic.sh"
        result=0
        CLEANUP_SCRIPT="$work/cleanup.sh" FIXTURE="$fixture" FIXTURE_STATUS="$original" INSTALL_EVIDENCE_DIR="$fixture/evidence" \
            /bin/bash "$shell_mode" "$work/failed-cleanup-driver.sh" > "$fixture/result.log" 2>&1 || result=$?
        expected=$original
        [[ $original != 0 ]] || expected=1
        [[ $result == "$expected" && -d $fixture/scratch ]] || { cat "$fixture/result.log" >&2; exit 1; }
        files=("$fixture/evidence"/*)
        [[ ${#files[@]} == 1 ]]
        if [[ $original == 0 ]]; then [[ ${files[0]} == "$fixture/evidence/startup-$(uname -m).png" ]];
        else [[ ${files[0]} == "$fixture/evidence/startup-failure-$(uname -m).txt" ]]; fi
        cases=$((cases + 1))
    done
done
# Exercise the complete original launcher with synthetic LaunchServices only.
# These witnesses verify exact invocation, the unchanged timeout, and exit codes.
cat > "$work/bin/open" <<'STUB'
#!/bin/bash
set -euo pipefail
expected_app=$(cd "$FIXTURE/Cadence.app" && pwd -P)
[[ $# == 7 && $1 == -n && $2 == -W && $3 == "$expected_app" &&
    $4 == --args && $5 == --demo && $6 == --snapshot ]] || exit 98
printf 'ordinary-launch\n' >> "$FIXTURE/calls"
case $FIXTURE_PRODUCT_RESULT in
    0) printf 'SYNTHETIC-PNG\n' > "$7" ;;
    7) exit 7 ;;
    1) while true; do /bin/sleep 0.01; done ;;
esac
STUB
cat > "$work/bin/spctl" <<'STUB'
#!/bin/bash
[[ $# == 5 && $1 == --assess && $2 == --type && $3 == execute && $4 == --verbose=4 ]] || exit 98
STUB
cat > "$work/bin/sips" <<'STUB'
#!/bin/bash
[[ $# == 3 && $1 == -g && $2 == format ]] || exit 98
printf 'format: png\n'
STUB
cat > "$work/bin/sleep" <<'STUB'
#!/bin/bash
printf 'timer\n' >> "$FIXTURE/timer"
/bin/sleep 0.02
STUB
cat > "$work/bin/ps" <<'STUB'
#!/bin/bash
exit 0
STUB
chmod +x "$work/bin/open" "$work/bin/spctl" "$work/bin/sips" "$work/bin/sleep" "$work/bin/ps"
for product_result in 0 7 1; do
    fixture="$work/complete-launch-$product_result"
    mkdir -p "$fixture/Cadence.app"
    : > "$fixture/calls"
    : > "$fixture/timer"
    result=0
    PATH="$work/bin:$PATH" FIXTURE="$fixture" FIXTURE_PRODUCT_RESULT="$product_result" \
        LAUNCH_UI_EVIDENCE_DIR='' INSTALL_EVIDENCE_DIR='' \
        /bin/bash "$root/scripts/verify-demo-startup.sh" "$fixture/Cadence.app" > "$fixture/result.log" 2>&1 || result=$?
    [[ $result == "$product_result" && $(grep -c '^ordinary-launch$' "$fixture/calls") == 1 ]] || {
        printf 'Complete synthetic launch expected %s, got %s.\n' "$product_result" "$result" >&2
        cat "$fixture/result.log" >&2; exit 1;
    }
    if [[ $product_result == 1 ]]; then [[ $(wc -l < "$fixture/timer" | tr -d ' ') == 30 ]]; fi
    cases=$((cases + 1))
done
printf 'Launch UI observer: %s synthetic authority/lifecycle contracts passed; no native UI session executed.\n' "$cases"

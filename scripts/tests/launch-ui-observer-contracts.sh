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
nonce=$(jq -r '.observationID' "$control/binding.json")
result=''; previous=''
for argument in "$@"; do
    if [[ $previous == -resultBundlePath ]]; then result=$argument; fi
    previous=$argument
done
[[ $result == "$control/result.xcresult" ]] || exit 98
case $FIXTURE_CASE in
    session-fail) exit 71 ;;
    protocol-missing) printf 'Missing private observer protocol paths: FAKE_SECRET=private\n'; exit 65 ;;
    stage-before-ready|foreign-stage|unknown-stage|stage-only-ready)
        case $FIXTURE_CASE in
            stage-before-ready)
                printf 'prefix CadenceObserverStage:%s:screenSessionStarted:EndCadenceObserver suffix\n' "$nonce"
                printf 'CadenceObserverStage:%s:candidateVerified:EndCadenceObserver\n' "$nonce" ;;
            foreign-stage) printf 'CadenceObserverStage:foreign:ready:EndCadenceObserver\n' ;;
            unknown-stage) printf 'CadenceObserverStage:%s:EXCLUDED-private-value:EndCadenceObserver\n' "$nonce" ;;
            stage-only-ready) printf 'CadenceObserverStage:%s:ready:EndCadenceObserver\n' "$nonce" ;;
        esac
        while [[ ! -e $control/stop ]]; do /bin/sleep 0.01; done
        exit 72 ;;
    never-ready) while [[ ! -e $control/stop ]]; do /bin/sleep 0.01; done; exit 72 ;;
    wrong-ready) printf 'CadenceObserverReady:wrong-token:EndCadenceObserver\n'; while [[ ! -e $control/stop ]]; do /bin/sleep 0.01; done; exit 73 ;;
esac
if [[ $FIXTURE_CASE == prefixed-ready ]]; then printf '2026-10-30 16:30:47.504156+0000 LaunchUIObserverTests-Runner'; fi
printf 'CadenceObserverReady:%s:EndCadenceObserver\n' "$nonce"
while [[ ! -e $control/launch.json && ! -e $control/stop ]]; do /bin/sleep 0.01; done
if [[ $FIXTURE_CASE == hung-session ]]; then
    trap '' TERM
    while true; do /bin/sleep 0.01; done
fi
mkdir -p "$result/export"
jq -n --arg nonce "$nonce" '[{testIdentifier:"ObserverTests/testObserveExistingLaunch()",attachments:[
    {suggestedHumanReadableName:("CadenceObserver-"+$nonce+"-observation-0_0_BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB.json"),exportedFileName:"observation.json"},
    {suggestedHumanReadableName:("CadenceObserver-"+$nonce+"-session_0_CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC.txt"),exportedFileName:"session.txt"}]}]' > "$result/export/manifest.json"
jq -n --slurpfile binding "$control/binding.json" '{binding:$binding[0],launcherPID:900,capturedUTC:"synthetic",ownedProcesses:[],windows:[],unavailableOwners:[],limited:false,complete:true,interpretation:"Synthetic only"}' > "$result/export/observation.json"
if [[ $FIXTURE_CASE == permission-request ]]; then
    printf 'HOLD: synthetic permission request; no action\n' > "$result/export/session.txt"
    exit 74
fi
printf 'Observed: SYNTHETIC only\n' > "$result/export/session.txt"
printf 'CadenceObserverDone:%s:EndCadenceObserver\n' "$nonce"
STUB
chmod +x "$work/bin/xcodebuild"
cat > "$work/bin/xcrun" <<'STUB'
#!/bin/bash
set -euo pipefail
[[ $# == 7 && $1 == xcresulttool && $2 == export && $3 == attachments && $4 == --path && $6 == --output-path ]] || exit 98
[[ $FIXTURE_CASE != collector-failure && $FIXTURE_CASE != collector-failure-enabled ]] || exit 71
cp -R "$5/export/." "$7/"
STUB
chmod +x "$work/bin/xcrun"
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
if [[ $FIXTURE_CASE == collector-failure-enabled ]]; then export LAUNCH_UI_ALLOW_NORMAL_OPEN=true; fi
launch_ui_prepare "$FIXTURE/Cadence.app" "$FIXTURE/scratch"
if [[ $observer_ready == true ]]; then
    jq -n --arg nonce "$observer_id" '{schema:"cadence/launcher/v1",observationID:$nonce,launcherPID:900,supervisorPID:900}' > "$observer_control/launch.json"
    launch_ui_attach 900
fi
if [[ $FIXTURE_CASE == diagnostic-output-fail ]]; then mkdir "$FIXTURE/evidence/bootstrap.json"; fi
finish_result=0
launch_ui_finish 42 || finish_result=$?
if [[ $FIXTURE_CASE == collector-failure-enabled ]]; then
    [[ $finish_result == 1 && $observer_cleanup_failed == false ]]
elif [[ $FIXTURE_CASE == kill-errors || $FIXTURE_CASE == ps-unavailable ]]; then
    [[ $finish_result == 1 && $observer_cleanup_failed == true && -n $observer_launcher ]]
else [[ $finish_result == 0 ]]; fi
if [[ $FIXTURE_CASE == disabled ]]; then [[ ! -d $FIXTURE/evidence ]]; exit; fi
jq -e --arg mode "${LAUNCH_UI_ALLOW_NORMAL_OPEN:-false}" '.original_startup_exit == "42" and .runtime_acceptance == false and .read_only == ($mode != "true")' "$FIXTURE/evidence/status.json" >/dev/null
case $FIXTURE_CASE in
    success|prefixed-ready|diagnostic-output-fail|diagnostic-missing-reader)
        jq -e '.status == "OBSERVED"' "$FIXTURE/evidence/status.json" >/dev/null
        jq -e '.bundleID == "dev.cadence.app" and .build == "15" and .observationID != ""' "$FIXTURE/evidence/binding.json" >/dev/null
        jq -e '.launcherPID == 900' "$observer_control/launch.json" >/dev/null ;;
    *) jq -e '.status == "HOLD"' "$FIXTURE/evidence/status.json" >/dev/null ;;
esac
case $FIXTURE_CASE in
    success|prefixed-ready|diagnostic-output-fail|diagnostic-missing-reader|session-fail|protocol-missing|never-ready|stage-before-ready|foreign-stage|unknown-stage|stage-only-ready|wrong-ready|permission-request|hung-session|kill-errors|ps-unavailable|collector-failure|collector-failure-enabled)
        grep -q '^session$' "$FIXTURE/calls"
        # Only private fixture/runner executable paths can be signaled.
        ! grep -Eq '1103|1104' "$FIXTURE/signals" ;;
    *) ! grep -q '^session$' "$FIXTURE/calls" ;;
esac
# Verified teardown retains the actual reaped test exit and cannot qualify the
# product. Missing/failing diagnostics never change original result or status.
case $FIXTURE_CASE in
    success|prefixed-ready|session-fail|protocol-missing|never-ready|stage-before-ready|foreign-stage|unknown-stage|stage-only-ready|wrong-ready|permission-request|hung-session|collector-failure|collector-failure-enabled)
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
case $FIXTURE_CASE in
    collector-failure|collector-failure-enabled)
        jq -e '.status == "HOLD" and (.reason | contains("completion frame observed"))' "$FIXTURE/evidence/status.json" >/dev/null ;;
    permission-request)
        jq -e '.status == "HOLD" and (.reason | contains("completion frame not-observed"))' "$FIXTURE/evidence/status.json" >/dev/null ;;
esac
case $FIXTURE_CASE in
    stage-before-ready) expected_stage=screenSessionStarted ;;
    stage-only-ready) expected_stage=ready ;;
    foreign-stage|unknown-stage) expected_stage=unavailable ;;
    *) expected_stage='' ;;
esac
if [[ -n $expected_stage ]]; then
    [[ $observer_ready == false && $observer_test_result == 72 ]]
    jq -e --arg stage "$expected_stage" '.status == "HOLD" and (.reason | contains("last stage: " + $stage + ";"))' "$FIXTURE/evidence/preflight.json" >/dev/null
    ! grep -q EXCLUDED "$FIXTURE/evidence/preflight.json"
fi
DRIVER
cases=0
for scenario in disabled local wrong-os wrong-xcode no-gui auth-required status-fail missing-binding missing-build session-fail protocol-missing never-ready stage-before-ready foreign-stage unknown-stage stage-only-ready wrong-ready permission-request hung-session kill-errors ps-unavailable diagnostic-output-fail diagnostic-missing-reader collector-failure collector-failure-enabled missing-verifier prefixed-ready success; do
    fixture="$work/$scenario"
    mkdir -p "$fixture/Cadence.app" "$fixture/scratch" "$fixture/build/Build/Products"
    : > "$fixture/calls"
    : > "$fixture/signals"
    printf '#!/bin/bash\nexit 0\n' > "$fixture/build/Build/Products/observer-launcher"
    chmod +x "$fixture/build/Build/Products/observer-launcher"
    if [[ $scenario == missing-verifier ]]; then rm "$fixture/build/Build/Products/observer-launcher"; fi
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
        cp "$root/scripts/collect-observer-evidence.sh" "$fixture/isolated/collect-observer-evidence.sh"
        cp "$root/scripts/observer-process-bridge.sh" "$fixture/isolated/observer-process-bridge.sh"
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
# Copy only the external launch boundary; production still pins /usr/bin/open.
mkdir "$work/launcher"
cp "$root/scripts/launch-ui-observer.sh" "$work/launcher/launch-ui-observer.sh"
/usr/bin/perl - "$root/scripts/verify-demo-startup.sh" > "$work/launcher/verify-demo-startup.sh" <<'PERL'
open(my $source, '<', $ARGV[0]) or die;
my $text = do { local $/; <$source> };
my $count = ($text =~ s{^([ \t]*)/usr/bin/open (?=-n -W )}{$1 . q{"$FIXTURE_OPEN" }}gme);
die "Expected one explicit system LaunchServices boundary\n" unless $count == 1;
print $text;
PERL
for product_result in 0 7 1; do
    fixture="$work/complete-launch-$product_result"
    mkdir -p "$fixture/Cadence.app"
    : > "$fixture/calls"
    : > "$fixture/timer"
    result=0
    PATH="$work/bin:$PATH" FIXTURE_OPEN="$work/bin/open" FIXTURE="$fixture" FIXTURE_PRODUCT_RESULT="$product_result" \
        LAUNCH_UI_ALLOW_NORMAL_OPEN=false LAUNCH_UI_EVIDENCE_DIR='' INSTALL_EVIDENCE_DIR='' \
        /bin/bash "$work/launcher/verify-demo-startup.sh" "$fixture/Cadence.app" > "$fixture/result.log" 2>&1 || result=$?
    [[ $result == "$product_result" && $(grep -c '^ordinary-launch$' "$fixture/calls") == 1 ]] || {
        printf 'Complete synthetic launch expected %s, got %s.\n' "$product_result" "$result" >&2
        cat "$fixture/result.log" >&2; exit 1;
    }
    if [[ $product_result == 1 ]]; then [[ $(wc -l < "$fixture/timer" | tr -d ' ') == 30 ]]; fi
    cases=$((cases + 1))
done
# A rejected consent controller is authoritative even if product startup passes.
# Execute the real finish callback through the real outer EXIT cleanup.
cat > "$work/controller-exit-driver.sh" <<'DRIVER'
#!/bin/bash
set -uo pipefail
source "$OBSERVER_SCRIPT"
source "$CLEANUP_SCRIPT"
app="$FIXTURE/Cadence.app"
work="$FIXTURE/scratch"
launcher=''
diagnostic_launcher=900
diagnostic_script=/usr/bin/true
observer_evidence_owned=true
observer_ready=true
observer_id=AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA
observer_control=''
observer_plan=''
observer_cleanup_failed=false
launch_ui_stop() { observer_test_result=$FIXTURE_CLIENT_EXIT; observer_bridge_result=$FIXTURE_BRIDGE_EXIT; return 0; }
ps() { return 0; }
trap cleanup EXIT
if [[ $FIXTURE_STATUS == 0 ]]; then
    printf 'SYNTHETIC PNG\n' > "$INSTALL_EVIDENCE_DIR/startup-$(uname -m).png"
fi
exit "$FIXTURE_STATUS"
DRIVER
for shell_mode in -e +e; do
    for enabled in false true; do
        for client in 0 65; do
            for bridge in 0 255; do
                for original in 0 42; do
                    fixture="$work/controller-exit-$shell_mode-$enabled-$client-$bridge-$original"
                    mkdir -p "$fixture/Cadence.app" "$fixture/scratch" "$fixture/ui" "$fixture/consumer"
                    printf 'Observed: synthetic controller\n' > "$fixture/ui/session.txt"
                    printf '{}\n' > "$fixture/ui/observation-0.json"
                    printf '{"action":"verified-normal-open","observation_id":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"}\n' > "$fixture/ui/first-open.json"
                    result=0
                    OBSERVER_SCRIPT="$root/scripts/launch-ui-observer.sh" CLEANUP_SCRIPT="$work/cleanup.sh" \
                        FIXTURE="$fixture" FIXTURE_CLIENT_EXIT="$client" FIXTURE_BRIDGE_EXIT="$bridge" FIXTURE_STATUS="$original" \
                        LAUNCH_UI_ALLOW_NORMAL_OPEN="$enabled" LAUNCH_UI_EVIDENCE_DIR="$fixture/ui" INSTALL_EVIDENCE_DIR="$fixture/consumer" \
                        /bin/bash "$shell_mode" "$work/controller-exit-driver.sh" > "$fixture/log" 2>&1 || result=$?
                    expected=$original
                    if [[ $enabled == true && ( $client != 0 || $bridge != 0 ) && $original == 0 ]]; then expected=1; fi
                    [[ $result == "$expected" ]] || { printf 'Controller rejection lost: enabled=%s client=%s bridge=%s original=%s returned=%s\n' "$enabled" "$client" "$bridge" "$original" "$result" >&2; exit 1; }
                    [[ ! -e $fixture/scratch ]] || exit 1
                    if [[ $original == 0 ]]; then
                        files=("$fixture/consumer/"*)
                        [[ ${#files[@]} == 1 && ${files[0]} == "$fixture/consumer/startup-$(uname -m).png" ]] || exit 1
                    fi
                    cases=$((cases + 1))
                done
            done
        done
    done
done
# Enabled first-open requires its exact exported action/nonce, even with PNG,
# successful test, bridge and collection. Read-only mode remains independent.
for shell_mode in -e +e; do
    for receipt in missing foreign action malformed symlink extra array fifo; do
        fixture="$work/open-proof-$shell_mode-$receipt"
        mkdir -p "$fixture/Cadence.app" "$fixture/scratch" "$fixture/ui" "$fixture/consumer"
        printf 'Observed: synthetic controller\n' > "$fixture/ui/session.txt"
        printf '{}\n' > "$fixture/ui/observation-0.json"
        case $receipt in
            foreign) printf '{"action":"verified-normal-open","observation_id":"BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"}\n' > "$fixture/ui/first-open.json" ;;
            action) printf '{"action":"unclassified","observation_id":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"}\n' > "$fixture/ui/first-open.json" ;;
            malformed) printf '{\n' > "$fixture/ui/first-open.json" ;;
            extra) printf '{"action":"verified-normal-open","observation_id":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","unexpected":true}\n' > "$fixture/ui/first-open.json" ;;
            array) printf '[]\n' > "$fixture/ui/first-open.json" ;;
            fifo) mkfifo "$fixture/ui/first-open.json" ;;
            symlink)
                printf '{"action":"verified-normal-open","observation_id":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"}\n' > "$fixture/foreign.json"
                ln -s "$fixture/foreign.json" "$fixture/ui/first-open.json" ;;
        esac
        result=0
        OBSERVER_SCRIPT="$root/scripts/launch-ui-observer.sh" CLEANUP_SCRIPT="$work/cleanup.sh" \
            FIXTURE="$fixture" FIXTURE_CLIENT_EXIT=0 FIXTURE_BRIDGE_EXIT=0 FIXTURE_STATUS=0 \
            LAUNCH_UI_ALLOW_NORMAL_OPEN=true LAUNCH_UI_EVIDENCE_DIR="$fixture/ui" INSTALL_EVIDENCE_DIR="$fixture/consumer" \
            /bin/bash "$shell_mode" "$work/controller-exit-driver.sh" > "$fixture/log" 2>&1 || result=$?
        [[ $result == 1 && ! -e $fixture/scratch && -s $fixture/consumer/startup-$(uname -m).png ]]
        jq -e '.status == "HOLD" and (.reason | contains("Open evidence exit 1"))' "$fixture/ui/status.json" >/dev/null
        cases=$((cases + 1))
    done
done
printf 'Launch UI observer: %s synthetic authority/lifecycle contracts passed; no native UI session executed.\n' "$cases"

#!/bin/bash
# Real bounded broker/IPC and cleanup, with only the ps executable substituted.
set -euo pipefail
umask 077
root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/cadence-process-contracts.XXXXXX")
observer_bridge_pid=''
cleanup() {
    if [[ -n $observer_bridge_pid ]]; then
        : > "$observer_control/stop"
        launch_ui_stop_bridge || true
    fi
    rm -r "$work"
}
trap cleanup EXIT
mkdir "$work/bin"
# Replace one external dependency in a disposable copy, not production hooks.
/usr/bin/perl - "$root/scripts/observer-process-bridge.sh" > "$work/bridge.sh" <<'PERL'
open(my $source, '<', $ARGV[0]) or die;
my $text = do { local $/; <$source> };
my $count = ($text =~ s{'/bin/ps'}{q{$ENV{FIXTURE_PS}}}ge);
die "Unexpected process boundary\n" unless $count == 1;
print $text;
PERL
chmod +x "$work/bridge.sh"
cat > "$work/bin/ps" <<'STUB'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >> "$FIXTURE/calls"
[[ ${FIXTURE_PS_FAIL:-false} != true ]] || exit 71
if [[ ${FIXTURE_PS_TIMEOUT:-false} == true ]]; then printf '%s\n' "$$" > "$FIXTURE/query-child"; exec /bin/sleep 20; fi
owned="$FIXTURE/app with spaces/Cadence.app/Contents/MacOS/Cadence"
relocated='/private/var/folders/fixture/AppTranslocation/owned/d/Cadence.app/Contents/MacOS/Cadence'
case "$*" in
    '-axo pid=,comm=') printf '800 %s\n801 /Applications/Cadence.app/Contents/MacOS/Cadence\n777 /unrelated/private\n' "$owned" ;;
    '-p 800 -o comm=') printf '%s\n' "$owned" ;;
    '-p 802 -o comm='|'-p 803 -o comm=') printf '%s\n' "$relocated" ;;
    '-p 801 -o comm=') printf '/Applications/Cadence.app/Contents/MacOS/Cadence\n' ;;
    '-p 900 -o comm=') printf '/usr/bin/open\n' ;;
    '-p 777 -o comm=') printf '/unrelated/private\n' ;;
    '-p 800 -o command=') printf '%s --demo --snapshot %s/scratch/startup.png\n' "$owned" "$FIXTURE" ;;
    '-p 802 -o command=') printf '%s --demo --snapshot %s/scratch/startup.png\n' "$relocated" "$FIXTURE" ;;
    '-p 900 -o command=') printf 'open -n -W %s/app with spaces/Cadence.app --args --demo --snapshot %s/scratch/startup.png\n' "$FIXTURE" "$FIXTURE" ;;
    '-p 803 -o command=') printf 'EXCLUDED private foreign arguments\n' ;;
    '-p 800 -o stat='|'-p 802 -o stat=') printf 'T\n' ;;
    '-p 900 -o stat=') printf 'S\n' ;;
    *) exit 98 ;;
esac
STUB
chmod +x "$work/bin/ps"
# shellcheck source=scripts/launch-ui-observer.sh
source "$root/scripts/launch-ui-observer.sh"
nonce=AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA
cases=0
new_case() {
    request_prefix=''; request_suffix=''; request_fragment=false; request_no_newline=false
    cases=$((cases+1)); fixture="$work/case-$cases"
    mkdir "$fixture" "$fixture/control"
    observer_control="$fixture/control"; observer_id=$nonce; observer_product_launcher=900; observer_bridge_result=0
    jq -n --arg root "$fixture" --arg nonce "$nonce" '{observationID:$nonce,copiedPath:($root+"/app with spaces/Cadence.app"),snapshotPath:($root+"/scratch/startup.png")}' > "$observer_control/binding.json"
    : > "$observer_control/xcode-private.log"
    FIXTURE="$fixture" FIXTURE_PS="$work/bin/ps" "$work/bridge.sh" "$observer_control" 900 "$nonce" "$$" > "$fixture/bridge-private.log" 2>&1 &
    observer_bridge_pid=$!
}
request() {
    request_id=$(printf '%08X-BBBB-BBBB-BBBB-BBBBBBBBBBBB' "$cases")
    printf -v frame '%sCadenceObserverQuery:%s:%s:%s:%s:EndCadenceObserver%s' "$request_prefix" "$nonce" "$request_id" "$1" "$2" "$request_suffix"
    if [[ $request_fragment == true ]]; then
        printf '%s' "${frame:0:30}" >> "$observer_control/xcode-private.log"
        /bin/sleep 0.05
        printf '%s' "${frame:30}" >> "$observer_control/xcode-private.log"
    else printf '%s' "$frame" >> "$observer_control/xcode-private.log"; fi
    if [[ $request_no_newline != true ]]; then printf '\n' >> "$observer_control/xcode-private.log"; fi
    reply="$observer_control/reply-$request_id.json"
    for ((attempt=0; attempt<400; attempt++)); do [[ ! -f $reply ]] || break; /bin/sleep 0.01; done
    [[ -f $reply ]] || { printf 'Missing bound process reply in case %s.\n' "$cases" >&2; cat "$fixture/bridge-private.log" >&2; exit 1; }
    jq -e --arg nonce "$nonce" --arg id "$request_id" --arg kind "$1" --argjson pid "$2" '.schema=="cadence/process-query/v1" and .observationID==$nonce and .requestID==$id and .kind==$kind and .pid==$pid' "$reply" >/dev/null
}
stop() { : > "$observer_control/stop"; launch_ui_stop_bridge; [[ -z $observer_bridge_pid && $observer_bridge_result == 0 ]]; }
new_case; request processes 0
jq -e '.ok and (.output|contains("800 ") and contains("801 ") and (contains("777 ")|not))' "$reply" >/dev/null
stop
# Reproduce XCTest forwarding a valid query inside a partial logging line.
new_case; request_prefix='2026-10-30 16:30:47.504156+0000 LaunchUIObserverTests-Runner'
request processes 0
jq -e '.ok' "$reply" >/dev/null
stop
for transport in suffix fragmented no-newline; do
    new_case
    case $transport in
        suffix) request_suffix='[2729:11079] [Security] synthetic logging suffix' ;;
        fragmented) request_fragment=true ;;
        no-newline) request_no_newline=true ;;
    esac
    request processes 0; jq -e '.ok' "$reply" >/dev/null; stop
done
for pair in 'command 800' 'state 800' 'executable 800' 'command 802' 'command 900' 'executable 900'; do
    new_case; read -r kind pid <<< "$pair"; request "$kind" "$pid"; jq -e '.ok and (.output|length>0)' "$reply" >/dev/null; stop
done
for pair in 'command 777' 'command 801' 'command 803' 'state 0' 'processes 800'; do
    new_case; read -r kind pid <<< "$pair"; request "$kind" "$pid"; jq -e '.ok==false and .output==""' "$reply" >/dev/null; stop
done
export FIXTURE_PS_FAIL=true
new_case; request processes 0; unset FIXTURE_PS_FAIL; jq -e '.ok==false and .output==""' "$reply" >/dev/null; stop
export FIXTURE_PS_TIMEOUT=true
new_case; request processes 0; unset FIXTURE_PS_TIMEOUT
jq -e '.ok==false and .output==""' "$reply" >/dev/null
query_child=$(cat "$fixture/query-child")
if kill -0 "$query_child" 2>/dev/null; then exit 1; fi
stop
# Cancellation during an in-flight query must reap the broker and its child.
export FIXTURE_PS_TIMEOUT=true
new_case; unset FIXTURE_PS_TIMEOUT
request_id=$(printf '%08X-BBBB-BBBB-BBBB-BBBBBBBBBBBB' "$cases")
printf 'CadenceObserverQuery:%s:%s:processes:0:EndCadenceObserver\n' "$nonce" "$request_id" >> "$observer_control/xcode-private.log"
for ((attempt=0; attempt<200; attempt++)); do
    [[ ! -f $fixture/query-child ]] || break
    /bin/sleep 0.01
done
[[ -f $fixture/query-child ]]
query_child=$(cat "$fixture/query-child")
: > "$observer_control/stop"
launch_ui_stop_bridge
[[ -z $observer_bridge_pid && $observer_bridge_result == 0 ]]
if kill -0 "$query_child" 2>/dev/null; then exit 1; fi
[[ ! -e $observer_control/reply-$request_id.json ]]
# A signal without the parent's stop request must remain a fault.
new_case; request processes 0
kill -TERM "$observer_bridge_pid"
for ((attempt=0; attempt<200; attempt++)); do
    if ! kill -0 "$observer_bridge_pid" 2>/dev/null; then break; fi
    /bin/sleep 0.01
done
launch_ui_stop_bridge
[[ -z $observer_bridge_pid && $observer_bridge_result == 143 ]]
for fault in unknown-kind replay; do
    new_case
    request_id=$(printf '%08X-BBBB-BBBB-BBBB-BBBBBBBBBBBB' "$cases")
    if [[ $fault == replay ]]; then request processes 0; kind=processes; else kind=arbitrary; fi
    before_calls=0
    if [[ -f $fixture/calls ]]; then before_calls=$(wc -l < "$fixture/calls"); fi
    printf 'CadenceObserverQuery:%s:%s:%s:0:EndCadenceObserver' "$nonce" "$request_id" "$kind" >> "$observer_control/xcode-private.log"
    for ((attempt=0; attempt<400; attempt++)); do
        if ! kill -0 "$observer_bridge_pid" 2>/dev/null; then break; fi
        /bin/sleep 0.01
    done
    if kill -0 "$observer_bridge_pid" 2>/dev/null; then exit 1; fi
    launch_ui_stop_bridge
    [[ -z $observer_bridge_pid && $observer_bridge_result != 0 ]]
    after_calls=0
    if [[ -f $fixture/calls ]]; then after_calls=$(wc -l < "$fixture/calls"); fi
    [[ $before_calls == "$after_calls" ]]
done
new_case; printf 'CadenceObserverQuery:FOREIGN:00000000-BBBB-BBBB-BBBB-BBBBBBBBBBBB:command:800:EndCadenceObserver\n' >> "$observer_control/xcode-private.log"
for ((attempt=0; attempt<400; attempt++)); do
    if ! kill -0 "$observer_bridge_pid" 2>/dev/null; then break; fi
    /bin/sleep 0.01
done
if kill -0 "$observer_bridge_pid" 2>/dev/null; then exit 1; fi
launch_ui_stop_bridge
[[ -z $observer_bridge_pid && $observer_bridge_result != 0 ]]
[[ ! -e $observer_control/reply-00000000-BBBB-BBBB-BBBB-BBBBBBBBBBBB.json ]]
printf '%s parent process broker contracts passed; no native UI or unrelated argv published.\n' "$cases"

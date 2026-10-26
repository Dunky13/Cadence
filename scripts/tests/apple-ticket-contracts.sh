#!/bin/bash
# Synthetic only: real validation wrapper, fake xcrun/sleep, no Apple services.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/cadence-ticket-contracts.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin" "$work/automation scripts"
cp "$root/scripts/validate-apple-ticket.sh" "$work/automation scripts/"
wrapper="$work/automation scripts/validate-apple-ticket.sh"

cat > "$work/bin/xcrun" <<'STUB'
#!/bin/bash
set -euo pipefail
count=0
[[ ! -f $FIXTURE_STATE/attempts ]] || count=$(cat "$FIXTURE_STATE/attempts")
count=$((count + 1))
printf '%s\n' "$count" > "$FIXTURE_STATE/attempts"
printf '%s\0' "$@" > "$FIXTURE_STATE/argv-$count"
[[ $# == 3 && $1 == stapler && $2 == validate && $3 == "$FIXTURE_TARGET" ]] || exit 99
printf 'child stdout %s\n' "$count"
printf 'child stderr %s\n' "$count" >&2
url=https://api.apple-cloudkit.com/database/1/com.apple.gk.ticket-delivery/production/public/records/lookup
marker='Error Domain=NSURLErrorDomain Code=-1005 "The network connection was lost."'
mode=$FIXTURE_MODE
case $mode in
    transient) [[ $count != 2 ]] || mode=success ;;
    two-transient) [[ $count != 3 ]] || mode=success ;;
    split) [[ $count != 2 ]] || mode=success ;;
    changed-failure) [[ $count != 2 ]] || mode=non68 ;;
    stale-markers) [[ $count != 2 ]] || mode=unmarked ;;
esac
case $mode in
    success) printf 'The validate action worked!\n'; exit 0 ;;
    signal) kill -s "$FIXTURE_SIGNAL" "$PPID"; exit 0 ;;
    unmarked) printf 'Unclassified validation failure\n' >&2; exit 68 ;;
    no-url) printf '%s\n' "$marker" >&2; exit 68 ;;
    no-marker) printf '%s\n' "$url" >&2; exit 68 ;;
    wrong-url) url=https://example.invalid/database/1/com.apple.gk.ticket-delivery/production/public/records/lookup ;;
    suffix-url) url="$url.evil" ;;
    query-url) url="$url?other=1" ;;
    prefixed-url) url="https://example.invalid/$url" ;;
    userinfo-url) url=${url/api.apple-cloudkit.com/api.apple-cloudkit.com@evil.invalid} ;;
    wrong-path) url=${url/production/development} ;;
    wrong-code) marker='Error Domain=NSURLErrorDomain Code=-10050 "Other error"' ;;
    wrong-domain) marker='Error Domain=OtherDomain Code=-1005 "Other error"' ;;
    split) printf '%s\n' "$marker"; printf 'NSErrorFailingURLStringKey=%s,\n' "$url" >&2; exit 68 ;;
esac
printf '%s UserInfo={NSErrorFailingURLStringKey=%s, NSErrorFailingURLKey=%s}\n' "$marker" "$url" "$url" >&2
[[ $mode != non68 ]] || exit 42
exit 68
STUB
cat > "$work/bin/sleep" <<'STUB'
#!/bin/bash
set -euo pipefail
[[ $# == 1 && $1 == 2 ]] || exit 99
printf '%s\n' "$1" >> "$FIXTURE_STATE/sleeps"
case ${FIXTURE_SLEEP:-ok} in
    fail) exit 74 ;;
    signal) kill -s "$FIXTURE_SIGNAL" "$PPID" ;;
esac
STUB
cat > "$work/bin/mktemp" <<'STUB'
#!/bin/bash
set -euo pipefail
[[ ${FIXTURE_MKTEMP:-ok} != fail ]] || exit 73
scratch=$(/usr/bin/mktemp "$@")
printf '%s\n' "$scratch" > "$FIXTURE_STATE/scratch"
printf '%s\n' "$scratch"
[[ ${FIXTURE_MKTEMP:-ok} != fail-after-create ]] || exit 73
STUB
cat > "$work/bin/rm" <<'STUB'
#!/bin/bash
set -euo pipefail
[[ $# == 3 && $1 == -rf && $2 == -- && $3 == "$(cat "$FIXTURE_STATE/scratch")" ]] || exit 99
printf '%s\n' "$3" >> "$FIXTURE_STATE/removals"
case ${FIXTURE_CLEANUP:-ok} in
    fail) exit 73 ;;
    noop) exit 0 ;;
    remove-then-fail) /bin/rm "$@"; exit 73 ;;
    signal) kill -s "$FIXTURE_SIGNAL" "$PPID" ;;
esac
exec /bin/rm "$@"
STUB
cat > "$work/bin/cat" <<'STUB'
#!/bin/bash
case ${FIXTURE_REPLAY:-ok}:$1 in
    fail:*/cadence-ticket-validation.*/stdout) exit 74 ;;
    signal-stdout:*/cadence-ticket-validation.*/stdout|signal-stderr:*/cadence-ticket-validation.*/stderr)
        kill -s "$FIXTURE_SIGNAL" "$PPID" ;;
esac
exec /bin/cat "$@"
STUB
chmod +x "$work/bin/"*
original_path=$PATH
cases=0
fail() { printf 'FAIL %s: %s\n' "$case_name" "$*" >&2; /bin/cat "$state/stdout" "$state/stderr" >&2; exit 1; }
new_case() {
    case_name=$1
    state="$work/$case_name"
    mkdir -p "$state/tmp" "$state/input with spaces/My App.app/Contents"
    printf 'unrelated private scratch\n' > "$state/tmp/unrelated"
    printf 'exact immutable image bytes\n' > "$state/input with spaces/My Installer.dmg"
    printf 'exact immutable app bytes\n' > "$state/input with spaces/My App.app/Contents/payload"
    cp "$state/input with spaces/My Installer.dmg" "$state/original-image"
    cp "$state/input with spaces/My App.app/Contents/payload" "$state/original-app"
    export FIXTURE_STATE="$state" FIXTURE_TARGET="$state/input with spaces/My Installer.dmg"
    export FIXTURE_MODE=success FIXTURE_SLEEP=ok FIXTURE_CLEANUP=ok FIXTURE_MKTEMP=ok FIXTURE_REPLAY=ok FIXTURE_SIGNAL=TERM
}
invoke() {
    result=0
    PATH="$work/bin:$original_path" TMPDIR="$state/tmp" /bin/bash "$shell_mode" "$wrapper" "$FIXTURE_TARGET" \
        > "$state/stdout" 2> "$state/stderr" || result=$?
}
expect() { [[ $result == "$1" ]] || fail "Expected exit $1, got $result"; }
count_is() {
    local actual=0
    [[ ! -f $state/$1 ]] || actual=$(wc -l < "$state/$1" | tr -d ' ')
    [[ $actual == "$2" ]] || fail "Expected $2 $1, got $actual"
}
attempts_are() {
    local actual=0 index
    [[ ! -f $state/attempts ]] || actual=$(cat "$state/attempts")
    [[ $actual == "$1" ]] || fail "Expected $1 child attempts, got $actual"
    printf '%s\0' stapler validate "$FIXTURE_TARGET" > "$state/expected-argv"
    for ((index=1; index<=actual; index++)); do
        cmp "$state/expected-argv" "$state/argv-$index" || fail 'Child argv changed'
        grep -qx "child stdout $index" "$state/stdout" || fail 'Child stdout lost'
        grep -qx "child stderr $index" "$state/stderr" || fail 'Child stderr lost'
    done
}
passed() {
    local scratch=''
    if [[ -f $state/scratch ]]; then
        scratch=$(cat "$state/scratch")
        [[ $scratch == "$state/tmp/cadence-ticket-validation."* ]] || fail 'Scratch escaped the owned parent'
        count_is removals 1
        if [[ $FIXTURE_CLEANUP == fail || $FIXTURE_CLEANUP == noop ]]; then
            [[ -d $scratch && $result != 0 ]] || fail 'Cleanup failure did not reject'
            grep -q 'Scratch cleanup failed:' "$state/stderr" || fail 'Cleanup failure lost diagnostic'
            /bin/rm -rf "$scratch"
        else
            [[ ! -e $scratch && ! -L $scratch ]] || fail 'Scratch leaked'
        fi
    fi
    [[ $(cat "$state/tmp/unrelated") == 'unrelated private scratch' ]] || fail 'Unowned scratch changed'
    cmp "$state/original-image" "$state/input with spaces/My Installer.dmg" || fail 'Target image changed'
    cmp "$state/original-app" "$state/input with spaces/My App.app/Contents/payload" || fail 'Target app changed'
    cases=$((cases + 1))
    printf 'PASS %s\n' "$case_name"
}

# The production wrapper is standalone, and must reject under either invoking
# errexit mode. Explicit /bin/bash exercises Apple's actual Bash 3.2 on macOS.
for shell_mode in -e +e; do
    new_case "$shell_mode-success"
    invoke; expect 0; attempts_are 1; count_is sleeps 0
    printf 'child stdout 1\nThe validate action worked!\n' > "$state/expected-stdout"
    printf 'child stderr 1\n' > "$state/expected-stderr"
    cmp "$state/expected-stdout" "$state/stdout" || fail 'Stdout contract changed'
    cmp "$state/expected-stderr" "$state/stderr" || fail 'Stderr contract changed'
    passed

    for mode in transient two-transient split; do
        new_case "$shell_mode-$mode"
        export FIXTURE_MODE=$mode
        if [[ $mode == two-transient ]]; then expected_attempts=3; else expected_attempts=2; fi
        # Include a bundle target and a spaced wrapper path from a fixture copy.
        export FIXTURE_TARGET="$state/input with spaces/My App.app"
        invoke; expect 0; attempts_are "$expected_attempts"; count_is sleeps "$((expected_attempts - 1))"
        grep -qx 'The validate action worked!' "$state/stdout" || fail 'No actual child success'
        grep -q 'NSURLErrorDomain Code=-1005' "$state/stdout" "$state/stderr" || fail 'Transient diagnostic lost'
        passed
    done

    new_case "$shell_mode-exhausted"
    export FIXTURE_MODE=repeated
    invoke; expect 68; attempts_are 3; count_is sleeps 2
    [[ $(grep -c 'NSURLErrorDomain Code=-1005' "$state/stderr") == 3 ]] || fail 'Exhaustion diagnostics lost'
    passed

    for mode in unmarked no-url no-marker wrong-url suffix-url query-url prefixed-url userinfo-url wrong-path wrong-code wrong-domain non68; do
        new_case "$shell_mode-$mode"
        export FIXTURE_MODE=$mode
        invoke
        if [[ $mode == non68 ]]; then expect 42; else expect 68; fi
        attempts_are 1; count_is sleeps 0; passed
    done

    for mode in changed-failure stale-markers; do
        new_case "$shell_mode-$mode"
        export FIXTURE_MODE=$mode
        invoke
        if [[ $mode == changed-failure ]]; then expect 42; else expect 68; fi
        attempts_are 2; count_is sleeps 1; passed
    done

    new_case "$shell_mode-sleep-fails"
    export FIXTURE_MODE=transient FIXTURE_SLEEP=fail
    invoke; expect 1; attempts_are 1; count_is sleeps 1; passed

    for outcome in success repeated; do
        for cleanup_mode in fail noop remove-then-fail; do
            new_case "$shell_mode-$outcome-cleanup-$cleanup_mode"
            export FIXTURE_MODE=$outcome FIXTURE_CLEANUP=$cleanup_mode
            invoke; expect 1
            if [[ $outcome == success ]]; then attempts_are 1; else attempts_are 3; fi
            passed
        done
    done

    for temp_mode in fail fail-after-create; do
        new_case "$shell_mode-mktemp-$temp_mode"
        export FIXTURE_MKTEMP=$temp_mode
        invoke; expect 1; attempts_are 0; count_is sleeps 0; passed
    done

    new_case "$shell_mode-replay-fails"
    export FIXTURE_REPLAY=fail FIXTURE_MODE=transient
    invoke; expect 1; count_is sleeps 0; passed

    for signal_name in HUP INT TERM; do
        case $signal_name in HUP) signal_status=129 ;; INT) signal_status=130 ;; TERM) signal_status=143 ;; esac
        for at in child sleep; do
            new_case "$shell_mode-$signal_name-during-$at"
            export FIXTURE_SIGNAL=$signal_name
            if [[ $at == child ]]; then export FIXTURE_MODE=signal
            else export FIXTURE_MODE=transient FIXTURE_SLEEP=signal; fi
            invoke; expect "$signal_status"
            attempts_are 1
            if [[ $at == sleep ]]; then count_is sleeps 1; else count_is sleeps 0; fi
            passed
        done
        for outcome in success unmarked; do
            for stream in stdout stderr; do
                new_case "$shell_mode-$signal_name-during-$stream-$outcome"
                export FIXTURE_SIGNAL=$signal_name FIXTURE_MODE=$outcome FIXTURE_REPLAY="signal-$stream"
                invoke; expect "$signal_status"
                attempts_are 1; count_is sleeps 0
                if [[ $outcome == success ]]; then
                    grep -qx 'The validate action worked!' "$state/stdout" || fail 'Captured success output lost on signal'
                else
                    grep -qx 'Unclassified validation failure' "$state/stderr" || fail 'Captured failure diagnostic lost on signal'
                fi
                passed
            done
            new_case "$shell_mode-$signal_name-during-cleanup-$outcome"
            export FIXTURE_SIGNAL=$signal_name FIXTURE_MODE=$outcome FIXTURE_CLEANUP=signal
            invoke
            if [[ $outcome == success ]]; then expect "$signal_status"; else expect 68; fi
            attempts_are 1; count_is sleeps 0; passed
        done
    done
done
printf 'Apple ticket validation: %s cases passed; synthetic tools only (Bash %s).\n' "$cases" "$BASH_VERSION"

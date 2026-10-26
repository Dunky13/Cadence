#!/bin/bash
# Synthetic tool-boundary tests. These never create or mount a real disk image.
set -euo pipefail
umask 077
root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/cadence-dmg-contracts.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/Cadence.app/Contents/MacOS"
printf 'fixture executable, never run\n' > "$work/Cadence.app/Contents/MacOS/Cadence"
chmod +x "$work/Cadence.app/Contents/MacOS/Cadence"
printf 'fixture plist, read by stub\n' > "$work/Cadence.app/Contents/Info.plist"
export TEST_APP="$work/Cadence.app"
export PATH="$work/bin:$PATH"

cat > "$work/bin/plutil" <<'STUB'
#!/bin/bash
case $2 in
    CFBundleIdentifier) printf '%s\n' dev.cadence.app ;;
    CFBundleExecutable) printf '%s\n' Cadence ;;
    CFBundleShortVersionString) printf '%s\n' "${TEST_BUNDLE_VERSION:-0.2.0}" ;;
    *) exit 1 ;;
esac
STUB
cat > "$work/bin/lipo" <<'STUB'
#!/bin/bash
printf '%s\n' "${TEST_ARCHS:-x86_64 arm64}"
STUB
cat > "$work/bin/codesign" <<'STUB'
#!/bin/bash
printf 'codesign %s\n' "$*" >> "$TEST_STATE/commands"
[[ ${TEST_SIGNATURE_FAIL:-0} == 0 ]] || exit 1
if [[ $1 == --display ]]; then
    if [[ ${TEST_DEVELOPER_ID:-0} == 1 ]]; then
        printf '%s\n' 'Authority=Developer ID Application: Fixture Team (0123456789)' >&2
    else
        printf '%s\n' 'Signature=adhoc' >&2
    fi
fi
STUB
cat > "$work/bin/ditto" <<'STUB'
#!/bin/bash
while [[ $1 == --* ]]; do shift; done
cp -R "$1" "$2"
STUB
cat > "$work/bin/sync" <<'STUB'
#!/bin/bash
exit 0
STUB
cat > "$work/bin/sleep" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$TEST_STATE/sleeps"
STUB
cat > "$work/bin/xcrun" <<'STUB'
#!/bin/bash
printf 'xcrun %s\n' "$*" >> "$TEST_STATE/commands"
[[ ${TEST_STAPLE_FAIL:-0} == 0 ]]
STUB
cat > "$work/bin/spctl" <<'STUB'
#!/bin/bash
printf 'spctl %s\n' "$*" >> "$TEST_STATE/commands"
STUB
cat > "$work/bin/mount" <<'STUB'
#!/bin/bash
if [[ -f $TEST_STATE/mounted ]]; then
    printf '/dev/disk99 on %s (hfs, local, read-only)\n' "$(cat "$TEST_STATE/mounted")"
fi
STUB
cat > "$work/bin/hdiutil" <<'STUB'
#!/bin/bash
set -euo pipefail
printf 'hdiutil %s\n' "$*" >> "$TEST_STATE/commands"
verb=$1
shift
case $verb in
    create)
        count=0
        [[ ! -f $TEST_STATE/attempts ]] || count=$(cat "$TEST_STATE/attempts")
        count=$((count + 1))
        printf '%s\n' "$count" > "$TEST_STATE/attempts"
        output=${!#}
        [[ ! -e $output ]] || { echo 'A partial image survived into a retry' >&2; exit 99; }
        printf 'partial\n' > "$output"
        case ${TEST_FAILURE_MODE:-none} in
            busy)
                if [[ $count -le ${TEST_BUSY_COUNT:-0} ]]; then
                    printf '%s\n' 'hdiutil: create failed - Resource busy' >&2
                    exit 1
                fi ;;
            permission) echo 'hdiutil: create failed - Permission denied' >&2; exit 1 ;;
            mixed) printf '%s\n' warning 'hdiutil: create failed - Resource busy' >&2; exit 1 ;;
            extra-newline) printf 'hdiutil: create failed - Resource busy\n\n' >&2; exit 1 ;;
            misleading) echo 'hdiutil: create failed - Resource busy (permission denied)' >&2; exit 1 ;;
            mixed-stdout) echo 'Permission denied'; echo 'hdiutil: create failed - Resource busy' >&2; exit 1 ;;
        esac
        printf 'verified fixture image\n' > "$output" ;;
    verify) [[ ${TEST_VERIFY_FAIL:-0} == 0 ]] ;;
    attach)
        mountpoint=''
        while [[ $# -gt 0 ]]; do
            if [[ $1 == -mountpoint ]]; then mountpoint=$2; shift 2; else shift; fi
        done
        [[ -n $mountpoint ]]
        printf '%s\n' "$mountpoint" > "$TEST_STATE/mounted"
        cp -R "$TEST_APP" "$mountpoint/Cadence.app"
        ln -s /Applications "$mountpoint/Applications"
        [[ ${TEST_ATTACH_FAIL:-0} == 0 ]] ;;
    detach)
        count=0
        [[ ! -f $TEST_STATE/detaches ]] || count=$(cat "$TEST_STATE/detaches")
        printf '%s\n' "$((count + 1))" > "$TEST_STATE/detaches"
        target=${!#}
        [[ -f $TEST_STATE/mounted && $target == "$(cat "$TEST_STATE/mounted")" ]] || exit 1
        if [[ ${TEST_DETACH_FAIL:-none} == always || ${TEST_DETACH_FAIL:-none} == once && $count == 0 ]]; then exit 1; fi
        rm "$TEST_STATE/mounted" ;;
    *) exit 1 ;;
esac
STUB
chmod +x "$work/bin/"*

case_number=0
new_case() {
    case_number=$((case_number + 1))
    export TEST_STATE="$work/case-$case_number"
    mkdir -p "$TEST_STATE/out" "$TEST_STATE/tmp"
    export TMPDIR="$TEST_STATE/tmp"
    unset TEST_FAILURE_MODE TEST_BUSY_COUNT TEST_VERIFY_FAIL TEST_ARCHS TEST_SIGNATURE_FAIL
    unset TEST_DEVELOPER_ID TEST_STAPLE_FAIL TEST_ATTACH_FAIL TEST_DETACH_FAIL TEST_BUNDLE_VERSION
    output="$TEST_STATE/out/Cadence-Installer-0.2.0-universal-local.dmg"
    package=(bash "$root/scripts/package-dmg.sh" --app "$TEST_APP" --output-dir "$TEST_STATE/out" --version 0.2.0 --architecture universal)
}
die() { printf 'DMG contract failed: %s (case %s)\n' "$*" "$case_number" >&2; cat "$TEST_STATE/log" >&2; exit 1; }
run_ok() { "$@" >"$TEST_STATE/log" 2>&1 || die 'Expected success'; }
run_bad() { if "$@" >"$TEST_STATE/log" 2>&1; then die 'Expected failure'; fi; }
attempts_are() { [[ $(cat "$TEST_STATE/attempts" 2>/dev/null || printf 0) == "$1" ]] || die "Expected $1 create attempts"; }
sleeps_are() {
    local actual=0
    if [[ -f $TEST_STATE/sleeps ]]; then actual=$(wc -l < "$TEST_STATE/sleeps" | tr -d ' '); fi
    [[ $actual == "$1" ]] || die "Expected $1 waits"
    if [[ -f $TEST_STATE/sleeps ]]; then
        while IFS= read -r wait; do [[ $wait == 2 ]] || die 'Retry delay changed'; done < "$TEST_STATE/sleeps"
    fi
}
clean_work() {
    local path
    for path in "$TEST_STATE/out"/.cadence-dmg.*; do [[ ! -e $path ]] || die 'Packaging workspace leaked'; done
}

new_case
run_ok "${package[@]}"
attempts_are 1
[[ $(cat "$output") == 'verified fixture image' ]] || die 'Wrong finished image'
clean_work

new_case
export TEST_FAILURE_MODE=busy TEST_BUSY_COUNT=2
run_ok "${package[@]}"
attempts_are 3
sleeps_are 2
clean_work

new_case
export TEST_FAILURE_MODE=busy TEST_BUSY_COUNT=10
run_bad "${package[@]}"
attempts_are 3
sleeps_are 2
[[ ! -e $output ]] || die 'Exhausted attempt promoted an image'
clean_work

for mode in permission mixed extra-newline misleading mixed-stdout; do
    new_case
    export TEST_FAILURE_MODE=$mode
    run_bad "${package[@]}"
    attempts_are 1
    sleeps_are 0
    [[ ! -e $output ]] || die 'Terminal failure promoted an image'
    clean_work
done

new_case
export TEST_VERIFY_FAIL=1
run_bad "${package[@]}"
[[ ! -e $output ]] || die 'Unverified image was promoted'
clean_work

new_case
printf 'existing image\n' > "$output"
run_bad "${package[@]}"
attempts_are 0
[[ $(cat "$output") == 'existing image' ]] || die 'Collision damaged existing image'
export TEST_FAILURE_MODE=permission
run_bad "${package[@]}" --force
[[ $(cat "$output") == 'existing image' ]] || die 'Failed forced replacement damaged existing image'
unset TEST_FAILURE_MODE
run_ok "${package[@]}" --force
[[ $(cat "$output") == 'verified fixture image' ]] || die 'Forced replacement did not finish'

new_case
printf 'keep target\n' > "$TEST_STATE/target"
ln -s "$TEST_STATE/target" "$output"
run_bad "${package[@]}" --force
attempts_are 0
[[ -L $output && $(cat "$TEST_STATE/target") == 'keep target' ]] || die 'Symlink collision was modified'
rm "$output"
mkdir "$output"
run_bad "${package[@]}" --force
attempts_are 0

new_case
export TEST_ARCHS=arm64
run_bad "${package[@]}"
attempts_are 0

new_case
chmod -x "$TEST_APP/Contents/MacOS/Cadence"
run_bad "${package[@]}"
attempts_are 0
chmod +x "$TEST_APP/Contents/MacOS/Cadence"

new_case
export TEST_BUNDLE_VERSION=0.3.0
run_bad "${package[@]}"
attempts_are 0

new_case
run_bad "${package[@]}" --release
attempts_are 0
export TEST_DEVELOPER_ID=1 TEST_STAPLE_FAIL=1
run_bad "${package[@]}" --release
attempts_are 0
unset TEST_STAPLE_FAIL
run_ok "${package[@]}" --release
[[ -f $TEST_STATE/out/Cadence-Installer-0.2.0-universal.dmg ]] || die 'Release name is not descriptive'
[[ ! -e $output ]] || die 'Release package received a local filename'

new_case
printf 'fixture image\n' > "$output"
run_ok bash "$root/scripts/check-dmg.sh" "$output" --architecture universal --version 0.2.0
[[ $(cat "$TEST_STATE/detaches") == 1 && ! -f $TEST_STATE/mounted ]] || die 'Successful check did not detach its mount'

new_case
printf 'fixture image\n' > "$output"
export TEST_ATTACH_FAIL=1
run_bad bash "$root/scripts/check-dmg.sh" "$output" --architecture universal
[[ ! -f $TEST_STATE/mounted ]] || die 'Partial attachment leaked its owned mount'

new_case
printf 'fixture image\n' > "$output"
export TEST_DETACH_FAIL=once
run_ok bash "$root/scripts/check-dmg.sh" "$output" --architecture universal
[[ $(cat "$TEST_STATE/detaches") == 2 && ! -f $TEST_STATE/mounted ]] || die 'Owned forced detach recovery failed'

new_case
printf 'fixture image\n' > "$output"
export TEST_DETACH_FAIL=always
run_bad bash "$root/scripts/check-dmg.sh" "$output" --architecture universal
[[ -f $TEST_STATE/mounted ]] || die 'Persistent detach failure lost its diagnostic state'
grep -q 'Preserved workspace:' "$TEST_STATE/log" || die 'Uncertain mount cleanup was not reported'

printf 'DMG contracts passed (%s isolated cases).\n' "$case_number"

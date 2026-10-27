#!/bin/bash
# Synthetic failure capture only: no native app, policy provider or UI operations.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/cadence-failure-contracts.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"
awk '/^cleanup\(\) \{/ { copy=1 } copy { print } copy && /^\}/ { exit }' \
    "$root/scripts/verify-demo-startup.sh" > "$work/cleanup.sh"
cat > "$work/bin/provider" <<'STUB'
#!/bin/bash
set -euo pipefail
name=${0##*/}
printf '%s %s\n' "$name" "$*" >> "$FIXTURE/calls"
case $name in
    uname) [[ $* == -m ]] || exit 99; printf 'arm64\n' ;;
    sw_vers) printf 'SYNTHETIC test OS\n' ;;
    xattr) [[ $# == 3 && $1 == -p && $2 == com.apple.quarantine && $3 == "$FIXTURE_APP" ]] || exit 99; printf 'SYNTHETIC-quarantine-preserved\n' ;;
    plutil) [[ $# == 6 && $1 == -extract && $3 == raw && $4 == -o && $5 == - ]] || exit 99; printf 'SYNTHETIC %s\n' "$2" ;;
    codesign) [[ $# == 3 && $1 == --display && $2 == --verbose=4 ]] || exit 99; printf 'SYNTHETIC team metadata\n' ;;
    shasum) [[ $# == 3 && $1 == -a && $2 == 256 ]] || exit 99; printf 'SYNTHETIC executable hash\n' ;;
    sips) [[ $# == 3 && $1 == -g && $2 == format ]] || exit 99; printf 'SYNTHETIC incomplete PNG\n' ;;
    launchctl) [[ $# == 2 && $1 == print && $2 == gui/* ]] || exit 99 ;;
    id) [[ $* == -u ]] || exit 99; printf '501\n' ;;
    automationmodetool) [[ $# == 0 ]] || exit 99; printf 'SYNTHETIC mode disabled; no grant attempted\n' ;;
    log)
        [[ $# == 8 && $1 == show && $2 == --style && $3 == compact && $4 == --last && $5 == 2m && $6 == --info && $7 == --predicate ]] || exit 99
        [[ $8 == 'process == "syspolicyd" AND eventMessage CONTAINS "dev.cadence.app"' ]] || exit 99
        [[ $FIXTURE_LOG_FAIL == 0 ]] || exit 77
        printf 'SYNTHETIC policy event; no Apple or consent proof\n' ;;
    ps)
        case "$*" in
            '-axo pid=,comm=')
                printf '1101 %s/Contents/MacOS/Cadence\n1102 /tmp/AppTranslocation/fixture/d/Cadence.app/Contents/MacOS/Cadence\n1103 /tmp/AppTranslocation/foreign/d/Cadence.app/Contents/MacOS/Cadence\n' "$FIXTURE_APP" ;;
            '-p 900 -o pid=,stat=,etime=,comm=') printf 'SYNTHETIC owned launcher state\n' ;;
            '-p 1101 -o command=') printf '%s/Contents/MacOS/Cadence --demo --snapshot %s/startup.png\n' "$FIXTURE_APP" "$FIXTURE_SCRATCH" ;;
            '-p 1102 -o command=') printf '/tmp/AppTranslocation/fixture/d/Cadence.app/Contents/MacOS/Cadence --demo --snapshot %s/startup.png\n' "$FIXTURE_SCRATCH" ;;
            '-p 1103 -o command=') printf '/tmp/AppTranslocation/foreign/d/Cadence.app/Contents/MacOS/Cadence --demo --snapshot /other/startup.png\n' ;;
            '-p 1101 -o pid=,stat=,etime=,command=') printf '1101 SYNTHETIC owned normal process\n' ;;
            '-p 1102 -o pid=,stat=,etime=,command=') printf '1102 SYNTHETIC owned translocated process\n' ;;
            *) exit 99 ;;
        esac ;;
    *) exit 99 ;;
esac
STUB
chmod +x "$work/bin/provider"
for name in uname sw_vers xattr plutil codesign shasum sips launchctl id automationmodetool log ps; do
    ln -s provider "$work/bin/$name"
done
cat > "$work/driver.sh" <<'DRIVER'
#!/bin/bash
set -uo pipefail
if [[ $FIXTURE_SHELL_MODE == -e ]]; then [[ $- == *e* ]] || exit 98;
else [[ $- != *e* ]] || exit 98; fi
kill() { printf '%s\n' "$*" >> "$FIXTURE/signals"; }
wait() { return 0; }
app=$FIXTURE_APP
work=$FIXTURE_SCRATCH
launcher=900
diagnostic_launcher=900
if [[ $FIXTURE_STATUS == 42 ]]; then launcher=''; fi
diagnostic_script=$FIXTURE_DIAGNOSTICS
source "$FIXTURE_CLEANUP"
trap cleanup EXIT
exit "$FIXTURE_STATUS"
DRIVER
cases=0
for shell_mode in -e +e; do
    for original_status in 0 42 130 143; do
        for log_fail in 0 1 2; do
            fixture="$work/$shell_mode-$original_status-$log_fail"
            app="$fixture/installed apps/Cadence.app"
            scratch="$fixture/owned snapshot"
            mkdir -p "$app/Contents/MacOS" "$scratch"
            if [[ $original_status == 42 ]]; then : > "$scratch/startup.png"; fi
            : > "$fixture/calls"
            : > "$fixture/signals"
            if [[ $log_fail == 2 ]]; then : > "$fixture/evidence"; fi
            result=0
            PATH="$work/bin:$PATH" INSTALL_EVIDENCE_DIR="$fixture/evidence" \
                FIXTURE="$fixture" FIXTURE_APP="$app" FIXTURE_SCRATCH="$scratch" FIXTURE_LOG_FAIL="$log_fail" \
                FIXTURE_DIAGNOSTICS="$root/scripts/capture-startup-failure.sh" FIXTURE_CLEANUP="$work/cleanup.sh" \
                FIXTURE_STATUS="$original_status" FIXTURE_SHELL_MODE="$shell_mode" \
                /bin/bash "$shell_mode" "$work/driver.sh" > "$fixture/log" 2>&1 || result=$?
            [[ $result == "$original_status" && ! -e $scratch ]] || { cat "$fixture/log" >&2; exit 1; }
            printf '1101\n1102\n' > "$fixture/expected-signals"
            if [[ $original_status != 42 ]]; then printf '900\n' >> "$fixture/expected-signals"; fi
            cmp "$fixture/signals" "$fixture/expected-signals" || exit 1
            evidence="$fixture/evidence/startup-failure-arm64.txt"
            if [[ $original_status == 0 || $log_fail == 2 ]]; then
                [[ ! -e $evidence ]] || exit 1
                if [[ $original_status != 0 ]]; then
                    rg -q -F 'Could not retain startup failure diagnostics' "$fixture/log" || exit 1
                fi
            else
                [[ -s $evidence ]] || { cat "$fixture/log" >&2; exit 1; }
                for expected in 'does not establish runtime acceptance' SYNTHETIC-quarantine-preserved '1101 SYNTHETIC owned' '1102 SYNTHETIC owned' 'no grant attempted'; do
                    rg -q -F "$expected" "$evidence" || { cat "$evidence" >&2; exit 1; }
                done
                ! rg -q -F '1103 SYNTHETIC' "$evidence" || exit 1
                if [[ $original_status == 42 ]]; then rg -q -F 'SYNTHETIC incomplete PNG' "$evidence";
                else rg -q -F 'No snapshot was produced.' "$evidence"; fi
                if [[ $log_fail == 0 ]]; then rg -q -F 'SYNTHETIC policy event' "$evidence";
                else rg -q -F 'Policy log read failed with status 77' "$evidence"; fi
            fi
            cases=$((cases + 1))
        done
    done
done
printf 'Startup failure capture: %s cases passed; synthetic providers only.\n' "$cases"

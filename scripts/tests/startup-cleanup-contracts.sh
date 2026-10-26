#!/bin/bash
# Exact production cleanup body with synthetic process metadata and signal sink.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/cadence-startup-contracts.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"
awk '/^cleanup\(\) \{/ { copy=1 } copy { print } copy && /^\}/ { exit }' \
    "$root/scripts/verify-demo-startup.sh" > "$work/cleanup.sh"
[[ -s $work/cleanup.sh ]] || exit 1
cat > "$work/bin/ps" <<'STUB'
#!/bin/bash
set -euo pipefail
case "$*" in
    '-axo pid=,comm=') cat "$FIXTURE/processes" ;;
    '-p '*' -o command=')
        [[ $# == 4 && -f $FIXTURE/args-$2 ]] || exit 1
        cat "$FIXTURE/args-$2" ;;
    *) exit 99 ;;
esac
STUB
chmod +x "$work/bin/ps"
cases=0
for shell_mode in -e +e; do
    for original_status in 0 42; do
        for spaced in plain spaced; do
            fixture="$work/$shell_mode-$original_status-$spaced"
            mkdir -p "$fixture"
            if [[ $spaced == spaced ]]; then app="$fixture/installed apps/Cadence.app";
            else app="$fixture/Cadence.app"; fi
            scratch="$fixture/owned snapshot"
            mkdir -p "$app" "$scratch"
            owned="$app/Contents/MacOS/Cadence"
            relocated='/private/var/folders/fixture/AppTranslocation/owned-uuid/d/Cadence.app/Contents/MacOS/Cadence'
            foreign='/Applications/Cadence.app/Contents/MacOS/Cadence'
            other_bundle='/private/var/folders/fixture/AppTranslocation/other-uuid/d/Other.app/Contents/MacOS/Cadence'
            {
                printf '1101 %s\n1102 %s\n1103 %s\n1104 %s\n1105 %s\n1106 %s\n1107 %s\n1108 %s\n' \
                    "$owned" "$relocated" "$foreign" "$relocated" "$other_bundle" "$relocated" "$owned" "$relocated"
            } > "$fixture/processes"
            printf '%s --demo --snapshot %s/startup.png\n' "$owned" "$scratch" > "$fixture/args-1101"
            printf '%s --demo --snapshot %s/startup.png\n' "$relocated" "$scratch" > "$fixture/args-1102"
            printf '%s --demo --snapshot %s/startup.png\n' "$foreign" "$scratch" > "$fixture/args-1103"
            printf '%s --demo --snapshot %s/other.png\n' "$relocated" "$scratch" > "$fixture/args-1104"
            printf '%s --demo --snapshot %s/startup.png\n' "$other_bundle" "$scratch" > "$fixture/args-1105"
            printf '%s --demo --snapshot %s/startup.png.extra\n' "$relocated" "$scratch" > "$fixture/args-1106"
            printf '%s --demo\n' "$owned" > "$fixture/args-1107"
            # 1108 disappeared between enumeration and argument lookup.
            : > "$fixture/signals"
            cat > "$fixture/driver.sh" <<'DRIVER'
#!/bin/bash
set -uo pipefail
if [[ $FIXTURE_SHELL_MODE == -e ]]; then
    [[ $- == *e* ]] || { printf 'Requested -e was not preserved.\n' >&2; exit 98; }
else
    [[ $- != *e* ]] || { printf 'Requested +e was not preserved.\n' >&2; exit 98; }
fi
kill() { printf '%s\n' "$*" >> "$FIXTURE/signals"; }
app=$FIXTURE_APP
work=$FIXTURE_SCRATCH
launcher=''
source "$FIXTURE_CLEANUP"
trap cleanup EXIT
exit "$FIXTURE_STATUS"
DRIVER
            result=0
            PATH="$work/bin:$PATH" FIXTURE="$fixture" FIXTURE_APP="$app" FIXTURE_SCRATCH="$scratch" \
                FIXTURE_CLEANUP="$work/cleanup.sh" FIXTURE_STATUS="$original_status" FIXTURE_SHELL_MODE="$shell_mode" \
                /bin/bash "$shell_mode" "$fixture/driver.sh" > "$fixture/log" 2>&1 || result=$?
            [[ $result == "$original_status" ]] || { cat "$fixture/log" >&2; exit 1; }
            printf '1101\n1102\n' > "$fixture/expected-signals"
            cmp "$fixture/expected-signals" "$fixture/signals" || { printf 'Unsafe or incomplete owned cleanup.\n' >&2; exit 1; }
            [[ ! -e $scratch ]] || exit 1
            cases=$((cases + 1))
        done
    done
done
printf 'Startup cleanup: %s cases passed; synthetic process metadata and signals only.\n' "$cases"

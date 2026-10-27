#!/bin/bash
# Read-only diagnostics for a failed owned demo launch. Never approves a prompt.
set -euo pipefail
umask 077
[[ $# == 3 && -d $1 && ! -L $1 && -d $2 && ! -L $2 && $3 =~ ^[1-9][0-9]*$ ]] || exit 2
[[ -n ${INSTALL_EVIDENCE_DIR:-} ]] || exit 2
app=$1
work=$2
launcher=$3
mkdir -p "$INSTALL_EVIDENCE_DIR"
diagnostics="$work/startup-failure.txt"
{
    printf 'Startup failed; this diagnostic does not establish runtime acceptance.\n'
    sw_vers
    printf 'Native architecture: '; uname -m
    printf 'Installed app: %s\nLauncher PID: %s\n' "$app" "$launcher"
    for key in CFBundleIdentifier CFBundleShortVersionString CFBundleVersion; do
        printf '%s: ' "$key"
        plutil -extract "$key" raw -o - "$app/Contents/Info.plist" || printf 'Unavailable.\n'
    done
    codesign --display --verbose=4 "$app" 2>&1 || printf 'Signature metadata unavailable.\n'
    shasum -a 256 "$app/Contents/MacOS/Cadence" || printf 'Executable digest unavailable.\n'
    printf 'Installed app quarantine (read only):\n'
    xattr -p com.apple.quarantine "$app" 2>&1 || printf 'Quarantine attribute unavailable.\n'
    printf '\nLauncher state:\n'
    ps -p "$launcher" -o pid=,stat=,etime=,comm= 2>&1 || printf 'Launcher no longer exists.\n'
    printf '\nSnapshot at timeout:\n'
    if [[ -f $work/startup.png ]]; then
        sips -g format "$work/startup.png" || printf 'Snapshot format unavailable.\n'
    else
        printf 'No snapshot was produced.\n'
    fi
    printf '\nExisting GUI session and UI automation mode (read only):\n'
    if launchctl print "gui/$(id -u)" >/dev/null 2>&1; then
        printf 'GUI launchd domain exists; this does not establish UI-control permission.\n'
    else
        printf 'GUI launchd domain unavailable.\n'
    fi
    automationmodetool 2>&1 || printf 'Automation mode status unavailable; no permission was requested.\n'
    printf '\nProcesses with the exact owned snapshot arguments:\n'
    while read -r pid executable; do
        if [[ $pid =~ ^[1-9][0-9]*$ && ( $executable == "$app/Contents/MacOS/Cadence" ||
            $executable == */AppTranslocation/*/d/Cadence.app/Contents/MacOS/Cadence ) ]]; then
            arguments=$(ps -p "$pid" -o command= 2>/dev/null) || continue
            if [[ $arguments == "$executable --demo --snapshot $work/startup.png" ]]; then
                ps -p "$pid" -o pid=,stat=,etime=,command= || printf 'Owned process disappeared.\n'
            fi
        fi
    done < <(ps -axo pid=,comm=)
    printf '\nCadence Gatekeeper policy events from the last two minutes:\n'
    # Bound the policy reader itself; an expired alarm terminates that same PID.
    perl -e 'alarm 20; exec @ARGV; die "Could not execute policy reader: $!\n";' -- \
        log show --style compact --last 2m --info --predicate \
        'process == "syspolicyd" AND eventMessage CONTAINS "dev.cadence.app"' 2>&1 || \
        printf 'Policy log read failed with status %s; consent cause is unconfirmed.\n' "$?"
} > "$diagnostics"
cp "$diagnostics" "$INSTALL_EVIDENCE_DIR/startup-failure-$(uname -m).txt"

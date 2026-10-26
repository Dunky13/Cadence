#!/bin/bash
# Launch through LaunchServices, using Cadence's existing read-only snapshot mode.
set -euo pipefail
umask 077
[[ $# == 1 && -d $1 && ! -L $1 ]] || exit 2
app=$(cd "$1" && pwd -P)
work=$(mktemp -d "${TMPDIR:-/tmp}/cadence-startup.XXXXXX")
launcher=''
cleanup() {
    result=$?
    trap - EXIT
    # Quarantined apps may execute from AppTranslocation. Require our unique
    # snapshot argument as well as the expected executable before terminating.
    while read -r pid executable; do
        if [[ $pid =~ ^[1-9][0-9]*$ && ( $executable == "$app/Contents/MacOS/Cadence" ||
            $executable == */AppTranslocation/*/d/Cadence.app/Contents/MacOS/Cadence ) ]]; then
            process_arguments=$(ps -p "$pid" -o command= 2>/dev/null) || continue
            if [[ $process_arguments == "$executable --demo --snapshot $work/startup.png" ]]; then
                kill "$pid" 2>/dev/null || true
            fi
        fi
    done < <(ps -axo pid=,comm=)
    if [[ -n $launcher ]]; then kill "$launcher" 2>/dev/null || true; wait "$launcher" 2>/dev/null || true; fi
    rm -rf "$work" || result=1
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
spctl --assess --type execute --verbose=4 "$app"
open -n -W "$app" --args --demo --snapshot "$work/startup.png" &
launcher=$!
finished=false
for ((attempt=0; attempt<30; attempt++)); do
    if ! kill -0 "$launcher" 2>/dev/null; then finished=true; break; fi
    sleep 1
done
[[ $finished == true ]] || { printf 'LaunchServices demo startup timed out.\n' >&2; exit 1; }
wait "$launcher"
launcher=''
[[ -s $work/startup.png && $(sips -g format "$work/startup.png") == *'format: png'* ]] || { printf 'Installed app did not produce its native demo snapshot.\n' >&2; exit 1; }
if [[ -n ${INSTALL_EVIDENCE_DIR:-} ]]; then
    mkdir -p "$INSTALL_EVIDENCE_DIR"
    cp "$work/startup.png" "$INSTALL_EVIDENCE_DIR/startup-$(uname -m).png"
fi
printf 'LaunchServices opened the installed app, rendered read-only demo state and exited.\n'

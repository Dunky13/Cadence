#!/bin/bash
# Launch through LaunchServices, using Cadence's existing read-only snapshot mode.
set -euo pipefail
umask 077
[[ $# == 1 && -d $1 && ! -L $1 ]] || exit 2
app=$(cd "$1" && pwd -P)
diagnostic_script="$(cd "$(dirname "$0")" && pwd)/capture-startup-failure.sh"
# Optional read-only QA telemetry; product success/failure remains authoritative.
# shellcheck source=scripts/launch-ui-observer.sh
source "$(dirname "$diagnostic_script")/launch-ui-observer.sh"
work=$(mktemp -d "${TMPDIR:-/tmp}/cadence-startup.XXXXXX")
launcher=''
diagnostic_launcher=''
cleanup() {
    product_result=$?
    result=$product_result
    trap - EXIT
    # Finish owned teardown if another handled signal arrives during diagnostics.
    # Preserve an existing failure; cancellation must still turn success into failure.
    trap 'if [[ $result == 0 ]]; then result=129; fi' HUP
    trap 'if [[ $result == 0 ]]; then result=130; fi' INT
    trap 'if [[ $result == 0 ]]; then result=143; fi' TERM
    if declare -F launch_ui_finish >/dev/null; then
        if ! launch_ui_finish "$result"; then
            printf 'UI observer owned teardown failed; qualification is held.\n' >&2
            if [[ $result == 0 ]]; then result=1; fi
        fi
    fi
    # A valid startup PNG stays the sole consumer artifact if only QA teardown
    # failed. That failure belongs to the separate observer HOLD evidence.
    if [[ $product_result != 0 && -n ${diagnostic_launcher:-$launcher} && -n ${INSTALL_EVIDENCE_DIR:-} ]]; then
        "$diagnostic_script" "$app" "$work" "${diagnostic_launcher:-$launcher}" || \
            printf 'Could not retain startup failure diagnostics; original failure is preserved.\n' >&2
    fi
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
    if [[ ${observer_cleanup_failed:-false} == true ]]; then
        printf 'Preserved private observer control for unverified teardown: %s\n' "$work" >&2
    else
        rm -rf "$work" || result=1
    fi
    exit "$result"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
spctl --assess --type execute --verbose=4 "$app"
launch_ui_prepare "$app" "$work" || printf 'UI observer preparation unavailable; ordinary launch proceeds.\n' >&2
[[ ${observer_cleanup_failed:-false} != true ]] || exit 1
if [[ ${LAUNCH_UI_ALLOW_NORMAL_OPEN:-false} == true && ${observer_ready:-false} != true ]]; then
    printf 'Verified first-open controller did not establish readiness.\n' >&2
    exit 1
fi
open -n -W "$app" --args --demo --snapshot "$work/startup.png" &
launcher=$!
diagnostic_launcher=$launcher
launch_ui_attach "$launcher" || printf 'UI observer launch binding unavailable; original launch result preserved.\n' >&2
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

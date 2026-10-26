#!/bin/bash
# Validation only. Retry the diagnosed CloudKit connection-loss response, never
# staple mutations or notarization submissions. Success requires xcrun exit 0.
set -euo pipefail
umask 077

fail() { printf 'validate-apple-ticket: %s\n' "$*" >&2; exit 1; }
[[ $# == 1 ]] || { printf 'Usage: validate-apple-ticket.sh PATH\n' >&2; exit 2; }

# Keep scratch and trap state at script scope for macOS Bash 3.2 EXIT traps.
work=''
output_pending=false
replay_output() {
    local replay_status=0
    cat "$work/stdout" || replay_status=1
    cat "$work/stderr" >&2 || replay_status=1
    output_pending=false
    return "$replay_status"
}
cleanup() {
    result=$?
    trap - EXIT
    # Finish replay/removal if another handled signal arrives during cleanup.
    # Preserve an existing failure; a signal must still turn success into failure.
    trap 'if [[ $result == 0 ]]; then result=129; fi' HUP
    trap 'if [[ $result == 0 ]]; then result=130; fi' INT
    trap 'if [[ $result == 0 ]]; then result=143; fi' TERM
    # A handled signal can arrive while waiting for xcrun. Retain its captured
    # diagnostics before removing scratch, just as on a normal child failure.
    if [[ $output_pending == true ]] && ! replay_output; then
        printf 'validate-apple-ticket: Cannot replay validation output.\n' >&2
        result=1
    fi
    if [[ -n $work ]]; then
        if ! rm -rf -- "$work" || [[ -e $work || -L $work ]]; then
            printf 'validate-apple-ticket: Scratch cleanup failed: %s\n' "$work" >&2
            result=1
        fi
    fi
    exit "$result"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
work=$(mktemp -d "${TMPDIR:-/tmp}/cadence-ticket-validation.XXXXXX") || fail 'Cannot create private scratch.'
[[ -d $work && ! -L $work ]] || fail 'Expected owned scratch directory.'

ticket_url='https://api[.]apple-cloudkit[.]com/database/1/com[.]apple[.]gk[.]ticket-delivery/production/public/records/lookup'
attempt=1
while :; do
    output_pending=true
    if xcrun stapler validate "$1" >"$work/stdout" 2>"$work/stderr"; then
        status=0
    else
        status=$?
    fi
    replay_output || fail 'Cannot replay validation output.'
    [[ $status != 0 ]] || exit 0
    # Boundaries reject lookalike error codes and URL prefixes/suffixes. Apple
    # NSError output delimits its URL values with spaces, quotes or punctuation.
    if [[ $status != 68 || $attempt == 3 ]] ||
        ! LC_ALL=C grep -Eq 'Error Domain=NSURLErrorDomain Code=-1005([[:space:]]|$)' "$work/stdout" "$work/stderr" ||
        ! LC_ALL=C grep -Eq "(^|[[:space:]=\"'(])${ticket_url}([[:space:]\"',)}]|$)" "$work/stdout" "$work/stderr"; then
        exit "$status"
    fi
    printf 'validate-apple-ticket: CloudKit connection lost; retrying validation (%s/3).\n' "$((attempt + 1))" >&2
    sleep 2 || fail 'Retry delay failed.'
    attempt=$((attempt + 1))
done

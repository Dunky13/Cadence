#!/bin/bash
# Explicit network operation, never called by pull-request CI or local packaging.
{ set +x; } 2>/dev/null
set -euo pipefail
umask 077
fail() { printf 'notarize-artifact: %s\n' "$*" >&2; exit 1; }
archive='' stage='' version='' architecture='' evidence=''
while [[ $# -gt 0 ]]; do
    [[ $# -ge 2 ]] || fail 'Options require a value.'
    case "$1" in
        --archive) archive=$2 ;;
        --stage) stage=$2 ;;
        --version) version=$2 ;;
        --architecture) architecture=$2 ;;
        --evidence-dir) evidence=$2 ;;
        *) fail "Unknown option: $1" ;;
    esac
    shift 2
done
[[ $(uname -s) == Darwin ]] || fail 'macOS is required.'
for tool in xcrun jq shasum mktemp; do command -v "$tool" >/dev/null || fail "Missing prerequisite: $tool"; done
[[ $version =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || fail 'Version must be numeric x.y.z.'
case "$architecture" in arm64|x86_64|universal) ;; *) fail 'Invalid architecture.' ;; esac
case "$stage" in
    app) expected="Cadence-App-$version-$architecture.zip" ;;
    installer) expected="Cadence-Installer-$version-$architecture.dmg" ;;
    *) fail 'Stage must be app or installer.' ;;
esac
[[ -f $archive && ! -L $archive && ${archive##*/} == "$expected" ]] || fail "Expected a regular archive named $expected."
[[ -n $evidence ]] || fail 'An evidence directory is required.'
source_commit=${SOURCE_COMMIT:-${GITHUB_SHA:-}}
if [[ -z $source_commit ]]; then source_commit=$(git rev-parse --verify HEAD 2>/dev/null) || fail 'A source commit is required.'; fi
[[ $source_commit =~ ^[0-9a-fA-F]{40}$ ]] || fail 'Source commit must be a full SHA.'
timeout=${APPLE_NOTARY_TIMEOUT:-30m}
[[ $timeout =~ ^[1-9][0-9]*[smh]$ ]] || fail 'APPLE_NOTARY_TIMEOUT must be a positive duration, such as 30m.'
auth=()
if [[ -n ${NOTARY_KEYCHAIN_PROFILE:-} ]]; then
    [[ -z ${NOTARY_KEY_FILE:-} ]] || fail 'Choose one notary authentication method.'
    auth=(--keychain-profile "$NOTARY_KEYCHAIN_PROFILE")
    if [[ -n ${NOTARY_KEYCHAIN:-} ]]; then auth+=(--keychain "$NOTARY_KEYCHAIN"); fi
else
    [[ -f ${NOTARY_KEY_FILE:-} && -n ${NOTARY_KEY_ID:-} && -n ${NOTARY_ISSUER_ID:-} ]] || fail 'Configure a notary keychain profile or API key file, ID, and issuer.'
    auth=(--key "$NOTARY_KEY_FILE" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
fi
mkdir -p "$evidence"
[[ -d $evidence && ! -L $evidence ]] || fail 'Evidence must be a directory, not a symlink.'
receipt="$evidence/$stage-$architecture-receipt.json"
log="$evidence/$stage-$architecture-log.json"
[[ ! -e $receipt && ! -L $receipt && ! -e $log && ! -L $log ]] || fail 'Evidence already exists. Reconcile the previous submission instead of resubmitting.'
lock="$evidence/.$stage-$architecture.lock"
mkdir "$lock" 2>/dev/null || fail 'Another submission owns this evidence stage. Reconcile it before retrying.'
work=''
cleanup() {
    result=$?
    trap - EXIT
    if [[ -n $work ]]; then rm -rf -- "$work" || result=1; fi
    rmdir "$lock" || result=1
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
work=$(mktemp -d "${TMPDIR:-/tmp}/cadence-notary.XXXXXX")
[[ ! -e $receipt && ! -L $receipt && ! -e $log && ! -L $log ]] || fail 'Submission evidence appeared while claiming the stage.'
submitted_sha256=$(shasum -a 256 "$archive"); submitted_sha256=${submitted_sha256%% *}
submission_id='' status=Unknown diagnostics=false warning_count=null wait_result=null
write_receipt() {
    jq -n --arg version "$version" --arg architecture "$architecture" --arg stage "$stage" \
        --arg filename "$expected" --arg commit "$source_commit" --arg sha256 "$submitted_sha256" \
        --arg run_id "${GITHUB_RUN_ID:-}" --arg run_attempt "${GITHUB_RUN_ATTEMPT:-}" \
        --arg id "$submission_id" --arg status "$status" --arg logfile "${log##*/}" \
        --argjson verified "$diagnostics" --argjson warnings "$warning_count" --argjson wait_result "$wait_result" '
        {schema:"cadence/apple-notarization/v1",app:"Cadence",version:$version,architecture:$architecture,
         stage:$stage,source_commit:$commit,archive_filename:$filename,submitted_sha256:$sha256,
         submission_id:(if $id == "" then null else $id end),status:$status,wait_exit_status:$wait_result,
         ci_run:{id:(if $run_id == "" then null else $run_id end),attempt:(if $run_attempt == "" then null else $run_attempt end)},
         diagnostics:{verified:$verified,log_file:(if $verified then $logfile else null end),warning_count:$warnings}}' \
        > "$work/receipt.json"
    cp "$work/receipt.json" "$receipt"
}
normalize_status() {
    jq -sr '(if length == 1 then .[0].status else null end) |
        if type != "string" then "Unknown" else ascii_downcase |
        if . == "accepted" then "Accepted" elif . == "invalid" then "Invalid"
        elif . == "rejected" then "Rejected" elif . == "in progress" or . == "inprogress" then "In Progress"
        elif . == "submitted" then "Submitted" else "Unknown" end end' "$1" 2>/dev/null || printf 'Unknown\n'
}
write_receipt
submit_result=0
xcrun notarytool submit "$archive" "${auth[@]}" --no-wait --output-format json \
    > "$work/submit.json" 2> "$work/submit.stderr" || submit_result=$?
submission_id=$(jq -ser '(if length == 1 then .[0].id else null end) |
    if type == "string" and test("^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$")
    then ascii_downcase else empty end' "$work/submit.json" 2>/dev/null) || submission_id=
status=$(normalize_status "$work/submit.json")
write_receipt
if [[ -n $submission_id ]]; then
    printf 'Cadence %s notarization: %s (%s)\n' "$stage" "$submission_id" "$expected"
fi
[[ $submit_result == 0 && -n $submission_id ]] || fail "Submission did not return a verified ID (exit $submit_result). Receipt: $receipt. Do not automatically resubmit."
wait_result=0
xcrun notarytool wait "$submission_id" "${auth[@]}" --timeout "$timeout" --output-format json \
    > "$work/wait.json" 2> "$work/wait.stderr" || wait_result=$?
status=$(normalize_status "$work/wait.json")
write_receipt
case "$status" in
    Accepted|Invalid|Rejected)
        if xcrun notarytool log "$submission_id" "${auth[@]}" "$work/log.json" \
            > "$work/log.stdout" 2> "$work/log.stderr"; then
            if jq -se --arg id "$submission_id" --arg status "$status" --arg filename "$expected" --arg sha "$submitted_sha256" '
                length == 1 and (.[0] | type == "object" and
                (.jobId | type == "string" and ascii_downcase == $id) and
                (.status | type == "string" and ascii_downcase == ($status | ascii_downcase)) and
                ((has("archiveFilename") | not) or .archiveFilename == $filename) and
                ((has("sha256") | not) or (.sha256 | type == "string" and ascii_downcase == $sha)) and
                (.issues == null or (.issues | type == "array" and all(.[]; type == "object" and (.severity | type == "string")))))' \
                "$work/log.json" >/dev/null 2>&1; then
                cp "$work/log.json" "$log"
                diagnostics=true
                warning_count=$(jq '[.issues[]? | select(.severity | ascii_downcase == "warning")] | length' "$log")
            fi
        fi
        ;;
esac
write_receipt
if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
    printf '### Cadence notarization: %s\n\n- Archive: %s\n- Submission: %s\n- Status: **%s**\n- Verified diagnostics: %s\n- Submitted SHA256: %s\n\n' \
        "$stage" "$expected" "$submission_id" "$status" "$diagnostics" "$submitted_sha256" >> "$GITHUB_STEP_SUMMARY"
fi
[[ $wait_result == 0 && $status == Accepted && $diagnostics == true ]] || fail "Notarization is not fully verified ($status, wait exit $wait_result, diagnostics $diagnostics). Receipt: $receipt. Retain the ID and reconcile it before another submission."
current_sha256=$(shasum -a 256 "$archive"); current_sha256=${current_sha256%% *}
[[ $current_sha256 == "$submitted_sha256" ]] || fail 'Archive changed after submission.'
printf 'Accepted with matching Apple diagnostics: %s\n' "$expected"

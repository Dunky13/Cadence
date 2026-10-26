#!/bin/bash
# Explicit prepare/submit/wait. Restored or attempted intents never upload again.
# jq programs intentionally use literal dollar names.
# shellcheck disable=SC2016
{ set +x; } 2>/dev/null
set -euo pipefail
umask 077
fail() { printf 'notarize-artifact: %s\n' "$*" >&2; exit 1; }
# shellcheck source=scripts/apple-stage-state.sh
source "$(dirname "$0")/apple-stage-state.sh"
archive='' stage='' version='' build='' architecture='' evidence='' operation=wait
while [[ $# -gt 0 ]]; do
    [[ $# -ge 2 && -n $2 ]] || fail 'Options require a value.'
    case "$1" in
        --archive) archive=$2 ;; --stage) stage=$2 ;; --version) version=$2 ;;
        --build) build=$2 ;; --architecture) architecture=$2 ;; --evidence-dir) evidence=$2 ;;
        --operation) operation=$2 ;; *) fail "Unknown option: $1" ;;
    esac
    shift 2
done
[[ $(uname -s) == Darwin ]] || fail 'macOS is required.'
for tool in xcrun jq shasum mktemp; do command -v "$tool" >/dev/null || fail "Missing prerequisite: $tool"; done
binding=$(apple_binding "$version" "$build" "$architecture")
case $operation in prepare|claim|submit|wait|verify) ;; *) fail 'Operation must be prepare, claim, submit, wait, or verify.' ;; esac
case "$stage" in
    app) expected="Cadence-App-$version-build-$build-$architecture.zip" ;;
    installer) expected="Cadence-Installer-$version-build-$build-$architecture.dmg" ;;
    *) fail 'Stage must be app or installer.' ;;
esac
apple_regular "$archive"
[[ ${archive##*/} == "$expected" ]] || fail "Expected an archive named $expected."
[[ -n $evidence ]] || fail 'An evidence directory is required.'
mkdir -p "$evidence"
[[ -d $evidence && ! -L $evidence ]] || fail 'Evidence must be a directory, not a symlink.'
receipt="$evidence/$stage-$architecture-receipt.json"
log="$evidence/$stage-$architecture-log.json"
lock_directory=${APPLE_NOTARY_LOCK_DIRECTORY:-$evidence}
[[ -d $lock_directory && ! -L $lock_directory ]] || fail 'Invalid process lock directory.'
lock="$lock_directory/.$stage-$architecture.lock"
mkdir "$lock" 2>/dev/null || fail 'Another process owns this evidence stage.'
work=''
cleanup() {
    result=$?; trap - EXIT
    if [[ -n $work ]]; then rm -rf -- "$work" || result=1; fi
    rmdir "$lock" || result=1
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
work=$(mktemp -d "${TMPDIR:-/tmp}/cadence-notary.XXXXXX")
sha=$(apple_sha "$archive")
if [[ -e $receipt || -L $receipt ]]; then
    apple_regular "$receipt"
    jq -se --argjson binding "$binding" --arg stage "$stage" --arg name "$expected" --arg sha "$sha" '
        length == 1 and (.[0] | .schema == "cadence/apple-notarization/v2" and .binding == $binding
        and .stage == $stage and .archive_filename == $name and .submitted_sha256 == $sha
        and (.ci_run.id | type == "string" and test("^[1-9][0-9]*$"))
        and (.ci_run.attempt | type == "string" and test("^[1-9][0-9]*$"))
        and (.restored | type == "boolean") and (.attempted | type == "boolean") and (.diagnostics.verified | type == "boolean")
        and (.upload_claimed | type == "boolean") and (.claim_restored | type == "boolean")
        and (if .upload_claimed then
            (.upload_owner.id | type == "string" and test("^[1-9][0-9]*$")) and
            (.upload_owner.attempt | type == "string" and test("^[1-9][0-9]*$"))
            else .upload_owner == null and .attempted == false end)
        and (.submission_id == null or (.submission_id | type == "string" and
          test("^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$")))
        and (if .attempted == false then .submission_id == null and .status == "Prepared" else true end))' \
        "$receipt" >/dev/null || fail 'Unbound, legacy, malformed, or mismatched receipt/archive.'
else
    [[ $operation == prepare && ! -e $log && ! -L $log ]] || fail 'Prepare a bound intent before any network operation.'
    jq -n --argjson binding "$binding" --arg stage "$stage" --arg name "$expected" --arg sha "$sha" \
        --arg run "$GITHUB_RUN_ID" --arg attempt "$GITHUB_RUN_ATTEMPT" '
        {schema:"cadence/apple-notarization/v2",binding:$binding,stage:$stage,archive_filename:$name,
         submitted_sha256:$sha,ci_run:{id:$run,attempt:$attempt},restored:false,attempted:false,
         upload_claimed:false,claim_restored:false,upload_owner:null,
         submission_id:null,status:"Prepared",wait_exit_status:null,
         diagnostics:{verified:false,log_file:null,warning_count:null}}' > "$work/receipt.json"
    apple_atomic "$work/receipt.json" "$receipt"
fi
[[ $operation != prepare ]] || exit 0
id=$(jq -r '.submission_id // empty' "$receipt")
verify_accepted() {
    apple_regular "$log"
    [[ -n $id && $(jq -r .status "$receipt") == Accepted && $(jq -r .diagnostics.verified "$receipt") == true \
        && $(jq -r .wait_exit_status "$receipt") == 0 ]] \
        || fail 'Accepted receipt and diagnostics are required.'
    apple_log_matches "$log" "$id" Accepted "$expected" "$sha" || fail 'Retained Apple diagnostics do not match the submitted bytes.'
    [[ $(apple_sha "$archive") == "$sha" ]] || fail 'Archive changed after submission.'
}
if [[ $operation == verify ]]; then verify_accepted; exit 0; fi
timeout=${APPLE_NOTARY_TIMEOUT:-30m}
[[ $timeout =~ ^[1-9][0-9]*[smh]$ ]] || fail 'APPLE_NOTARY_TIMEOUT must be a positive finite duration.'
auth=()
if [[ -n ${NOTARY_KEYCHAIN_PROFILE:-} ]]; then
    [[ -z ${NOTARY_KEY_FILE:-} ]] || fail 'Choose one notary authentication method.'
    auth=(--keychain-profile "$NOTARY_KEYCHAIN_PROFILE")
    if [[ -n ${NOTARY_KEYCHAIN:-} ]]; then auth+=(--keychain "$NOTARY_KEYCHAIN"); fi
else
    [[ -f ${NOTARY_KEY_FILE:-} && -n ${NOTARY_KEY_ID:-} && -n ${NOTARY_ISSUER_ID:-} ]] || fail 'Configure a notary keychain profile or API key file, ID, and issuer.'
    auth=(--key "$NOTARY_KEY_FILE" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
fi
# update passes jq programs unchanged; dollar names belong to jq.
# shellcheck disable=SC2016
update() { jq "$@" "$receipt" > "$work/receipt.json"; apple_atomic "$work/receipt.json" "$receipt"; }
if [[ $operation == claim ]]; then
    if [[ $(jq -r .upload_claimed "$receipt") == false ]]; then
        [[ -z $id && $(jq -r .attempted "$receipt") == false ]] || fail 'An attempted submission cannot be claimed again.'
        update --arg run "$GITHUB_RUN_ID" --arg attempt "$GITHUB_RUN_ATTEMPT" \
            '.upload_claimed = true | .claim_restored = false | .upload_owner = {id:$run,attempt:$attempt}'
    fi
    # The caller must persist this claim before entering the separate upload step.
    exit 0
fi
read_id() {
    jq -ser '(if length == 1 then .[0].id else null end) |
        select(type == "string" and test("^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$")) | ascii_downcase' "$1" 2>/dev/null
}
read_status() {
    jq -ser --arg id "$id" 'length == 1 and (.[0].id | type == "string" and ascii_downcase == $id)' "$1" >/dev/null 2>&1 || return 1
    jq -er '.status | select(. == "Accepted" or . == "Invalid" or . == "Rejected" or . == "In Progress" or . == "Submitted")' "$1"
}
retain_unverified() {
    # Keep only diagnostic fields, never raw client stdout/stderr or auth inputs.
    if jq -se 'if length == 1 and (.[0] | type == "object") then
        .[0] | {jobId,status,archiveFilename,sha256,issues} else empty end' "$1" > "$work/unverified.json"; then
        apple_atomic "$work/unverified.json" "$evidence/$stage-$architecture-unverified-log.json"
    fi
}
pending() { printf 'notarize-artifact: %s; retained state: %s\n' "$*" "$receipt" >&2; exit 75; }
if [[ $operation == submit && $(jq -r .upload_claimed "$receipt") == true && $(jq -r .claim_restored "$receipt") == false \
    && -z $id && $(jq -r .attempted "$receipt") == false \
    && $(jq -r .upload_owner.id "$receipt") == "$GITHUB_RUN_ID" \
    && $(jq -r .upload_owner.attempt "$receipt") == "$GITHUB_RUN_ATTEMPT" ]]; then
    # Persist before upload, including when the process dies without an answer.
    update '.attempted = true | .status = "Unknown"'
    submit_result=0
    xcrun notarytool submit "$archive" "${auth[@]}" --no-wait --output-format json \
        > "$work/submit.json" 2> "$work/submit.stderr" || submit_result=$?
    id=$(read_id "$work/submit.json") || id=''
    if [[ -n $id ]]; then
        update --arg id "$id" '.submission_id = $id | .status = "Submitted"'
        [[ $(apple_sha "$archive") == "$sha" ]] || fail 'Archive changed during submission.'
        printf 'Retained %s UUID: %s\n' "$stage" "$id"
        [[ $submit_result == 0 ]] || pending "Submit returned UUID with exit $submit_result; reconcile it"
        exit 0
    fi
    pending 'Upload result has no verified UUID; reconcile history on the next invocation, never resubmit'
fi
if [[ -z $id ]]; then
    # A restored, never-attempted intent is also uncertain: its previous owner
    # may have uploaded after its last durable checkpoint. History is mandatory.
    xcrun notarytool history "${auth[@]}" --output-format json > "$work/history.json" 2> "$work/history.stderr" \
        || pending 'Apple history is unavailable'
    jq -se 'length == 1 and (.[0].history | type == "array" and all(.[];
        (.name | type == "string") and (.id | type == "string" and
          test("^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$"))))' "$work/history.json" >/dev/null \
        || fail 'Malformed Apple history.'
    jq -r --arg name "$expected" '.history[] | select(.name == $name) | .id | ascii_downcase' "$work/history.json" > "$work/matches"
    count=$(wc -l < "$work/matches" | tr -d ' ')
    [[ $count == 1 ]] || pending 'Missing or ambiguous history; no upload is permitted'
    read -r id < "$work/matches"
    xcrun notarytool log "$id" "${auth[@]}" "$work/recovered-log.json" > "$work/log.stdout" 2> "$work/log.stderr" \
        || pending 'Final history log is unavailable (possibly still pending)'
    status=$(jq -er '.status | select(. == "Accepted" or . == "Invalid" or . == "Rejected")' "$work/recovered-log.json") \
        || fail 'History log is not final.'
    if ! apple_log_matches "$work/recovered-log.json" "$id" "$status" "$expected" "$sha"; then
        retain_unverified "$work/recovered-log.json"
        fail 'History log identity/hash mismatch; no upload is permitted.'
    fi
    update --arg id "$id" '.submission_id = $id | .attempted = true | .status = "Submitted"'
    # UUID must be durable before any further status request.
fi
# submit on a restored/existing intent only reconciles; no wait until its checkpoint.
if [[ $operation == submit ]]; then exit 0; fi
info_result=0
xcrun notarytool info "$id" "${auth[@]}" --output-format json > "$work/info.json" 2> "$work/info.stderr" || info_result=$?
[[ $info_result == 0 ]] || pending 'Submission info is unavailable'
status=$(read_status "$work/info.json") || fail 'Malformed/mismatched submission info.'
wait_result=0
case $status in
    'In Progress'|Submitted)
        xcrun notarytool wait "$id" "${auth[@]}" --timeout "$timeout" --output-format json \
            > "$work/wait.json" 2> "$work/wait.stderr" || wait_result=$?
        status=$(read_status "$work/wait.json") || pending 'Wait did not return verifiable status'
        ;;
esac
update --arg status "$status" --argjson result "$wait_result" \
    '.status = $status | .wait_exit_status = $result | .diagnostics = {verified:false,log_file:null,warning_count:null}'
case $status in
    Accepted|Invalid|Rejected)
        xcrun notarytool log "$id" "${auth[@]}" "$work/log.json" > "$work/log.stdout" 2> "$work/log.stderr" \
            || fail 'Final diagnostics are unavailable.'
        if ! apple_log_matches "$work/log.json" "$id" "$status" "$expected" "$sha"; then
            retain_unverified "$work/log.json"
            fail 'Apple diagnostics do not match submission ID, status, filename, or SHA256.'
        fi
        apple_atomic "$work/log.json" "$log"
        warnings=$(jq '[.issues[]? | select(.severity | ascii_downcase == "warning")] | length' "$log")
        update --arg log "${log##*/}" --argjson warnings "$warnings" \
            '.diagnostics = {verified:true,log_file:$log,warning_count:$warnings}'
        [[ $status == Accepted ]] || fail "Apple returned $status; retained rejection diagnostics."
        [[ $wait_result == 0 ]] || pending "Wait exited $wait_result; recheck retained UUID"
        verify_accepted
        ;;
    *) pending "Apple returned $status" ;;
esac
printf 'Accepted with matching Apple diagnostics: %s\n' "$expected"

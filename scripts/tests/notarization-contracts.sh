#!/bin/bash
# Exercise notarization contracts with a fake xcrun. Never contact Apple.
set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
helper="$root/scripts/notarize-artifact.sh"
for tool in jq shasum mktemp; do
    command -v "$tool" >/dev/null || { printf 'Missing test prerequisite: %s\n' "$tool" >&2; exit 1; }
done
work=$(mktemp -d "${TMPDIR:-/tmp}/cadence-notary-contracts.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"
cat > "$work/bin/xcrun" <<'STUB'
#!/bin/bash
set -euo pipefail
[[ ${1:-} == notarytool ]] || exit 91
operation=${2:-}
shift 2
printf '%s\n' "$operation" >> "$FAKE_CALL_LOG"
id='A1234567-89AB-4CDE-8123-456789ABCDEF'
mode=${FAKE_MODE:-accepted}
case "$operation" in
    submit)
        no_wait=false
        for argument in "$@"; do
            [[ $argument != --wait ]] || exit 92
            if [[ $argument == --no-wait ]]; then no_wait=true; fi
        done
        [[ $no_wait == true ]] || exit 93
        printf 'FAKE_PRIVATE_STDERR_MARKER\n' >&2
        case "$mode" in
            submit-failure) printf '{"status":"Unknown"}\n'; exit 7 ;;
            submit-failure-with-id) printf '{"id":"%s","status":"In Progress"}\n' "$id"; exit 7 ;;
            missing-id) printf '{"status":"Submitted"}\n' ;;
            invalid-id) printf '{"id":"not-a-uuid","status":"Submitted"}\n' ;;
            malformed-submit) printf '{not JSON\n' ;;
            *) printf '{"id":"%s","status":"In Progress"}\n' "$id" ;;
        esac
        ;;
    wait)
        [[ ${1:-} == a1234567-89ab-4cde-8123-456789abcdef ]] || exit 94
        printf 'FAKE_PRIVATE_STDERR_MARKER\n' >&2
        case "$mode" in
            timeout) printf '{"id":"%s","status":"In Progress"}\n' "$id"; exit 124 ;;
            invalid) printf '{"id":"%s","status":"Invalid"}\n' "$id"; exit 65 ;;
            rejected) printf '{"id":"%s","status":"Rejected"}\n' "$id" ;;
            wait-error) printf '{"id":"%s","status":"Accepted"}\n' "$id"; exit 8 ;;
            tamper)
                printf 'tampered after upload\n' >> "$FAKE_ARCHIVE"
                printf '{"id":"%s","status":"Accepted"}\n' "$id"
                ;;
            *) printf '{"id":"%s","status":"Accepted"}\n' "$id" ;;
        esac
        ;;
    log)
        [[ ${1:-} == a1234567-89ab-4cde-8123-456789abcdef ]] || exit 95
        output=''
        for argument in "$@"; do output=$argument; done
        [[ -n $output ]] || exit 96
        printf 'FAKE_PRIVATE_STDERR_MARKER\n' >&2
        case "$mode" in
            missing-log) exit 9 ;;
            malformed-log) printf '{not JSON\n' > "$output"; exit 0 ;;
        esac
        log_id=$id
        log_status=Accepted
        filename=${FAKE_ARCHIVE##*/}
        sha=$FAKE_ORIGINAL_SHA
        issues='[]'
        case "$mode" in
            invalid) log_status=Invalid ;;
            rejected) log_status=Rejected ;;
            wrong-log-id) log_id='B1234567-89AB-4CDE-8123-456789ABCDEF' ;;
            wrong-log-status) log_status=Invalid ;;
            wrong-filename) filename='Another-App-1.2.3-universal.zip' ;;
            wrong-sha) sha='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' ;;
            invalid-issues) issues='[{"severity":true}]' ;;
            warnings) issues='[{"severity":"warning","message":"Fixture warning"},{"severity":"Warning","message":"Second fixture warning"},{"severity":"info"}]' ;;
        esac
        if [[ $mode == minimal-log ]]; then
            jq -n --arg id "$log_id" --arg status "$log_status" '{jobId:$id,status:$status,issues:null}' > "$output"
        else
            jq -n --arg id "$log_id" --arg status "$log_status" --arg filename "$filename" \
                --arg sha "$sha" --argjson issues "$issues" \
                '{jobId:$id,status:$status,archiveFilename:$filename,sha256:$sha,issues:$issues}' > "$output"
        fi
        ;;
    *) exit 97 ;;
esac
STUB
chmod +x "$work/bin/xcrun"

cases=0
source_commit='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
fail() { printf 'FAIL: %s (%s)\n' "$case_name" "$*" >&2; exit 1; }
passed() { cases=$((cases + 1)); printf 'PASS: %s\n' "$case_name"; }
new_case() {
    case_name=$1
    directory="$work/$case_name"
    mkdir "$directory"
    stage=${2:-app}
    extension=zip
    prefix=App
    if [[ $stage == installer ]]; then extension=dmg; prefix=Installer; fi
    archive="$directory/Cadence-$prefix-1.2.3-universal.$extension"
    evidence="$directory/evidence"
    receipt="$evidence/$stage-universal-receipt.json"
    diagnostic="$evidence/$stage-universal-log.json"
    calls="$directory/calls"
    : > "$calls"
    printf 'immutable fixture archive bytes\n' > "$archive"
    original_sha=$(shasum -a 256 "$archive")
    original_sha=${original_sha%% *}
    test_source_commit=$source_commit
    test_timeout=1s
}
invoke() {
    mode=$1
    shift
    result=0
    (
        unset NOTARY_KEY_FILE NOTARY_KEY_ID NOTARY_ISSUER_ID NOTARY_KEYCHAIN
        unset NOTARY_KEYCHAIN_PROFILE GITHUB_STEP_SUMMARY APPLE_NOTARY_TIMEOUT
        if [[ $mode != no-auth ]]; then export NOTARY_KEYCHAIN_PROFILE=fixture-profile; fi
        export PATH="$work/bin:$PATH"
        export SOURCE_COMMIT="$test_source_commit" APPLE_NOTARY_TIMEOUT="$test_timeout"
        export FAKE_MODE="$mode" FAKE_CALL_LOG="$calls" FAKE_ARCHIVE="$archive" FAKE_ORIGINAL_SHA="$original_sha"
        export GITHUB_STEP_SUMMARY="$directory/summary.md"
        export GITHUB_RUN_ID=12345 GITHUB_RUN_ATTEMPT=2
        /bin/bash "$helper" --archive "$archive" --stage "$stage" --version 1.2.3 \
            --architecture universal --evidence-dir "$evidence" "$@"
    ) > "$directory/stdout" 2> "$directory/stderr" || result=$?
}
call_count() {
    awk -v operation="$1" '$0 == operation { count++ } END { print count+0 }' "$calls"
}
assert_calls() {
    [[ $(call_count submit) == "$1" && $(call_count wait) == "$2" && $(call_count log) == "$3" ]] ||
        fail "unexpected submit/wait/log calls: $(tr '\n' ',' < "$calls")"
}
assert_success() { [[ $result == 0 ]] || fail "helper exited $result"; }
assert_failure() { [[ $result != 0 ]] || fail 'helper unexpectedly succeeded'; }
assert_receipt() {
    [[ -f $receipt ]] || fail 'missing public receipt'
    jq -e "$1" "$receipt" >/dev/null || fail "receipt assertion: $1"
}
assert_no_private_output() {
    if [[ -d $evidence ]] && grep -REq 'FAKE_PRIVATE_STDERR_MARKER|fixture-profile' "$evidence"; then
        fail 'private tool output or authentication input was retained in public evidence'
    fi
}

new_case accepted-app
invoke accepted
assert_success
assert_calls 1 1 1
assert_receipt '.schema == "cadence/apple-notarization/v1" and .app == "Cadence" and .version == "1.2.3" and .architecture == "universal" and .stage == "app" and .archive_filename == "Cadence-App-1.2.3-universal.zip" and .source_commit == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" and .submission_id == "a1234567-89ab-4cde-8123-456789abcdef" and .status == "Accepted" and .wait_exit_status == 0 and .diagnostics.verified and .diagnostics.warning_count == 0'
jq -e --arg sha "$original_sha" '.submitted_sha256 == $sha' "$receipt" >/dev/null || fail 'wrong submitted digest'
assert_receipt '.ci_run.id == "12345" and .ci_run.attempt == "2"'
[[ -f $diagnostic ]] || fail 'matching diagnostic log not retained'
grep -Fq 'Cadence-App-1.2.3-universal.zip' "$directory/summary.md" || fail 'missing descriptive summary'
assert_no_private_output
passed

new_case accepted-installer installer
invoke accepted
assert_success
assert_calls 1 1 1
assert_receipt '.stage == "installer" and .archive_filename == "Cadence-Installer-1.2.3-universal.dmg" and .diagnostics.log_file == "installer-universal-log.json"'
passed

new_case accepted-minimal-diagnostics
invoke minimal-log
assert_success
assert_receipt '.diagnostics.verified and .diagnostics.warning_count == 0'
passed

new_case accepted-warning-count
invoke warnings
assert_success
assert_receipt '.diagnostics.verified and .diagnostics.warning_count == 2'
passed

for mode in invalid rejected; do
    new_case "$mode"
    invoke "$mode"
    assert_failure
    assert_calls 1 1 1
    assert_receipt '.submission_id != null and .diagnostics.verified and (.status == "Invalid" or .status == "Rejected")'
    [[ -f $diagnostic ]] || fail 'rejection diagnostic was discarded'
    assert_no_private_output
    passed
done

new_case wait-timeout
invoke timeout
assert_failure
assert_calls 1 1 0
assert_receipt '.status == "In Progress" and .submission_id != null and .wait_exit_status == 124 and (.diagnostics.verified | not)'
passed

for mode in submit-failure missing-id invalid-id malformed-submit; do
    new_case "$mode"
    invoke "$mode"
    assert_failure
    assert_calls 1 0 0
    assert_receipt '.submission_id == null and (.diagnostics.verified | not)'
    assert_no_private_output
    passed
done

new_case failed-submit-retains-returned-id
invoke submit-failure-with-id
assert_failure
assert_calls 1 0 0
assert_receipt '.submission_id == "a1234567-89ab-4cde-8123-456789abcdef" and (.diagnostics.verified | not)'
passed

for mode in wrong-log-id wrong-log-status malformed-log missing-log wrong-filename wrong-sha invalid-issues; do
    new_case "$mode"
    invoke "$mode"
    assert_failure
    assert_calls 1 1 1
    assert_receipt '.status == "Accepted" and .submission_id != null and (.diagnostics.verified | not) and .diagnostics.log_file == null'
    [[ ! -e $diagnostic ]] || fail 'unverified diagnostic was promoted'
    assert_no_private_output
    passed
done

new_case wait-exit-failure-even-with-accepted-log
invoke wait-error
assert_failure
assert_calls 1 1 1
assert_receipt '.status == "Accepted" and .wait_exit_status == 8 and .diagnostics.verified'
passed

new_case archive-changed-after-wait
invoke tamper
assert_failure
assert_calls 1 1 1
assert_receipt '.status == "Accepted" and .diagnostics.verified'
grep -Fq 'Archive changed after submission' "$directory/stderr" || fail 'archive mutation was not detected'
jq -e --arg sha "$original_sha" '.submitted_sha256 == $sha' "$receipt" >/dev/null || fail 'original digest was overwritten'
passed

new_case existing-evidence-blocks-resubmission
invoke accepted
assert_success
receipt_sha=$(shasum -a 256 "$receipt")
invoke accepted
assert_failure
assert_calls 1 1 1
[[ $(shasum -a 256 "$receipt") == "$receipt_sha" ]] || fail 'existing receipt was overwritten'
passed

new_case existing-log-blocks-submission
mkdir "$evidence"
printf 'existing diagnostic\n' > "$diagnostic"
invoke accepted
assert_failure
assert_calls 0 0 0
grep -Fxq 'existing diagnostic' "$diagnostic" || fail 'existing log was overwritten'
passed

new_case existing-stage-lock-blocks-submission
mkdir -p "$evidence/.app-universal.lock"
printf 'owned by another submitter\n' > "$evidence/.app-universal.lock/owner"
invoke accepted
assert_failure
assert_calls 0 0 0
[[ ! -e $receipt ]] || fail 'Another submitter lock was bypassed'
grep -Fxq 'owned by another submitter' "$evidence/.app-universal.lock/owner" || fail 'Another submitter lock was modified'
passed

new_case missing-authentication
invoke no-auth
assert_failure
assert_calls 0 0 0
[[ ! -e $receipt ]] || fail 'upload receipt created without authentication'
passed

new_case wrong-project-name
wrong="$directory/Another-App-1.2.3-universal.zip"
cp "$archive" "$wrong"
invoke accepted --archive "$wrong"
assert_failure
assert_calls 0 0 0
passed

new_case invalid-version
invoke accepted --version v1.2.3
assert_failure
assert_calls 0 0 0
passed

new_case archive-version-mismatch
invoke accepted --version 1.2.4
assert_failure
assert_calls 0 0 0
passed

new_case invalid-architecture
invoke accepted --architecture linux
assert_failure
assert_calls 0 0 0
passed

new_case archive-architecture-mismatch
invoke accepted --architecture arm64
assert_failure
assert_calls 0 0 0
passed

new_case invalid-stage
invoke accepted --stage payload
assert_failure
assert_calls 0 0 0
passed

new_case archive-stage-mismatch
invoke accepted --stage installer
assert_failure
assert_calls 0 0 0
passed

new_case symlink-archive
link="$directory/link/Cadence-App-1.2.3-universal.zip"
mkdir "$directory/link"
ln -s "$archive" "$link"
invoke accepted --archive "$link"
assert_failure
assert_calls 0 0 0
passed

new_case missing-option-value
invoke accepted --version
assert_failure
assert_calls 0 0 0
passed

new_case invalid-timeout
test_timeout=forever
invoke accepted
assert_failure
assert_calls 0 0 0
passed

new_case invalid-source-commit
test_source_commit=12345
invoke accepted
assert_failure
assert_calls 0 0 0
passed

printf 'Notarization contracts: %s cases passed; no Apple services contacted.\n' "$cases"

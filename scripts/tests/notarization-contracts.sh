#!/bin/bash
# Durable receipt/recovery contracts. Fake provider only; no Apple services.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/cadence-notary-contracts.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"
cat > "$work/bin/uname" <<'STUB'
#!/bin/bash
printf 'Darwin\n'
STUB
cat > "$work/bin/xcrun" <<'STUB'
#!/bin/bash
set -euo pipefail
[[ $1 == notarytool ]] || exit 91
operation=$2; shift 2
printf '%s\n' "$operation" >> "$FAKE_CALL_LOG"
id=a1234567-89ab-4cde-8123-456789abcdef
mode=${FAKE_MODE:-accepted}
case $operation in
    submit)
        [[ " $* " == *' --no-wait '* && " $* " != *' --wait '* ]] || exit 92
        printf 'FAKE_PRIVATE_STDERR_MARKER\n' >&2
        case $mode in
            missing-id) printf '{"status":"Submitted"}'; exit 7 ;;
            failure-with-id) printf '{"id":"%s","status":"In Progress"}' "$id"; exit 7 ;;
        esac
        printf '{"id":"%s","status":"In Progress"}\n' "$id" ;;
    history)
        case $mode in
            history-unavailable) exit 9 ;;
            history-missing) printf '{"history":[]}'; exit 0 ;;
            history-ambiguous)
                jq -n --arg id "$id" --arg name "${FAKE_ARCHIVE##*/}" '{history:[{id:$id,name:$name},{id:$id,name:$name}]}'
                exit 0 ;;
        esac
        jq -n --arg id "$id" --arg name "${FAKE_ARCHIVE##*/}" '{history:[{id:$id,name:$name}]}' ;;
    info|wait)
        [[ $1 == "$id" ]] || exit 94
        status='In Progress'
        if [[ $operation == wait ]]; then
            [[ " $* " == *' --timeout 1s '* ]] || exit 93
            status=Accepted
            case $mode in pending) status='In Progress' ;; rejected) status=Rejected ;; invalid) status=Invalid ;; esac
        fi
        if [[ $mode == wrong-info-id && $operation == info ]]; then id=b1234567-89ab-4cde-8123-456789abcdef; fi
        if [[ $mode == tamper && $operation == wait ]]; then printf 'changed' >> "$FAKE_ARCHIVE"; fi
        printf '{"id":"%s","status":"%s"}\n' "$id" "$status"
        [[ $mode != pending || $operation != wait ]] || exit 124
        [[ $mode != wait-error || $operation != wait ]] || exit 8
        ;;
    log)
        output=''; for argument in "$@"; do output=$argument; done
        case $mode in missing-log|pending-log) exit 9 ;; esac
        status=Accepted name=${FAKE_ARCHIVE##*/} sha=$FAKE_ORIGINAL_SHA issues='[]'
        case $mode in
            rejected) status=Rejected ;; invalid) status=Invalid ;;
            wrong-log-id) id=b1234567-89ab-4cde-8123-456789abcdef ;;
            wrong-log-status) status=Invalid ;;
            wrong-filename) name=wrong.zip ;;
            wrong-sha) sha=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb ;;
            warnings) issues='[{"severity":"warning"},{"severity":"Warning"}]' ;;
            invalid-issues) issues='[{"severity":true}]' ;;
        esac
        jq -n --arg id "$id" --arg status "$status" --arg name "$name" --arg sha "$sha" --argjson issues "$issues" \
            '{jobId:$id,status:$status,archiveFilename:$name,sha256:$sha,issues:$issues}' > "$output"
        if [[ $mode == missing-log-sha ]]; then jq 'del(.sha256)' "$output" > "$output.tmp"; mv "$output.tmp" "$output"; fi
        ;;
    *) exit 97 ;;
esac
STUB
chmod +x "$work/bin/"*
export PATH="$work/bin:$PATH" SOURCE_COMMIT=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
export BUILD_CI_RUN_ID=101 BUILD_ARTIFACT_ID=202 BUILD_ARTIFACT_DIGEST=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
export APPLE_TEAM_ID=ABC1234567 GITHUB_RUN_ID=303 GITHUB_RUN_ATTEMPT=1 APPLE_NOTARY_TIMEOUT=1s
export NOTARY_KEYCHAIN_PROFILE=fixture-profile
unset APPLE_NOTARY_LOCK_DIRECTORY
unset NOTARY_KEY_FILE NOTARY_KEYCHAIN NOTARY_KEY_ID NOTARY_ISSUER_ID
cases=0
fail() { printf 'FAIL %s: %s\n' "$case_name" "$*" >&2; cat "$directory/output" >&2; exit 1; }
new_case() {
    case_name=$1 stage=${2:-app}
    directory="$work/$case_name"; mkdir "$directory"
    archive="$directory/Cadence-App-1.2.3-build-42-universal.zip"
    [[ $stage != installer ]] || archive="$directory/Cadence-Installer-1.2.3-build-42-universal.dmg"
    printf 'exact retained bytes' > "$archive"
    original_sha=$(shasum -a 256 < "$archive"); original_sha=${original_sha%% *}
    evidence="$directory/evidence" receipt="$directory/evidence/$stage-universal-receipt.json"
    calls="$directory/calls"; : > "$calls"
    export GITHUB_RUN_ID=303 GITHUB_RUN_ATTEMPT=1
}
invoke() {
    result=0
    FAKE_CALL_LOG="$calls" FAKE_ARCHIVE="$archive" FAKE_ORIGINAL_SHA="$original_sha" FAKE_MODE="$2" \
        bash "$root/scripts/notarize-artifact.sh" --archive "$archive" --stage "$stage" --version 1.2.3 --build 42 \
        --architecture universal --evidence-dir "$evidence" --operation "$1" "${@:3}" > "$directory/output" 2>&1 || result=$?
}
expect() { [[ $result == "$1" ]] || fail "expected exit $1, got $result"; }
count() { awk -v op="$1" '$0 == op {n++} END {print n+0}' "$calls"; }
assert_json() { jq -e "$1" "$receipt" >/dev/null || fail "receipt assertion: $1"; }
passed() {
    if [[ -d $evidence ]]; then
        leak_status=0
        grep -R -q -E 'FAKE_PRIVATE_STDERR_MARKER|fixture-profile' "$evidence" || leak_status=$?
        case $leak_status in
            0) fail 'private evidence leak' ;;
            1) ;;
            *) fail 'could not scan retained evidence for private data' ;;
        esac
    fi
    cases=$((cases+1)); printf 'PASS %s\n' "$case_name"
}
prepare() { invoke prepare accepted; expect 0; [[ ! -s $calls ]] || fail 'prepare used network'; invoke claim accepted; expect 0; }
submit() { invoke submit accepted; expect 0; }

for kind in app installer; do
    new_case "accepted-$kind" "$kind"
    prepare; prepare
    assert_json '.schema == "cadence/apple-notarization/v2" and .attempted == false and .binding.build_number == "42" and .ci_run.id == "303"'
    submit
    assert_json '.attempted and .submission_id == "a1234567-89ab-4cde-8123-456789abcdef"'
    [[ $(count wait) == 0 ]] || fail 'submit waited before checkpoint'
    invoke wait accepted; expect 0
    assert_json '.status == "Accepted" and .diagnostics.verified'
    export GITHUB_RUN_ID=404 GITHUB_RUN_ATTEMPT=2
    invoke submit accepted; expect 0
    invoke wait accepted; expect 0
    invoke verify accepted; expect 0
    [[ $(count submit) == 1 ]] || fail 'resubmitted retained UUID'
    passed
done
new_case restored-unattempted-intent
prepare
export GITHUB_RUN_ATTEMPT=2
invoke submit accepted; expect 0
[[ $(count submit) == 0 && $(count history) == 1 ]] || fail 'restored intent uploaded'
assert_json '.attempted and .submission_id != null and .ci_run.attempt == "1"'
invoke wait accepted; expect 0
passed
new_case restored-same-owner
prepare
jq '.restored=true | .claim_restored=true' "$receipt" > "$directory/changed"; mv "$directory/changed" "$receipt"
invoke submit accepted; expect 0
[[ $(count submit) == 0 && $(count history) == 1 ]] || fail 'explicit restored intent uploaded'
passed
new_case cancelled-before-upload-claim
invoke prepare accepted; expect 0
jq '.restored=true' "$receipt" > "$directory/changed"; mv "$directory/changed" "$receipt"
export GITHUB_RUN_ID=404 GITHUB_RUN_ATTEMPT=2
invoke claim history-missing; expect 0
invoke submit history-missing; expect 0
[[ $(count submit) == 1 && $(count history) == 0 ]] || fail 'proven unclaimed state did not upload exactly once'
assert_json '.ci_run.id == "303" and .upload_owner.id == "404" and .attempted'
passed
new_case claimed-uncertainty-stays-closed
prepare
jq '.restored=true | .claim_restored=true' "$receipt" > "$directory/changed"; mv "$directory/changed" "$receipt"
invoke claim history-missing; expect 0
invoke submit history-missing; expect 75
invoke submit history-missing; expect 75
[[ $(count submit) == 0 ]] || fail 'ambiguous claimed upload repeated'
passed
new_case lost-uuid
prepare
invoke submit missing-id; expect 75
assert_json '.attempted and .submission_id == null'
invoke submit accepted; expect 0
invoke wait accepted; expect 0
[[ $(count submit) == 1 && $(count history) == 1 ]] || fail 'lost UUID was resubmitted'
passed
new_case failed-submit-retains-id
prepare; invoke submit failure-with-id; expect 75
invoke wait accepted; expect 0
[[ $(count submit) == 1 ]] || fail 'resubmitted failure with UUID'
passed
for mode in history-missing history-ambiguous history-unavailable pending-log wrong-sha; do
    new_case "lost-uuid-$mode"
    prepare; invoke submit missing-id; expect 75
    invoke wait "$mode"
    if [[ $mode == wrong-sha ]]; then expect 1; else expect 75; fi
    assert_json '.submission_id == null'
    [[ $(count submit) == 1 ]] || fail 'uncertain upload repeated'
    passed
done
new_case pending-resumes
prepare; submit
invoke wait pending; expect 75
assert_json '.status == "In Progress" and .diagnostics.verified == false and .wait_exit_status == 124'
invoke wait accepted; expect 0
[[ $(count submit) == 1 ]] || fail 'pending submission repeated'
passed
new_case accepted-log-after-wait-error
prepare; submit
invoke wait wait-error; expect 75
assert_json '.status == "Accepted" and .diagnostics.verified and .wait_exit_status == 8'
invoke verify accepted; expect 1
invoke wait accepted; expect 0
invoke verify accepted; expect 0
[[ $(count submit) == 1 ]] || fail 'wait error repeated upload'
passed
for mode in rejected invalid wrong-log-id wrong-log-status wrong-filename wrong-sha invalid-issues missing-log missing-log-sha wrong-info-id tamper; do
    new_case "$mode"
    prepare; submit
    invoke wait "$mode"; expect 1
    invoke verify accepted; expect 1
    if [[ $mode == rejected || $mode == invalid ]]; then
        assert_json '.diagnostics.verified and .status != "Accepted"'
        [[ -f $evidence/$stage-universal-log.json ]] || fail 'rejection diagnostic lost'
    fi
    [[ $(count submit) == 1 ]] || fail 'submission repeated'
    passed
done
new_case warning-diagnostics
prepare; submit; invoke wait warnings; expect 0
assert_json '.diagnostics.warning_count == 2'
passed
for field in source_commit build_number bundle_id architecture team_id origin; do
    new_case "wrong-binding-$field"
    prepare
    jq --arg field "$field" '.binding[$field] = "wrong"' "$receipt" > "$directory/changed"
    mv "$directory/changed" "$receipt"
    invoke submit accepted; expect 1
    [[ ! -s $calls ]] || fail 'mismatched binding reached provider'
    passed
done
for field in BUILD_CI_RUN_ID BUILD_ARTIFACT_ID BUILD_ARTIFACT_DIGEST SOURCE_COMMIT APPLE_TEAM_ID GITHUB_RUN_ID GITHUB_RUN_ATTEMPT; do
    new_case "missing-$field"
    saved=${!field}; export "$field="
    invoke prepare accepted; expect 1
    export "$field=$saved"
    [[ ! -s $calls ]] || fail 'missing binding reached provider'
    passed
done
new_case wrong-archive-hash
prepare; printf 'tamper' >> "$archive"
invoke submit accepted; expect 1
[[ ! -s $calls ]] || fail 'changed archive uploaded'
passed
new_case legacy-receipt
prepare; jq '.schema = "cadence/apple-notarization/v1"' "$receipt" > "$directory/changed"; mv "$directory/changed" "$receipt"
invoke submit accepted; expect 1
[[ ! -s $calls ]] || fail 'legacy receipt reached provider'
passed
for field in binding binding.build_number submitted_sha256; do
    new_case "missing-receipt-$field"
    prepare
    jq --arg field "$field" 'delpaths([$field | split(".")])' "$receipt" > "$directory/changed"; mv "$directory/changed" "$receipt"
    invoke submit accepted; expect 1
    [[ ! -s $calls ]] || fail 'missing receipt binding reached provider'
    passed
done
new_case missing-build
invoke prepare accepted --build ''; expect 1
[[ ! -s $calls ]] || fail 'missing build reached provider'
passed
new_case missing-intent
invoke submit accepted; expect 1
[[ ! -s $calls ]] || fail 'submitted without intent'
passed
new_case lock
mkdir -p "$evidence/.app-universal.lock"
invoke prepare accepted; expect 1
[[ ! -s $calls ]] || fail 'lock bypassed'
passed
new_case wrong-build-name
invoke prepare accepted --build 43; expect 1
[[ ! -s $calls ]] || fail 'wrong build name reached provider'
passed
new_case changed-retained-log
prepare; submit; invoke wait accepted; expect 0
jq '.sha256="wrong"' "$evidence/app-universal-log.json" > "$directory/changed"; mv "$directory/changed" "$evidence/app-universal-log.json"
invoke verify accepted; expect 1
passed
printf 'Notarization contracts: %s cases passed; no Apple services contacted.\n' "$cases"

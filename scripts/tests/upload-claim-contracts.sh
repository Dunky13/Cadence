#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/cadence-claim-tests.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin" "$work/state" "$work/state/evidence"
cat > "$work/bin/gh" <<'STUB'
#!/bin/bash
[[ ${CLAIM_MODE:-} != api-failure ]] || exit 1
case $* in
    *attempts/1/jobs*)
        case ${CLAIM_MODE:-} in
            started) printf '[{"jobs":[{"steps":[{"name":"Candidate phase app-submit","conclusion":"cancelled","started_at":"2026-10-26T00:00:00Z"}]}]}]' ;;
            missing) printf '[{"jobs":[{"steps":[]}]}]' ;;
            duplicate) printf '[{"jobs":[{"steps":[{"name":"Candidate phase app-submit","conclusion":"skipped","started_at":null},{"name":"Candidate phase app-submit","conclusion":"skipped","started_at":null}]}]}]' ;;
            *) printf '[{"jobs":[{"steps":[{"name":"Candidate phase app-submit","conclusion":"skipped","started_at":null}]}]}]' ;;
        esac ;;
    *)
        if [[ ${CLAIM_MODE:-} == wrong-owner ]]; then printf '{"path":".github/workflows/ci.yml"}'; else
        printf '{"path":".github/workflows/release.yml","head_branch":"main","status":"completed","repository":{"full_name":"Dunky13/Cadence"},"head_repository":{"full_name":"Dunky13/Cadence"}}'; fi ;;
esac
STUB
chmod +x "$work/bin/gh"
receipt="$work/state/evidence/app-universal-receipt.json"
new_receipt() { printf '{"schema":"cadence/apple-notarization/v2","ci_run":{"id":"1","attempt":"1"},"upload_claimed":true,"claim_restored":true,"attempted":false,"submission_id":null,"upload_owner":{"id":"200","attempt":"1"}}' > "$receipt"; }
invoke() { result=0; PATH="$work/bin:$PATH" GITHUB_REPOSITORY=Dunky13/Cadence CLAIM_MODE=$1 bash "$root/scripts/recover-unstarted-upload.sh" "$work/state" > "$work/output" 2>&1 || result=$?; }
new_receipt; invoke skipped; [[ $result == 0 ]]
jq -e '.upload_claimed == false and .upload_owner == null and .ci_run.id == "1" and .unstarted_upload_proof.started_at == null' "$receipt" >/dev/null
for mode in started missing duplicate; do
    new_receipt; cp "$receipt" "$work/before"; invoke "$mode"; [[ $result == 0 ]]; cmp "$receipt" "$work/before"
done
for mode in wrong-owner api-failure; do
    new_receipt; cp "$receipt" "$work/before"; invoke "$mode"; [[ $result != 0 ]]; cmp "$receipt" "$work/before"
done
new_receipt
jq '.attempted=true' "$receipt" > "$work/changed"; mv "$work/changed" "$receipt"
cp "$receipt" "$work/before"; invoke skipped; [[ $result == 0 ]]; cmp "$receipt" "$work/before"
printf '7 upload-claim cancellation contracts passed (synthetic only).\n'

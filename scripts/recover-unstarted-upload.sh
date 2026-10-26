#!/bin/bash
# Reclaim only when GitHub proves the distinct upload step never started.
set -euo pipefail
umask 077
[[ $# == 1 && -d $1 && ! -L $1 ]] || exit 2
[[ ${GITHUB_REPOSITORY:-} == Dunky13/Cadence ]] || exit 2
work=$(mktemp -d "${TMPDIR:-/tmp}/cadence-unstarted.XXXXXX")
trap 'rm -rf "$work"' EXIT
for stage in app installer; do
    receipt="$1/evidence/$stage-universal-receipt.json"
    [[ -e $receipt ]] || continue
    [[ -f $receipt && ! -L $receipt ]] || exit 1
    if ! jq -e '.schema == "cadence/apple-notarization/v2" and .upload_claimed == true and .claim_restored == true and .attempted == false and .submission_id == null' "$receipt" >/dev/null; then continue; fi
    run=$(jq -er '.upload_owner.id | select(type == "string" and test("^[1-9][0-9]*$"))' "$receipt")
    attempt=$(jq -er '.upload_owner.attempt | select(type == "string" and test("^[1-9][0-9]*$"))' "$receipt")
    gh api "repos/$GITHUB_REPOSITORY/actions/runs/$run" > "$work/run.json"
    jq -e --arg repo "$GITHUB_REPOSITORY" '.path == ".github/workflows/release.yml" and .head_branch == "main" and .status == "completed" and .repository.full_name == $repo and .head_repository.full_name == $repo' "$work/run.json" >/dev/null || exit 1
    gh api --paginate --slurp "repos/$GITHUB_REPOSITORY/actions/runs/$run/attempts/$attempt/jobs?per_page=100" > "$work/jobs.json"
    jq --arg step "Candidate phase $stage-submit" '[.[].jobs[].steps[]? | select(.name == $step)]' "$work/jobs.json" > "$work/steps.json"
    if jq -e 'length == 1 and all(.[]; .conclusion == "skipped" and .started_at == null)' "$work/steps.json" >/dev/null; then
        jq --arg run "$run" --arg attempt "$attempt" --arg step "Candidate phase $stage-submit" '
            .upload_claimed = false | .upload_owner = null | .claim_restored = false |
            .unstarted_upload_proof = {run_id:$run,attempt:$attempt,step:$step,conclusion:"skipped",started_at:null}' "$receipt" > "$work/receipt.json"
        mv "$work/receipt.json" "$receipt"
        printf 'Reclaimed %s only after GitHub proved the previous upload step never started.\n' "$stage"
    fi
    # Started/missing/ambiguous step evidence cannot authorize another upload.
done

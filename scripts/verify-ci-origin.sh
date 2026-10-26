#!/bin/bash
# Recheck the exact gate and artifact at every credential boundary.
set -euo pipefail
umask 077
fail() { printf 'verify-ci-origin: %s\n' "$*" >&2; exit 1; }
# A job-only rerun can replay a successful preflight's old checkpoint ID. Fresh
# scheduled/dispatch runs select current custody and remain the recovery owner.
[[ ${GITHUB_RUN_ATTEMPT:-} == 1 ]] || fail 'Job reruns may replay stale custody. Use a fresh scheduled run or no-input release dispatch; no signing started.'
[[ ${GITHUB_REPOSITORY:-} == Dunky13/Cadence && ${GITHUB_REF:-} == refs/heads/main ]] || fail 'Only this repository main may sign.'
[[ ${SOURCE_COMMIT:-} =~ ^[0-9a-f]{40}$ && ${BUILD_CI_RUN_ID:-} =~ ^[1-9][0-9]*$ && ${BUILD_ARTIFACT_ID:-} =~ ^[1-9][0-9]*$ ]] || fail 'Missing exact source/run/artifact binding.'
[[ ${BUILD_ARTIFACT_DIGEST:-} =~ ^sha256:[0-9a-f]{64}$ ]] || fail 'Missing immutable build digest.'
[[ $(git rev-parse HEAD) == "$SOURCE_COMMIT" && -z $(git status --porcelain) ]] || fail 'Checkout is dirty or differs from the selected source.'
work=$(mktemp -d "${TMPDIR:-/tmp}/cadence-origin.XXXXXX")
trap 'rm -rf "$work"' EXIT
gh api "repos/$GITHUB_REPOSITORY/actions/runs/$BUILD_CI_RUN_ID" > "$work/run.json"
jq -e --arg source "$SOURCE_COMMIT" --arg repo "$GITHUB_REPOSITORY" '
    .head_sha == $source and .head_branch == "main" and .event == "push"
    and .path == ".github/workflows/ci.yml" and .status == "completed" and .conclusion == "success"
    and .repository.full_name == $repo and .head_repository.full_name == $repo' "$work/run.json" >/dev/null || fail 'Untrusted or unsuccessful origin run.'
[[ ${BUILD_NUMBER:-} == "$(jq -r .run_number "$work/run.json")" ]] || fail 'Build number differs from the selected CI run.'
gh api --paginate --slurp "repos/$GITHUB_REPOSITORY/actions/runs/$BUILD_CI_RUN_ID/jobs?filter=latest&per_page=100" > "$work/jobs.json"
jq -e '[.[].jobs[] | select(.name == "ci-required")] | length == 1 and all(.[]; .status == "completed" and .conclusion == "success")' "$work/jobs.json" >/dev/null \
    || fail 'Exact ci-required aggregate did not pass.'
gh api "repos/$GITHUB_REPOSITORY/actions/artifacts/$BUILD_ARTIFACT_ID" > "$work/artifact.json"
jq -e --arg source "$SOURCE_COMMIT" --argjson run "$BUILD_CI_RUN_ID" --arg digest "$BUILD_ARTIFACT_DIGEST" '
    .name == ("Cadence-macOS-universal-" + $source) and .workflow_run.id == $run
    and .workflow_run.head_sha == $source and .digest == $digest' "$work/artifact.json" >/dev/null || fail 'Artifact is unbound to the passed CI origin.'
git fetch --no-tags origin main
git merge-base --is-ancestor "$SOURCE_COMMIT" FETCH_HEAD || fail 'Selected source is no longer on main.'

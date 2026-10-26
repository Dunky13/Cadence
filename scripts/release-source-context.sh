#!/bin/bash
# Sourced by release entry points (caller supplies fail). Product identity never
# follows the automation checkout. There is no flag that skips either binding.
release_checkout_check() (
    cd "$1" || fail 'Release checkout is missing.'
    [[ $(git rev-parse --verify HEAD) == "$2" ]] || fail 'Release checkout HEAD differs from its pinned commit.'
    local dirty
    dirty=$(git status --porcelain --untracked-files=all) || fail 'Cannot inspect release checkout cleanliness.'
    [[ -z $dirty ]] || fail 'Release checkout is dirty.'
)

release_automation_ci() (
    # A separate process owns private API scratch and cleanup; do not replace the
    # phase driver's traps. Discover a run, then recheck its exact ID and jobs.
    set -euo pipefail
    local run
    # A failing function can unwind locals before EXIT runs on Bash 3.2. This
    # variable belongs only to this subshell and remains available to cleanup.
    cadence_automation_ci_work=$(mktemp -d "${TMPDIR:-/tmp}/cadence-automation-origin.XXXXXX") || fail 'Cannot create automation CI scratch.'
    cadence_automation_ci_exit=0
    trap 'cadence_automation_ci_exit=$?; trap - EXIT; rm -rf -- "$cadence_automation_ci_work" || cadence_automation_ci_exit=1; exit "$cadence_automation_ci_exit"' EXIT
    gh api --paginate --slurp "repos/$GITHUB_REPOSITORY/actions/workflows/ci.yml/runs?head_sha=$AUTOMATION_COMMIT&branch=main&event=push&status=success&per_page=100" > "$cadence_automation_ci_work/runs.json" \
        || fail 'Cannot query automation CI runs.'
    run=$(jq -er --arg sha "$AUTOMATION_COMMIT" --arg repo "$GITHUB_REPOSITORY" '
        [.[].workflow_runs[] | select(.head_sha == $sha and .head_branch == "main" and .event == "push"
          and .path == ".github/workflows/ci.yml" and .status == "completed" and .conclusion == "success"
          and .repository.full_name == $repo and .head_repository.full_name == $repo)]
        | sort_by(.id) | last | .id | select(type == "number" and . > 0 and . == floor)' "$cadence_automation_ci_work/runs.json") \
        || fail 'Automation commit has no passed main-push CI run.'
    [[ $run =~ ^[1-9][0-9]*$ ]] || fail 'Automation CI run ID is malformed.'
    gh api "repos/$GITHUB_REPOSITORY/actions/runs/$run" > "$cadence_automation_ci_work/run.json" || fail 'Cannot recheck exact automation CI run.'
    jq -e --arg sha "$AUTOMATION_COMMIT" --arg repo "$GITHUB_REPOSITORY" --argjson run "$run" '
        .id == $run and .head_sha == $sha and .head_branch == "main" and .event == "push"
        and .path == ".github/workflows/ci.yml" and .status == "completed" and .conclusion == "success"
        and .repository.full_name == $repo and .head_repository.full_name == $repo' "$cadence_automation_ci_work/run.json" >/dev/null \
        || fail 'Automation CI run is untrusted or unsuccessful.'
    gh api --paginate --slurp "repos/$GITHUB_REPOSITORY/actions/runs/$run/jobs?filter=latest&per_page=100" > "$cadence_automation_ci_work/jobs.json" \
        || fail 'Cannot query automation CI aggregate.'
    jq -e '[.[].jobs[] | select(.name == "ci-required")] | length == 1 and all(.[];
        .status == "completed" and .conclusion == "success")' "$cadence_automation_ci_work/jobs.json" >/dev/null \
        || fail 'Exact automation ci-required aggregate did not pass.'
)

release_source_context() {
    local expected=$1 automation_root=$2 resource
    [[ $expected =~ ^[0-9a-f]{40}$ ]] || fail 'A full product source commit is required.'
    automation_root=$(cd "$automation_root" && pwd -P) || fail 'Automation checkout is missing.'
    release_source_directory=$automation_root
    if [[ -n ${RELEASE_SOURCE_DIRECTORY+x} || -n ${AUTOMATION_COMMIT+x} ]]; then
        [[ -n ${RELEASE_SOURCE_DIRECTORY:-} && ${AUTOMATION_COMMIT:-} =~ ^[0-9a-f]{40}$ ]] \
            || fail 'Split release context requires both source directory and automation commit.'
        [[ ${GITHUB_REPOSITORY:-} == Dunky13/Cadence && ${GITHUB_REF:-} == refs/heads/main \
            && ${GITHUB_REF_TYPE:-} == branch && ${GITHUB_SHA:-} == "$AUTOMATION_COMMIT" ]] \
            || fail 'Automation must be pinned to this workflow main commit.'
        [[ -d $RELEASE_SOURCE_DIRECTORY && ! -L $RELEASE_SOURCE_DIRECTORY ]] || fail 'Product source checkout is missing or a symlink.'
        release_source_directory=$(cd "$RELEASE_SOURCE_DIRECTORY" && pwd -P) || fail 'Cannot resolve product checkout.'
        [[ $release_source_directory != "$automation_root" ]] || fail 'Split release context requires a separate product checkout.'
        [[ $(git -C "$automation_root" rev-parse --show-toplevel) == "$automation_root" \
            && $(git -C "$release_source_directory" rev-parse --show-toplevel) == "$release_source_directory" ]] \
            || fail 'Release directories must each be checkout roots.'
        release_checkout_check "$automation_root" "$AUTOMATION_COMMIT" || fail 'Automation checkout verification failed.'
        git -C "$automation_root" fetch --no-tags origin main || fail 'Cannot fetch current main for automation verification.'
        git -C "$automation_root" merge-base --is-ancestor "$AUTOMATION_COMMIT" FETCH_HEAD \
            || fail 'Automation commit is not on current main.'
        if [[ $AUTOMATION_COMMIT != "$expected" ]]; then
            release_automation_ci || fail 'Automation CI verification failed.'
        fi
    fi
    release_checkout_check "$release_source_directory" "$expected" || fail 'Product checkout verification failed.'
    [[ -d $release_source_directory/Resources && ! -L $release_source_directory/Resources ]] || fail 'Product Resources directory is missing or a symlink.'
    for resource in Info.plist Install.txt; do
        [[ -f $release_source_directory/Resources/$resource && ! -L $release_source_directory/Resources/$resource ]] \
            || fail "Missing regular frozen product resource: $resource"
        if [[ -n ${AUTOMATION_COMMIT:-} ]]; then
            git -C "$release_source_directory" ls-files --error-unmatch "Resources/$resource" >/dev/null \
                || fail 'Product resource is not tracked by the frozen source.'
        fi
    done
}

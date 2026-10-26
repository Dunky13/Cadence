#!/bin/bash
# Select existing trusted CI bytes, preferring an unfinished candidate over new work.
set -euo pipefail
umask 077
fail() { printf 'select-release-candidate: %s\n' "$*" >&2; exit 1; }
repo=${GITHUB_REPOSITORY:-}
[[ $repo =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ && ${GITHUB_REF:-} == refs/heads/main ]] || fail 'Only the trusted main workflow may select releases.'
for tool in gh jq git plutil; do command -v "$tool" >/dev/null || fail "Missing $tool"; done
work=$(mktemp -d "${TMPDIR:-/tmp}/cadence-selection.XXXXXX")
trap 'rm -rf "$work"' EXIT
emit() { printf '%s=%s\n' "$1" "$2"; if [[ -n ${GITHUB_OUTPUT:-} ]]; then printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"; fi; }
gh api "repos/$repo" > "$work/repo.json"
repo_id=$(jq -er '.id | select(type == "number" and . > 0)' "$work/repo.json")
[[ $(jq -r .default_branch "$work/repo.json") == main ]] || fail 'Unexpected default branch.'
gh api "repos/$repo/branches/main" > "$work/main.json"
jq -e '.protected == true' "$work/main.json" >/dev/null || fail 'Trusted-main automation requires enforced main protection. No release started.'
gh api --paginate --slurp "repos/$repo/actions/artifacts?per_page=100" > "$work/artifacts.json"
jq -e 'type == "array" and all(.[]; (.artifacts | type == "array"))' "$work/artifacts.json" >/dev/null || fail 'Malformed artifact inventory.'
jq --argjson repo_id "$repo_id" '[.[].artifacts[] | select(.workflow_run.head_branch == "main" and .workflow_run.head_repository_id == $repo_id)] | sort_by(.id)' "$work/artifacts.json" > "$work/all.json"
# Artifact names carry no authority. Validate their owning workflow, including
# completion markers, before they can affect candidate selection.
jq '[.[] | select(.name | test("^Cadence-(Checkpoint|Published)-"))]' "$work/all.json" > "$work/named.json"
printf '[]\n' > "$work/trusted.json"
jq -c '.[]' "$work/named.json" > "$work/named-lines"
while IFS= read -r item; do
    owner=$(jq -er '.workflow_run.id | select(type == "number" and . > 0)' <<< "$item") || fail 'Missing checkpoint owner.'
    if [[ ! -e $work/owner-$owner.json ]]; then gh api "repos/$repo/actions/runs/$owner" > "$work/owner-$owner.json"; fi
    if jq -e --arg repo "$repo" --argjson repo_id "$repo_id" '
        .path == ".github/workflows/release.yml" and .head_branch == "main"
        and .repository.full_name == $repo and .head_repository.id == $repo_id
        and (.event == "workflow_run" or .event == "schedule" or .event == "workflow_dispatch")' "$work/owner-$owner.json" >/dev/null; then
        jq --argjson item "$item" '. + [$item]' "$work/trusted.json" > "$work/trusted.tmp"
        mv "$work/trusted.tmp" "$work/trusted.json"
    fi
done < "$work/named-lines"
mv "$work/trusted.json" "$work/all.json"
# A completed marker is advisory only for queue selection. Publication independently
# reconciles exact public bytes, tag and immutable state after a lost response.
jq -r '.[] | select(.name | test("^Cadence-Checkpoint-[0-9]+-[0-9]+-[0-9]+-[0-9]+-[a-z-]+$")) |
    [.name,.id,.expired,.workflow_run.id] | @tsv' "$work/all.json" > "$work/checkpoints"
checkpoint_id='' checkpoint_run='' checkpoint_expired='' build_run='' build_artifact=''
while IFS=$'\t' read -r name id expired owner; do
    [[ -n $name ]] || continue
    IFS=- read -r _ _ ci artifact _ _ _ <<< "$name"
    completed=$(jq --arg name "Cadence-Published-$ci-$artifact" '[.[] | select(.name == $name)] | length' "$work/all.json")
    [[ $completed == 0 ]] || continue
    # Finish the oldest active candidate first; choose its newest immutable state.
    if [[ -z $build_run ]]; then build_run=$ci; build_artifact=$artifact; fi
    [[ $build_run == "$ci" && $build_artifact == "$artifact" ]] || continue
    checkpoint_id=$id checkpoint_run=$owner checkpoint_expired=$expired
 done < "$work/checkpoints"
if [[ -n $checkpoint_id ]]; then
    [[ $checkpoint_expired == false ]] || fail 'Newest active candidate custody expired. Reconcile retained submissions; rebuilding is forbidden.'
    gh api "repos/$repo/actions/runs/$checkpoint_run" > "$work/owner.json"
    jq -e --arg repo "$repo" --argjson repo_id "$repo_id" '
        .path == ".github/workflows/release.yml" and .head_branch == "main"
        and .repository.full_name == $repo and .head_repository.id == $repo_id
        and (.event == "workflow_run" or .event == "schedule" or .event == "workflow_dispatch")' "$work/owner.json" >/dev/null \
        || fail 'Checkpoint did not originate in the trusted release workflow.'
else
    if [[ ${GITHUB_EVENT_NAME:-} == workflow_run ]]; then
        [[ -f ${GITHUB_EVENT_PATH:-} ]] || fail 'Missing triggering event.'
        build_run=$(jq -er '.workflow_run.id | select(type == "number" and . > 0)' "$GITHUB_EVENT_PATH")
    else
        gh api "repos/$repo/actions/workflows/ci.yml/runs?branch=main&event=push&status=success&per_page=1" > "$work/runs.json"
        build_run=$(jq -er '.workflow_runs[0].id | select(type == "number" and . > 0)' "$work/runs.json") || fail 'No successful trusted-main CI candidate.'
    fi
fi
[[ $build_run =~ ^[1-9][0-9]*$ ]] || fail 'Invalid origin CI run.'
gh api "repos/$repo/actions/runs/$build_run" > "$work/ci.json"
jq -e --arg repo "$repo" --argjson repo_id "$repo_id" '
    .path == ".github/workflows/ci.yml" and .event == "push" and .head_branch == "main"
    and .status == "completed" and .conclusion == "success"
    and .repository.full_name == $repo and .head_repository.id == $repo_id
    and (.head_sha | type == "string" and test("^[0-9a-f]{40}$"))' "$work/ci.json" >/dev/null \
    || fail 'Origin must be a successful same-repository main-push macOS CI run.'
source=$(jq -r .head_sha "$work/ci.json")
gh api --paginate --slurp "repos/$repo/actions/runs/$build_run/jobs?filter=latest&per_page=100" > "$work/jobs.json"
jq -e '[.[].jobs[] | select(.name == "ci-required")] | length == 1 and all(.[]; .status == "completed" and .conclusion == "success")' "$work/jobs.json" >/dev/null \
    || fail 'The exact ci-required aggregate did not pass.'
gh api --paginate --slurp "repos/$repo/actions/runs/$build_run/artifacts?per_page=100" > "$work/builds.json"
jq --arg name "Cadence-macOS-universal-$source" '[.[].artifacts[] | select(.name == $name)]' "$work/builds.json" > "$work/match.json"
jq -e 'length == 1 and all(.[]; (.digest | type == "string" and test("^sha256:[0-9a-f]{64}$")))' "$work/match.json" >/dev/null \
    || fail 'Missing, expired, duplicate or unbound universal build artifact. Do not rebuild a pending candidate.'
[[ -n $checkpoint_id || $(jq -r '.[0].expired' "$work/match.json") == false ]] || fail 'Origin build expired before any state checkpoint; no new release may start.'
artifact=$(jq -r '.[0].id' "$work/match.json")
[[ -z $build_artifact || $artifact == "$build_artifact" ]] || fail 'Origin artifact changed.'
git fetch --no-tags origin main
git merge-base --is-ancestor "$source" FETCH_HEAD || fail 'Origin source is no longer on main.'
git show "$source:Resources/Info.plist" > "$work/Info.plist"
version=$(plutil -extract CFBundleShortVersionString raw "$work/Info.plist")
[[ $version =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || fail 'Invalid stable version intent.'
gh api --paginate --slurp "repos/$repo/releases?per_page=100" > "$work/releases.json"
jq -e 'type == "array" and all(.[]; type == "array" and all(.[];
    type == "object" and (.tag_name | type == "string") and
    (.draft | type == "boolean") and (.prerelease | type == "boolean")))' "$work/releases.json" >/dev/null || fail 'Malformed release inventory.'
jq --arg tag "v$version" '[.[][] | select(.tag_name == $tag)]' "$work/releases.json" > "$work/releases-match.json"
count=$(jq length "$work/releases-match.json")
[[ $count -le 1 ]] || fail 'Ambiguous version ownership.'
# An unchanged version already published is a no-op. A pending checkpoint always
# goes through the publisher's stronger same-candidate reconciliation instead.
if [[ -z $checkpoint_id ]] && jq -e --arg tag "v$version" 'any(.[][]; .tag_name == $tag and .draft == false and .prerelease == false)' "$work/releases.json" >/dev/null; then
    emit eligible false
    exit 0
fi
remote_refs=$(git ls-remote origin "refs/tags/v$version" "refs/tags/v$version^{}")
object='' peeled=''
while read -r sha ref extra; do
    [[ -n $sha ]] || continue
    [[ $sha =~ ^[0-9a-f]{40}$ && -z $extra ]] || fail 'Malformed remote tag identity.'
    case $ref in
        "refs/tags/v$version") [[ -z $object ]] || fail 'Duplicate tag object.'; object=$sha ;;
        "refs/tags/v$version^{}") [[ -z $peeled ]] || fail 'Duplicate peeled tag.'; peeled=$sha ;;
        *) fail 'Unexpected remote tag reference.' ;;
    esac
done <<< "$remote_refs"
if [[ -n $object ]]; then
    [[ ${peeled:-$object} == "$source" ]] || fail 'Release tag identifies a different source candidate.'
else
    [[ -z $peeled ]] || fail 'Peeled tag has no object.'
fi
if [[ $count == 1 ]]; then
    [[ -n $checkpoint_id ]] || fail 'A draft already owns this version and no recoverable candidate exists.'
    # shellcheck source=scripts/publication-candidate.sh
    source "$(dirname "$0")/publication-candidate.sh"
    origin=$(jq -cn --arg run "$build_run" --arg artifact "$artifact" --arg digest "$(jq -r '.[0].digest' "$work/match.json")" \
        '{build_ci_run_id:$run,build_artifact_id:$artifact,build_artifact_digest:$digest}')
    jq '.[0]' "$work/releases-match.json" > "$work/release-match.json"
    publication_binding "$work/release-match.json" "$repo" "$(jq -r .run_number "$work/ci.json")" "$origin" "v$version" "$version" "$source" \
        || fail 'Existing version does not belong to the retained candidate.'
fi
version_newer() {
    local left right index
    local candidate_parts previous_parts
    IFS=. read -r -a candidate_parts <<< "$1"
    IFS=. read -r -a previous_parts <<< "$2"
    for index in 0 1 2; do
        left=${candidate_parts[$index]} right=${previous_parts[$index]}
        if [[ ${#left} -gt ${#right} || ( ${#left} -eq ${#right} && $left > $right ) ]]; then return 0; fi
        if [[ ${#left} -lt ${#right} || ( ${#left} -eq ${#right} && $left < $right ) ]]; then return 1; fi
    done
    return 1
}
jq -r --arg tag "v$version" '.[][] | select(.draft == false and .prerelease == false and .tag_name != $tag) |
    .tag_name | select(test("^v(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$"))' "$work/releases.json" > "$work/versions"
while IFS= read -r previous; do
    version_newer "$version" "${previous#v}" || fail 'Candidate must be newer than every published stable version.'
done < "$work/versions"
emit eligible true
emit source_sha "$source"
emit release_tag "v$version"
emit build_run_id "$build_run"
emit build_number "$(jq -r .run_number "$work/ci.json")"
emit build_artifact_id "$artifact"
emit build_artifact_digest "$(jq -r '.[0].digest' "$work/match.json")"
emit checkpoint_id "$checkpoint_id"

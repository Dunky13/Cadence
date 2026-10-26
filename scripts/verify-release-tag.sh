#!/bin/bash
# Read-only preflight by default; --create-tag is used only after artifact verification.
set -euo pipefail
script_dir=$(cd "$(dirname "$0")" && pwd -P)
cd "$script_dir/.."
fail() { printf 'verify-release-tag: %s\n' "$*" >&2; exit 1; }
mode='' recover=${RECOVER_CANDIDATE:-false}
for argument in "$@"; do
    case "$argument" in
        --resume) recover=true ;;
        --allow-missing-tag|--create-tag) [[ -z $mode ]] || fail 'Conflicting preflight modes.'; mode=$argument ;;
        *) fail 'Usage: verify-release-tag.sh [--allow-missing-tag|--create-tag] [--resume]' ;;
    esac
done
[[ $recover == true || $recover == false ]] || fail 'RECOVER_CANDIDATE must be true or false.'
tag=${RELEASE_TAG:-${GITHUB_REF_NAME:-}}
commit=${SOURCE_COMMIT:-${GITHUB_SHA:-}}
repository=${GITHUB_REPOSITORY:-}
if [[ -n ${RELEASE_TAG:-} ]]; then
    [[ ${GITHUB_REF:-} == refs/heads/main && ${GITHUB_REF_TYPE:-} == branch ]] || fail 'Automatic releases must be dispatched on main.'
    [[ -n ${SOURCE_COMMIT:-} ]] || fail 'An automatic release requires a pinned SOURCE_COMMIT.'
else
    [[ -z $mode ]] || fail 'Tag creation requires the main-branch release context.'
    [[ ${GITHUB_REF_TYPE:-} == tag && ${GITHUB_REF:-} == "refs/tags/$tag" ]] || fail 'Run this workflow on a version tag, not a branch.'
fi
[[ $tag =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || fail 'Production tags must use vMAJOR.MINOR.PATCH.'
[[ $commit =~ ^[0-9a-f]{40}$ ]] || fail 'A full workflow commit SHA is required.'
[[ $repository =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail 'GITHUB_REPOSITORY is required.'
[[ $(git rev-parse --verify HEAD) == "$commit" ]] || fail 'Checkout differs from the workflow commit.'
if [[ -z $mode ]]; then
    [[ $(git rev-parse --verify "refs/tags/$tag^{commit}") == "$commit" ]] || fail 'Local tag differs from the selected commit.'
fi
version=$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist)
[[ $tag == "v$version" ]] || fail 'Tag does not match the app version in Resources/Info.plist.'
# Fetch current main without changing the checkout or persisting credentials.
git fetch --no-tags origin main
git merge-base --is-ancestor "$commit" FETCH_HEAD || fail 'Tagged commit is not on current main.'
remote_refs=$(git ls-remote origin "refs/tags/$tag" "refs/tags/$tag^{}")
object='' peeled=''
while read -r sha ref extra; do
    [[ -n $sha ]] || continue
    [[ $sha =~ ^[0-9a-f]{40}$ && -z $extra ]] || fail 'Malformed remote tag response.'
    case "$ref" in
        "refs/tags/$tag") [[ -z $object ]] || fail 'Duplicate remote tag.'; object=$sha ;;
        "refs/tags/$tag^{}") [[ -z $peeled ]] || fail 'Duplicate peeled tag.'; peeled=$sha ;;
        *) fail 'Unexpected remote tag reference.' ;;
    esac
done <<< "$remote_refs"
if [[ -n $object ]]; then
    [[ ${peeled:-$object} == "$commit" ]] || fail 'Remote tag moved or does not identify the selected commit.'
else
    [[ -n $mode && -z $peeled ]] || fail 'Remote tag is missing or malformed.'
fi
work=$(mktemp -d "${TMPDIR:-/tmp}/cadence-release-preflight.XXXXXX")
trap 'rm -rf "$work"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# A list request must succeed. Auth/network failures cannot masquerade as no release.
gh api --paginate --slurp "repos/$repository/releases?per_page=100" > "$work/releases.json"
jq -e 'type == "array" and all(.[]; type == "array" and all(.[];
    type == "object" and (.tag_name | type == "string") and
    (.draft | type == "boolean") and (.prerelease | type == "boolean")))' "$work/releases.json" >/dev/null \
    || fail 'Malformed GitHub release list.'
jq --arg tag "$tag" '[.[][] | select(.tag_name == $tag)]' "$work/releases.json" > "$work/matches.json"
count=$(jq length "$work/matches.json")
if [[ $count != 0 ]]; then
    [[ $recover == true && $count == 1 ]] || fail 'A release or draft already exists; explicit same-candidate --resume is required.'
    # Preflight admits drafts only. Published recovery belongs exclusively to
    # publish-release, which downloads and verifies all four immutable assets.
    jq '.[0]' "$work/matches.json" > "$work/candidate.json"
    jq -e '.draft == true and .immutable == false' "$work/candidate.json" >/dev/null \
        || fail 'Preflight recovery allows a bound draft only; published candidates require publisher validation.'
    # shellcheck source=scripts/publication-candidate.sh
    source "$script_dir/publication-candidate.sh"
    source_commit=$commit
    origin=$(publication_origin)
    build=${BUILD_NUMBER:-$(plutil -extract CFBundleVersion raw Resources/Info.plist)}
    publication_binding "$work/candidate.json" "$repository" "$build" "$origin" "$tag" "$version" "$source_commit" \
        || fail 'Draft is not an unambiguous automation-owned same-source/build/artifact candidate.'
    [[ -n $object ]] || fail 'A recovery draft requires its existing same-source remote tag.'
fi
# Compare decimal components as strings, avoiding integer overflow on large versions.
version_newer() {
    local candidate=$1 previous=$2 left right index
    local candidate_parts previous_parts
    IFS=. read -r -a candidate_parts <<< "$candidate"
    IFS=. read -r -a previous_parts <<< "$previous"
    for index in 0 1 2; do
        left=${candidate_parts[$index]} right=${previous_parts[$index]}
        if [[ ${#left} -gt ${#right} ]]; then return 0; fi
        if [[ ${#left} -lt ${#right} ]]; then return 1; fi
        if [[ $left > $right ]]; then return 0; fi
        if [[ $left < $right ]]; then return 1; fi
    done
    return 1
}
jq -r '.[][] | select(.draft == false and .prerelease == false) | .tag_name |
    select(test("^v(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$"))' "$work/releases.json" > "$work/versions"
while IFS= read -r previous; do
    version_newer "$version" "${previous#v}" || fail "Version must be newer than published production release $previous."
done < "$work/versions"
if [[ $mode == --create-tag ]]; then
    if [[ -z $object ]]; then
        jq -n --arg ref "refs/tags/$tag" --arg sha "$commit" '{ref:$ref,sha:$sha}' > "$work/create-tag.json"
        gh api --hostname github.com --method POST "repos/$repository/git/refs" --input "$work/create-tag.json" \
            > "$work/tag.json" || fail 'Tag creation failed; reconcile remote state before retrying.'
        jq -e --arg ref "refs/tags/$tag" --arg sha "$commit" \
            '.ref == $ref and .object.type == "commit" and .object.sha == $sha' "$work/tag.json" >/dev/null \
            || fail 'Created tag response does not identify the selected commit.'
    fi
    # Never force a conflicting local or remote tag. Verify again after fetching.
    git fetch --no-tags origin "refs/tags/$tag:refs/tags/$tag"
    RECOVER_CANDIDATE=$recover "$script_dir/verify-release-tag.sh"
fi
printf 'Production preflight passed: %s at %s, on main, no conflicting release and newer than published versions.\n' "$tag" "$commit"

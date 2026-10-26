#!/bin/bash
# Synthetic git/GitHub preflight contracts, with no remote changes or submissions.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/cadence-tag-contracts.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"
cat > "$work/bin/git" <<'STUB'
#!/bin/bash
set -euo pipefail
printf 'git %s\n' "$*" >> "$TAG_CALLS"
commit=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
tag=${RELEASE_TAG:-$GITHUB_REF_NAME}
case "$1" in
    rev-parse)
        if [[ ${TAG_SCENARIO:-} == wrong-checkout && $3 == HEAD ]]; then commit=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb; fi
        if [[ ${TAG_SCENARIO:-} == wrong-local-tag && $3 != HEAD ]]; then commit=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb; fi
        printf '%s\n' "$commit" ;;
    status) : ;;
    fetch)
        [[ ${TAG_SCENARIO:-} != fetch-error ]] || exit 1
        if [[ $* == *refs/tags/* ]]; then touch "$TAG_STATE/fetched"; fi ;;
    merge-base) [[ ${TAG_SCENARIO:-} != off-main ]] ;;
    ls-remote)
        case "${TAG_SCENARIO:-}" in
            remote-error) exit 1 ;;
            moved-tag) printf 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\trefs/tags/%s\n' "$tag" ;;
            annotated-tag)
                printf 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\trefs/tags/%s\n' "$tag"
                printf '%s\trefs/tags/%s^{}\n' "$commit" "$tag" ;;
            malformed-tag) printf 'not-a-sha\trefs/tags/%s\n' "$tag" ;;
            missing-tag|create-failure|wrong-created-tag)
                if [[ -e $TAG_STATE/created ]]; then printf '%s\trefs/tags/%s\n' "$commit" "$tag"; fi ;;
            *) printf '%s\trefs/tags/%s\n' "$commit" "$tag" ;;
        esac ;;
    *) exit 99 ;;
esac
STUB
cat > "$work/bin/gh" <<'STUB'
#!/bin/bash
set -euo pipefail
printf 'gh %s\n' "$*" >> "$TAG_CALLS"
if [[ $* == api\ --hostname\ github.com\ --method\ POST\ repos/*/git/refs\ --input\ * ]]; then
    [[ ${TAG_SCENARIO:-} != create-failure ]] || exit 1
    for argument in "$@"; do input=$argument; done
    jq -e '.ref == ("refs/tags/" + env.RELEASE_TAG) and .sha == env.SOURCE_COMMIT' "$input" >/dev/null
    touch "$TAG_STATE/created"
    sha=$SOURCE_COMMIT
    if [[ ${TAG_SCENARIO:-} == wrong-created-tag ]]; then sha=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb; fi
    jq -n --arg ref "refs/tags/$RELEASE_TAG" --arg sha "$sha" '{ref:$ref,object:{type:"commit",sha:$sha}}'
    exit
fi
[[ $* == api\ --paginate\ --slurp\ repos/*/releases\?per_page=100 ]] || exit 99
[[ ${TAG_SCENARIO:-} != api-error ]] || exit 1
cat "$TAG_RELEASES"
STUB
chmod +x "$work/bin/"*
version=$(plutil -extract CFBundleShortVersionString raw "$root/Resources/Info.plist")
cases=0
fail() { printf 'FAIL preflight %s: %s\n' "$case_name" "$*" >&2; exit 1; }
new_case() {
    case_name=$1
    mkdir "$work/$case_name"
    releases="$work/$case_name/releases.json"
    calls="$work/$case_name/calls"
    printf '[[]]\n' > "$releases"
    : > "$calls"
}
invoke() {
    result=0
    env PATH="$work/bin:$PATH" TAG_CALLS="$calls" TAG_RELEASES="$releases" TAG_STATE="$work/$case_name" \
        GITHUB_REF_TYPE=tag GITHUB_REF="refs/tags/v$version" GITHUB_REF_NAME="v$version" \
        GITHUB_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa GITHUB_REPOSITORY=example/Cadence \
        SOURCE_COMMIT='' RELEASE_TAG='' TAG_SCENARIO='' RECOVER_CANDIDATE=false \
        BUILD_CI_RUN_ID=17 BUILD_ARTIFACT_ID=23 \
        BUILD_ARTIFACT_DIGEST=sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd "$@" /bin/bash "$root/scripts/verify-release-tag.sh" ${test_mode:+"$test_mode"} \
        > "$work/$case_name/output" 2>&1 || result=$?
}
accept() { invoke "$@"; [[ $result == 0 ]] || { cat "$work/$case_name/output" >&2; fail 'valid tag rejected'; }; cases=$((cases + 1)); }
reject() { invoke "$@"; [[ $result != 0 ]] || fail 'invalid tag accepted'; cases=$((cases + 1)); }

new_case first-release; accept
new_case annotated-tag; accept TAG_SCENARIO=annotated-tag
new_case older-release
printf '[[{"tag_name":"v0.0.0","draft":false,"prerelease":false}]]\n' > "$releases"
accept
new_case newer-draft-other-version
printf '[[{"tag_name":"v99.0.0","draft":true,"prerelease":false}]]\n' > "$releases"
accept
new_case newer-prerelease
printf '[[{"tag_name":"v99.0.0","draft":false,"prerelease":true}]]\n' > "$releases"
accept
new_case branch; reject GITHUB_REF_TYPE=branch GITHUB_REF=refs/heads/main GITHUB_REF_NAME=main
new_case malformed-tag; reject GITHUB_REF_NAME=v01.2.3 GITHUB_REF=refs/tags/v01.2.3
new_case mismatched-version; reject GITHUB_REF_NAME=v999.0.0 GITHUB_REF=refs/tags/v999.0.0
new_case abbreviated-sha; reject GITHUB_SHA=aaaaaaa
new_case wrong-checkout; reject TAG_SCENARIO=wrong-checkout
new_case wrong-local-tag; reject TAG_SCENARIO=wrong-local-tag
new_case off-main; reject TAG_SCENARIO=off-main
new_case fetch-error; reject TAG_SCENARIO=fetch-error
new_case moved-tag; reject TAG_SCENARIO=moved-tag
new_case remote-error; reject TAG_SCENARIO=remote-error
new_case missing-tag; reject TAG_SCENARIO=missing-tag
new_case malformed-remote; reject TAG_SCENARIO=malformed-tag
new_case api-error; reject TAG_SCENARIO=api-error
new_case malformed-api
printf '[{"tag_name":"v0.0.0"}]\n' > "$releases"
reject
new_case existing-release
jq -n --arg tag "v$version" '[[{tag_name:$tag,draft:false,prerelease:false}]]' > "$releases"
reject
new_case existing-draft
jq -n --arg tag "v$version" '[[{tag_name:$tag,draft:true,prerelease:false}]]' > "$releases"
reject
new_case newer-release-on-second-page
printf '[[],[{"tag_name":"v99999999999999999999999999999.0.0","draft":false,"prerelease":false}]]\n' > "$releases"
reject
main_context=(GITHUB_REF_TYPE=branch GITHUB_REF=refs/heads/main GITHUB_REF_NAME=main
    SOURCE_COMMIT=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa RELEASE_TAG="v$version")
test_mode=--allow-missing-tag
new_case main-without-tag; accept "${main_context[@]}" TAG_SCENARIO=missing-tag
[[ ! -e $work/$case_name/created ]] || fail 'read-only preflight created a tag'
new_case main-existing-tag; accept "${main_context[@]}"
new_case main-newer-than-dispatch
accept "${main_context[@]}" GITHUB_SHA=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
new_case main-wrong-checkout; reject "${main_context[@]}" TAG_SCENARIO=wrong-checkout
new_case main-moved-tag; reject "${main_context[@]}" TAG_SCENARIO=moved-tag
new_case main-tag-lookup-failure; reject "${main_context[@]}" TAG_SCENARIO=remote-error
new_case non-main-dispatch; reject "${main_context[@]}" GITHUB_REF=refs/heads/feature
new_case unpinned-main; reject "${main_context[@]}" SOURCE_COMMIT=''
test_mode=--create-tag
new_case create-main-tag; accept "${main_context[@]}" TAG_SCENARIO=missing-tag
[[ -e $work/$case_name/created && -e $work/$case_name/fetched ]] || fail 'new tag was not created and fetched'
new_case reuse-exact-main-tag; accept "${main_context[@]}"
[[ ! -e $work/$case_name/created && -e $work/$case_name/fetched ]] || fail 'existing tag was replaced or not fetched'
new_case reject-conflicting-tag; reject "${main_context[@]}" TAG_SCENARIO=moved-tag
[[ ! -e $work/$case_name/created ]] || fail 'conflicting tag was replaced'
new_case failed-tag-creation; reject "${main_context[@]}" TAG_SCENARIO=create-failure
new_case mismatched-created-tag; reject "${main_context[@]}" TAG_SCENARIO=wrong-created-tag
new_case no-tag-for-existing-release
jq -n --arg tag "v$version" '[[{tag_name:$tag,draft:false,prerelease:false}]]' > "$releases"
reject "${main_context[@]}" TAG_SCENARIO=missing-tag
[[ ! -e $work/$case_name/created ]] || fail 'tag created despite existing release'
# Bound draft recovery, with the same origin and build fields as the publisher.
# shellcheck source=scripts/publication-candidate.sh
source "$root/scripts/publication-candidate.sh"
new_bound_draft() {
    new_case "$1"
    local build origin candidate marker
    build=$(plutil -extract CFBundleVersion raw "$root/Resources/Info.plist")
    origin='{"build_ci_run_id":"17","build_artifact_id":"23","build_artifact_digest":"sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"}'
    candidate=$(jq -cnS --arg version "$version" --arg build "$build" --argjson origin "$origin" '
        {schema:"cadence/publication/v1",repository:"example/Cadence",tag:("v"+$version),
         version:$version,build_number:$build,source_commit:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",origin:$origin,
         assets:{("Cadence-App-"+$version+"-universal.zip"):("d"*64),
                 ("Cadence-Installer-"+$version+"-universal.dmg"):("e"*64),
                 SHA256SUMS:("f"*64),"distribution.json":("a"*64)}}')
    marker=$(publication_body "$candidate")
    jq -n --arg tag "v$version" --arg body "$marker" '[[{id:42,tag_name:$tag,
        name:("Cadence "+$tag),target_commitish:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        draft:true,immutable:false,prerelease:false,body:$body,
        author:{login:"github-actions[bot]",type:"Bot",id:41898282}}]]' > "$releases"
}
test_mode=--allow-missing-tag
new_bound_draft resume-draft
accept "${main_context[@]}" RECOVER_CANDIDATE=true
[[ ! -e $work/$case_name/created ]] || fail 'draft preflight created a tag'
new_bound_draft no-implicit-resume
reject "${main_context[@]}"
new_bound_draft resume-published
jq '.[0][0].draft=false | .[0][0].immutable=true' "$releases" > "$releases.tmp"
mv "$releases.tmp" "$releases"
reject "${main_context[@]}" RECOVER_CANDIDATE=true
for field in target_commitish body name author; do
    new_bound_draft "resume-conflicting-$field"
    jq --arg field "$field" '.[0][0][$field]="wrong"' "$releases" > "$releases.tmp"
    mv "$releases.tmp" "$releases"
    reject "${main_context[@]}" RECOVER_CANDIDATE=true
done
for binding in BUILD_CI_RUN_ID BUILD_ARTIFACT_ID BUILD_ARTIFACT_DIGEST; do
    new_bound_draft "resume-wrong-$binding"
    reject "${main_context[@]}" RECOVER_CANDIDATE=true "$binding=99"
done
new_bound_draft resume-duplicate-drafts
jq '.[0] += .[0]' "$releases" > "$releases.tmp"
mv "$releases.tmp" "$releases"
reject "${main_context[@]}" RECOVER_CANDIDATE=true
new_bound_draft resume-no-remote-tag
reject "${main_context[@]}" RECOVER_CANDIDATE=true TAG_SCENARIO=missing-tag
test_mode=--create-tag
new_bound_draft resume-create-tag-mode
accept "${main_context[@]}" RECOVER_CANDIDATE=true
[[ ! -e $work/$case_name/created && -e $work/$case_name/fetched ]] || fail 'recovery replaced its tag'
test_mode=--resume
new_bound_draft tag-resume-cli
accept
for conflict in marker-source marker-origin marker-assets duplicate-json; do
    new_bound_draft "resume-$conflict"
    case "$conflict" in
        marker-source) transform='.source_commit="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' ;;
        marker-origin) transform='.origin.build_ci_run_id="18"' ;;
        marker-assets) transform='.assets.extra=("d"*64)' ;;
        duplicate-json) transform='.' ;;
    esac
    marker=$(jq -r '.[0][0].body | capture("^<!-- cadence-publication/v1 (?<c>.+) -->$").c' "$releases" | jq -cS "$transform")
    if [[ $conflict == duplicate-json ]]; then marker="{\"schema\":\"other\",${marker#\{}"; fi
    marker=$(publication_body "$marker")
    jq --arg body "$marker" '.[0][0].body=$body' "$releases" > "$releases.tmp"
    mv "$releases.tmp" "$releases"
    reject "${main_context[@]}"
done
printf 'Production tag preflight contracts: %s cases passed; no provider mutations.\n' "$cases"

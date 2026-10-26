#!/bin/bash
# Publish only the exact verified distribution, checking uploaded and public bytes.
{ set +x; } 2>/dev/null
set -euo pipefail
umask 077
export LC_ALL=C
script_dir=$(cd "$(dirname "$0")" && pwd -P)
fail() { printf 'publish-release: %s\n' "$*" >&2; exit 1; }
recover=${RECOVER_CANDIDATE:-false}
if [[ ${1:-} == --resume ]]; then recover=true; shift; fi
[[ $recover == true || $recover == false ]] || fail 'RECOVER_CANDIDATE must be true or false.'
[[ $# == 2 ]] || fail 'Usage: publish-release.sh [--resume] TAG DISTRIBUTION_DIRECTORY'
tag=$1 input=$2
version_pattern='^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
[[ $tag =~ $version_pattern ]] || fail 'Expected a stable vMAJOR.MINOR.PATCH tag.'
version=${tag#v}
source_commit=${SOURCE_COMMIT:-${GITHUB_SHA:-}}
repo=${GITHUB_REPOSITORY:-}
[[ $source_commit =~ ^[0-9a-f]{40}$ ]] || fail 'A full selected source commit is required.'
[[ -z ${RELEASE_TAG:-} || $RELEASE_TAG == "$tag" ]] || fail 'Selected release tag differs from the publication tag.'
[[ $repo =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail 'GITHUB_REPOSITORY must identify the destination repository.'
[[ -n ${GH_TOKEN:-${GITHUB_TOKEN:-}} ]] || fail 'A GitHub publication token is required.'
[[ ${GH_HOST:-github.com} == github.com ]] || fail 'This release flow targets github.com.'
for tool in gh git jq shasum cmp plutil; do command -v "$tool" >/dev/null || fail "Missing prerequisite: $tool"; done
# shellcheck source=scripts/release-source-context.sh
source "$script_dir/release-source-context.sh"
release_source_context "$source_commit" "$script_dir/.."
if [[ -z ${RELEASE_TAG:-} ]]; then
    [[ $(git rev-parse --verify "refs/tags/$tag^{commit}") == "$source_commit" ]] || fail 'Local tag differs from the selected source commit.'
fi
[[ -d $input && ! -L $input ]] || fail 'Distribution directory is missing or is a symlink.'
input=$(cd "$input" && pwd -P)
archive="Cadence-App-$version-universal.zip"
image="Cadence-Installer-$version-universal.dmg"
files=("$archive" "$image" SHA256SUMS distribution.json)
expected=$(printf '%s\n' "${files[@]}" | sort)
shopt -s nullglob dotglob
# shellcheck source=scripts/publication-candidate.sh
source "$script_dir/publication-candidate.sh"
origin=$(publication_origin)
validate_payload() {
    local directory=$1 path actual='' line digest name checksummed=''
    local checksum_pattern='^([0-9a-f]{64})  (.*)$'
    for path in "$directory/"*; do
        [[ -f $path && ! -L $path ]] || fail 'Distribution contains a nonregular entry.'
        actual+="${path##*/}"$'\n'
    done
    [[ $(printf '%s' "$actual" | sort) == "$expected" ]] || fail 'Distribution does not contain exactly the four expected assets.'
    while IFS= read -r line || [[ -n $line ]]; do
        [[ $line =~ $checksum_pattern ]] || fail 'Malformed checksum entry.'
        digest=${BASH_REMATCH[1]} name=${BASH_REMATCH[2]}
        case "$name" in "$archive"|"$image"|distribution.json) ;; *) fail 'Unexpected checksum path.' ;; esac
        [[ $(shasum -a 256 "$directory/$name") == "$digest  $directory/$name" ]] || fail 'Distribution checksum mismatch.'
        checksummed+="$name"$'\n'
    done < "$directory/SHA256SUMS"
    [[ $(printf '%s' "$checksummed" | sort) == "$(printf '%s\n' "$archive" "$image" distribution.json | sort)" ]] \
        || fail 'Checksums must name the app, installer, and distribution manifest exactly once.'
    jq -e --argjson origin "$origin" --arg version "$version" --arg commit "$source_commit" --arg app "$archive" --arg installer "$image" '
        (.schema == "cadence/distribution/v1" or .schema == "cadence/distribution/v2") and .version == $version
        and .architecture == "universal" and .source_commit == $commit
        and .app_archive == $app and .installer == $installer
        and .signing == "Developer ID" and .notarization == "Accepted"
        and .tickets == "stapled and validated" and .origin == $origin
        and (.build_number | type == "string" and test("^[0-9]+(\\.[0-9]+){0,2}$"))' "$directory/distribution.json" >/dev/null \
        || fail 'Distribution manifest does not prove the requested signed/notarized release.'
}
validate_payload "$input"
build=$(jq -r .build_number "$input/distribution.json")
[[ $(plutil -extract CFBundleShortVersionString raw "$release_source_directory/Resources/Info.plist") == "$version" ]] \
    || fail 'Selected version differs from the source app version.'
[[ ${BUILD_NUMBER:-$(plutil -extract CFBundleVersion raw "$release_source_directory/Resources/Info.plist")} == "$build" ]] \
    || fail 'Selected build differs from the source app build.'
work=$(mktemp -d "${TMPDIR:-/tmp}/cadence-publish.XXXXXX")
release_id=''
cleanup() {
    result=$?
    trap - EXIT
    if [[ $result != 0 && -n $release_id ]]; then
        printf 'publish-release: Retained release %s for diagnosis; inspect its current state before retrying.\n' "$release_id" >&2
    fi
    rm -rf -- "$work" || result=1
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# Return 4 only for a real HTTP 404; authentication/network failures stop the flow.
api_optional() {
    local endpoint=$1 destination=$2 result=0 line status
    gh api --hostname github.com --include "$endpoint" > "$work/api-response" 2> "$work/api-error" || result=$?
    IFS= read -r line < "$work/api-response" || fail 'GitHub returned no HTTP response.'
    line=${line%$'\r'}
    [[ $line =~ ^HTTP/[0-9.]+[[:space:]]+([0-9]{3}) ]] || fail 'GitHub returned an unrecognized HTTP response.'
    status=${BASH_REMATCH[1]}
    if [[ $status == 404 && $result != 0 ]]; then return 4; fi
    [[ $result == 0 && $status == 200 ]] || fail 'GitHub lookup failed; refusing to assume absence.'
    awk 'body { print } /^\r?$/ { body=1 }' "$work/api-response" > "$destination"
}
verify_remote_tag() {
    local type sha object_pin depth=0
    gh api --hostname github.com "repos/$repo/git/ref/tags/$tag" > "$work/tag.json" 2> "$work/api-error" \
        || fail 'Unable to resolve the remote release tag.'
    jq -e --arg ref "refs/tags/$tag" '.ref == $ref and (.object.type == "commit" or .object.type == "tag")
        and (.object.sha | type == "string" and test("^[0-9a-f]{40}$"))' "$work/tag.json" >/dev/null \
        || fail 'Remote release tag response is malformed.'
    object_pin=$(jq -cS '{ref,type:.object.type,sha:.object.sha}' "$work/tag.json")
    [[ -z ${pinned_tag_object:-} || $pinned_tag_object == "$object_pin" ]] || fail 'Remote tag object changed during publication.'
    pinned_tag_object=$object_pin
    type=$(jq -r .object.type "$work/tag.json")
    sha=$(jq -r .object.sha "$work/tag.json")
    while [[ $type == tag ]]; do
        depth=$((depth + 1))
        [[ $depth -le 8 ]] || fail 'Remote annotated tag nesting is excessive.'
        gh api --hostname github.com "repos/$repo/git/tags/$sha" > "$work/tag-object.json" 2> "$work/api-error" \
            || fail 'Unable to resolve an annotated release tag.'
        jq -e --arg sha "$sha" '.sha == $sha and (.object.type == "commit" or .object.type == "tag")
            and (.object.sha | type == "string" and test("^[0-9a-f]{40}$"))' "$work/tag-object.json" >/dev/null \
            || fail 'Annotated release tag response is malformed.'
        type=$(jq -r .object.type "$work/tag-object.json")
        sha=$(jq -r .object.sha "$work/tag-object.json")
    done
    [[ $sha == "$source_commit" ]] || fail 'Remote tag no longer identifies the verified source commit.'
}
# Pin both the tag object and its resolved commit, including annotated tags.
if [[ -z ${RELEASE_TAG:-} ]]; then verify_remote_tag; fi
assets='{}'
for name in "${files[@]}"; do
    digest=$(shasum -a 256 < "$input/$name"); digest=${digest%% *}
    assets=$(jq -cS --arg name "$name" --arg digest "$digest" '. + {($name):$digest}' <<< "$assets")
done
candidate=$(jq -cnS --arg repo "$repo" --arg tag "$tag" --arg source "$source_commit" \
    --arg version "$version" --arg build "$build" --argjson origin "$origin" --argjson assets "$assets" \
    '{schema:"cadence/publication/v1",repository:$repo,tag:$tag,source_commit:$source,version:$version,
      build_number:$build,origin:$origin,assets:$assets}')
body=$(publication_body "$candidate")
# shellcheck source=scripts/publication-upload-custody.sh
source "$script_dir/publication-upload-custody.sh"
publication_custody_init "$input" "$work" "$candidate"
expected_json=$(printf '%s\n' "${files[@]}" | jq -R . | jq -s 'sort')
find_candidate() {
    # Tag lookup alone omits drafts. Enumerate all pages and reject ambiguity.
    gh api --hostname github.com --paginate --slurp "repos/$repo/releases?per_page=100" \
        > "$work/releases.json" 2> "$work/api-error" || fail 'Unable to check existing releases and drafts.'
    jq -e 'type == "array" and all(.[]; type == "array" and all(.[];
        type == "object" and (.tag_name | type == "string") and
        (.draft | type == "boolean") and (.prerelease | type == "boolean")))' "$work/releases.json" >/dev/null \
        || fail 'Malformed release list.'
    jq --arg tag "$tag" '[.[][] | select(.tag_name == $tag)]' "$work/releases.json" > "$work/matches.json"
    count=$(jq length "$work/matches.json")
    [[ $count -le 1 ]] || fail 'Multiple releases identify this candidate tag.'
    if [[ $count == 1 ]]; then
        jq '.[0]' "$work/matches.json" > "$work/release.json"
        publication_binding "$work/release.json" "$repo" "$build" "$origin" "$tag" "$version" "$source_commit" \
            || fail 'Existing release is not an automation-owned, source-bound candidate.'
        jq -e --arg body "$body" '.body == $body' "$work/release.json" >/dev/null \
            || fail 'Existing candidate marker conflicts with the verified four asset hashes.'
        release_id=$(jq -r .id "$work/release.json")
    else
        release_id=''
    fi
}
verify_metadata() {
    local draft=$1
    gh api --hostname github.com "repos/$repo/releases/$release_id" > "$work/release.json" 2> "$work/api-error" \
        || fail 'Unable to read release metadata.'
    publication_binding "$work/release.json" "$repo" "$build" "$origin" "$tag" "$version" "$source_commit" \
        || fail 'Release identity, ownership or candidate binding changed.'
    jq -e --arg body "$body" --arg url "https://github.com/$repo/releases/tag/$tag" \
        --argjson id "$release_id" --argjson draft "$draft" '
        .id == $id and .body == $body and .html_url == $url and .draft == $draft
        and (if $draft then .immutable == false else .immutable == true end)' "$work/release.json" >/dev/null \
        || fail 'Release metadata/state changed or published release is not immutable.'
}
verify_assets() {
    local destination=$1 complete=$2 name id digest
    gh api --hostname github.com --paginate --slurp "repos/$repo/releases/$release_id/assets?per_page=100" \
        > "$work/assets.json" 2> "$work/api-error" || fail 'Unable to list release assets.'
    jq -e --argjson expected "$expected_json" --argjson complete "$complete" '
        type == "array" and all(.[]; type == "array") and
        ([.[][]] as $a | all($a[];
            (.name as $n | $expected | index($n) != null)
            and (.id | type == "number" and . > 0 and . == floor)
            and .state == "uploaded")
        and ([$a[].name] | length == (unique | length))
        and ([$a[].id] | length == (unique | length))
        and (if $complete then ([$a[].name] | sort) == $expected else true end))' "$work/assets.json" >/dev/null \
        || fail 'Release assets contain extras, duplicates, incomplete uploads or a missing required asset.'
    mkdir "$destination"
    jq -r '.[][] | [.name, (.id|tostring)] | @tsv' "$work/assets.json" > "$work/asset-ids"
    while IFS=$'\t' read -r name id; do
        # Download by the validated ID, never by tag/name glob or an API-supplied URL.
        gh api --hostname github.com -H 'Accept: application/octet-stream' "repos/$repo/releases/assets/$id" \
            > "$destination/$name" 2> "$work/api-error" || fail 'Unable to download exact release asset bytes.'
        digest=$(shasum -a 256 < "$destination/$name"); digest=${digest%% *}
        [[ $digest == "$(jq -r --arg name "$name" '.[$name]' <<< "$assets")" ]] \
            || fail 'Downloaded release asset hash differs from the verified candidate.'
        cmp -s "$input/$name" "$destination/$name" || fail 'Downloaded release bytes differ from verified local bytes.'
    done < "$work/asset-ids"
    if [[ $complete == true ]]; then validate_payload "$destination"; fi
}
repair_empty_starters() {
    local name id result
    verify_metadata true
    gh api --hostname github.com --paginate --slurp "repos/$repo/releases/$release_id/assets?per_page=100" > "$work/starter-assets.json" \
        || fail 'Unable to inspect unfinished draft uploads.'
    jq -e --argjson expected "$expected_json" '
        type == "array" and all(.[]; type == "array") and
        ([.[][]] as $a | ([$a[].name] | length == (unique | length)) and
        all($a[]; (.name as $name | $expected | index($name) != null) and
            (.id | type == "number" and . > 0 and . == floor) and
            (.state == "uploaded" or (.state == "starter" and .size == 0 and
             .uploader.login == "github-actions[bot]" and .uploader.type == "Bot" and .uploader.id == 41898282))))' \
        "$work/starter-assets.json" >/dev/null || fail 'An unfinished asset is unowned, nonempty, duplicated or unexpected.'
    jq -r '.[][] | select(.state == "starter") | [.name,(.id|tostring)] | @tsv' "$work/starter-assets.json" > "$work/starters"
    while IFS=$'\t' read -r name id; do
        [[ -n $name ]] || continue
        publication_require_abandoned "$name" "$id" "$assets"
        verify_metadata true
        gh api --hostname github.com "repos/$repo/releases/assets/$id" > "$work/starter.json" || fail 'Unable to recheck unfinished asset.'
        jq -e --arg name "$name" --argjson id "$id" '.id == $id and .name == $name and .state == "starter" and .size == 0
            and .uploader.login == "github-actions[bot]" and .uploader.type == "Bot" and .uploader.id == 41898282' \
            "$work/starter.json" >/dev/null || fail 'Unfinished asset changed; no deletion is permitted.'
        result=0
        gh api --hostname github.com --method DELETE "repos/$repo/releases/assets/$id" > "$work/delete-output" 2> "$work/api-error" || result=$?
        # Reconcile a lost DELETE response by ID. Never touch completed bytes.
        gh api --hostname github.com --paginate --slurp "repos/$repo/releases/$release_id/assets?per_page=100" > "$work/after-delete.json" \
            || fail 'Unfinished-asset cleanup is unresolved.'
        jq -e --argjson id "$id" 'all(.[][]; .id != $id)' "$work/after-delete.json" >/dev/null \
            || fail "Empty unfinished upload was not removed (exit $result)."
    done < "$work/starters"
}
find_candidate
existing=$release_id
if [[ -n $existing ]]; then
    [[ $recover == true ]] || fail 'Candidate exists; explicit --resume or RECOVER_CANDIDATE=true is required.'
fi
# Published recovery still requires current main ancestry; it is not a version-selection no-op.
git fetch --no-tags origin main
git merge-base --is-ancestor "$source_commit" FETCH_HEAD || fail 'Selected source is not on current main.'
version_newer() {
    local candidate_version=$1 previous_version=$2 left right index
    local current previous
    IFS=. read -r -a current <<< "$candidate_version"
    IFS=. read -r -a previous <<< "$previous_version"
    for index in 0 1 2; do
        left=${current[$index]} right=${previous[$index]}
        if [[ ${#left} -gt ${#right} || ( ${#left} -eq ${#right} && $left > $right ) ]]; then return 0; fi
        if [[ ${#left} -lt ${#right} || ( ${#left} -eq ${#right} && $left < $right ) ]]; then return 1; fi
    done
    return 1
}
# Preserve monotonicity across all published stable versions, not just /latest.
jq -r --arg tag "$tag" '.[][] | select(.draft == false and .prerelease == false and .tag_name != $tag)
    | .tag_name | select(test("^v(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$"))' \
    "$work/releases.json" > "$work/versions"
while IFS= read -r previous; do
    version_newer "$version" "${previous#v}" || fail 'Candidate must be newer than every other stable release.'
done < "$work/versions"
result=0
api_optional "repos/$repo/releases/latest" "$work/latest.json" || result=$?
if [[ $result == 0 ]]; then
    latest=$(jq -er 'select(.draft == false and .prerelease == false) | .tag_name | select(type == "string")' "$work/latest.json")
    [[ $latest =~ $version_pattern ]] || fail 'Latest stable release has an unrecognized version.'
    if [[ $latest != "$tag" || -z $existing || $(jq -r .draft "$work/release.json") != false ]]; then
        version_newer "$version" "${latest#v}" || fail 'Candidate must be newer than the latest stable release.'
    fi
fi
if [[ -n $existing && $(jq -r .draft "$work/release.json") == false ]]; then
    if [[ -n ${RELEASE_TAG:-} ]]; then
        [[ ${GITHUB_REF:-} == refs/heads/main && ${GITHUB_REF_TYPE:-} == branch && -n ${SOURCE_COMMIT:-} ]] \
            || fail 'Automatic recovery requires the pinned main-branch release context.'
    else
        [[ ${GITHUB_REF_TYPE:-} == tag && ${GITHUB_REF:-} == "refs/tags/$tag" ]] \
            || fail 'Tag recovery requires its version-tag workflow context.'
    fi
    verify_metadata false
    verify_remote_tag
    verify_assets "$work/recovered-public-assets" true
    verify_metadata false
    verify_remote_tag
else
    # Read-only preflight and tag creation retain main/context/version gates.
    preflight=()
    if [[ -n ${RELEASE_TAG:-} ]]; then preflight+=(--create-tag); fi
    RECOVER_CANDIDATE=$recover "$script_dir/verify-release-tag.sh" ${preflight[@]+"${preflight[@]}"}
    verify_remote_tag
    if [[ -z $release_id ]]; then
        jq -n --arg tag "$tag" --arg source "$source_commit" --arg body "$body" \
            '{tag_name:$tag,target_commitish:$source,name:("Cadence " + $tag),body:$body,
              draft:true,prerelease:false}' > "$work/create.json"
        # A lost response must be reconciled by the binding; never repeat POST.
        gh api --hostname github.com --method POST "repos/$repo/releases" --input "$work/create.json" \
            > "$work/create-response.json" 2> "$work/api-error" || :
        find_candidate
        [[ -n $release_id ]] || fail 'Draft creation unresolved; no matching candidate is visible. Retry with --resume; no second create was attempted.'
        existing=$release_id
    fi
    verify_metadata true
    repair_empty_starters
    verify_assets "$work/existing-assets" false
    # Upload each missing file once. Reconcile every response, even a failed one.
    for name in "${files[@]}"; do
        if [[ ! -f $work/existing-assets/$name ]]; then
            verify_metadata true
            gh api --hostname github.com --include --method POST -H 'Content-Type: application/octet-stream' \
                -H "Content-Length: $(wc -c < "$input/$name" | tr -d '[:space:]')" \
                "https://uploads.github.com/repos/$repo/releases/$release_id/assets?name=$name" --input "$input/$name" \
                > "$work/upload-output" 2> "$work/api-error" || :
            publication_record_502 "$name" "$work" "$repo" "$release_id" "$assets"
            verify_assets "$work/upload-check-$name" false
            [[ -f $work/upload-check-$name/$name ]] \
                || fail 'Upload unresolved; missing asset retained for explicit same-candidate recovery.'
        fi
    done
    verify_assets "$work/draft-assets" true
    verify_metadata true
    verify_remote_tag
    jq -n '{draft:false,prerelease:false,make_latest:"true"}' > "$work/publish.json"
    gh api --hostname github.com --method PATCH "repos/$repo/releases/$release_id" --input "$work/publish.json" \
        > "$work/publish-output" 2> "$work/api-error" || :
    # Lost publish response succeeds only through immutable exact-byte readback.
    # A still-draft response fails; publication is never repeated in this invocation.
    verify_metadata false
    verify_remote_tag
    verify_assets "$work/public-assets" true
    verify_metadata false
    verify_remote_tag
fi
url=$(jq -er '.html_url | select(type == "string")' "$work/release.json")
[[ $url == "https://github.com/$repo/releases/tag/$tag" ]] || fail 'Unexpected published release URL.'
printf 'Published, immutable and downloaded-byte verified: %s\n' "$url"
if [[ -n ${GITHUB_OUTPUT:-} ]]; then
    printf 'release_url=%s\n' "$url" >> "$GITHUB_OUTPUT"
fi
if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
    printf 'Published [%s](%s) from %s; immutable release and all four public assets match the candidate.\n' \
        "$tag" "$url" "$source_commit" >> "$GITHUB_STEP_SUMMARY"
fi

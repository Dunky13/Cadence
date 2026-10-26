#!/bin/bash
# Publish only the exact verified distribution, checking uploaded and public bytes.
{ set +x; } 2>/dev/null
set -euo pipefail
umask 077
export LC_ALL=C
fail() { printf 'publish-release: %s\n' "$*" >&2; exit 1; }
[[ $# == 2 ]] || fail 'Usage: publish-release.sh TAG DISTRIBUTION_DIRECTORY'
tag=$1 input=$2
version_pattern='^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
[[ $tag =~ $version_pattern ]] || fail 'Expected a stable vMAJOR.MINOR.PATCH tag.'
version=${tag#v}
source_commit=${GITHUB_SHA:-}
repo=${GITHUB_REPOSITORY:-}
[[ $source_commit =~ ^[0-9a-f]{40}$ ]] || fail 'GITHUB_SHA must name the exact source commit.'
[[ $repo =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail 'GITHUB_REPOSITORY must identify the destination repository.'
[[ -n ${GH_TOKEN:-${GITHUB_TOKEN:-}} ]] || fail 'A GitHub publication token is required.'
[[ ${GH_HOST:-github.com} == github.com ]] || fail 'This release flow targets github.com.'
for tool in gh git jq shasum; do command -v "$tool" >/dev/null || fail "Missing prerequisite: $tool"; done
[[ $(git rev-parse --verify HEAD) == "$source_commit" ]] || fail 'Checkout differs from GITHUB_SHA.'
[[ $(git rev-parse --verify "refs/tags/$tag^{commit}") == "$source_commit" ]] || fail 'Local tag differs from GITHUB_SHA.'
[[ -d $input && ! -L $input ]] || fail 'Distribution directory is missing or is a symlink.'
input=$(cd "$input" && pwd -P)
archive="Cadence-App-$version-universal.zip"
image="Cadence-Installer-$version-universal.dmg"
files=("$archive" "$image" SHA256SUMS distribution.json)
expected=$(printf '%s\n' "${files[@]}" | sort)
shopt -s nullglob dotglob
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
    jq -e --arg version "$version" --arg commit "$source_commit" --arg app "$archive" --arg installer "$image" '
        .schema == "cadence/distribution/v1" and .version == $version
        and .architecture == "universal" and .source_commit == $commit
        and .app_archive == $app and .installer == $installer
        and .signing == "Developer ID" and .notarization == "Accepted"
        and .tickets == "stapled and validated"' "$directory/distribution.json" >/dev/null \
        || fail 'Distribution manifest does not prove the requested signed/notarized release.'
}
validate_payload "$input"
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
    local type sha depth=0
    gh api --hostname github.com "repos/$repo/git/ref/tags/$tag" > "$work/tag.json" 2> "$work/api-error" \
        || fail 'Unable to resolve the remote release tag.'
    jq -e --arg ref "refs/tags/$tag" '.ref == $ref and (.object.type == "commit" or .object.type == "tag")
        and (.object.sha | type == "string" and test("^[0-9a-f]{40}$"))' "$work/tag.json" >/dev/null \
        || fail 'Remote release tag response is malformed.'
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
verify_remote_tag
# REST lookup by tag does not find pending draft tags. List all pages instead.
gh api --hostname github.com --paginate --slurp "repos/$repo/releases?per_page=100" \
    > "$work/releases.json" 2> "$work/api-error" || fail 'Unable to check existing releases and drafts.'
jq -e --arg tag "$tag" 'type == "array" and all(.[]; type == "array" and
    all(.[]; type == "object" and (.tag_name | type == "string") and .tag_name != $tag))' \
    "$work/releases.json" >/dev/null || fail 'A release/draft exists or the release list is malformed; refusing to replace it.'
result=0
api_optional "repos/$repo/releases/latest" "$work/latest.json" || result=$?
if [[ $result == 0 ]]; then
    latest=$(jq -er 'select(.draft == false and .prerelease == false) | .tag_name | select(type == "string")' "$work/latest.json")
    [[ $latest =~ $version_pattern ]] || fail 'Latest stable release has an unrecognized version.'
    IFS=. read -r latest_major latest_minor latest_patch <<< "${latest#v}"
    IFS=. read -r major minor patch <<< "$version"
    current=("$major" "$minor" "$patch")
    previous=("$latest_major" "$latest_minor" "$latest_patch")
    newer=false
    for index in 0 1 2; do
        left=${current[$index]} right=${previous[$index]}
        if [[ ${#left} -gt ${#right} || ( ${#left} -eq ${#right} && $left > $right ) ]]; then newer=true; break; fi
        if [[ ${#left} -lt ${#right} || ( ${#left} -eq ${#right} && $left < $right ) ]]; then break; fi
    done
    [[ $newer == true ]] || fail 'Candidate must be newer than the latest stable release.'
fi
# Capture the new draft's ID directly; tag-based REST lookup is for published releases.
jq -n --arg tag "$tag" --arg source "$source_commit" \
    '{tag_name:$tag,target_commitish:$source,name:("Cadence " + $tag),
      draft:true,prerelease:false,generate_release_notes:true}' > "$work/create.json"
gh api --hostname github.com --method POST "repos/$repo/releases" --input "$work/create.json" \
    > "$work/release.json" 2> "$work/api-error" \
    || fail 'Draft creation failed; reconcile GitHub state before retrying.'
release_id=$(jq -er '.id | select(type == "number" and . > 0 and . == floor)' "$work/release.json")
expected_json=$(printf '%s\n' "${files[@]}" | jq -R . | jq -s 'sort')
verify_metadata() {
    local draft=$1
    gh api --hostname github.com "repos/$repo/releases/$release_id" > "$work/release.json" 2> "$work/api-error" \
        || fail 'Unable to read release metadata.'
    jq -e --arg tag "$tag" --arg source "$source_commit" --argjson id "$release_id" --argjson draft "$draft" '
        .id == $id and .tag_name == $tag and .target_commitish == $source
        and .draft == $draft and .prerelease == false' "$work/release.json" >/dev/null \
        || fail 'Release metadata does not match the expected source and publication state.'
}
verify_metadata true
upload=()
for name in "${files[@]}"; do upload+=("$input/$name"); done
gh release upload "$tag" --repo "$repo" "${upload[@]}" > "$work/upload-output" 2> "$work/api-error" \
    || fail 'Asset upload failed; the draft remains unpublished.'
verify_assets() {
    local destination=$1 name
    gh api --hostname github.com --paginate --slurp "repos/$repo/releases/$release_id/assets?per_page=100" \
        > "$work/assets.json" 2> "$work/api-error" || fail 'Unable to list release assets.'
    jq -e --argjson expected "$expected_json" '[.[][] | .name] | sort == $expected' "$work/assets.json" >/dev/null \
        || fail 'Release assets do not match the exact expected set.'
    mkdir "$destination"
    gh release download "$tag" --repo "$repo" --dir "$destination" > "$work/download-output" 2> "$work/api-error" \
        || fail 'Unable to download release assets for byte verification.'
    validate_payload "$destination"
    for name in "${files[@]}"; do
        [[ $(shasum -a 256 < "$input/$name") == "$(shasum -a 256 < "$destination/$name")" ]] \
            || fail 'Downloaded release bytes differ from verified local bytes.'
    done
}
verify_assets "$work/draft-assets"
verify_metadata true
verify_remote_tag
gh release edit "$tag" --repo "$repo" --draft=false --prerelease=false --latest --verify-tag \
    > "$work/publish-output" 2> "$work/api-error" || fail 'Publication failed; inspect GitHub before retrying.'
verify_metadata false
verify_remote_tag
verify_assets "$work/public-assets"
url=$(jq -er '.html_url | select(type == "string")' "$work/release.json")
[[ $url == "https://github.com/$repo/releases/tag/$tag" ]] || fail 'Unexpected published release URL.'
printf 'Published and downloaded-byte verified: %s\n' "$url"
if [[ -n ${GITHUB_OUTPUT:-} ]]; then
    printf 'release_url=%s\n' "$url" >> "$GITHUB_OUTPUT"
fi
if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
    printf 'Published [%s](%s) from %s; all four draft and public assets match verified bytes.\n' \
        "$tag" "$url" "$source_commit" >> "$GITHUB_STEP_SUMMARY"
fi

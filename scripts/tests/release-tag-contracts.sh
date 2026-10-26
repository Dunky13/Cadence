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
case "$1" in
    rev-parse)
        if [[ ${TAG_SCENARIO:-} == wrong-checkout && $3 == HEAD ]]; then commit=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb; fi
        if [[ ${TAG_SCENARIO:-} == wrong-local-tag && $3 != HEAD ]]; then commit=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb; fi
        printf '%s\n' "$commit" ;;
    fetch) [[ ${TAG_SCENARIO:-} != fetch-error ]] ;;
    merge-base) [[ ${TAG_SCENARIO:-} != off-main ]] ;;
    ls-remote)
        case "${TAG_SCENARIO:-}" in
            remote-error) exit 1 ;;
            moved-tag) printf 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\trefs/tags/%s\n' "$GITHUB_REF_NAME" ;;
            annotated-tag)
                printf 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\trefs/tags/%s\n' "$GITHUB_REF_NAME"
                printf '%s\trefs/tags/%s^{}\n' "$commit" "$GITHUB_REF_NAME" ;;
            malformed-tag) printf 'not-a-sha\trefs/tags/%s\n' "$GITHUB_REF_NAME" ;;
            missing-tag) : ;;
            *) printf '%s\trefs/tags/%s\n' "$commit" "$GITHUB_REF_NAME" ;;
        esac ;;
    *) exit 99 ;;
esac
STUB
cat > "$work/bin/gh" <<'STUB'
#!/bin/bash
set -euo pipefail
printf 'gh %s\n' "$*" >> "$TAG_CALLS"
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
    env PATH="$work/bin:$PATH" TAG_CALLS="$calls" TAG_RELEASES="$releases" \
        GITHUB_REF_TYPE=tag GITHUB_REF="refs/tags/v$version" GITHUB_REF_NAME="v$version" \
        GITHUB_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa GITHUB_REPOSITORY=example/Cadence \
        TAG_SCENARIO='' "$@" /bin/bash "$root/scripts/verify-release-tag.sh" \
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
printf 'Production tag preflight contracts: %s cases passed; no provider mutations.\n' "$cases"

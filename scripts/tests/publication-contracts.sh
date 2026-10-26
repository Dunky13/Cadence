#!/bin/bash
# Synthetic GitHub boundary tests: these fixtures never publish or contact Apple.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/cadence-publication-tests.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"
cat > "$work/bin/git" <<'STUB'
#!/bin/bash
set -euo pipefail
case "$*" in
    'rev-parse --verify HEAD')
        if [[ $PUBLICATION_MODE == wrong-checkout ]]; then printf '%040d\n' 1; else printf '%s\n' "$GITHUB_SHA"; fi ;;
    'rev-parse --verify refs/tags/v1.2.3^{commit}')
        if [[ $PUBLICATION_MODE == wrong-local-tag ]]; then printf '%040d\n' 1; else printf '%s\n' "$GITHUB_SHA"; fi ;;
    *) printf 'Unexpected git command\n' >&2; exit 1 ;;
esac
STUB
cat > "$work/bin/gh" <<'STUB'
#!/bin/bash
set -euo pipefail
state=$PUBLICATION_STATE mode=$PUBLICATION_MODE
printf '%s\n' "$*" >> "$state/calls"
record() { printf 'event:%s\n' "$1" >> "$state/calls"; }
metadata() {
    local draft=true
    [[ -e $state/published ]] && draft=false
    if [[ $mode == wrong-draft-state && ! -e $state/published ]]; then draft=false; fi
    if [[ $mode == wrong-public-state && -e $state/published ]]; then draft=true; fi
    jq -n --arg source "$GITHUB_SHA" --argjson draft "$draft" '{id:42,tag_name:"v1.2.3",target_commitish:$source,
        draft:$draft,prerelease:false,html_url:"https://github.com/fixture/Cadence/releases/tag/v1.2.3"}'
}
if [[ $1 == api ]]; then
    include=false endpoint='' input_file='' method='' previous=''
    for argument in "$@"; do
        if [[ $previous == --input ]]; then input_file=$argument; fi
        if [[ $previous == --method ]]; then method=$argument; fi
        [[ $argument != --include ]] || include=true
        if [[ $argument == repos/* ]]; then endpoint=$argument; fi
        previous=$argument
    done
    header() { if [[ $include == true ]]; then printf 'HTTP/2.0 %s\r\nContent-Type: application/json\r\n\r\n' "$1"; fi; }
    case "$endpoint" in
        'repos/fixture/Cadence/releases?per_page=100')
            [[ $mode != lookup-auth && $mode != lookup-network ]] || exit 1
            if [[ $mode == existing-release || $mode == existing-draft ]]; then
                printf '[[{"tag_name":"v1.2.3","draft":true}]]\n'
            else printf '[[]]\n'; fi ;;
        repos/fixture/Cadence/releases)
            record create
            [[ $method == POST && -f $input_file ]] || exit 1
            jq -e '.tag_name == "v1.2.3" and .target_commitish == env.GITHUB_SHA and
                .draft == true and .prerelease == false and .generate_release_notes == true' "$input_file" >/dev/null || exit 1
            touch "$state/created"
            mkdir "$state/assets"
            metadata ;;
        repos/fixture/Cadence/git/ref/tags/v1.2.3)
            count=0
            [[ ! -f $state/tag-count ]] || read -r count < "$state/tag-count"
            count=$((count + 1))
            printf '%s\n' "$count" > "$state/tag-count"
            sha=$GITHUB_SHA type=commit
            if [[ $mode == annotated ]]; then sha=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb; type=tag; fi
            if [[ $mode == wrong-remote-tag || ( $mode == moved-tag-before-publish && $count -eq 2 ) || ( $mode == moved-tag-after-publish && $count -eq 3 ) ]]; then sha=cccccccccccccccccccccccccccccccccccccccc; fi
            jq -n --arg sha "$sha" --arg type "$type" '{ref:"refs/tags/v1.2.3",object:{sha:$sha,type:$type}}' ;;
        repos/fixture/Cadence/git/tags/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb)
            jq -n --arg sha "$GITHUB_SHA" '{sha:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",object:{sha:$sha,type:"commit"}}' ;;
        repos/fixture/Cadence/releases/tags/v1.2.3)
            if [[ -e $state/published || $mode == existing-release ]]; then header '200 OK'; metadata
            elif [[ $mode == lookup-auth ]]; then header '403 Forbidden'; printf '{"message":"Forbidden"}\n'; exit 1
            elif [[ $mode == lookup-network ]]; then exit 1
            else header '404 Not Found'; printf '{"message":"Not Found"}\n'; exit 1; fi ;;
        repos/fixture/Cadence/releases/latest)
            if [[ $mode == latest-auth ]]; then header '401 Unauthorized'; printf '{"message":"Unauthorized"}\n'; exit 1; fi
            latest='v1.2.2'
            case "$mode" in
                latest-newer) latest=v2.0.0 ;;
                latest-equal) latest=v1.2.3 ;;
                latest-malformed) latest=nightly ;;
                latest-big) latest=v9999999999999999999999999999999999999999.0.0 ;;
                no-latest) header '404 Not Found'; printf '{"message":"Not Found"}\n'; exit 1 ;;
            esac
            header '200 OK'
            jq -n --arg latest "$latest" '{tag_name:$latest,draft:false,prerelease:false}' ;;
        repos/fixture/Cadence/releases/42) metadata ;;
        'repos/fixture/Cadence/releases/42/assets?per_page=100')
            names=()
            for path in "$state/assets/"*; do names+=("${path##*/}"); done
            if [[ $mode == extra-remote-asset || ( $mode == extra-public-asset && -e $state/published ) ]]; then names+=(unexpected.txt); fi
            printf '%s\n' "${names[@]}" | jq -R '{name:.}' | jq -s '[.]' ;;
        *) printf 'Unexpected API endpoint: %s\n' "$endpoint" >&2; exit 1 ;;
    esac
    exit
fi
[[ $1 == release ]] || exit 1
command=$2
shift 2
case "$command" in
    upload)
        record upload
        [[ $* != *--clobber* ]] || exit 1
        if [[ $mode == upload-failure ]]; then printf 'partial\n' > "$state/assets/partial"; exit 1; fi
        for argument in "$@"; do if [[ -f $argument ]]; then cp "$argument" "$state/assets/"; fi; done ;;
    download)
        record download
        destination=''
        while [[ $# -gt 0 ]]; do
            if [[ $1 == --dir ]]; then destination=$2; shift 2; else shift; fi
        done
        [[ -n $destination ]] || exit 1
        cp "$state/assets/"* "$destination/"
        if [[ $mode == corrupt-draft-download || ( $mode == corrupt-public-download && -e $state/published ) ]]; then
            printf 'corrupted\n' >> "$destination/Cadence-App-1.2.3-universal.zip"
        fi
        if [[ $mode == extra-downloaded-file ]]; then printf 'extra\n' > "$destination/extra.txt"; fi ;;
    edit)
        record publish
        [[ $* == *--draft=false* && $* == *--prerelease=false* && $* == *--latest* ]] || exit 1
        [[ $mode != publish-failure ]] || exit 1
        touch "$state/published" ;;
    *) exit 1 ;;
esac
STUB
chmod +x "$work/bin/"*
cases=0
fail() { printf 'FAIL publication %s: %s\n' "$case_name" "$*" >&2; cat "$state/output" >&2; exit 1; }
new_case() {
    case_name=$1 mode=${2:-$1}
    state="$work/$case_name"
    input="$state/input"
    mkdir -p "$input" "$state/tmp"
    : > "$state/calls"
    printf 'app bytes\n' > "$input/Cadence-App-1.2.3-universal.zip"
    printf 'installer bytes\n' > "$input/Cadence-Installer-1.2.3-universal.dmg"
    jq -n '{schema:"cadence/distribution/v1",version:"1.2.3",architecture:"universal",
        source_commit:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",app_archive:"Cadence-App-1.2.3-universal.zip",
        installer:"Cadence-Installer-1.2.3-universal.dmg",signing:"Developer ID",notarization:"Accepted",
        tickets:"stapled and validated"}' > "$input/distribution.json"
    checksums
}
checksums() { (cd "$input" && shasum -a 256 Cadence-App-1.2.3-universal.zip Cadence-Installer-1.2.3-universal.dmg distribution.json > SHA256SUMS); }
invoke() {
    result=0
    env PATH="$work/bin:$PATH" TMPDIR="$state/tmp" PUBLICATION_STATE="$state" PUBLICATION_MODE="$mode" \
        GITHUB_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa GITHUB_REPOSITORY=fixture/Cadence GH_TOKEN=synthetic \
        GH_HOST=github.com GITHUB_STEP_SUMMARY="$state/summary" GITHUB_OUTPUT="$state/outputs" \
        /bin/bash "$root/scripts/publish-release.sh" v1.2.3 "$input" > "$state/output" 2>&1 || result=$?
    [[ -z $(ls -A "$state/tmp") ]] || fail 'private temporary files leaked'
}
reject_before_create() {
    invoke
    [[ $result != 0 ]] || fail 'unsafe input was accepted'
    ! grep -qx event:create "$state/calls" || fail 'draft creation reached after a failed preflight'
    cases=$((cases + 1))
}
reject_before_publish() {
    invoke
    [[ $result != 0 ]] || fail 'unsafe draft was published'
    [[ -e $state/created && ! -e $state/published ]] || fail 'draft not retained or release published'
    ! grep -qx event:publish "$state/calls" || fail 'publication reached after a failed gate'
    cases=$((cases + 1))
}
for mode in success annotated no-latest; do
    new_case "$mode"
    invoke
    [[ $result == 0 && -e $state/published ]] || fail 'valid release rejected'
    [[ $(grep -cx event:download "$state/calls") == 2 ]] || fail 'draft and public assets were not both downloaded'
    grep -q 'Published.*v1.2.3' "$state/summary" || fail 'success summary missing'
    grep -qx 'release_url=https://github.com/fixture/Cadence/releases/tag/v1.2.3' "$state/outputs" || fail 'environment URL output missing'
    cases=$((cases + 1))
done
for mode in wrong-checkout wrong-local-tag wrong-remote-tag existing-release existing-draft lookup-auth lookup-network latest-newer latest-equal latest-malformed latest-big latest-auth; do
    new_case "$mode"
    reject_before_create
done
new_case corrupt-local success
printf 'changed\n' >> "$input/Cadence-App-1.2.3-universal.zip"
reject_before_create
new_case extra-local success
printf 'extra\n' > "$input/extra"
reject_before_create
new_case symlink-local success
mv "$input/Cadence-App-1.2.3-universal.zip" "$state/archive"
ln -s "$state/archive" "$input/Cadence-App-1.2.3-universal.zip"
reject_before_create
new_case extra-checksum-path success
printf '%064d  ../escape\n' 0 >> "$input/SHA256SUMS"
reject_before_create
new_case duplicate-checksum success
head -n 1 "$input/SHA256SUMS" >> "$state/duplicate"
cat "$state/duplicate" >> "$input/SHA256SUMS"
reject_before_create
new_case missing-manifest-checksum success
sed '/distribution.json/d' "$input/SHA256SUMS" > "$state/without-manifest"
mv "$state/without-manifest" "$input/SHA256SUMS"
reject_before_create
for field in source_commit version architecture signing notarization tickets schema; do
    new_case "wrong-manifest-$field" success
    jq --arg field "$field" '.[$field]="wrong"' "$input/distribution.json" > "$state/manifest"
    mv "$state/manifest" "$input/distribution.json"
    checksums
    reject_before_create
done
for mode in upload-failure wrong-draft-state corrupt-draft-download extra-downloaded-file extra-remote-asset moved-tag-before-publish; do
    new_case "$mode"
    reject_before_publish
done
new_case publish-failure
invoke
[[ $result != 0 && -e $state/created && ! -e $state/published ]] || fail 'failed publication hid its retained draft'
cases=$((cases + 1))
for mode in wrong-public-state corrupt-public-download extra-public-asset moved-tag-after-publish; do
    new_case "$mode"
    invoke
    [[ $result != 0 && -e $state/published ]] || fail 'bad public readback was accepted'
    [[ ! -s $state/summary ]] || fail 'success claimed despite failed public readback'
    cases=$((cases + 1))
done
printf 'Publication contracts: %s cases passed; no provider calls or publication.\n' "$cases"

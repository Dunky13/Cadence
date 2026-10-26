#!/bin/bash
# Synthetic GitHub boundary tests: these fixtures never publish or contact Apple.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/cadence-publication-tests.XXXXXX")
work=$(cd "$work" && pwd -P)
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"
cat > "$work/bin/plutil" <<'STUB'
#!/bin/bash
if [[ ${PUBLICATION_SPLIT:-false} == true ]]; then
    path=''; for argument in "$@"; do path=$argument; done
    [[ $path == "$RELEASE_SOURCE_DIRECTORY/Resources/Info.plist" ]] || { printf '999.0.0\n'; exit; }
fi
if [[ $* == *CFBundleVersion* ]]; then printf '123\n'; else printf '1.2.3\n'; fi
STUB
cat > "$work/bin/git" <<'STUB'
#!/bin/bash
set -euo pipefail
commit=${SOURCE_COMMIT:-$GITHUB_SHA}
directory=$PWD
if [[ $1 == -C ]]; then directory=$2; shift 2; fi
case "$*" in
    'rev-parse --show-toplevel') printf '%s\n' "$directory" ;;
    'ls-files --error-unmatch '*) : ;;
    'rev-parse --verify HEAD')
        if [[ $PUBLICATION_MODE == wrong-checkout ]]; then printf '%040d\n' 1; elif [[ -n ${AUTOMATION_COMMIT:-} && $directory != "$RELEASE_SOURCE_DIRECTORY" ]]; then printf '%s\n' "$AUTOMATION_COMMIT"; else printf '%s\n' "$commit"; fi ;;
    'rev-parse --verify refs/tags/v1.2.3^{commit}')
        if [[ $PUBLICATION_MODE == wrong-local-tag ]]; then printf '%040d\n' 1; else printf '%s\n' "$commit"; fi ;;
    'status --porcelain --untracked-files=all') : ;;
    'fetch --no-tags origin main') : ;;
    'fetch --no-tags origin refs/tags/v1.2.3:refs/tags/v1.2.3') : ;;
    'merge-base --is-ancestor '* ) [[ $PUBLICATION_MODE != off-main ]] ;;
    'ls-remote origin refs/tags/v1.2.3 refs/tags/v1.2.3^{}')
        if [[ $PUBLICATION_MODE == tag-lookup-error ]]; then exit 1; fi
        if [[ $PUBLICATION_MODE == wrong-remote-tag ]]; then
            printf '%040d\trefs/tags/v1.2.3\n' 1
        elif [[ $PUBLICATION_MODE != main-without-tag && $PUBLICATION_MODE != tag-create-failure || -e $PUBLICATION_STATE/tag-created ]]; then
            printf '%s\trefs/tags/v1.2.3\n' "$commit"
        fi ;;
    *) printf 'Unexpected git command\n' >&2; exit 1 ;;
esac
STUB
cat > "$work/bin/gh" <<'STUB'
#!/bin/bash
set -euo pipefail
state=$PUBLICATION_STATE mode=$PUBLICATION_MODE
commit=${SOURCE_COMMIT:-$GITHUB_SHA}
shopt -s nullglob
printf '%s\n' "$*" >> "$state/calls"
record() { printf 'event:%s\n' "$1" >> "$state/calls"; }
metadata() {
    local draft=true immutable=false
    [[ ! -e $state/published ]] || { draft=false; immutable=true; }
    if [[ $mode == wrong-draft-state && ! -e $state/published ]]; then draft=false; fi
    if [[ $mode == wrong-public-state && -e $state/published ]]; then draft=true; fi
    if [[ ( $mode == mutable-public || $mode == policy-disabled ) && -e $state/published ]]; then immutable=false; fi
    jq --argjson draft "$draft" --argjson immutable "$immutable" \
        '. + {id:42,draft:$draft,immutable:$immutable,author:{login:"github-actions[bot]",type:"Bot",id:41898282},
        html_url:("https://github.com/"+env.GITHUB_REPOSITORY+"/releases/tag/v1.2.3")} | del(.generate_release_notes)
        | if env.PUBLICATION_MODE == "unowned-draft" then .author.login="maintainer"
          elif env.PUBLICATION_MODE == "spoofed-bot" then .author.id=123 else . end' "$state/create.json"
}
asset_list() {
    local path name id=100 size digest
    printf '['
    for path in "$state/assets/"*; do
        name=${path##*/}
        id=$((id + 1))
        printf '%s' "$name" > "$state/id-$id"
        size=$(wc -c < "$path")
        digest=$(shasum -a 256 < "$path"); digest=${digest%% *}
        asset_state=uploaded
        [[ ! -f $state/starter-$name ]] || asset_state=starter
        uploader_id=41898282
        [[ $mode != foreign-starter ]] || uploader_id=7
        jq -cn --arg name "$name" --argjson id "$id" --argjson size "$size" --arg digest "sha256:$digest" --arg state "$asset_state" --argjson uploader "$uploader_id" \
            '{name:$name,id:$id,size:$size,digest:$digest,state:$state,uploader:{login:"github-actions[bot]",type:"Bot",id:$uploader}}'
    done | jq -s .
    printf ']'
}
if [[ $1 == api ]]; then
    include=false endpoint='' input_file='' method='' previous=''
    for argument in "$@"; do
        if [[ $previous == --input ]]; then input_file=$argument; fi
        if [[ $previous == --method ]]; then method=$argument; fi
        [[ $argument != --include ]] || include=true
        if [[ $argument == repos/* ]]; then endpoint=$argument; fi
        if [[ $argument == https://uploads.github.com/repos/* ]]; then
            endpoint=${argument#https://uploads.github.com/}
        fi
        previous=$argument
    done
    header() { if [[ $include == true ]]; then printf 'HTTP/2.0 %s\r\nContent-Type: application/json\r\n\r\n' "$1"; fi; }
    # The same fake provider serves legacy and explicit trusted-main contexts.
    endpoint=${endpoint/repos\/Dunky13\/Cadence/repos\/fixture\/Cadence}
    case "$endpoint" in
        *workflows/ci.yml/runs\?*)
            jq -n '[{workflow_runs:[{id:901,head_sha:env.AUTOMATION_COMMIT,head_branch:"main",event:"push",
                path:".github/workflows/ci.yml",status:"completed",conclusion:"success",
                repository:{full_name:env.GITHUB_REPOSITORY},head_repository:{full_name:env.GITHUB_REPOSITORY}}]}]' ;;
        */runs/901)
            jq -n '{id:901,head_sha:env.AUTOMATION_COMMIT,head_branch:"main",event:"push",
                path:".github/workflows/ci.yml",status:"completed",conclusion:"success",
                repository:{full_name:env.GITHUB_REPOSITORY},head_repository:{full_name:env.GITHUB_REPOSITORY}}' ;;
        */runs/901/jobs\?*)
            if [[ $mode == automation-ci-failed ]]; then printf '[{"jobs":[]}]';
            else printf '[{"jobs":[{"name":"ci-required","status":"completed","conclusion":"success"}]}]'; fi ;;
        repos/fixture/Cadence/git/refs)
            record tag-create
            [[ $method == POST && -f $input_file && $mode != tag-create-failure ]] || exit 1
            jq -e --arg sha "$commit" '.ref == "refs/tags/v1.2.3" and .sha == $sha' "$input_file" >/dev/null
            touch "$state/tag-created"
            jq -n --arg sha "$commit" '{ref:"refs/tags/v1.2.3",object:{type:"commit",sha:$sha}}' ;;

        'repos/fixture/Cadence/releases?per_page=100')
            [[ $mode != lookup-auth && $mode != lookup-network ]] || exit 1
            if [[ $mode == existing-release || $mode == existing-draft ]]; then
                printf '[[{"tag_name":"v1.2.3","draft":true}]]\n'
            elif [[ -e $state/created ]]; then metadata | jq -s '[.]'
            else printf '[[]]\n'; fi ;;
        repos/fixture/Cadence/releases)
            record create
            [[ $method == POST && -f $input_file ]] || exit 1
            jq -e --arg sha "$commit" '.tag_name == "v1.2.3" and .target_commitish == $sha and
                .draft == true and .prerelease == false and (.body | startswith("<!-- cadence-publication/v1 "))' "$input_file" >/dev/null || exit 1
            [[ ! -e $state/created ]] || exit 1
            [[ $mode != create-no-write ]] || exit 1
            cp "$input_file" "$state/create.json"
            touch "$state/created"
            mkdir "$state/assets"
            [[ $mode != lost-create-response ]] || exit 1
            metadata ;;
        repos/fixture/Cadence/git/ref/tags/v1.2.3)
            count=0
            [[ ! -f $state/tag-count ]] || read -r count < "$state/tag-count"
            count=$((count + 1))
            printf '%s\n' "$count" > "$state/tag-count"
            sha=$commit type=commit
            if [[ $mode == annotated ]]; then sha=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb; type=tag; fi
            if [[ $mode == wrong-remote-tag || ( $mode == moved-tag-before-publish && $count -eq 3 ) || ( $mode == moved-tag-after-publish && $count -eq 4 ) ]]; then sha=cccccccccccccccccccccccccccccccccccccccc; fi
            jq -n --arg sha "$sha" --arg type "$type" '{ref:"refs/tags/v1.2.3",object:{sha:$sha,type:$type}}' ;;
        repos/fixture/Cadence/git/tags/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb)
            jq -n --arg sha "$commit" '{sha:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",object:{sha:$sha,type:"commit"}}' ;;
        repos/fixture/Cadence/releases/tags/v1.2.3)
            if [[ -e $state/published || $mode == existing-release ]]; then header '200 OK'; metadata
            elif [[ $mode == lookup-auth ]]; then header '403 Forbidden'; printf '{"message":"Forbidden"}\n'; exit 1
            elif [[ $mode == lookup-network ]]; then exit 1
            else header '404 Not Found'; printf '{"message":"Not Found"}\n'; exit 1; fi ;;
        repos/fixture/Cadence/releases/latest)
            if [[ $mode == latest-auth ]]; then header '401 Unauthorized'; printf '{"message":"Unauthorized"}\n'; exit 1; fi
            latest='v1.2.2'
            [[ ! -e $state/published ]] || latest=v1.2.3
            case "$mode" in
                latest-newer) latest=v2.0.0 ;;
                latest-equal) latest=v1.2.3 ;;
                latest-malformed) latest=nightly ;;
                latest-big) latest=v9999999999999999999999999999999999999999.0.0 ;;
                no-latest) header '404 Not Found'; printf '{"message":"Not Found"}\n'; exit 1 ;;
            esac
            header '200 OK'
            jq -n --arg latest "$latest" '{tag_name:$latest,draft:false,prerelease:false}' ;;
        repos/fixture/Cadence/releases/42)
            if [[ $method == PATCH ]]; then
                record publish
                jq -e '.draft == false and .prerelease == false and .make_latest == "true"' "$input_file" >/dev/null
                [[ $mode != publish-failure ]] || exit 1
                touch "$state/published"
                [[ $mode != lost-publish-response ]] || exit 1
            fi
            metadata ;;
        'repos/fixture/Cadence/releases/42/assets?name='*)
            record upload
            [[ $* == *https://uploads.github.com/repos/"$GITHUB_REPOSITORY"/releases/42/assets\?name=* ]] || exit 1
            [[ $* == *'Content-Length: '* && $* == *'Content-Type: application/octet-stream'* ]] || exit 1
            name=${endpoint##*name=}
            [[ $method == POST && -f $input_file && ! -e $state/assets/$name ]] || exit 1
            if [[ $mode == starter-upload || $mode == starter-unknown ]]; then
                : > "$state/assets/$name"; touch "$state/starter-$name"
                if [[ $mode == starter-upload ]]; then
                    printf 'HTTP/2.0 502 Bad Gateway\r\nX-GitHub-Request-Id: FIXTURE:502\r\nContent-Type: application/json\r\n\r\n'
                fi
                exit 1
            fi
            if [[ $mode == upload-failure ]]; then printf 'partial\n' > "$state/assets/partial"; exit 1; fi
            if [[ $mode == upload-no-write || ( $mode == interrupted-upload && $name == Cadence-Installer-1.2.3-universal.dmg ) ]]; then exit 1; fi
            cp "$input_file" "$state/assets/$name"
            [[ $mode != lost-upload-response ]] || exit 1 ;;
        'repos/fixture/Cadence/releases/42/assets?per_page=100')
            if [[ $mode == extra-remote-asset || ( $mode == extra-public-asset && -e $state/published ) ]]; then
                printf 'extra\n' > "$state/assets/unexpected.txt"
            fi
            if [[ $mode == asset-list-auth ]]; then exit 1; fi
            if [[ $mode == duplicate-assets ]]; then asset_list | jq '.[0] += .[0]'
            elif [[ $mode == incomplete-asset ]]; then asset_list | jq '.[0] |= map(.state="starter")'
            else asset_list; fi ;;
        repos/fixture/Cadence/releases/assets/*)
            id=${endpoint##*/}
            name=$(cat "$state/id-$id")
            if [[ $method == DELETE ]]; then
                [[ -f $state/assets/$name ]] || exit 1
                # Production DELETE has no state/size precondition. Do not invent one.
                if [[ $mode == completion-race ]]; then cp "$PUBLICATION_INPUT/$name" "$state/assets/$name"; record completed-before-delete; fi
                record delete
                rm "$state/assets/$name" "$state/starter-$name"
                [[ $mode != lost-delete-response ]] || exit 1
                exit 0
            fi
            if [[ $* != *application/octet-stream* ]]; then
                asset_list | jq --argjson id "$id" '.[0][] | select(.id == $id)'
                exit 0
            fi
            record download
            [[ $mode != asset-download-error ]] || exit 1
            cat "$state/assets/$name"
            if [[ $name == Cadence-App-1.2.3-universal.zip && ( $mode == corrupt-draft-download || ( $mode == corrupt-public-download && -e $state/published ) ) ]]; then
                printf 'corrupted\n'
            fi ;;
        *) printf 'Unexpected API endpoint: %s\n' "$endpoint" >&2; exit 1 ;;
    esac
    exit
fi
exit 99
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
        tickets:"stapled and validated",build_number:"123",
        origin:{build_ci_run_id:"17",build_artifact_id:"23",
        build_artifact_digest:"sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"}}' > "$input/distribution.json"
    checksums
}
checksums() { (cd "$input" && shasum -a 256 Cadence-App-1.2.3-universal.zip Cadence-Installer-1.2.3-universal.dmg distribution.json > SHA256SUMS); }
invoke() {
    result=0
    : > "$state/summary"
    : > "$state/outputs"
    env PATH="$work/bin:$PATH" TMPDIR="$state/tmp" PUBLICATION_STATE="$state" PUBLICATION_MODE="$mode" \
        PUBLICATION_STATE_DIRECTORY="$state/custody" PUBLICATION_INPUT="$input" \
        GITHUB_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa GITHUB_REPOSITORY=fixture/Cadence GH_TOKEN=synthetic \
        GH_HOST=github.com GITHUB_STEP_SUMMARY="$state/summary" GITHUB_OUTPUT="$state/outputs" \
        SOURCE_COMMIT='' RELEASE_TAG='' RECOVER_CANDIDATE=false \
        BUILD_CI_RUN_ID=17 BUILD_ARTIFACT_ID=23 \
        BUILD_ARTIFACT_DIGEST=sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd \
        GITHUB_REF_TYPE=tag GITHUB_REF=refs/tags/v1.2.3 GITHUB_REF_NAME=v1.2.3 "$@" \
        /bin/bash "$root/scripts/publish-release.sh" ${resume_option:+"$resume_option"} v1.2.3 "$input" > "$state/output" 2>&1 || result=$?
    [[ -z $(ls -A "$state/tmp") ]] || fail 'private temporary files leaked'
}
reject_before_create() {
    invoke "$@"
    [[ $result != 0 ]] || fail 'unsafe input was accepted'
    ! grep -qx event:create "$state/calls" || fail 'draft creation reached after a failed preflight'
    [[ ! -e $state/tag-created ]] || fail 'tag created after a failed preflight'
    cases=$((cases + 1))
}
reject_before_publish() {
    invoke
    [[ $result != 0 ]] || fail 'unsafe draft was published'
    [[ -e $state/created && ! -e $state/published ]] || fail 'draft not retained or release published'
    ! grep -qx event:publish "$state/calls" || fail 'publication reached after a failed gate'
    cases=$((cases + 1))
}
for mode in success annotated no-latest lost-create-response lost-upload-response lost-publish-response; do
    new_case "$mode"
    invoke
    [[ $result == 0 && -e $state/published ]] || fail 'valid release rejected'
    [[ $(grep -c '^event:create$' "$state/calls") == 1 ]] || fail 'draft creation repeated'
    [[ $(grep -c '^event:upload$' "$state/calls") == 4 ]] || fail 'asset uploads repeated'
    [[ $(grep -c '^event:publish$' "$state/calls") == 1 ]] || fail 'publication repeated'
    [[ $(grep -cx event:download "$state/calls") -ge 8 ]] || fail 'draft and public assets were not both downloaded'
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
for field in source_commit version architecture signing notarization tickets schema origin build_number; do
    new_case "wrong-manifest-$field" success
    jq --arg field "$field" '.[$field]="wrong"' "$input/distribution.json" > "$state/manifest"
    mv "$state/manifest" "$input/distribution.json"
    checksums
    reject_before_create
done
for mode in upload-failure wrong-draft-state corrupt-draft-download extra-remote-asset moved-tag-before-publish; do
    new_case "$mode"
    reject_before_publish
done
new_case publish-failure
invoke
[[ $result != 0 && -e $state/created && ! -e $state/published ]] || fail 'failed publication hid its retained draft'
cases=$((cases + 1))
for mode in wrong-public-state corrupt-public-download extra-public-asset moved-tag-after-publish mutable-public; do
    new_case "$mode"
    invoke
    [[ $result != 0 && -e $state/published ]] || fail 'bad public readback was accepted'
    [[ ! -s $state/summary ]] || fail 'success claimed despite failed public readback'
    cases=$((cases + 1))
done
main_context=(GITHUB_REF_TYPE=branch GITHUB_REF=refs/heads/main GITHUB_REF_NAME=main
    SOURCE_COMMIT=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa RELEASE_TAG=v1.2.3)
for mode in main-without-tag main-existing-tag; do
    new_case "$mode"
    invoke "${main_context[@]}" GITHUB_SHA=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
    [[ $result == 0 && -e $state/published ]] || fail 'latest-main release rejected'
    if [[ $mode == main-without-tag ]]; then
        [[ -e $state/tag-created ]] || fail 'missing tag was not created'
        [[ $(grep -c '^event:tag-create$' "$state/calls") == 1 ]] || fail 'tag creation was retried'
    else
        [[ ! -e $state/tag-created ]] || fail 'existing tag was replaced'
    fi
    cases=$((cases + 1))
done
for mode in off-main tag-lookup-error tag-create-failure wrong-remote-tag existing-release latest-newer; do
    new_case "main-$mode" "$mode"
    reject_before_create "${main_context[@]}"
done
new_case main-corrupt-payload main-without-tag
printf 'corrupt\n' >> "$input/Cadence-App-1.2.3-universal.zip"
reject_before_create "${main_context[@]}"
new_case main-tag-mismatch main-without-tag
reject_before_create "${main_context[@]}" RELEASE_TAG=v9.9.9
new_case create-no-write
invoke
[[ $result != 0 && ! -e $state/created && ! -e $state/published ]] || fail 'failed creation accepted'
[[ $(grep -c '^event:create$' "$state/calls") == 1 ]] || fail 'failed creation retried'
cases=$((cases + 1))
# Recovery across separate invocations: only the explicitly selected candidate
# may be resumed. Record each mutation to prove no create/overwrite/republication.
seed_draft() {
    new_case "$1" "${2:-publish-failure}"
    invoke
    [[ $result != 0 && -e $state/created && ! -e $state/published ]] || fail 'draft seed failed'
    mode=success
    : > "$state/calls"
}
no_mutations() {
    ! grep -Eq '^event:(create|upload|publish|tag-create|delete)$' "$state/calls" || fail 'unexpected recovery mutation'
}
for interruption in publish-failure upload-no-write interrupted-upload; do
    seed_draft "resume-$interruption" "$interruption"
    invoke RECOVER_CANDIDATE=true
    [[ $result == 0 && -e $state/published ]] || fail 'same candidate draft recovery failed'
    ! grep -qx event:create "$state/calls" || fail 'recovery created another draft'
    uploads=$(grep -c '^event:upload$' "$state/calls" || true)
    case "$interruption" in
        publish-failure) [[ $uploads == 0 ]] || fail 'complete draft assets were reuploaded' ;;
        upload-no-write) [[ $uploads == 4 ]] || fail 'empty draft assets not completed' ;;
        interrupted-upload) [[ $uploads == 3 ]] || fail 'existing partial draft asset was reuploaded' ;;
    esac
    [[ $(grep -c '^event:publish$' "$state/calls") == 1 ]] || fail 'draft published more than once'
    cases=$((cases + 1))
done
new_case resume-published success
invoke
[[ $result == 0 ]] || fail 'published seed failed'
: > "$state/calls"
invoke RECOVER_CANDIDATE=true
[[ $result == 0 ]] || fail 'published identical candidate recovery failed'
no_mutations
[[ $(grep -c '^event:download$' "$state/calls") == 4 ]] || fail 'published recovery did not verify every asset'
cases=$((cases + 1))
for state_kind in draft published; do
    new_case "implicit-resume-$state_kind" success
    if [[ $state_kind == draft ]]; then mode=publish-failure; fi
    invoke
    mode=success
    : > "$state/calls"
    invoke
    [[ $result != 0 ]] || fail 'implicit recovery accepted'
    no_mutations
    cases=$((cases + 1))
done
for conflict in source body title extra-asset conflicting-asset duplicate-assets incomplete-asset asset-list-auth asset-download-error unowned-draft spoofed-bot; do
    seed_draft "resume-reject-$conflict"
    case "$conflict" in
        source) jq '.target_commitish="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' "$state/create.json" > "$state/changed"; mv "$state/changed" "$state/create.json" ;;
        body) jq '.body += "\n<!-- cadence-publication/v1 ambiguous -->"' "$state/create.json" > "$state/changed"; mv "$state/changed" "$state/create.json" ;;
        title) jq '.name="Unrelated release"' "$state/create.json" > "$state/changed"; mv "$state/changed" "$state/create.json" ;;
        extra-asset) printf 'extra\n' > "$state/assets/extra" ;;
        conflicting-asset) printf 'wrong bytes\n' > "$state/assets/Cadence-App-1.2.3-universal.zip" ;;
        *) mode=$conflict ;;
    esac
    invoke RECOVER_CANDIDATE=true
    [[ $result != 0 ]] || fail 'conflicting recovery accepted'
    no_mutations
    [[ ! -s $state/summary ]] || fail 'failed recovery claimed success'
    cases=$((cases + 1))
done
for binding in BUILD_CI_RUN_ID BUILD_ARTIFACT_ID BUILD_ARTIFACT_DIGEST; do
    seed_draft "resume-reject-$binding"
    invoke RECOVER_CANDIDATE=true "$binding=99"
    [[ $result != 0 ]] || fail 'mismatched build origin accepted'
    no_mutations
    cases=$((cases + 1))
done
seed_draft resume-other-payload
printf 'different but valid local archive\n' > "$input/Cadence-App-1.2.3-universal.zip"
checksums
invoke RECOVER_CANDIDATE=true
[[ $result != 0 ]] || fail 'different candidate bytes reused a draft'
no_mutations
cases=$((cases + 1))
for mode_name in mutable-public policy-disabled corrupt-public-download extra-public-asset; do
    new_case "resume-published-$mode_name" success
    invoke
    [[ $result == 0 ]] || fail 'published seed failed'
    mode=$mode_name
    : > "$state/calls"
    invoke RECOVER_CANDIDATE=true
    [[ $result != 0 ]] || fail 'bad published state accepted during recovery'
    no_mutations
    [[ ! -s $state/summary ]] || fail 'bad public recovery claimed success'
    cases=$((cases + 1))
done
seed_draft resume-cli
resume_option=--resume
invoke
unset resume_option
[[ $result == 0 ]] || fail 'explicit --resume CLI rejected'
cases=$((cases + 1))
seed_draft main-resume
invoke "${main_context[@]}" RECOVER_CANDIDATE=true
[[ $result == 0 ]] || fail 'main-context same-candidate recovery rejected'
cases=$((cases + 1))
for ref in refs/heads/feature refs/heads/main; do
    new_case "published-bad-context-${ref##*/}" success
    invoke
    [[ $result == 0 ]] || fail 'published seed failed'
    : > "$state/calls"
    invoke "${main_context[@]}" RECOVER_CANDIDATE=true GITHUB_REF="$ref" GITHUB_REF_TYPE=tag
    [[ $result != 0 ]] || fail 'published recovery bypassed workflow context'
    no_mutations
    cases=$((cases + 1))
done
new_case manifest-v2 success
jq '.schema="cadence/distribution/v2"' "$input/distribution.json" > "$state/manifest"
mv "$state/manifest" "$input/distribution.json"
checksums
invoke
[[ $result == 0 ]] || fail 'compatible v2 manifest rejected'
cases=$((cases + 1))
for recovery_mode in success lost-delete-response; do
    seed_draft "resume-empty-starter-$recovery_mode" starter-upload
    mode=$recovery_mode
    invoke RECOVER_CANDIDATE=true
    [[ $result == 0 && -e $state/published ]] || fail 'owned empty starter did not recover'
    [[ $(grep -c '^event:delete$' "$state/calls") == 1 ]] || fail 'starter deletion was not limited to one exact ID'
    [[ $(grep -c '^event:upload$' "$state/calls") == 4 ]] || fail 'missing assets were not completed exactly once'
    cases=$((cases + 1))
done
for invalid_starter in foreign-starter nonempty-starter; do
    seed_draft "reject-$invalid_starter" starter-upload
    if [[ $invalid_starter == nonempty-starter ]]; then printf 'protected bytes' > "$state/assets/Cadence-App-1.2.3-universal.zip"; else mode=foreign-starter; fi
    invoke RECOVER_CANDIDATE=true
    [[ $result != 0 ]] || fail 'unsafe starter repair accepted'
    no_mutations
    cases=$((cases + 1))
done
seed_draft unproven-starter-race starter-unknown
mode=completion-race
invoke RECOVER_CANDIDATE=true
[[ $result != 0 ]] || fail 'unproven in-flight starter was repaired'
no_mutations
[[ ! -e $state/published ]] || fail 'uncertain starter published'
cases=$((cases + 1))
seed_draft wrong-terminal-receipt starter-upload
jq '.terminal_502_uploads[0].sha256="ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"' "$state/custody/publication-receipts.json" > "$state/changed"
mv "$state/changed" "$state/custody/publication-receipts.json"
invoke RECOVER_CANDIDATE=true
[[ $result != 0 ]] || fail 'wrong terminal upload binding accepted'
no_mutations
cases=$((cases + 1))
seed_draft missing-terminal-receipt starter-upload
rm "$state/custody/publication-receipts.json"
invoke RECOVER_CANDIDATE=true
[[ $result != 0 ]] || fail 'lost terminal evidence authorized deletion'
no_mutations
cases=$((cases + 1))
# Full immutable-publication and published-recovery paths use new automation,
# with product tag/source/version/build and four asset hashes left unchanged.
mkdir -p "$work/product/Resources"
cp "$root/Resources/Info.plist" "$root/Resources/Install.txt" "$work/product/Resources/"
split_context=(PUBLICATION_SPLIT=true RELEASE_SOURCE_DIRECTORY="$work/product"
    AUTOMATION_COMMIT=cccccccccccccccccccccccccccccccccccccccc GITHUB_SHA=cccccccccccccccccccccccccccccccccccccccc
    SOURCE_COMMIT=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa GITHUB_REPOSITORY=Dunky13/Cadence
    RELEASE_TAG=v1.2.3 GITHUB_REF_TYPE=branch GITHUB_REF=refs/heads/main GITHUB_REF_NAME=main)
new_case split-source-publication success
invoke "${split_context[@]}"
[[ $result == 0 && -e $state/published ]] || fail 'split-source publication failed'
jq -e '.target_commitish == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" and .tag_name == "v1.2.3"' "$state/create.json" >/dev/null || fail 'tag/release followed automation commit'
[[ $(grep -c '^event:upload$' "$state/calls") == 4 ]] || fail 'wrong split-source upload count'
invoke "${split_context[@]}" RECOVER_CANDIDATE=true AUTOMATION_COMMIT=dddddddddddddddddddddddddddddddddddddddd GITHUB_SHA=dddddddddddddddddddddddddddddddddddddddd
[[ $result == 0 && $(grep -c '^event:upload$' "$state/calls") == 4 && $(grep -c '^event:publish$' "$state/calls") == 1 ]] || fail 'automation repair changed immutable published bytes'
cases=$((cases+2))
new_case split-source-unpassed-automation automation-ci-failed
reject_before_create "${split_context[@]}"
printf 'Publication contracts: %s cases passed; no provider calls or publication.\n' "$cases"

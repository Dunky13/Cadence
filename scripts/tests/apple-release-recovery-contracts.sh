#!/bin/bash
# Exercise the real phase driver, packaging, and install gates with fake tools.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/cadence-release-contracts.XXXXXX")
work=$(cd "$work" && pwd -P)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/repo/scripts" "$work/repo/Resources" "$work/provider"
for script in validate-apple-ticket.sh release-source-context.sh release-macos.sh notarize-artifact.sh apple-stage-state.sh verify-apple-distribution.sh verify-apple-dmg-binding.sh package-dmg.sh check-dmg.sh verify-demo-startup.sh launch-ui-observer.sh capture-startup-failure.sh capture-observer-bootstrap.sh collect-observer-evidence.sh; do
    cp "$root/scripts/$script" "$work/repo/scripts/"
done
printf '{"CFBundleShortVersionString":"1.2.3","CFBundleVersion":"42"}\n' > "$work/repo/Resources/Info.plist"
printf 'Install fixture\n' > "$work/repo/Resources/Install.txt"
cat > "$work/bin/fake-tool" <<'STUB'
#!/bin/bash
set -euo pipefail
tool=${0##*/}
printf '%s %s\n' "$tool" "$*" >> "$FIXTURE_CALLS"
case $tool in
    uname) printf 'Darwin\n' ;;
    git)
        directory=$PWD
        if [[ $1 == -C ]]; then directory=$2; shift 2; fi
        case $1 in
            rev-parse)
                if [[ $2 == --show-toplevel ]]; then printf '%s\n' "$directory"
                elif [[ -n ${AUTOMATION_COMMIT:-} && $directory == "$FIXTURE_AUTOMATION_ROOT" ]]; then printf '%s\n' "$AUTOMATION_COMMIT"
                else printf '%s\n' "$SOURCE_COMMIT"; fi ;;
            status) [[ ${FIXTURE_MODE:-} != dirty ]] || printf ' M modified\n' ;;
            fetch|merge-base|ls-files) : ;;
            *) exit 91 ;;
        esac ;;
    gh)
        endpoint=''; for argument in "$@"; do endpoint=$argument; done
        case $endpoint in
            *workflows/ci.yml/runs\?*)
                jq -n '[{workflow_runs:[{id:901,head_sha:env.AUTOMATION_COMMIT,head_branch:"main",event:"push",
                    path:".github/workflows/ci.yml",status:"completed",conclusion:"success",
                    repository:{full_name:env.GITHUB_REPOSITORY},head_repository:{full_name:env.GITHUB_REPOSITORY}}]}]' ;;
            */runs/901)
                jq -n '{id:901,head_sha:env.AUTOMATION_COMMIT,head_branch:"main",event:"push",
                    path:".github/workflows/ci.yml",status:"completed",conclusion:"success",
                    repository:{full_name:env.GITHUB_REPOSITORY},head_repository:{full_name:env.GITHUB_REPOSITORY}}' ;;
            */runs/901/jobs\?*) printf '[{"jobs":[{"name":"ci-required","status":"completed","conclusion":"success"}]}]' ;;
            *) exit 98 ;;
        esac ;;
    plutil)
        key=$2 path=''; for argument in "$@"; do path=$argument; done
        jq -er --arg key "$key" '.[$key]' "$path" ;;
    lipo) printf '%s\n' "${FIXTURE_ARCHS:-arm64 x86_64}" ;;
    codesign)
        target=''; for argument in "$@"; do target=$argument; done
        case $1 in
            --display)
                team=$APPLE_TEAM_ID
                [[ ${FIXTURE_MODE:-} != wrong-team ]] || team=WRONG12345
                printf 'Authority=Developer ID Application: Fixture\nTeamIdentifier=%s\n' "$team" >&2 ;;
            --force)
                if [[ -d $target ]]; then printf 'signed bundle' > "$target/Contents/signature";
                else printf 'signed' >> "$target"; fi ;;
            --verify) [[ ${FIXTURE_MODE:-} != bad-signature ]] ;;
            *) exit 92 ;;
        esac ;;
    ditto)
        arguments=("$@")
        source_path=${arguments[${#arguments[@]}-2]} destination=${arguments[${#arguments[@]}-1]}
        if [[ $1 == -c ]]; then
            tar -cf "$destination" -C "$(dirname "$source_path")" "${source_path##*/}"
        elif [[ $1 == -x ]]; then
            mkdir -p "$destination"; tar -xf "$source_path" -C "$destination"
        else
            cp -R "$source_path" "$destination"
        fi ;;
    spctl) [[ ${FIXTURE_MODE:-} != gatekeeper-failure ]] ;;
    hdiutil)
        operation=$1; shift
        case $operation in
            create)
                source_path='' destination=''
                while [[ $# -gt 0 ]]; do
                    if [[ $1 == -srcfolder ]]; then source_path=$2; shift; fi
                    destination=$1; shift
                done
                [[ ${FIXTURE_MODE:-} != package-failure ]] || exit 3
                tar -cf "$destination" -C "$source_path" . ;;
            verify) [[ ${FIXTURE_MODE:-} != image-failure ]] ;;
            attach)
                mountpoint='' image=''
                while [[ $# -gt 0 ]]; do
                    if [[ $1 == -mountpoint ]]; then mountpoint=$2; shift; fi
                    image=$1; shift
                done
                tar -xf "$image" -C "$mountpoint"
                printf '%s\n' "$mountpoint" > "$FIXTURE_PROVIDER/mount"
                if [[ ${FIXTURE_MODE:-} == installed-wrong-build ]]; then
                    jq '.CFBundleVersion="99"' "$mountpoint/Cadence.app/Contents/Info.plist" > "$mountpoint/changed"
                    mv "$mountpoint/changed" "$mountpoint/Cadence.app/Contents/Info.plist"
                fi ;;
            detach) rm -f "$FIXTURE_PROVIDER/mount" ;;
            *) exit 93 ;;
        esac ;;
    mount)
        if [[ -f $FIXTURE_PROVIDER/mount ]]; then printf '/dev/fixture on %s (hfs, readonly)\n' "$(cat "$FIXTURE_PROVIDER/mount")"; fi ;;
    xcrun)
        if [[ $1 == stapler ]]; then
            operation=$2 target=$3
            [[ ${FIXTURE_MODE:-} != staple-failure ]] || exit 9
            [[ ${FIXTURE_MODE:-} != ticket-failure || $operation != validate ]] || exit 9
            if [[ $operation == staple ]]; then
                if [[ -d $target ]]; then printf ticket > "$target/Contents/ticket";
                else printf ticket >> "$target"; fi
            fi
            exit 0
        fi
        [[ $1 == notarytool ]] || exit 94
        operation=$2; shift 2
        stage=app id=a1234567-89ab-4cde-8123-456789abcdef
        if [[ $1 == *Installer* || $1 == b1234567-89ab-4cde-8123-456789abcdef ]]; then
            stage=installer id=b1234567-89ab-4cde-8123-456789abcdef
        fi
        record="$FIXTURE_PROVIDER/$stage.json"
        case $operation in
            submit)
                [[ ! -e $record ]] || exit 95
                sha=$(shasum -a 256 < "$1"); sha=${sha%% *}
                jq -n --arg id "$id" --arg name "${1##*/}" --arg sha "$sha" '{jobId:$id,status:"Accepted",archiveFilename:$name,sha256:$sha,issues:[]}' > "$record"
                printf '{"id":"%s","status":"In Progress"}' "$id" ;;
            info|wait)
                status=Accepted
                if [[ ${FIXTURE_MODE:-} == pending ]]; then status='In Progress'; fi
                printf '{"id":"%s","status":"%s"}' "$id" "$status"
                [[ $operation != wait || $status == Accepted ]] || exit 124 ;;
            log)
                destination=''; for argument in "$@"; do destination=$argument; done
                cp "$record" "$destination" ;;
            history)
                jq -s '{history:map({id:.jobId,name:.archiveFilename})}' "$FIXTURE_PROVIDER/"*.json ;;
            *) exit 96 ;;
        esac ;;
    open)
        [[ ${FIXTURE_MODE:-} != startup-failure ]] || exit 1
        previous=''
        for argument in "$@"; do
            if [[ $previous == --snapshot ]]; then printf 'fixture png' > "$argument"; fi
            previous=$argument
        done ;;
    sips) printf 'format: png\n' ;;
    *) exit 97 ;;
esac
STUB
chmod +x "$work/bin/fake-tool"
for name in uname git gh plutil lipo codesign ditto spctl hdiutil mount xcrun open sips; do ln -s fake-tool "$work/bin/$name"; done
export PATH="$work/bin:$PATH" SOURCE_COMMIT=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
export BUILD_CI_RUN_ID=101 BUILD_ARTIFACT_ID=202 BUILD_ARTIFACT_DIGEST=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
export APPLE_TEAM_ID=ABC1234567 GITHUB_RUN_ID=303 GITHUB_RUN_ATTEMPT=1 APPLE_NOTARY_TIMEOUT=1s
export APPLE_SIGNING_IDENTITY='Developer ID Application: Fixture (ABC1234567)' NOTARY_KEYCHAIN_PROFILE=fixture-profile
unset NOTARY_KEY_FILE NOTARY_KEYCHAIN NOTARY_KEY_ID NOTARY_ISSUER_ID APPLE_NOTARY_LOCK_DIRECTORY
cases=0
fail() { printf 'FAIL %s: %s\n' "$case_name" "$*" >&2; cat "$directory/output" >&2; exit 1; }
new_case() {
    case_name=$1 directory="$work/$1"; mkdir "$directory" "$directory/provider"
    app="$directory/input/Cadence.app" state="$directory/state" output="$directory/candidate"
    mkdir -p "$app/Contents/MacOS"
    printf '{"CFBundleIdentifier":"dev.cadence.app","CFBundleExecutable":"Cadence","CFBundleShortVersionString":"1.2.3","CFBundleVersion":"42"}' > "$app/Contents/Info.plist"
    printf '#!/bin/bash\nexit 0\n' > "$app/Contents/MacOS/Cadence"; chmod +x "$app/Contents/MacOS/Cadence"
    export FIXTURE_CALLS="$directory/calls" FIXTURE_PROVIDER="$directory/provider" GITHUB_RUN_ID=303 GITHUB_RUN_ATTEMPT=1
    : > "$FIXTURE_CALLS"
}
invoke() {
    result=0
    FIXTURE_MODE=${2:-accepted} bash "$work/repo/scripts/release-macos.sh" --phase "$1" --state-dir "$state" \
        --app "$app" --output-dir "$output" > "$directory/output" 2>&1 || result=$?
}
expect() { [[ $result == "$1" ]] || fail "expected exit $1, got $result"; }
expect_failure() { [[ $result != 0 && $result != 75 ]] || fail "expected terminal failure, got $result"; }
count() { awk -v pattern="$1" 'index($0,pattern) {n++} END {print n+0}' "$FIXTURE_CALLS"; }
passed() { cases=$((cases+1)); printf 'PASS %s\n' "$case_name"; }
through_app() { invoke prepare; expect 0; invoke app-claim; expect 0; invoke app-submit; expect 0; invoke app-wait; expect 0; }
through_installer() { through_app; invoke installer-prepare; expect 0; invoke installer-claim; expect 0; invoke installer-submit; expect 0; invoke installer-wait; expect 0; }

new_case durable-all-phases
invoke prepare; expect 0
[[ $(count 'notarytool submit') == 0 ]] || fail 'prepare uploaded'
app_sha=$(shasum -a 256 "$state/prepared-app/"*.zip)
prepared_signs=$(count 'codesign --force')
invoke prepare; expect 0
[[ $(count 'codesign --force') == "$prepared_signs" ]] || fail 'repeat prepare signed again'
invoke app-claim; expect 0
invoke app-submit; expect 0
invoke app-wait pending; expect 75
[[ ! -e $output ]] || fail 'pending promoted'
export GITHUB_RUN_ID=404 GITHUB_RUN_ATTEMPT=2
jq '.restored=true' "$state/evidence/app-universal-receipt.json" > "$directory/changed"; mv "$directory/changed" "$state/evidence/app-universal-receipt.json"
invoke prepare; expect 0
invoke app-claim; expect 0
invoke app-submit; expect 0
invoke app-wait; expect 0
[[ $(count 'notarytool submit') == 1 ]] || fail 'resume repeated submit'
invoke installer-prepare; expect 0
image_sha=$(shasum -a 256 "$state/prepared-installer/"*.dmg)
packaging=$(count 'hdiutil create') signs=$(count 'codesign --force')
invoke installer-prepare; expect 0
[[ $(count 'hdiutil create') == "$packaging" && $(count 'codesign --force') == "$signs" ]] || fail 'repeat installer prepare regenerated bytes'
invoke installer-claim; expect 0
invoke installer-submit; expect 0
invoke installer-wait; expect 0
invoke finish; expect 0
[[ $(shasum -a 256 "$state/prepared-app/"*.zip) == "$app_sha" && $(shasum -a 256 "$state/prepared-installer/"*.dmg) == "$image_sha" ]] || fail 'stapling mutated submitted bytes'
[[ $(find "$output" -type f | wc -l | tr -d ' ') == 4 ]] || fail 'wrong public file count'
jq -e '.build_number == "42" and .origin == {build_ci_run_id:"101",build_artifact_id:"202",build_artifact_digest:"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"} and .submissions.app.filename == "Cadence-App-1.2.3-build-42-universal.zip"' "$output/distribution.json" >/dev/null || fail 'manifest omitted origin or submitted identity'
final_sha=$(shasum -a 256 "$output/SHA256SUMS")
finish_staples=$(count 'stapler staple')
invoke finish; expect 0
[[ $(count 'stapler staple') == "$finish_staples" && $(shasum -a 256 "$output/SHA256SUMS") == "$final_sha" ]] || fail 'repeated finish changed final bytes'
[[ $(count 'notarytool submit') == 2 && $(count 'hdiutil attach') -gt 0 && $(count 'spctl --assess') -gt 0 ]] || fail 'gates/topology missing'
passed

for mode in wrong-team dirty; do
    new_case "prepare-$mode"
    invoke prepare "$mode"; expect 1
    [[ $(count 'notarytool submit') == 0 && ! -e $output ]] || fail 'failed preparation reached upload/promotion'
    passed
done
for field in CFBundleVersion CFBundleIdentifier CFBundleShortVersionString; do
    new_case "app-metadata-$field"
    jq --arg key "$field" '.[$key]="99"' "$app/Contents/Info.plist" > "$directory/changed"; mv "$directory/changed" "$app/Contents/Info.plist"
    invoke prepare; expect 1
    [[ $(count 'notarytool submit') == 0 ]] || fail 'wrong metadata uploaded'
    passed
done
new_case architecture-mismatch
export FIXTURE_ARCHS=arm64
invoke prepare; expect 1
unset FIXTURE_ARCHS
passed
for mode in staple-failure ticket-failure gatekeeper-failure package-failure; do
    new_case "installer-prepare-$mode"
    through_app
    invoke installer-prepare "$mode"; expect_failure
    [[ $(count 'notarytool submit') == 1 && ! -e $output ]] || fail 'failed app trust gate advanced'
    invoke installer-prepare; expect 0
    passed
done
for mode in staple-failure ticket-failure gatekeeper-failure image-failure installed-wrong-build startup-failure; do
    new_case "finish-$mode"
    through_installer
    invoke finish "$mode"; expect_failure
    [[ ! -e $output ]] || fail 'failed final gate promoted candidate'
    invoke finish; expect 0
    [[ $(count 'notarytool submit') == 2 ]] || fail 'retry repeated Apple upload'
    passed
done
new_case receipt-mismatch-before-installer
through_app
jq '.binding.build_number="99"' "$state/evidence/app-universal-receipt.json" > "$directory/changed"; mv "$directory/changed" "$state/evidence/app-universal-receipt.json"
invoke installer-prepare; expect 1
[[ $(count 'hdiutil create') == 0 ]] || fail 'mismatched app evidence packaged'
passed
new_case corrupted-prepared-archive
invoke prepare; expect 0
printf tamper >> "$state/prepared-app/"*.zip
invoke prepare; expect 1
invoke app-submit; expect 1
[[ $(count 'notarytool submit') == 0 && $(count 'codesign --force') == 2 ]] || fail 'corrupt state regenerated/uploaded'
passed
# A checkpoint with no submitted bytes resumes using repaired automation, while
# product metadata and installer instructions remain frozen. Changing automation
# again after an Apple submission must preserve the receipt and submitted bytes.
new_case split-source-empty-checkpoint-to-completion
mkdir -p "$work/repo/.release-source/Resources" "$state/evidence"
cp "$work/repo/Resources/"* "$work/repo/.release-source/Resources/"
printf '{"CFBundleShortVersionString":"9.9.9","CFBundleVersion":"99"}\n' > "$work/repo/Resources/Info.plist"
printf 'Wrong automation instructions\n' > "$work/repo/Resources/Install.txt"
cp "$work/durable-all-phases/state/candidate.json" "$state/candidate.json"
original_binding=$(shasum -a 256 "$state/candidate.json")
export RELEASE_SOURCE_DIRECTORY="$work/repo/.release-source" FIXTURE_AUTOMATION_ROOT="$work/repo"
export AUTOMATION_COMMIT=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb GITHUB_SHA=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
export GITHUB_REPOSITORY=Dunky13/Cadence GITHUB_REF=refs/heads/main GITHUB_REF_TYPE=branch
invoke prepare; expect 0
invoke app-claim; expect 0
invoke app-submit; expect 0
invoke app-wait pending; expect 75
submitted_sha=$(shasum -a 256 "$state/prepared-app/"*.zip)
receipt_sha=$(shasum -a 256 "$state/evidence/app-universal-receipt.json")
prepared_signs=$(count 'codesign --force')
export AUTOMATION_COMMIT=cccccccccccccccccccccccccccccccccccccccc GITHUB_SHA=cccccccccccccccccccccccccccccccccccccccc
invoke prepare; expect 0
invoke app-claim; expect 0
invoke app-submit; expect 0
[[ $(shasum -a 256 "$state/prepared-app/"*.zip) == "$submitted_sha" && $(shasum -a 256 "$state/evidence/app-universal-receipt.json") == "$receipt_sha" ]] || fail 'automation repair replaced submitted bytes or receipt'
[[ $(count 'codesign --force') == "$prepared_signs" && $(count 'notarytool submit') == 1 ]] || fail 'automation repair resigned or resubmitted'
invoke app-wait; expect 0
invoke installer-prepare; expect 0
[[ $(tar -xOf "$state/prepared-installer/"*.dmg './Install Cadence.txt') == 'Install fixture' ]] || fail 'installer used automation resources'
invoke installer-claim; expect 0
invoke installer-submit; expect 0
invoke installer-wait; expect 0
invoke finish; expect 0
[[ $(shasum -a 256 "$state/candidate.json") == "$original_binding" ]] || fail 'candidate binding was rebased to automation'
jq -e '.source_commit == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" and .version == "1.2.3" and .build_number == "42"' "$output/distribution.json" >/dev/null || fail 'distribution followed automation identity'
passed
printf 'Apple release recovery: %s cases passed; fake tools only.\n' "$cases"

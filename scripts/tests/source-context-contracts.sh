#!/bin/bash
# Synthetic GitHub/git boundaries; run the actual context and origin scripts.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd -P)
work=$(mktemp -d "${TMPDIR:-/tmp}/cadence-source-context.XXXXXX")
work=$(cd "$work" && pwd -P)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/automation/scripts" "$work/automation/Resources" "$work/automation/.release-source/Resources"
cp "$root/scripts/release-source-context.sh" "$root/scripts/verify-ci-origin.sh" "$root/scripts/verify-release-input.sh" "$work/automation/scripts/"
printf '{"CFBundleShortVersionString":"9.9.9","CFBundleVersion":"99"}' > "$work/automation/Resources/Info.plist"
printf 'automation install instructions\n' > "$work/automation/Resources/Install.txt"
printf '{"CFBundleShortVersionString":"0.2.0","CFBundleVersion":"15"}' > "$work/automation/.release-source/Resources/Info.plist"
printf 'frozen product install instructions\n' > "$work/automation/.release-source/Resources/Install.txt"
cat > "$work/bin/git" <<'STUB'
#!/bin/bash
set -euo pipefail
directory=$PWD
if [[ $1 == -C ]]; then directory=$2; shift 2; fi
role=automation sha=$AUTOMATION_COMMIT
if [[ $directory == "$RELEASE_SOURCE_DIRECTORY" ]]; then role=product sha=$SOURCE_COMMIT; fi
printf 'git %s %s\n' "$role" "$*" >> "$CONTEXT_CALLS"
case "$1 $2" in
    'rev-parse --show-toplevel')
        [[ $CONTEXT_MODE != non-root ]] || directory=${directory%/*}
        printf '%s\n' "$directory" ;;
    'rev-parse --verify')
        [[ $CONTEXT_MODE != "$role-head" ]] || sha=cccccccccccccccccccccccccccccccccccccccc
        printf '%s\n' "$sha" ;;
    'status --porcelain')
        [[ $CONTEXT_MODE != "$role-status-error" ]] || exit 1
        if [[ $CONTEXT_MODE == "$role-dirty" ]]; then printf ' M Resources/Install.txt\n'; fi ;;
    'fetch --no-tags') [[ $CONTEXT_MODE != fetch-error ]] ;;
    'merge-base --is-ancestor') [[ $CONTEXT_MODE != off-main ]] ;;
    'ls-files --error-unmatch') [[ $CONTEXT_MODE != untracked-resource ]] ;;
    *) exit 98 ;;
esac
STUB
cat > "$work/bin/gh" <<'STUB'
#!/bin/bash
set -euo pipefail
printf 'gh %s\n' "$*" >> "$CONTEXT_CALLS"
[[ $CONTEXT_MODE != api-error ]] || exit 1
endpoint=''; for argument in "$@"; do endpoint=$argument; done
run_json() {
    local sha=$AUTOMATION_COMMIT branch=main event=push path=.github/workflows/ci.yml conclusion=success repo=$GITHUB_REPOSITORY
    case $CONTEXT_MODE in
        ci-wrong-sha) sha=$SOURCE_COMMIT ;;
        ci-branch) branch=feature ;;
        ci-event) event=pull_request ;;
        ci-path) path=.github/workflows/release.yml ;;
        ci-failed) conclusion=failure ;;
        ci-fork) repo=untrusted/Cadence ;;
    esac
    jq -n --arg sha "$sha" --arg branch "$branch" --arg event "$event" --arg path "$path" --arg conclusion "$conclusion" --arg repo "$repo" \
        '{id:901,head_sha:$sha,head_branch:$branch,event:$event,path:$path,status:"completed",conclusion:$conclusion,
          repository:{full_name:$repo},head_repository:{full_name:$repo}}'
}
case "$endpoint" in
    *workflows/ci.yml/runs\?*)
        if [[ $CONTEXT_MODE == missing-ci ]]; then printf '[{"workflow_runs":[]}]';
        else run_json | jq '[{workflow_runs:[.]}]'; fi ;;
    */runs/901)
        run_json | jq 'if env.CONTEXT_MODE == "ci-exact-run-changed" then .head_sha=env.SOURCE_COMMIT else . end' ;;
    */runs/901/jobs\?*)
        jobs='[{"jobs":[{"name":"ci-required","status":"completed","conclusion":"success"}]}]'
        case $CONTEXT_MODE in
            gate-failed) jq '.[0].jobs[0].conclusion="failure"' <<< "$jobs" ;;
            gate-pending) jq '.[0].jobs[0].status="in_progress"' <<< "$jobs" ;;
            gate-missing) printf '[{"jobs":[]}]' ;;
            gate-duplicate) jq '.[0].jobs += .[0].jobs' <<< "$jobs" ;;
            *) printf '%s' "$jobs" ;;
        esac ;;
    */runs/101)
        jq -n '{id:101,head_sha:env.SOURCE_COMMIT,head_branch:"main",event:"push",path:".github/workflows/ci.yml",
            status:"completed",conclusion:"success",run_number:15,
            repository:{full_name:env.GITHUB_REPOSITORY},head_repository:{full_name:env.GITHUB_REPOSITORY}}'
        ;;
    */runs/101/jobs\?*)
        if [[ $CONTEXT_MODE == product-ci-failed ]]; then printf '[{"jobs":[]}]';
        else printf '[{"jobs":[{"name":"ci-required","status":"completed","conclusion":"success"}]}]'; fi ;;
    */artifacts/202)
        jq -n '{name:("Cadence-macOS-universal-"+env.SOURCE_COMMIT),workflow_run:{id:101,head_sha:env.SOURCE_COMMIT},digest:env.BUILD_ARTIFACT_DIGEST}' ;;
    *) exit 99 ;;
esac
STUB
cat > "$work/bin/ditto" <<'STUB'
#!/bin/bash
for argument in "$@"; do destination=$argument; done
mkdir -p "$destination/Cadence.app/Contents/MacOS"
cp "$RELEASE_SOURCE_DIRECTORY/Resources/Info.plist" "$destination/Cadence.app/Contents/Info.plist"
printf 'frozen executable\n' > "$destination/Cadence.app/Contents/MacOS/Cadence"
STUB
cat > "$work/bin/codesign" <<'STUB'
#!/bin/bash
printf 'codesign\n' >> "$CONTEXT_CALLS"
STUB
cat > "$work/bin/xcrun" <<'STUB'
#!/bin/bash
if [[ $* == *-archs* ]]; then printf 'arm64 x86_64\n'; fi
STUB
chmod +x "$work/bin/"*
export PATH="$work/bin:$PATH" CONTEXT_CALLS="$work/calls" CONTEXT_MODE=passed
export SOURCE_COMMIT=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa AUTOMATION_COMMIT=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
export RELEASE_SOURCE_DIRECTORY="$work/automation/.release-source" GITHUB_SHA=$AUTOMATION_COMMIT
export GITHUB_REPOSITORY=Dunky13/Cadence GITHUB_REF=refs/heads/main GITHUB_REF_TYPE=branch GITHUB_RUN_ATTEMPT=1
export BUILD_CI_RUN_ID=101 BUILD_ARTIFACT_ID=202 BUILD_NUMBER=15
export BUILD_ARTIFACT_DIGEST=sha256:018949eab48217c2136ef238c009b00eda6b2daa6e8bde55a31f96d0fd421e37
cases=0
invoke() {
    result=0
    : > "$CONTEXT_CALLS"
    "$@" > "$work/output" 2>&1 || result=$?
}
accept() { [[ $result == 0 ]] || { cat "$work/output" >&2; exit 1; }; cases=$((cases+1)); }
reject() { [[ $result != 0 ]] || { printf 'FAIL accepted %s\n' "$CONTEXT_MODE" >&2; exit 1; }; cases=$((cases+1)); }
context() { /bin/bash -c 'fail() { printf "%s\n" "$*" >&2; exit 1; }; source "$1/scripts/release-source-context.sh"; release_source_context "$SOURCE_COMMIT" "$1"' -- "$work/automation"; }
invoke context; accept
grep -q '/runs/901/jobs?' "$CONTEXT_CALLS"
for mode in automation-head product-head automation-dirty product-dirty automation-status-error product-status-error non-root fetch-error off-main \
    api-error missing-ci ci-wrong-sha ci-branch ci-event ci-path ci-failed ci-fork ci-exact-run-changed \
    gate-failed gate-pending gate-missing gate-duplicate untracked-resource; do
    export CONTEXT_MODE=$mode
    invoke context; reject
done
export CONTEXT_MODE=passed
for binding in AUTOMATION_COMMIT RELEASE_SOURCE_DIRECTORY; do
    invoke env -u "$binding" /bin/bash "$work/automation/scripts/verify-ci-origin.sh"; reject
done
for binding in GITHUB_SHA GITHUB_REF GITHUB_REF_TYPE GITHUB_REPOSITORY; do
    invoke env "$binding=wrong" /bin/bash "$work/automation/scripts/verify-ci-origin.sh"; reject
done
for resource in Info.plist Install.txt; do
    mv "$RELEASE_SOURCE_DIRECTORY/Resources/$resource" "$work/resource"
    invoke context; reject
    ln -s "$work/resource" "$RELEASE_SOURCE_DIRECTORY/Resources/$resource"
    invoke context; reject
    rm "$RELEASE_SOURCE_DIRECTORY/Resources/$resource"
    mv "$work/resource" "$RELEASE_SOURCE_DIRECTORY/Resources/$resource"
done
invoke /bin/bash "$work/automation/scripts/verify-ci-origin.sh"; accept
grep -q '/runs/101/jobs?' "$CONTEXT_CALLS"
grep -q '/artifacts/202' "$CONTEXT_CALLS"
export CONTEXT_MODE=product-ci-failed
invoke /bin/bash "$work/automation/scripts/verify-ci-origin.sh"; reject
export CONTEXT_MODE=passed
mkdir "$work/input"
printf 'original archive\n' > "$work/input/Cadence-App-0.2.0-universal-local.zip"
printf 'original image\n' > "$work/input/Cadence-Installer-0.2.0-universal-local.dmg"
jq -n '{schema:"cadence/build/v1",version:"0.2.0",architecture:"universal",source_commit:env.SOURCE_COMMIT,
    source_dirty:false,signing:"ad-hoc",notarization:"not attempted"}' > "$work/input/build-manifest.json"
(cd "$work/input" && shasum -a 256 ./*.zip ./*.dmg build-manifest.json | sed 's|  ./|  |' > SHA256SUMS)
invoke /bin/bash "$work/automation/scripts/verify-release-input.sh" "$work/input" "$work/extracted"; accept
[[ -f $work/extracted/Cadence.app/Contents/Info.plist ]]
[[ $(plutil -extract CFBundleShortVersionString raw "$work/extracted/Cadence.app/Contents/Info.plist") == 0.2.0 ]]
printf 'Source context contracts: %s cases passed; frozen product and passed repair automation remain independently bound.\n' "$cases"

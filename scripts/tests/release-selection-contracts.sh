#!/bin/bash
# Synthetic provenance/custody boundaries. No provider or signing credentials.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/cadence-selection-test.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin" "$work/fixtures"
cat > "$work/bin/gh" <<'STUB'
#!/bin/bash
set -euo pipefail
endpoint=''
for arg in "$@"; do [[ $arg != repos/* ]] || endpoint=$arg; done
case $endpoint in
    repos/fixture/Cadence) printf '{"id":42,"default_branch":"main"}\n' ;;
    repos/fixture/Cadence/branches/main) cat "$FIXTURE/main.json" ;;
    repos/fixture/Cadence/actions/artifacts\?*) cat "$FIXTURE/inventory.json" ;;
    repos/fixture/Cadence/actions/workflows/ci.yml/runs\?*) printf '{"workflow_runs":[{"id":100}]}\n' ;;
    repos/fixture/Cadence/actions/runs/100) cat "$FIXTURE/ci.json" ;;
    repos/fixture/Cadence/actions/runs/200) cat "$FIXTURE/owner.json" ;;
    repos/fixture/Cadence/actions/runs/100/jobs\?*) cat "$FIXTURE/jobs.json" ;;
    repos/fixture/Cadence/actions/runs/100/artifacts\?*) cat "$FIXTURE/builds.json" ;;
    repos/fixture/Cadence/releases\?*) cat "$FIXTURE/releases.json" ;;
    *) printf 'Unexpected synthetic endpoint: %s\n' "$endpoint" >&2; exit 90 ;;
esac
STUB
cat > "$work/bin/git" <<'STUB'
#!/bin/bash
case $1 in fetch) exit 0 ;; merge-base) [[ ${OFF_MAIN:-false} == false ]] ;; ls-remote) if [[ ${CONFLICTING_TAG:-false} == true ]]; then printf '%s\trefs/tags/v1.2.3\n' cccccccccccccccccccccccccccccccccccccccc; fi ;;
    show) printf 'fixture plist\n' ;; *) exit 91 ;; esac
STUB
cat > "$work/bin/plutil" <<'STUB'
#!/bin/bash
printf '1.2.3\n'
STUB
chmod +x "$work/bin/"*
export FIXTURE="$work/fixtures"
source_sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
digest=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
cases=0
reset_case() {
    printf '{"protected":true}\n' > "$FIXTURE/main.json"
    jq -n --arg sha "$source_sha" '{path:".github/workflows/ci.yml",event:"push",head_branch:"main",status:"completed",conclusion:"success",head_sha:$sha,run_number:8,repository:{full_name:"fixture/Cadence"},head_repository:{id:42}}' > "$FIXTURE/ci.json"
    printf '[{"jobs":[{"name":"ci-required","status":"completed","conclusion":"success"}]}]\n' > "$FIXTURE/jobs.json"
    jq -n --arg sha "$source_sha" --arg digest "$digest" '[{artifacts:[{id:300,name:("Cadence-macOS-universal-"+$sha),expired:false,digest:$digest}]}]' > "$FIXTURE/builds.json"
    printf '[{"artifacts":[]}]\n' > "$FIXTURE/inventory.json"
    printf '[[]]\n' > "$FIXTURE/releases.json"
    printf '{"path":".github/workflows/release.yml","event":"schedule","head_branch":"main","repository":{"full_name":"fixture/Cadence"},"head_repository":{"id":42}}\n' > "$FIXTURE/owner.json"
}
mutate() { jq "$2" "$FIXTURE/$1.json" > "$work/changed.json"; mv "$work/changed.json" "$FIXTURE/$1.json"; }
invoke() {
    result=0
    PATH="$work/bin:$PATH" GITHUB_REPOSITORY=fixture/Cadence GITHUB_REF=refs/heads/main GITHUB_EVENT_NAME=workflow_dispatch \
        bash "$root/scripts/select-release-candidate.sh" > "$work/output" 2> "$work/error" || result=$?
}
check() { [[ $result == "$2" ]] || { cat "$work/error"; printf 'FAIL %s (exit %s)\n' "$1" "$result"; exit 1; }; cases=$((cases+1)); }
reset_case; invoke; check 'trusted-main exact CI artifact' 0
grep -q 'build_artifact_id=300' "$work/output"
reset_case; mutate main '.protected=false'; invoke; check 'unprotected main' 1
reset_case; mutate ci '.event="pull_request"'; invoke; check 'PR origin' 1
reset_case; mutate ci '.head_repository.id=7'; invoke; check 'fork origin' 1
reset_case; mutate ci '.conclusion="failure"'; invoke; check 'failed CI' 1
reset_case; mutate jobs '.[0].jobs[0].conclusion="skipped"'; invoke; check 'skipped aggregate' 1
reset_case; mutate jobs '.[0].jobs=[]'; invoke; check 'missing aggregate' 1
reset_case; mutate builds '.[0].artifacts += .[0].artifacts'; invoke; check 'ambiguous artifact' 1
reset_case; mutate builds '.[0].artifacts[0].digest=null'; invoke; check 'missing artifact digest' 1
reset_case; mutate builds '.[0].artifacts[0].expired=true'; invoke; check 'expired new candidate' 1
reset_case; printf '[[{"tag_name":"v1.2.3","draft":false,"prerelease":false}]]' > "$FIXTURE/releases.json"; invoke; check 'published version no-op' 0
grep -q 'eligible=false' "$work/output"
reset_case; printf '[[{"tag_name":"v1.2.3","draft":true,"prerelease":false}]]' > "$FIXTURE/releases.json"; invoke; check 'unbound draft' 1
reset_case; printf '[[{"tag_name":"v2.0.0","draft":false,"prerelease":false}]]' > "$FIXTURE/releases.json"; invoke; check 'older stable intent' 1
reset_case; printf '{"malformed":true}' > "$FIXTURE/releases.json"; invoke; check 'malformed release inventory' 1
checkpoint() {
    jq -n --argjson fork "${1:-42}" '[{artifacts:[{id:400,name:"Cadence-Checkpoint-100-300-200-1-app-submit",expired:false,workflow_run:{id:200,head_branch:"main",head_repository_id:$fork}}]}]' > "$FIXTURE/inventory.json"
}
reset_case; checkpoint; invoke; check 'resume retained candidate' 0
grep -q 'checkpoint_id=400' "$work/output"
reset_case; checkpoint; mutate builds '.[0].artifacts[0].expired=true'; invoke; check 'resume exact state after unsigned retention expiry' 0
reset_case; checkpoint; mutate inventory '.[0].artifacts[0].expired=true'; invoke; check 'expired active custody blocks rebuild' 1
reset_case; checkpoint 7; invoke; check 'fork checkpoint ignored' 0
grep -q '^checkpoint_id=$' "$work/output"
reset_case; checkpoint; mutate owner '.path=".github/workflows/ci.yml"'; invoke; check 'untrusted owner ignored' 0
grep -q '^checkpoint_id=$' "$work/output"
reset_case; export CONFLICTING_TAG=true; invoke; check 'conflicting version tag before credentials' 1; unset CONFLICTING_TAG
reset_case; export OFF_MAIN=true; invoke; check 'source no longer on main' 1; unset OFF_MAIN
printf '%s release-selection contracts passed (synthetic only).\n' "$cases"

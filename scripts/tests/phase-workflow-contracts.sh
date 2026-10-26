#!/bin/bash
# Run the actual hosted phase bodies on macOS's /bin/bash, not a rewritten driver.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/cadence-phase-workflow.XXXXXX")
trap 'rm -rf "$work"' EXIT
workflow="$root/.github/workflows/distribution.yml"
phases=(prepare app-claim app-submit app-wait installer-prepare installer-claim installer-submit installer-wait finish)
cases=0
fail() { printf 'FAIL phase workflow: %s\n' "$*" >&2; exit 1; }

# Extract complete steps first, then strip only the literal block's indentation.
# Fail on missing/duplicate steps or an unexpected block shape instead of running
# a stale copy of the shell body. actionlint validates the complete YAML separately.
extract_step() {
    awk -v name="$1" '
        /^      - / { selected = ($0 == "      - name: " name); if (selected) count++ }
        selected { print }
        END { if (count != 1) exit 1 }
    ' "$workflow" > "$2" || fail "cannot extract $1"
}
extract_body() {
    awk '
        /^        run: \|$/ { body = 1; next }
        body { if ($0 !~ /^          /) exit 1; print substr($0, 11); count++ }
        END { if (!count) exit 1 }
    ' "$1" > "$2" || fail "cannot extract literal run body from $1"
}
condition() { sed -n 's/^        if: //p' "$1"; }

mkdir -p "$work/steps" "$work/repo/scripts"
for phase in "${phases[@]}"; do
    extract_step "Candidate phase $phase" "$work/steps/$phase.yml"
    extract_body "$work/steps/$phase.yml" "$work/steps/$phase.sh"
    extract_step "Seal durable checkpoint after $phase" "$work/steps/seal-$phase.yml"
    extract_body "$work/steps/seal-$phase.yml" "$work/steps/seal-$phase.sh"
    extract_step "Retain exact state after $phase" "$work/steps/retain-$phase.yml"
done
cp "$root/scripts/checkpoint-state.sh" "$work/repo/scripts/"
cat > "$work/repo/scripts/with-apple-signing.sh" <<'STUB'
#!/bin/bash
set -euo pipefail
[[ $# == 9 && $1 == ./scripts/release-macos.sh && $2 == --phase && $4 == --state-dir && $6 == --app && $8 == --architecture && $9 == universal ]] || exit 99
printf '%s\n' "$3" >> "$PHASE_CALLS"
mkdir -p "$5/evidence"
printf '{"fixture":true}\n' > "$5/candidate.json"
if [[ $PHASE_RESULT == 75 ]]; then
    printf '{"status":"In Progress"}\n' > "$5/evidence/pending.json"
fi
exit "$PHASE_RESULT"
STUB
chmod +x "$work/repo/scripts/with-apple-signing.sh"
export SOURCE_COMMIT=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa BUILD_CI_RUN_ID=100 BUILD_ARTIFACT_ID=300
export BUILD_ARTIFACT_DIGEST=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
export GITHUB_RUN_ID=200 GITHUB_RUN_ATTEMPT=1 APPLE_TEAM_ID=ABC1234567

new_case() {
    directory="$work/case-$cases"
    mkdir -p "$directory/temp"
    export RUNNER_TEMP="$directory/temp" STATE_DIRECTORY="$directory/state" PHASE_CALLS="$directory/calls"
    cases=$((cases + 1))
}
run_body() {
    export GITHUB_OUTPUT="$directory/outputs" PHASE_RESULT=$2
    : > "$GITHUB_OUTPUT"
    result=0
    # Capture status in the parent; never source the body in an if/function whose
    # context could suppress errexit. -e is the shell printed by the hosted run.
    (cd "$work/repo" && /bin/bash "$shell_option" "$work/steps/$1.sh") > "$directory/log" 2>&1 || result=$?
}

# Every phase must preserve terminal status, keep pending recoverable, and emit
# readiness/team only for a successful finish. Also run with errexit disabled to
# establish that the explicit guard, rather than ambient shell behavior, works.
for shell_option in -e +e; do
    for phase in "${phases[@]}"; do
        for status in 1 37 75 0; do
            new_case
            run_body "$phase" "$status"
            expected=0
            if [[ $status != 0 && $status != 75 ]]; then expected=$status; fi
            [[ $result == "$expected" ]] || fail "$phase ($shell_option) child=$status returned $result, expected $expected"
            [[ $(cat "$PHASE_CALLS") == "$phase" ]] || fail "$phase called more than once"
            expected_output=''
            if [[ $status == 75 ]]; then
                expected_output='pending=true'
                [[ -f $STATE_DIRECTORY/evidence/pending.json ]] || fail 'pending evidence disappeared'
            elif [[ $status == 0 ]]; then
                expected_output='pending=false'
                if [[ $phase == finish ]]; then expected_output=$(printf 'pending=false\nready=true\nteam_id=%s' "$APPLE_TEAM_ID"); fi
            fi
            [[ $(cat "$GITHUB_OUTPUT") == "$expected_output" ]] || fail "$phase child=$status wrote unsafe outputs"
        done
    done
done

# Lock down the Actions conditions used below: successful checkpoint steps must
# not revive a failed job, while sealing/uploading runs after a failed phase.
for phase in "${phases[@]}"; do
    id=${phase//-/_}
    expected='success()'
    if [[ $phase == installer-* || $phase == finish ]]; then expected+=" && steps.app_wait.outputs.pending != 'true'"; fi
    if [[ $phase == finish ]]; then expected+=" && steps.installer_wait.outputs.pending != 'true'"; fi
    [[ $(condition "$work/steps/$phase.yml") == "$expected" ]] || fail "$phase lost its success/pending gate"
    [[ $(condition "$work/steps/seal-$phase.yml") == "\${{ always() && steps.$id.outcome != 'skipped' }}" ]] || fail "$phase lost failure sealing"
    [[ $(condition "$work/steps/retain-$phase.yml") == "\${{ always() && steps.seal_$id.outputs.exists == 'true' }}" ]] || fail "$phase lost failure retention"
    if grep -q 'continue-on-error:' "$work/steps/$phase.yml"; then fail "$phase ignores terminal failures"; fi
    grep -q '^          if-no-files-found: error$' "$work/steps/retain-$phase.yml" || fail "$phase tolerates missing checkpoints"
done
if grep -q '^    continue-on-error:' "$workflow"; then fail 'signing job ignores terminal failures'; fi

# Simulate only the verified success/pending/always conditions, executing each
# extracted phase and seal body as a separate hosted shell. Artifact upload is a
# local presence/checksum check; no credentials, Apple client, or API is invoked.
run_sequence() {
    local injected_phase=$1 injected_status=$2 phase failed=false app_pending=false installer_pending=false finish_ready=false status expected_result expected_calls='' retained=''
    new_case
    shell_option=-e
    for phase in "${phases[@]}"; do
        [[ $failed == false ]] || continue
        if [[ $phase == installer-* || $phase == finish ]]; then [[ $app_pending == false ]] || continue; fi
        if [[ $phase == finish ]]; then [[ $installer_pending == false ]] || continue; fi
        status=0
        if [[ $phase == "$injected_phase" ]]; then status=$injected_status; fi
        run_body "$phase" "$status"
        expected_result=0
        if [[ $status != 0 && $status != 75 ]]; then expected_result=$status; fi
        [[ $result == "$expected_result" ]] || fail "$phase sequence lost terminal status"
        expected_calls+="$phase"$'\n'
        if [[ $result != 0 ]]; then failed=true; fi
        if grep -qx pending=true "$GITHUB_OUTPUT"; then
            if [[ $phase == app-wait ]]; then app_pending=true; fi
            if [[ $phase == installer-wait ]]; then installer_pending=true; fi
        fi
        if grep -qx ready=true "$GITHUB_OUTPUT"; then finish_ready=true; fi
        # always(): seal even when this phase has just failed; skipped phases
        # never seal or retain. Run the real checkpoint packer from the YAML.
        run_body "seal-$phase" 0
        [[ $result == 0 && $(cat "$GITHUB_OUTPUT") == exists=true ]] || fail "$phase failed to seal evidence"
        (cd "$RUNNER_TEMP/checkpoint-$phase" && shasum -a 256 --check SHA256SUMS) > "$directory/checksums" 2>&1 || fail "$phase checkpoint is not intact"
        tar -xOf "$RUNNER_TEMP/checkpoint-$phase/state.tar.gz" ./candidate.json > "$directory/candidate.json"
        cmp "$STATE_DIRECTORY/candidate.json" "$directory/candidate.json" || fail "$phase checkpoint lost failure state"
        retained+="$phase"$'\n'
    done
    [[ $(cat "$PHASE_CALLS") == "${expected_calls%$'\n'}" && $retained == "$expected_calls" ]] || fail 'unexpected downstream invocation or missing retention'
    if [[ $injected_status == 1 || $injected_status == 37 ]]; then
        [[ $failed == true && $finish_ready == false && ${expected_calls%$'\n'} == *"$injected_phase" ]] || fail 'terminal failure allowed promotion'
    elif [[ $injected_status == 75 ]]; then
        [[ $failed == false && $finish_ready == false && ${expected_calls%$'\n'} == *"$injected_phase" ]] || fail 'pending state advanced or became ready'
        tar -xOf "$RUNNER_TEMP/checkpoint-$injected_phase/state.tar.gz" ./evidence/pending.json > "$directory/pending.json"
        cmp "$STATE_DIRECTORY/evidence/pending.json" "$directory/pending.json" || fail 'pending receipt was not retained'
    else
        [[ $failed == false && $finish_ready == true && $(wc -l < "$PHASE_CALLS") -eq 9 ]] || fail 'successful sequence did not finish exactly once'
    fi
}
for phase in "${phases[@]}"; do
    for status in 1 37; do run_sequence "$phase" "$status"; done
done
for phase in app-wait installer-wait finish; do run_sequence "$phase" 75; done
run_sequence finish 0

# The same Bash 3.2 behavior also affects nonterminal guards around restoration
# and promotion. Execute their exact YAML bodies and require rejection before
# any download, checksum, restore, or move can use an invalid precondition.
for name in 'Restore bound immutable state before credentials' 'Recover original CI input if preparation never produced submitted bytes' 'Promote only after credentials have been removed'; do
    case $name in Restore*) id=restore ;; Recover*) id=recover ;; Promote*) id=promote ;; esac
    extract_step "$name" "$work/steps/guard-$id.yml"
    extract_body "$work/steps/guard-$id.yml" "$work/steps/guard-$id.sh"
done
mkdir "$work/guard-bin"
cat > "$work/guard-bin/gh" <<'STUB'
#!/bin/bash
printf 'gh\n' >> "$GUARD_CALLS"
printf '%s\n' "$BUILD_ARTIFACT_DIGEST"
STUB
cat > "$work/guard-bin/shasum" <<'STUB'
#!/bin/bash
printf 'shasum\n' >> "$GUARD_CALLS"
exec /usr/bin/shasum "$@"
STUB
for name in download-release-artifact.sh verify-release-input.sh checkpoint-state.sh recover-unstarted-upload.sh; do
    cat > "$work/repo/scripts/$name" <<'STUB'
#!/bin/bash
printf '%s\n' "${0##*/}" >> "$GUARD_CALLS"
STUB
    chmod +x "$work/repo/scripts/$name"
done
chmod +x "$work/guard-bin/"*
guard_case() {
    local kind=$1 expected=$2 condition=$3
    new_case
    local repo="$directory/repo"
    mkdir -p "$repo/scripts" "$repo/dist" "$STATE_DIRECTORY/evidence"
    cp "$work/repo/scripts/"{download-release-artifact.sh,verify-release-input.sh,checkpoint-state.sh,recover-unstarted-upload.sh} "$repo/scripts/"
    export GUARD_CALLS="$directory/guard-calls" CHECKPOINT_ID=400
    : > "$GUARD_CALLS"
    if [[ $condition == invalid-id ]]; then CHECKPOINT_ID=invalid; fi
    if [[ $condition == existing-receipt ]]; then printf 'synthetic receipt\n' > "$STATE_DIRECTORY/evidence/app-universal-receipt.json"; fi
    if [[ $kind == promote ]]; then
        mkdir -p "$directory/payload"
        printf 'synthetic app\n' > "$directory/payload/app.zip"
        printf 'synthetic installer\n' > "$directory/payload/installer.dmg"
        jq -n --arg source "$SOURCE_COMMIT" '{schema:"cadence/distribution/v1",source_commit:$source,architecture:"universal",notarization:"Accepted",tickets:"stapled and validated",synthetic_fixture:true}' > "$directory/payload/distribution.json"
        (cd "$directory/payload" && /usr/bin/shasum -a 256 app.zip installer.dmg distribution.json > SHA256SUMS)
        if [[ $condition == linked-candidate ]]; then ln -s "$directory/payload" "$repo/dist/.signed-candidate";
        else cp -R "$directory/payload" "$repo/dist/.signed-candidate"; fi
        if [[ $condition == occupied-destination ]]; then mkdir "$repo/dist/release"; printf 'retain\n' > "$repo/dist/release/previous"; fi
        if [[ $condition == dangling-destination ]]; then ln -s "$directory/missing" "$repo/dist/release"; fi
    fi
    result=0
    (cd "$repo" && PATH="$work/guard-bin:$PATH" /bin/bash "$shell_option" "$work/steps/guard-$kind.sh") > "$directory/log" 2>&1 || result=$?
    [[ $result == "$expected" ]] || fail "$kind guard ($shell_option/$condition) returned $result, expected $expected"
    if [[ $expected != 0 ]]; then
        [[ ! -s $GUARD_CALLS ]] || fail "$kind used invalid state before rejecting $condition"
        if [[ $kind == promote ]]; then [[ -e $repo/dist/.signed-candidate || -L $repo/dist/.signed-candidate ]] || fail 'rejected promotion moved the source'; fi
    elif [[ $kind == promote ]]; then
        [[ -d $repo/dist/release && ! -L $repo/dist/release && ! -e $repo/dist/.signed-candidate ]] || fail 'valid promotion did not move once'
    else
        [[ -s $GUARD_CALLS ]] || fail "$kind did not execute valid recovery"
    fi
    if [[ $condition == occupied-destination ]]; then [[ $(cat "$repo/dist/release/previous") == retain ]] || fail 'old destination changed'; fi
    if [[ $condition == dangling-destination ]]; then [[ -L $repo/dist/release && ! -e $directory/missing ]] || fail 'dangling destination changed'; fi
}
for shell_option in -e +e; do
    guard_case restore 1 invalid-id
    guard_case restore 0 valid
    guard_case recover 1 existing-receipt
    guard_case recover 0 valid
    guard_case promote 1 linked-candidate
    guard_case promote 1 occupied-destination
    guard_case promote 1 dangling-destination
    guard_case promote 0 valid
done
printf '%s phase workflow contracts passed (extracted YAML, /bin/bash, synthetic child only).\n' "$cases"

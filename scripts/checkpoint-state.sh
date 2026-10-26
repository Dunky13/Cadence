#!/bin/bash
# Immutable, checksummed custody envelope. Contains signed payloads, never keys.
set -euo pipefail
umask 077
fail() { printf 'checkpoint-state: %s\n' "$*" >&2; exit 1; }
[[ $# == 3 ]] || fail 'Usage: checkpoint-state.sh pack|restore STATE_DIRECTORY ENVELOPE_DIRECTORY'
mode=$1 state=$2 envelope=$3
for variable in SOURCE_COMMIT BUILD_CI_RUN_ID BUILD_ARTIFACT_ID BUILD_ARTIFACT_DIGEST; do
    [[ -n ${!variable:-} ]] || fail "Missing binding: $variable"
done
[[ $SOURCE_COMMIT =~ ^[0-9a-f]{40}$ && $BUILD_CI_RUN_ID =~ ^[1-9][0-9]*$ && $BUILD_ARTIFACT_ID =~ ^[1-9][0-9]*$ ]] || fail 'Invalid source/CI artifact identity.'
[[ $BUILD_ARTIFACT_DIGEST =~ ^sha256:[0-9a-f]{64}$ ]] || fail 'Missing immutable build artifact digest.'
case $mode in
    pack)
        [[ -d $state && ! -L $state && ! -e $envelope ]] || fail 'Expected a regular state directory and fresh envelope.'
        # Reject links, sockets, credentials and unsafe names before retaining bytes.
        while IFS= read -r path; do
            [[ ! -L $path && ( -d $path || -f $path ) ]] || fail 'State contains a link or special file.'
            case $path in *$'\n'*|*$'\r'*|*.p12|*.p8|*.keychain*|*submit.stderr*|*wait.stderr*) fail 'Private or unsafe state path.' ;; esac
        done < <(find "$state" -print)
        mkdir -p "$envelope"
        tar -czf "$envelope/state.tar.gz" -C "$state" .
        digest=$(shasum -a 256 < "$envelope/state.tar.gz"); digest=${digest%% *}
        jq -n --arg commit "$SOURCE_COMMIT" --arg run "$BUILD_CI_RUN_ID" --arg artifact "$BUILD_ARTIFACT_ID" \
            --arg build_digest "$BUILD_ARTIFACT_DIGEST" --arg state_digest "$digest" \
            --arg owner_run "${GITHUB_RUN_ID:-}" --arg owner_attempt "${GITHUB_RUN_ATTEMPT:-}" \
            '{schema:"cadence/checkpoint/v1",source_commit:$commit,build_ci_run_id:$run,build_artifact_id:$artifact,
              build_artifact_digest:$build_digest,state_sha256:$state_digest,release_run_id:$owner_run,release_run_attempt:$owner_attempt}' \
            > "$envelope/checkpoint.json"
        (cd "$envelope" && shasum -a 256 checkpoint.json state.tar.gz > SHA256SUMS)
        ;;
    restore)
        [[ ! -e $state && -d $envelope && ! -L $envelope ]] || fail 'Restore requires fresh state and a regular envelope.'
        shopt -s nullglob dotglob
        entries=("$envelope/"*)
        [[ ${#entries[@]} == 3 ]] || fail 'Unexpected checkpoint envelope entries.'
        for name in checkpoint.json state.tar.gz SHA256SUMS; do
            [[ -f $envelope/$name && ! -L $envelope/$name ]] || fail 'Missing regular checkpoint entry.'
        done
        jq -e --arg commit "$SOURCE_COMMIT" --arg run "$BUILD_CI_RUN_ID" --arg artifact "$BUILD_ARTIFACT_ID" \
            --arg digest "$BUILD_ARTIFACT_DIGEST" '
            .schema == "cadence/checkpoint/v1" and .source_commit == $commit and .build_ci_run_id == $run
            and .build_artifact_id == $artifact and .build_artifact_digest == $digest
            and (.state_sha256 | type == "string" and test("^[0-9a-f]{64}$"))' "$envelope/checkpoint.json" >/dev/null \
            || fail 'Unbound or mismatched checkpoint.'
        digest=$(shasum -a 256 < "$envelope/state.tar.gz"); digest=${digest%% *}
        [[ $digest == "$(jq -r .state_sha256 "$envelope/checkpoint.json")" ]] || fail 'Checkpoint bytes changed.'
        # Only our regular files/directories can be extracted. No traversal or links.
        tar -tzf "$envelope/state.tar.gz" > "$envelope/paths.tmp"
        while IFS= read -r path; do
            [[ $path != . && $path != ./ ]] || continue
            [[ $path == . || $path == ./ || $path == ./* ]] || fail 'Unsafe checkpoint member.'
            case "/$path" in */../*|*/..|*//*) fail 'Unsafe checkpoint path.' ;; esac
        done < "$envelope/paths.tmp"
        tar -tvzf "$envelope/state.tar.gz" > "$envelope/types.tmp"
        while IFS= read -r line; do
            [[ $line == d* || $line == -* ]] || fail 'Checkpoint contains a link or special file.'
        done < "$envelope/types.tmp"
        rm "$envelope/paths.tmp" "$envelope/types.tmp"
        mkdir -p "$state"
        tar -xzf "$envelope/state.tar.gz" -C "$state"
        while IFS= read -r receipt; do
            jq '.restored = true' "$receipt" > "$receipt.restored"
            mv "$receipt.restored" "$receipt"
        done < <(find "$state" -name '*-receipt.json' -type f)
        ;;
    *) fail 'Unknown checkpoint operation.' ;;
esac

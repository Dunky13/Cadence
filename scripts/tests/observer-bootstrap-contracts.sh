#!/bin/bash
# Fake logs/plans only. No providers, XCTest, product launch or UI queries.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/cadence-bootstrap-contracts.XXXXXX")
trap 'rm -rf "$work"' EXIT
helper="$root/scripts/capture-observer-bootstrap.sh"
cases=0
fail() { printf 'FAIL bootstrap: %s\n' "$*" >&2; exit 1; }
new_case() {
    cases=$((cases + 1))
    fixture="$work/case-$cases"
    mkdir -m 700 "$fixture" "$fixture/evidence"
    printf 'unclassified synthetic bootstrap\n' > "$fixture/client.log"
    printf 'CADENCE_OBSERVER_CONTROL=private CADENCE_OBSERVER_EVIDENCE=private\n' > "$fixture/plan"
}
run_helper() {
    result=0
    LAUNCH_UI_EVIDENCE_DIR="$fixture/evidence" /bin/bash "$shell_mode" "${1:-$helper}" \
        "$fixture/client.log" "$fixture/plan" "${2:-65}" > "$fixture/console" 2>&1 || result=$?
}
assert_safe() {
    local output="$fixture/evidence/bootstrap.json"
    [[ $result == 0 && -s $output && ! -s $fixture/console ]] || fail "helper failed ($result)"
    jq -e '
        .schema == "cadence/observer-bootstrap/v1" and .status == "HOLD" and .cause == "UNKNOWN" and
        .read_only and .reader_available and .observations_only and
        (.runtime_acceptance == false) and (.authority_established == false) and (.causality_established == false) and
        (.plan_sample_tokens.proves_test_host_environment == false) and
        .client_exit >= 0 and .client_exit <= 255 and
        .byte_limit_per_input == 1048576 and .deadline_seconds == 12 and .hash_scope == "SAMPLED_BYTES_ONLY" and
        .log.sampled_bytes <= 1048576 and .plan.sampled_bytes <= 1048576 and
        ([.. | strings] | all(. == "cadence/observer-bootstrap/v1" or . == "HOLD" or . == "UNKNOWN" or
            . == "AVAILABLE" or . == "PARTIAL" or . == "UNAVAILABLE" or . == "SAMPLED_BYTES_ONLY" or
            . == "MISSING" or . == "UNSAFE" or . == "UNREADABLE" or . == "READ_FAILED" or . == "CHANGED" or
            . == "SAMPLED" or . == "EMPTY" or test("^[0-9a-f]{64}$")))
    ' "$output" >/dev/null || fail 'schema leaked an unallowlisted string or qualified runtime'
    [[ $(stat -f '%Lp' "$output") == 600 ]] || fail 'output is not private'
    local files=("$fixture/evidence/"*)
    [[ ${#files[@]} == 1 && ${files[0]} == "$output" ]] || fail 'unexpected evidence path'
    local pending=("$fixture/evidence/".observer-bootstrap.*)
    [[ ! -e ${pending[0]} ]] || fail 'private scratch leaked'
}
assert_absent() {
    [[ $result != 0 && ! -e $fixture/evidence/bootstrap.json && ! -L $fixture/evidence/bootstrap.json ]] || fail "published after failure ($result)"
    local pending=("$fixture/evidence/".observer-bootstrap.*)
    [[ ! -e ${pending[0]} ]] || fail 'interruption/failure skipped cleanup'
}

# Instrument a disposable byte-for-byte copy at one named boundary. No runtime
# test hooks in the shipped helper; all other production bytes remain intact.
instrument() {
    MARKER="$1" INJECTION="$2" /usr/bin/perl -0777 -e '
        my $source = <>;
        my $count = ($source =~ s/^(\s*# \Q$ENV{MARKER}\E:.*)$/$1\n$ENV{INJECTION}/mg);
        die "missing or duplicate boundary\n" unless $count == 1;
        print $source;
    ' "$helper" > "$fixture/instrumented.sh"
}

# Combine an actual post-publication failure with stalled private cleanup.
# Only disposable copies change; both original production alarms remain intact.
instrument_stalled_cleanup() {
    FAILURE="$1" /usr/bin/perl -0777 -e '
        my $source = <>;
        my $failure = $ENV{FAILURE};
        my $code = $failure eq "failure" ? q{die "synthetic post-publication failure\n";} :
            "kill " . chr(39) . $failure . chr(39) . q{, $$;};
        my $published = ($source =~ s/^(\s*# OUTPUT_PUBLISHED:.*)$/$1\n$code/m);
        my $cleanup = ($source =~ s/^(# CLEANUP_BEGIN:.*)$/$1\nsleep 30;/m);
        die "missing or duplicate boundary\n" unless $published == 1 && $cleanup == 1;
        print $source;
    ' "$helper" > "$fixture/instrumented.sh"
}

for shell_mode in -e +e; do
    # Fake credentials, environments, machine paths, quoted text and binary bytes
    # must never be copied into any JSON field or diagnostic console.
    new_case
    printf 'FAKE_API_KEY=synthetic-secret-8675309\nHOME=/private/secret-user\n"quoted private text"\n\000\377\n' >> "$fixture/client.log"
    printf '<dict>FAKE_PLAN_SECRET="another-private-value" /private/plan-path</dict>\n' >> "$fixture/plan"
    run_helper
    assert_safe
    ! grep -Eq 'synthetic-secret|secret-user|quoted private|FAKE_|another-private|plan-path' "$fixture/evidence/bootstrap.json" || fail 'private text leaked'
    jq -e '[.signature_flags[]] | all(. == false)' "$fixture/evidence/bootstrap.json" >/dev/null

    flags=(missing_private_protocol_variables runner_connection_failure runner_launch_failure test_bundle_load_failure test_bundle_signature_failure destination_or_plan_failure authorization_failure query_failure)
    phrases=('Missing private observer protocol paths' 'Failed to establish communication with the test runner' 'Failed to launch test runner' 'Failed to load the test bundle' 'Code Signature Invalid' 'Unable to find a destination matching' 'UIAuthorityRequestHOLD' 'SystemWindowQueryUnavailable')
    for ((index=0; index<${#flags[@]}; index++)); do
        new_case
        printf 'private-prefix "%s" private-suffix\n' "${phrases[$index]}" > "$fixture/client.log"
        run_helper
        assert_safe
        jq -e --arg flag "${flags[$index]}" '.signature_flags[$flag] and ([.signature_flags[] | select(. == true)] | length == 1)' \
            "$fixture/evidence/bootstrap.json" >/dev/null || fail "signature ${flags[$index]}"
    done
    for scenario in empty missing missing-plan unreadable symlink fifo directory hardlink oversized exact-cap; do
        new_case
        expected=SAMPLED
        case $scenario in
            empty) : > "$fixture/client.log"; : > "$fixture/plan"; expected=EMPTY ;;
            missing) rm "$fixture/client.log" "$fixture/plan"; expected=MISSING ;;
            missing-plan) rm "$fixture/plan" ;;
            unreadable) chmod 000 "$fixture/client.log"; expected=UNREADABLE ;;
            symlink) mv "$fixture/client.log" "$fixture/private.log"; ln -s "$fixture/private.log" "$fixture/client.log"; expected=UNSAFE ;;
            fifo) rm "$fixture/client.log"; mkfifo "$fixture/client.log"; expected=UNSAFE ;;
            directory) rm "$fixture/client.log"; mkdir "$fixture/client.log"; expected=UNSAFE ;;
            hardlink) ln "$fixture/client.log" "$fixture/private.log"; expected=UNSAFE ;;
            oversized|exact-cap)
                /usr/bin/perl -e 'print "x" x 1048576' > "$fixture/sample"
                cp "$fixture/sample" "$fixture/client.log"
                cp "$fixture/sample" "$fixture/plan"
                if [[ $scenario == oversized ]]; then
                    printf 'Missing private observer protocol paths\n' >> "$fixture/client.log"
                    printf 'CADENCE_OBSERVER_CONTROL CADENCE_OBSERVER_EVIDENCE\n' >> "$fixture/plan"
                fi ;;
        esac
        start=$SECONDS
        run_helper
        [[ $((SECONDS - start)) -lt 4 ]] || fail 'bounded regular/unsafe input read stalled'
        assert_safe
        jq -e --arg expected "$expected" '.log.state == $expected' "$fixture/evidence/bootstrap.json" >/dev/null
        if [[ $scenario == oversized || $scenario == exact-cap ]]; then
            sample_hash=$(shasum -a 256 "$fixture/sample"); sample_hash=${sample_hash%% *}
            truncated=false; [[ $scenario != oversized ]] || truncated=true
            jq -e --arg sha "$sample_hash" --argjson truncated "$truncated" '
                .log.sampled_bytes == 1048576 and .plan.sampled_bytes == 1048576 and
                .log.truncated == $truncated and .plan.truncated == $truncated and
                .log.sample_sha256 == $sha and .plan.sample_sha256 == $sha and
                (.signature_flags.missing_private_protocol_variables == false) and
                (.plan_sample_tokens.control_name_seen == false)
            ' "$fixture/evidence/bootstrap.json" >/dev/null || fail 'sample cap/hash semantics'
        fi
        if [[ $scenario == missing ]]; then
            jq -e '.diagnostic == "UNAVAILABLE" and .log.truncated == null and .log.sample_sha256 == null' "$fixture/evidence/bootstrap.json" >/dev/null
        elif [[ $scenario == missing-plan ]]; then
            jq -e '.diagnostic == "PARTIAL" and .plan.state == "MISSING"' "$fixture/evidence/bootstrap.json" >/dev/null
        fi
    done
    for exit_code in 0 1 65 255; do
        new_case
        run_helper "$helper" "$exit_code"
        assert_safe
        jq -e --argjson code "$exit_code" '.client_exit == $code and .status == "HOLD"' "$fixture/evidence/bootstrap.json" >/dev/null
    done
    for invalid in unavailable -1 256 00065 '65 private text'; do
        new_case
        run_helper "$helper" "$invalid"
        [[ $result == 2 ]] || fail 'invalid client exit accepted'
        assert_absent
    done
    for occupied in regular symlink directory; do
        new_case
        printf 'preserve original\n' > "$fixture/original"
        case $occupied in
            regular) cp "$fixture/original" "$fixture/evidence/bootstrap.json" ;;
            symlink) ln -s "$fixture/original" "$fixture/evidence/bootstrap.json" ;;
            directory) mkdir "$fixture/evidence/bootstrap.json" ;;
        esac
        run_helper
        [[ $result == 2 ]] || fail 'occupied output overwritten'
        if [[ $occupied != directory ]]; then cmp "$fixture/original" "$fixture/evidence/bootstrap.json" || fail 'prior output changed'; fi
    done
    new_case
    chmod 755 "$fixture/evidence"
    run_helper
    [[ $result == 2 ]] || fail 'nonprivate evidence directory accepted'
    assert_absent

    for boundary in FINGERPRINT_PARSE OUTPUT_FLUSH OUTPUT_PUBLISHED CLEANUP_BEGIN; do
        for signal_name in HUP INT TERM; do
            new_case
            instrument "$boundary" "kill '$signal_name', \$\$;"
            run_helper "$fixture/instrumented.sh"
            case $signal_name in HUP) expected=129;; INT) expected=130;; TERM) expected=143;; esac
            [[ $result == "$expected" ]] || fail "$boundary/$signal_name lost signal status ($result)"
            assert_absent
        done
    done
    for boundary in FINGERPRINT_PARSE OUTPUT_FLUSH; do
        new_case
        instrument "$boundary" 'die "synthetic parse/output failure\n";'
        run_helper "$fixture/instrumented.sh"
        [[ $result == 1 ]] || fail 'parse/output failure status'
        assert_absent
    done
    for state in READ_FAILED CHANGED; do
        new_case
        if [[ $state == READ_FAILED ]]; then
            instrument SAMPLE_READ "POSIX::close(fileno(\$handle));"
        else
            instrument SAMPLE_READ "truncate \$path, 0 or die;"
        fi
        run_helper "$fixture/instrumented.sh"
        assert_safe
        jq -e --arg state "$state" '.log.state == $state and .plan.state == $state and
            .log.sample_sha256 == null and .plan.sample_sha256 == null and .diagnostic == "UNAVAILABLE"' \
            "$fixture/evidence/bootstrap.json" >/dev/null || fail 'failed/changed input misrepresented'
    done
    new_case
    printf 'retain competing output\n' > "$fixture/original"
    instrument OUTPUT_FLUSH "symlink \"\$evidence/../original\", \$destination or die;"
    run_helper "$fixture/instrumented.sh"
    [[ $result == 1 && -L $fixture/evidence/bootstrap.json ]] || fail 'late occupied output replaced'
    cmp "$fixture/original" "$fixture/evidence/bootstrap.json" || fail 'competing output changed'
    pending=("$fixture/evidence/".observer-bootstrap.*)
    [[ ! -e ${pending[0]} ]] || fail 'late output failure skipped cleanup'
    new_case
    instrument CLEANUP_BEGIN "open(my \$blocker, \">\", \"\$scratch/blocker\") or die; close \$blocker;"
    run_helper "$fixture/instrumented.sh"
    [[ $result == 1 && ! -e $fixture/evidence/bootstrap.json ]] || fail 'cleanup failure published success JSON'

    for failure in HUP INT TERM failure; do
        new_case
        instrument_stalled_cleanup "$failure"
        start=$SECONDS
        run_helper "$fixture/instrumented.sh"
        case $failure in HUP) expected=129;; INT) expected=130;; TERM) expected=143;; failure) expected=1;; esac
        [[ $result == "$expected" && $((SECONDS - start)) -le 4 ]] || fail 'combined failure lost exit/deadline'
        # Forced exit may leave unuploaded private pending scratch. The owned
        # final JSON must already be revoked before that cleanup can stall.
        [[ ! -e $fixture/evidence/bootstrap.json && ! -L $fixture/evidence/bootstrap.json && ! -s $fixture/console ]] ||
            fail 'post-publication failure retained uploadable JSON during stalled cleanup'
    done

    # Actual production alarm, with a synthetic stalled parse and no child.
    new_case
    instrument FINGERPRINT_PARSE 'sleep 30;'
    start=$SECONDS
    run_helper "$fixture/instrumented.sh"
    elapsed=$((SECONDS - start))
    [[ $result == 124 && $elapsed -ge 11 && $elapsed -le 15 ]] || fail "deadline status/time ($result/$elapsed)"
    assert_absent
done

# Execute the actual outer cleanup and adapter, including consumer delivery.
# A missing/failed reader and cancellation inside it must preserve an existing
# product failure, observer exit65, private teardown and the one-file envelope.
awk '/^cleanup\(\) \{/ { copy=1 } copy { print } copy && /^\}/ { exit }' \
    "$root/scripts/verify-demo-startup.sh" > "$work/cleanup.sh"
cat > "$work/outer-driver.sh" <<'DRIVER'
#!/bin/bash
set -uo pipefail
# shellcheck source=scripts/launch-ui-observer.sh
source "$ADAPTER"
source "$CLEANUP"
app="$FIXTURE/Cadence.app"
work="$FIXTURE/scratch"
launcher=''
diagnostic_launcher=900
diagnostic_script="$FIXTURE/failure.sh"
observer_evidence_owned=true
observer_ready=false
observer_control="$work/control"
observer_plan="$work/plan"
observer_launcher=''
observer_test_result=65
observer_cleanup_failed=false
ps() { return 0; }
if [[ $ORIGINAL == 0 ]]; then printf 'SYNTHETIC PNG\n' > "$INSTALL_EVIDENCE_DIR/startup.png"; fi
trap cleanup EXIT
exit "$ORIGINAL"
DRIVER
for shell_mode in -e +e; do
    for original in 0 42; do
        for scenario in available missing-reader output-failure HUP INT TERM TERM-stalled-cleanup; do
            new_case
            mkdir -p "$fixture/scratch/control" "$fixture/adapter" "$fixture/consumer"
            printf 'Missing private observer protocol paths\n' > "$fixture/scratch/control/xcode-private.log"
            cp "$fixture/plan" "$fixture/scratch/plan"
            cp "$root/scripts/launch-ui-observer.sh" "$fixture/adapter/"
            cp "$helper" "$fixture/adapter/capture-observer-bootstrap.sh"
            case $scenario in
                missing-reader) rm "$fixture/adapter/capture-observer-bootstrap.sh" ;;
                output-failure) mkdir "$fixture/evidence/bootstrap.json" ;;
                HUP|INT|TERM)
                    instrument FINGERPRINT_PARSE "kill '$scenario', getppid(); kill '$scenario', \$\$;"
                    cp "$fixture/instrumented.sh" "$fixture/adapter/capture-observer-bootstrap.sh" ;;
                TERM-stalled-cleanup)
                    instrument_stalled_cleanup TERM
                    cp "$fixture/instrumented.sh" "$fixture/adapter/capture-observer-bootstrap.sh" ;;
            esac
            cat > "$fixture/failure.sh" <<'STUB'
#!/bin/bash
printf 'SYNTHETIC failure\n' > "$INSTALL_EVIDENCE_DIR/startup-failure.txt"
STUB
            chmod +x "$fixture/failure.sh" "$fixture/adapter/capture-observer-bootstrap.sh" 2>/dev/null || [[ $scenario == missing-reader ]]
            result=0
            FIXTURE="$fixture" ORIGINAL="$original" ADAPTER="$fixture/adapter/launch-ui-observer.sh" CLEANUP="$work/cleanup.sh" \
                LAUNCH_UI_EVIDENCE_DIR="$fixture/evidence" INSTALL_EVIDENCE_DIR="$fixture/consumer" \
                /bin/bash "$shell_mode" "$work/outer-driver.sh" > "$fixture/console" 2>&1 || result=$?
            expected=$original
            if [[ $original == 0 ]]; then
                case $scenario in HUP) expected=129;; INT) expected=130;; TERM) expected=143;; esac
            fi
            [[ $result == "$expected" && ! -d $fixture/scratch ]] || fail "outer $shell_mode/$original/$scenario lost failure/cleanup ($result)"
            files=("$fixture/consumer/"*)
            [[ ${#files[@]} == 1 ]] || fail 'consumer has extra diagnostic files'
            if [[ $original == 0 ]]; then [[ ${files[0]} == "$fixture/consumer/startup.png" ]] || fail 'valid PNG replaced';
            else [[ ${files[0]} == "$fixture/consumer/startup-failure.txt" ]] || fail 'startup failure missing'; fi
            jq -e --arg exit "$original" '.status == "HOLD" and .original_startup_exit == $exit and
                .runtime_acceptance == false and (.reason | contains("test exit 65; cleanup exit 0"))' \
                "$fixture/evidence/status.json" >/dev/null || fail 'diagnostic changed observer outcome'
            case $scenario in
                available) jq -e '.client_exit == 65 and .signature_flags.missing_private_protocol_variables' "$fixture/evidence/bootstrap.json" >/dev/null ;;
                output-failure) [[ -d $fixture/evidence/bootstrap.json ]] || fail 'occupied output changed' ;;
                *) [[ ! -e $fixture/evidence/bootstrap.json ]] || fail 'failed reader published JSON' ;;
            esac
        done
    done
done

# Pin the public artifact boundary, including the uploader version and every
# existing path. The ordinary consumer still has its exact single wildcard.
new_case
awk '/name: Retain separate allowlisted read-only system UI telemetry/ { copy=1 } copy { print } copy && /retention-days: 90/ { exit }' \
    "$root/.github/workflows/release.yml" > "$fixture/uploader"
grep -q 'actions/upload-artifact@b7c566a772e6b6bfb58ed0dc250532a479d7789f' "$fixture/uploader" || fail 'uploader pin changed'
sed -n 's/^            //p' "$fixture/uploader" > "$fixture/paths"
cat > "$fixture/expected" <<'PATHS'
${{ runner.temp }}/launch-ui-evidence/status.json
${{ runner.temp }}/launch-ui-evidence/preflight.json
${{ runner.temp }}/launch-ui-evidence/bootstrap.json
${{ runner.temp }}/launch-ui-evidence/binding.json
${{ runner.temp }}/launch-ui-evidence/session.txt
${{ runner.temp }}/launch-ui-evidence/session-stage.json
${{ runner.temp }}/launch-ui-evidence/first-open.json
${{ runner.temp }}/launch-ui-evidence/confirmation.json
${{ runner.temp }}/launch-ui-evidence/observation-0.json
${{ runner.temp }}/launch-ui-evidence/observation-1.json
${{ runner.temp }}/launch-ui-evidence/observation-2.json
${{ runner.temp }}/launch-ui-evidence/system-*.png
PATHS
cmp "$fixture/expected" "$fixture/paths" || fail 'UI upload allowlist broadened'
grep -q -F "path: \${{ runner.temp }}/consumer-evidence/*" "$root/.github/workflows/release.yml" || fail 'consumer envelope changed'
printf 'Observer bootstrap: %s synthetic bounded/privacy/signal contracts passed; runtime/authority/causality remain unqualified.\n' "$cases"

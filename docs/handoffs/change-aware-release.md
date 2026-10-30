# PR #11: Change-aware release and native CI repair

[Pull request](https://github.com/Dunky13/Cadence/pull/11)

## Result and scope

The release timer changes from every fifteen minutes to daily at 05:23 UTC.
Successful trusted-main CI still starts selection immediately. Automatic runs
skip distribution, publication and installation when the same automation commit
already reached a completed, non-skipped trusted distribution job, whether that
attempt passed or failed. Preflight-only failures/skips do not suppress a later
successful CI event. Intentional manual dispatch can retry unchanged code using
current retained candidate custody. Signing, submission-once, publication and
frozen product bytes are unchanged.

The user authorized one narrowly verified normal Cadence first-open Open action.
The controller requires exact public app identity, one owned stopped product and
snapshot arguments, its exact LaunchServices launcher, no competing Cadence or
pre-existing consent window, a unique Apple-signed system owner, complete normal
allowlisted text, and exactly Cancel/Open buttons. Unknown dialogs and warnings
fail. Stop is checked at entry, after awaited capture and immediately before the
click. The original thirty-second demo snapshot requirement remains.

## Proven bootstrap failure and repair

[CI 41075530961](https://github.com/Dunky13/Cadence/actions/runs/41075530961)
retained the explicitly approved temporary encrypted credential-free XCTest logs.
All four downloaded artifact archive digests matched GitHub metadata. Both
locally decrypted logs matched their existing bootstrap fingerprints:

| Native runner | Client bytes | SHA-256 |
| --- | ---: | --- |
| arm64 | 10168 | `17e85fef9d64704cb6c1a5201c93f6213e5a756a78d5b7b4f77daba8b6bde691` |
| Intel | 9697 | `f9662d038f8cf7933a1a4bfbdd2e6bcaf96d02d85948e724466c5156ace2b932` |

Both tests executed candidate verification, screen-session initialization and
owner preflight, then failed with NSCocoaErrorDomain 513 / NSPOSIXErrorDomain 1
saving `observer-control/ready`. The sandboxed runner could read external input
but could not write the parent's control/evidence directory. Its optional stage
and error writes failed for the same reason; absent markers did not prove that
test execution never started. Local final codesign inspection confirms App
Sandbox with read-only external-file access; the build now verifies that sandbox
entitlement rather than removing it or granting filesystem exceptions.

Ready/done now use exact observation-ID-bound stdout markers through FileHandle.
The parent remains the only writer of external control and evidence files.
Native evidence uses nonce-bound named XCTest attachments with keepAlways.
After verified teardown and client reaping, the parent privately exports the
result bundle and validates the exact test, nonce, generated names/extensions,
owned regular-file bounds and JSON bindings. Only existing allowlisted evidence
is retained. Highest validated stage wins; any session HOLD dominates success.
Foreign/duplicate/unsafe attachments or extraction failure hold qualification.
Raw result bundles, manifests, automatic screenshots and client logs are never
uploaded. No sandbox, Gatekeeper, quarantine or permission setting is weakened.

A local unit-test-only Xcode probe verified live marker forwarding more than
seven seconds before test completion and the actual attachment export format.
No local UI session or product launch was performed. Hosted PR/main CI exercises
the public-install flow against immutable v0.2.0/build15 without signing secrets,
write permission or a signing environment; this qualifies installer automation,
not newly built product bytes.

## Proven observation failure and process-query repair

At `434c4ce`, [CI 41083249075](https://github.com/Dunky13/Cadence/actions/runs/41083249075)
reaches readiness on both architectures, then fails with NSPOSIXErrorDomain 1
(Operation not permitted). Both encrypted archive digests and decoded bootstrap
fingerprints match. Arm64 client: 13994 bytes, SHA-256
`e6a62a115e7ffbfd7f30cb7d7c5117c826fce38c2953872cf09e029e784c0a81`.
Intel client: 13523 bytes, SHA-256
`db83808217e5f6cace4f723dc4364dc0d8014f2ac7b56c9e9514ab40a2638af4`.
The first throwing operation in observation is spawning `/bin/ps`; a nonzero
query exit would instead report the controller's ProcessQueryUnavailable error.
The runner's sandbox therefore also prevents process-query subprocess launch.

The parent harness now owns a finite read-only process-metadata broker. The
sandboxed client sends only fixed query kinds through nonce/request-ID-bound
stdout frames and reads private atomic typed replies. It never starts a helper.
Enumeration includes all Cadence executables so competing copies still block
Open. Per-process replies require the exact owned original/translocated app and
snapshot arguments or the exact known ordinary launcher. Unrelated arguments
are never returned. Queries, reply sizes, total requests and worker lifetime
are bounded; stop cancels client waits. The parent stops and reaps its worker
and any query child after XCTest teardown. Broker failures hold enabled consent
qualification even when product startup has already produced a valid PNG.
The sandbox and original thirty-second product timeout remain unchanged.

## Proven forwarding failure and framing repair

At `a8b007c`, [arm64 job 124179508537](https://github.com/Dunky13/Cadence/actions/runs/41089540851/job/124179508537)
reaches readiness, then reports ProcessQueryUnavailable without attempting Open.
Teardown, attachment collection and broker exit are all zero. The encrypted
archive digest and decoded client fingerprint match: 14089 bytes, SHA-256
`855d73c1e4a8e568ea05bfc79787855b5bd2a07d143caf32029dcc818714e2c3`.
The first query is present inside a partial XCTest logging line, immediately
after its timestamp/runner prefix. The broker's strict line-start matcher
therefore ignores the valid request, and the native client times out.

A synthetic replay of that prefix fails against the old broker and passes after
the repair. Ready, Done and Query now carry an explicit end marker and a leading
newline. The broker resynchronizes on complete start/end frames across reads;
readiness/completion look for the exact nonce-bound complete frame independently
of surrounding logging text. Foreign or malformed fields, unknown query kinds,
replayed requests and existing bounds still fail. Only transport framing changes;
metadata and consent authority are unchanged.

Focused final checks pass: 23 broker contracts, 12 exact-production Swift client
contracts, 24 attachment/signal contracts and 74 lifecycle contracts, plus the
existing first-open, stage and export checks. QA build-for-testing preserves the
sandbox. Both independent Standards and Spec reviews report no remaining
source-supported findings against `a8b007c`; reviewed broker SHA-256 is
`613fcfd02f522b9a683c5be5e14c5cb9e963396ec057279479eac57258d0ac99`.
Hosted repaired-frame startup remains required.

Intel in the same run failed earlier: copied-app ticket validation exhausted
three exact CloudKit connection-loss retries and exited 68 before the controller
started. A targeted rerun was rejected while the run was unfinished. This
provider failure is separate from the arm64 framing defect and cannot establish
broker/runtime acceptance. A changed repaired head will receive both native jobs.

## Proven launcher mismatch and explicit system path

At `4b4a005`, [arm64 job 124187086910](https://github.com/Dunky13/Cadence/actions/runs/41091739312/job/124187086910)
verifies the framing repair: process enumeration, owned product command/state
queries and observation attachment collection succeed. The owned translocated
Cadence process is stopped with the exact snapshot arguments. Open remains
unattempted because the next query, for the ordinary launcher, is rejected.
The verified encrypted client is 27181 bytes, SHA-256
`9825d2da86797a8a2ea838874b541ff856f99374bd623db221a144302aeef66b`.
Its archive digest and bootstrap fingerprint match. The retained failure
report identifies launcher command `open`; the broker requires `/usr/bin/open`.
The harness had invoked the bare PATH command.

A local read-only probe with two owned short-lived sleep processes confirms
that macOS ps comm reports a bare invocation as sleep and an absolute invocation
as /bin/sleep. Both children were reaped; no UI or product was launched. The
production harness now pins `/usr/bin/open`, aligning argv[0] and the executable
with the existing exact launcher checks. Flags, app/snapshot arguments,
LaunchServices behavior and the thirty-second deadline are unchanged. No
identity check is relaxed.

The complete-launch and release-recovery fixtures require exactly one explicit
system launch boundary, then substitute it only inside disposable copies with
a quoted inert fixture path. No production environment override is introduced.
The old source fails that regression; the repaired lifecycle tests cover valid
PNG, launcher failure and unchanged timeout behavior without opening the real
app. Final targeted checks pass: 8 cleanup, 30 failure-capture, 74 lifecycle,
23 broker, 24 first-open and 20 release-recovery cases. ShellCheck, Bash syntax,
actionlint and whitespace checks pass. Both independent Standards and Spec reviews report no remaining findings for
launcher SHA-256
`fff98212a730d843f017b0c6137bd54effbdacc9cf6737db5fb0b42b300edf53`.
Actual repaired-head launcher validation, normal Open and startup remain hosted
gates. The QA source is unchanged from the last successful compile.

## Validation and review

At `a8b007c`, the full local scripts/ci.sh passed on arm64/macOS 27/Xcode 27.1,
including 59
Swift tests with real launchd integration, native app build, workflow/static
checks, and all signing/recovery/publication contracts. Focused final checks
pass: 24 inert Open-controller cases, 24 attachment/signal cases, 17 exporter
cases, eight stage cases plus optional-output failures, 73 observer lifecycle
cases, 21 inert capture cases and the existing privacy/provenance contracts.
Final changed QA sources also pass build-for-testing with sandbox verification.
These are local/source results, not hosted runtime acceptance. The process
broker adds 17 isolated parent IPC/ownership/timeout cases and 12 exact-production
Swift reply/cancellation cases. Independent Standards and Spec reviews cover
this increment against `434c4ce`. Standards reproduced a cancellation defect:
requested stop during a valid in-flight query yielded broker exit 143. The
regression and independent rerun verify that only requested TERM cancels and
reaps cleanly; faults and other signals remain failures. Both re-reviews report
no remaining source-supported findings for broker SHA-256
`b1ce81d6451b4e7e7c94b085216fcce134bf5b1804862b9e77a875b13e41a640`.
The full local `scripts/ci.sh` passed for that broker increment, including the
sandbox-preserving QA compile, 59 Swift tests with launchd integration, native
build and all release contracts. Its initial broker matrix had 16 cases; the
final 17-case targeted rerun includes the repaired cancellation and unexpected
TERM paths. ShellCheck passes on the final scripts. No local UI was executed.

Independent Standards and Spec reviews initially found controller failures could
be ignored after successful product startup. The real finish/outer cleanup
reproduced that problem; the repair and both re-reviews passed at tree
36dc0dcf5ee9927f54aedeb0cf0e0d93bb0c9dff. The attachment transport review found a
stop request could arrive during capture/final queries and still permit Open.
Its inert regression fails against the reviewed method and passes after the
stop guards. Both independent re-reviews report no further findings at tree
06dae2fece2afe5a1e5734fab378372b91f5d47e. The subsequent process-broker
increment and its separate reviews are recorded above.

## Remaining gates and cleanup

The output-transport repair is verified by readiness on both architectures in
run 41083249075. The framing repair is verified by hosted broker replies and an owned-process
observation in run 41091739312. Its later launcher basename mismatch is repaired
by the explicit system path; hosted launcher checks and startup remain required. The previously
approved encrypted capture remains active with the same protected one-time key
until that repair is verified; remove it before final acceptance.

Repaired-head hosted arm64 and Intel readiness, actual dialog matching, native
startup and finalized result/attachment export remain required. Missing UI
images are optional telemetry; unknown dialogs, controller failure and enabled
collection failure cannot qualify a startup. If checks fail, diagnose and repair
in this same PR without weakening the gate. ci-required correctly fails when
native checks fail and packaging is skipped.

The temporary encrypted-log helper, public certificate, CI flag and uploader
are currently restored for the later observation diagnosis and must be removed
before final acceptance. The protected one-time key, private logs and task-owned
encrypted remote artifacts remain only until repair/evidence closure, then must
be deleted. Keep safe fingerprints and sanitized failure summaries. Local
temporary builds/test scratch must also be removed before final handoff;
ignored validation logs and the standalone offline HTML remain local.

No merge, Apple submission, public release or deployment was performed. The
schedule change is not live until the PR is merged. The authorized implementation
endpoint is a signed, pushed, reviewed PR; merge needs the user's separate
approval after required checks pass. To inspect checks from a repository checkout:
`gh pr checks 11 --repo Dunky13/Cadence`.

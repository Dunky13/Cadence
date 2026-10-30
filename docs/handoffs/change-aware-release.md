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

## Validation and review

The full local scripts/ci.sh passes on arm64/macOS 27/Xcode 27.1, including 59
Swift tests with real launchd integration, native app build, workflow/static
checks, and all signing/recovery/publication contracts. Focused final checks
pass: 24 inert Open-controller cases, 24 attachment/signal cases, 17 exporter
cases, eight stage cases plus optional-output failures, 57 observer lifecycle
cases, 21 inert capture cases and the existing privacy/provenance contracts.
Final changed QA sources also pass build-for-testing with sandbox verification.
These are local/source results, not hosted runtime acceptance.

Independent Standards and Spec reviews initially found controller failures could
be ignored after successful product startup. The real finish/outer cleanup
reproduced that problem; the repair and both re-reviews passed at tree
36dc0dcf5ee9927f54aedeb0cf0e0d93bb0c9dff. The attachment transport review found a
stop request could arrive during capture/final queries and still permit Open.
Its inert regression fails against the reviewed method and passes after the
stop guards. Both independent re-reviews report no further findings at tree
06dae2fece2afe5a1e5734fab378372b91f5d47e. Subsequent changes are this handoff's
updated evidence and structure.

## Remaining gates and cleanup

Repaired-head hosted arm64 and Intel readiness, actual dialog matching, native
startup and finalized result/attachment export remain required. Missing UI
images are optional telemetry; unknown dialogs, controller failure and enabled
collection failure cannot qualify a startup. If checks fail, diagnose and repair
in this same PR without weakening the gate. ci-required correctly fails when
native checks fail and packaging is skipped.

The temporary encrypted-log helper, public certificate, CI flag and uploader
are removed from the repaired source. The protected one-time key, private logs
and two task-owned encrypted remote artifacts remain only until repair/evidence
closure, then must be deleted. Keep safe fingerprints and sanitized failure
summaries. Local temporary builds/test scratch must also be removed before final
handoff; ignored validation logs and the standalone offline HTML remain local.

No merge, Apple submission, public release or deployment was performed. The
schedule change is not live until the PR is merged. The authorized implementation
endpoint is a signed, pushed, reviewed PR; merge needs the user's separate
approval after required checks pass. To inspect checks from a repository checkout:
`gh pr checks 11 --repo Dunky13/Cadence`.

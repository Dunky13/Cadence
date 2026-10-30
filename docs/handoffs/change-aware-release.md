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
allowlisted text and the exact Cancel/Open action pair. The observed native
profile additionally requires one passive Help control in a closed tree shape;
Help is never selected. Unknown dialogs, controls and warnings fail. Stop is checked at entry, after awaited capture and immediately before the
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

## Argument mutation and certified initial launch custody

At `57bc97b`, [run 41093264872](https://github.com/Dunky13/Cadence/actions/runs/41093264872)
gets both native runners through readiness, broker framing, owned-product
queries and observation export. Both report the correct `/usr/bin/open`
executable, then fail its command query without attempting Open. All four
artifact archive digests match GitHub metadata, and both decrypted client logs
match their bootstrap fingerprints:

| Native runner | Client bytes | SHA-256 |
| --- | ---: | --- |
| arm64 | 27609 | `752ee2d81447e1dcc910accfe820c03369f76aef2117dba034b45d2a863b1b77` |
| Intel | 26568 | `dcd76d350f7a860c8a1bd643ab79d2c35137b17ef66a6c0f6fd02528c9abc011` |

A local invalid-target CLI probe reproduces the remaining guard failure: after
open parses the arguments, ps reports a changed/truncated vector ending in
split long options and omits the snapshot path. Raw kernel argument queries
also lose the trailing arguments after that mutation. A suspended-spawn probe
reads all eight original arguments exactly before user code executes. This
local reproduction explains the matching hosted failure; the changed bytes
were observed locally, not retained as raw public CI arguments. Apple's
[ps argument reader](https://github.com/apple-oss-distributions/adv_cmds/blob/main/ps/print.c)
and [Darwin process-argument handler](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/kern_sysctl.c)
provide the primary interface context. No private entitlement, environment
dump, permission grant or security override is used.

The parent now supervises the unchanged ordinary LaunchServices invocation.
It verifies Apple's system executable and every initial argument while the
child is suspended, records an exclusive private nonce-bound receipt, then
resumes it. Later metadata queries must match that receipt, binding, and both
live kernel identities (PID, UID, parent, start timestamp and executable).
The command returned is explicitly the certified initial vector, not a claim
that open's runtime argument strings are unchanged. Product argv/hash/signature
checks remain independent. No prefix-only or missing-snapshot fallback is added.

Child masks/defaults are restored explicitly. Cancellation/stop is checked
before resume, child status is mirrored, and the original outer 30-second loop
has no added receipt wait. A separate 45-second supervisor safety alarm and
bounded outer TERM/KILL cover teardown. Child cleanup survives supervisor KILL:
published custody pins the original child identity, while pre-publication
recovery requires an owned still-stopped system launcher with every exact
initial argument and known parent/orphan relationship. Other stopped processes
are left alone. Incomplete cleanup holds qualification and retains control.
The native error message exposes only a fixed failure-stage vocabulary.

The 79 native contracts verify exact arguments, wrong bindings/nonces/PIDs,
argument-display mutation, live proof, TERM/INT/HUP/KILL, the actual outer stop
callback, unpublished-child recovery and foreign-process exclusion. Every app
target is guaranteed nonexistent; no local product or UI is launched. Parent
broker contracts expand to 26 cases, including verifier failure, output tamper
and timeout; lifecycle contracts expand to 75, including a missing verifier.
Both independent Standards and Spec source reviews report no remaining
findings, including the fixed-stage/allocation-guard recheck. The full local
scripts/ci.sh passes: all workflow/release contracts, sandbox QA compilation,
59 Swift tests with real launchd integration and the native app build. The final
79 native launcher contracts and static checks pass again after the safe stage
labels and allocation guard. Reviewed identity-reader SHA-256:
`c5285d27a081745189ec995764c9d3e7c1835c1adab4c281973a34c46853f612`.
Reviewed final supervisor SHA-256:
`894459dfa41018b1186d58ed69524e9b561a7d96aab8f1fd75500e7be8c5b625`.
Final Standards review also caught a fixture-only leak if a second suspended
spawn failed before cleanup was installed. Cleanup now starts immediately after
the first spawn and tracks the second child only after success, retrying reaping
on interruption. The 79 native contracts pass again after this repair.
Hosted startup remains required, followed by removal of the temporary encrypted
diagnostic exception.

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

## Refreshed failure at the certified-launcher head

[Run 41101077067](https://github.com/Dunky13/Cadence/actions/runs/41101077067)
on `4a43e86e2d9336698d0916867f7c51b1604f19a1` fails both native jobs.
Both reach readiness, enumerate the unique stopped translocated product, and
complete the certified launcher command and executable queries. This verifies
that the earlier sandbox/framing/launcher-argument failures are superseded at
this head. The current rejection is `UnknownFirstOpenHOLD`, immediately after
the CoreServicesUIAgent window enumeration and before any window snapshot or
Open action. Both products remain stopped; neither produces the required PNG.
The arm64 ticket connection loss recovers within the existing exact retry
policy, so it is not that job's terminal failure. Signing, notarization and
publication succeeded in the historical main run; installation acceptance did
not. No new distribution run was started for this repair.

All four downloaded archive SHA-256 values match GitHub artifact metadata.
Both decrypted client fingerprints match the retained bootstrap evidence:

| Runner | Bytes | SHA-256 |
| --- | ---: | --- |
| arm64 | 29665 | `8b2d37c5504fc7f14997fc65be8165bad961338b2939b08a4d8cd2d930e51613` |
| Intel | 47980 | `5d41e48765a694441b0ee03a278e1b62b370204afa1c27aa5a713e53bcde0b43` |

The source queried only XCTest windows and rejected an empty result even while
the system owner was becoming visible. XCTest has distinct window, dialog,
alert and sheet element types. The candidate queries top-level children once,
selecting all four surface types consistently for preflight, evidence and the
controller. Nested dialogs remain inside their parent surface, avoiding duplicate
counts. The controller leaves Open unattempted when no accessibility surface is
available yet, using only the existing samples and thirty-second deadline.
Multiple surfaces, unknown text, warnings, editable content, incomplete trees,
owner changes, competing products and cancellation still prevent Open.
The exact owner/product/custody/signature/argument checks are retained.
Apple documents the separate [dialog query](https://developer.apple.com/documentation/xcuiautomation/xcuielementtypequeryprovider/dialogs)
and [NSAlert modal dialog/sheet behavior](https://developer.apple.com/documentation/appkit/nsalert).
The hosted logs do not retain the missing root's element types; whether the
rejection is a distinct dialog type or a transient absent surface remains an
inference pending the repaired-head run, not established runtime acceptance.

The old controller fails the new exact-production inert regression on a dialog
surface. The repaired suite covers all four types, unavailable-then-visible
surfaces, bounds and all previous refusal cases. Export contracts additionally
reproduce a diagnostic defect: xcresult attachment order can cause a generic
unwind HOLD to overwrite the precise error. The collector now preserves the
precise HOLD in either order; any HOLD still dominates success.

A disposable local native alert probe compiled but did not enter its test method.
Its owned runner and xcodebuild were stopped without granting permission or
changing settings. It provides no local native UI proof. Inert contracts and
build-for-testing must not be presented as native first-open acceptance.

## Local checks for the surface-discovery candidate

The complete `scripts/ci.sh` passes on arm64/macOS 27.0.1/Xcode 27.1:
59 Swift tests with real launchd integration, the native app build, QA
build-for-testing with its sandbox verified, ShellCheck/Bash/actionlint,
and every workflow/signing/recovery/publication contract. Focused candidate
coverage includes 30 inert first-open controller cases, 22 capture cases and
19 export cases. The existing 79 native launcher contracts, 26 broker cases,
50 release-selection cases and 108 publication cases also pass. The new dialog
regression fails against the old controller; the precise-HOLD export regression
fails against the old collector. These local checks do not establish the
quarantined hosted installation or normal Open outcome.

## Hosted dialog discovery and remaining policy rejection

[Run 41109516102](https://github.com/Dunky13/Cadence/actions/runs/41109516102)
on `ea33845e4d1c0a2163ffcb80ebfa916ef5299654` fails both native jobs.
Both now resolve an `alert` Dialog at the confirmation snapshot, proving the
window-only discovery defect and the repaired discovery on these runners.
They then reject its filtered tree with `UnknownFirstOpenHOLD` before the
button query or Open action. Teardown, collection and broker exits are zero;
product startup times out without the required PNG. The repaired exporter
retains the precise HOLD rather than the generic unwind fallback.

All four archive digests match GitHub metadata. Both decrypted client logs
match the retained bootstrap fingerprints:

| Runner | Bytes | SHA-256 |
| --- | ---: | --- |
| arm64 | 30607 | `3dc6aa826a4ac68c6e6bad6239af6cf326618ce4f85fbd753980098702ac5565` |
| Intel | 30136 | `dc682cd8394d9dfadd968a4a64cfb45b176138f9ced243eb5dd815b4499d6bc2` |

The next increment captures the exact rejected filtered tree as optional
`confirmation.json`, using the existing nonce-bound observation schema and
attachment export, plus one exact upload path in each consumer workflow.
It records no pixels, identifiers or editable values, and refuses editable,
authority-request or truncated trees. The owner executable and Apple signature
are rechecked before retention. The record is explicitly incomplete and cannot
qualify startup or trigger an action. Recording failure leaves the original
policy rejection intact. No confirmation allowlist, timeout, consent authority,
sandbox setting or product code is changed. The actual text mismatch must be
read from repaired-head evidence before changing the policy.

Focused checks cover filtered retention at the rejecting controller call site,
refusal of unsafe trees/changed owners/bad signatures, optional write failure,
nonce/schema/name/export rejection and the exact updated upload allowlist.
The sandbox-preserving QA build and focused checks pass: first-open 39,
capture 22, export 25, attachment 27, lifecycle 75, bootstrap/privacy 139 and
workflow 110 cases, plus Bash syntax, ShellCheck, actionlint and whitespace.
Full product tests
and native app build passed at the preceding executable candidate; product and
release-selection code are unchanged in this diagnostic increment. Hosted
confirmation evidence and the actual Open/PNG outcome remain HOLD.

## Verified confirmation shape and scoped immutable text

[Run 41112227498](https://github.com/Dunky13/Cadence/actions/runs/41112227498)
on `c82d84fba63e3ad2268b0d0857863fcb37746d9a` exports `confirmation.json`
on both architectures. All four artifact archive hashes match GitHub metadata.
Both filtered trees contain a Dialog root labeled `alert`, two static-text nodes
with empty label/title fields, and exactly Help, Cancel and Open button nodes.
The same owned stopped candidate is bound; observation is incomplete with no
pixels or window ID. The controller rejects it without Open, and teardown,
collection and broker all exit zero. ci-required correctly fails for native
failure and skipped packaging; there is no independent aggregate defect.

The filter previously never read accessibility values, so these nodes could not
supply the mandatory complete prompt. A controller regression additionally
shows the old filter accepts a known prompt plus a warning carried only by a
static-text value. The candidate fixes that source-supported blind spot with
an explicit opt-in used only by the verified CoreServices confirmation path.
It reads String values only from static-text nodes, bounds them to 2048
characters, marks oversize/non-string values incomplete, includes that text in
permission/confirmation checks, and verifies it again in the final stable tree.
Unknown label/title text is preserved alongside the immutable text. Generic
telemetry and editable-field values remain unread; no identifiers, placeholders
or pixels are added. Apple's [element-attribute interface](https://developer.apple.com/documentation/xcuiautomation/xcuielementattributes)
distinguishes label, title and raw value attributes.

The actual native static-text values are not yet observed. The candidate does
not change allowed confirmation text, root-label handling, button counts or
which action is permitted. Help and the `alert` metadata therefore still block
this observed tree. The next bounded confirmation artifact must establish its
full displayed text before a strict compatible profile can be considered.
Source/inert results are not native Open or PNG acceptance.

Focused local checks pass: first-open 45, policy/filtering 40, capture 22,
export 25, attachment 27, lifecycle 75, bootstrap/privacy 140 and workflow 110,
plus Bash syntax, ShellCheck, actionlint, whitespace and a sandbox-preserving QA
build-for-testing. The old production controller fails the masked-value warning
regression. Tests also refuse non-string/oversize values and changed final
static text, and prove generic/editable value getters are never read. Product
tests and the full native app build were not repeated for this QA-only change;
preceding-head full-CI evidence remains separate.

The bounded confirmation export is now verified on both native runners, so the
temporary encrypted raw-log helper, recipient certificate, CI flag, caller and
uploader are removed. A pinned negative contract prevents their accidental
return. Existing protected keys and private evidence retain their ownership;
no provider artifact or credential was changed or deleted.

## Strict observed native profile and quarantine-bound footer

The Intel failure in [run 41115906962](https://github.com/Dunky13/Cadence/actions/runs/41115906962)
at `be9a832b9150938cec24d5dff8454db499664dd6` now includes complete immutable
text. Its archive SHA-256 matches GitHub metadata:
`1b2e49a6c3cb4dcd516d362f36c83839e5dd0cf9b78af2162e759fdec36404cf`.
The question is the expected Cadence Internet-download confirmation. The footer
states that `CadenceReleaseVerification` downloaded the file today at 7:32 PM,
followed by Apple's exact statement that malicious software was not detected.
The copied app's quarantine timestamp `6ae4f0d1` is
2026-10-30T19:32:33Z, binding that displayed minute to the installed candidate.
Arm64 later completed with the identical tree except for its own 7:37 PM
footer minute. Its quarantine timestamp `6ae4f1ea` is
2026-10-30T19:37:14Z, and its archive SHA-256 also verifies:
`bb0d7df8152f0cdcd525341ef7b0be3222bc6e97fb2aba3b315bb69b8926b4d4`.
Both architectures therefore provide complete observed-profile evidence, but
neither establishes actual Open/PNG acceptance on the repaired candidate.

A sanitized [native tree fixture](../../scripts/tests/fixtures/NativeFirstOpen.json)
contains only the observed role/text/control structure, without process IDs,
user paths or pixels. The old production controller rejects that fixture;
the new controller accepts it only with matching trusted quarantine context.
The initial profile used a Dialog root `alert` with no title, one empty image,
two immutable static-text leaves, then exactly Help, Cancel and Open leaves
with their observed label/title placement. Every leaf must be complete and
childless. The question must match the existing Cadence/Cadence.app prompts.
The entire footer must equal the expected notice derived from the copied app,
including its downloader and displayed minute. Unknown text, reordered/extra
controls, missing content, warnings and permission UI remain refusal cases.
The legacy Cancel/Open profile remains unchanged.

The metadata reader uses Foundation's quarantine-properties API, validates the
exact `CadenceReleaseVerification` agent and a finite positive Date that is not
in the future, and supports only the observed same-day English notice. It
formats that timestamp in the current time zone and clears the URL's metadata
cache before each read. It never changes quarantine. Metadata is read again
before the click; changed context holds qualification. An unsupported date or
unavailable context cannot qualify the new profile. No guessed origin strings,
wildcard suffix or arbitrary button exclusion is used.

The live button query must equal the button count of the already validated
closed tree, with one enabled exact Open match. Help is never clicked. Final
tree equality, unchanged quarantine context, candidate/launcher/owner custody,
unique stopped product and snapshot, cancellation and the once-only Open latch
remain required. The original thirty-second product loop and all trust gates
are unchanged. No permission setting, warning override or app activation is
introduced.

Focused checks pass: 58 exact-production inert controller cases, 64 filtering/
profile cases and 15 actual-filesystem metadata/format/cache/preservation cases
against an owned inert directory. The latter use the exact production metadata
reader and show the quarantine attribute is unchanged after reading, and that
changed agent/timestamp values are freshly read. At the initial profile candidate `23946da`, the full local `scripts/ci.sh` suite
passes on arm64/macOS 27.0.1/Xcode 27.1:
59 Swift tests with real launchd integration, native app build, sandbox-preserving
QA compile, static/workflow checks and all signing/recovery/publication contracts.
Hosted Open, required native demo PNG and all aggregate/package gates remain
HOLD until observed on the repaired head.

## XHigh image-metadata finding and repair

The direct Sol 6.1 XHigh review of `23946da` found no separate Standards issue,
but held Spec for one P2: the empty-image classifier checked fields that the
filter had already erased. Three supplemental raw-snapshot cases reached one
inert Open click: an unexpected image label, an authentication title, and an
image label changed between snapshots. The earlier negative test modified an
already-filtered Node and did not cover that actual boundary. That tree
was held before any push as an executable CI head or native Open action.

The repair retains bounded image label/title metadata only in the already
verified confirmation context, so classification and final equality inspect
the actual snapshot fields. Generic telemetry still redacts those image fields;
image values, pixels and identifiers remain unread. Unknown image text is
rejected by the closed profile, authority text is refused, and a changed image
label or title blocks the final action. The actual raw native image metadata
was not present in earlier filtered artifacts, so repaired-head runtime checks
must verify the enforced empty-image condition rather than infer it.

The old filter fails the new raw-controller image-label regression. Focused
rechecks pass: controller 62, filtering/privacy 69, capture 22, quarantine 15,
export 25, attachment 27 and lifecycle 75, plus static checks and a sandbox-
preserving QA build. Controller cases cover all three reported failures and
the symmetric changed-title case. Generic image redaction, no image-value
reads, authority detection and text truncation also have raw-snapshot coverage.
The full expensive suite was not repeated after this narrow repair; its
`23946da` evidence remains separate. The direct Sol 6.1 XHigh recheck of
`29a5d7f` found no remaining Standards or Spec source findings. It independently
reproduced all four unsafe parent cases and verified zero clicks after repair,
then reran the focused contracts. That reviewed, signed candidate was pushed.

## Enforced native image label

[Run 41124885712](https://github.com/Dunky13/Cadence/actions/runs/41124885712)
on `29a5d7f` still fails both native jobs and `ci-required`; packaging is skipped.
Both consumer archives match their GitHub metadata SHA-256 values:

- arm64: `5cc2196bc5bf5da9eba654e343dd9a0983f678338d5c810274e335223c9afd82`.
- Intel: `eb787187b626d1bb93f47ed44d9181ecc7b6e3c578af71ea0fc73269ca00f39f`.

ARM's rejected confirmation now retains the raw image label `alert`, empty
image title, exact known prompt and metadata-bound 8:40 PM footer. The previous
empty-image assumption is disproved. The strict classifier now requires exactly
that observed image label, with all other fields and the final snapshot equality
unchanged. It accepts neither missing nor arbitrary image metadata. The fixture
is replaced with this exact ARM tree, without binding paths, PIDs or pixels.
The old classifier fails this fixture through the production raw-snapshot
controller. The repair passes 63 controller and 71 filtering/privacy cases,
including refusal of empty, unexpected, authority-bearing and changed image text.

Intel has a distinct `ProcessQueryUnavailable` HOLD before any observation or
confirmation artifact; no Open was attempted. Its transient Apple CloudKit
connection loss recovered through the existing ticket-validation retry, and
notarization/Gatekeeper checks subsequently passed. The process-query subcause
is not established by retained evidence. It is not claimed fixed by the ARM
profile correction, and no broker deadline, trust check or startup deadline is
changed to hide it. Both products remained stopped and produced no demo PNG.
Cleanup, collection and bridge exits are zero; the native test exit is 65.

Focused capture 22, quarantine 15, export 25, attachment 27 and lifecycle 75
checks also pass, together with Bash syntax, ShellCheck, actionlint, whitespace
and a fresh sandbox-preserving QA build. The full expensive CI suite is not
repeated for this one-field profile correction; retained `23946da` results remain
separate. A new exact-candidate XHigh Standards/Spec pass is required before push.
Actual native Open, required PNG, finalized export and hosted CI remain HOLD.

## Verified ARM Open and supervisor child-exit failure

[Run 41127194059](https://github.com/Dunky13/Cadence/actions/runs/41127194059)
on `710a1c4` fails both native jobs and `ci-required`; packaging is skipped.
The signed candidate's direct Sol 6.1 XHigh Standards/Spec validation found no
source findings, independently passed 298 focused contracts plus 26 supplemental
checks per revision, and approved the exact push. Source review did not establish
native acceptance.

Both new consumer archives match GitHub metadata:

- arm64: `5d79dabca72bafd291c69d0008153f551bf3983d64267650a047f0aeeffb081c`.
- Intel: `df4a5377c1644cdf30cfb17309f850c6856ed9450b09b7a4043455c43884f40e`.

ARM now records `verified-normal-open` with the exact binding nonce. The native
test, cleanup, collection and bridge all exit zero. Its diagnostic after the
startup timeout reports a PNG recognized by sips, no remaining owned product,
and a zombie system launcher. The PNG's creation time and pixels were not
retained, so rendering within the original deadline and visual acceptance remain
HOLD. The optional read-only screenshot observation remains unavailable; this is
separate from the authoritative controller and required product PNG.

A native local reproduction using only nonexistent app targets leaves the
supervisor alive with its exited child a zombie in all three trials. A sample
of the exact owned supervisor shows its main thread blocked in sigwait. The
existing native launcher tests exercised held children and cancellation, but
not an ordinary child exit. A new production-helper regression releases the
invalid-target CLI's output back-pressure and requires prompt exit, exact child
status and reaping. It fails against `710a1c4` and passes after the repair.

The supervisor now repeatedly checks waitpid(WNOHANG), retaining the existing
pending-signal/stop handling and a bounded ten-millisecond interval instead of
depending on process-directed SIGCHLD waking that thread. It mirrors the child
status and reaps normally. No launcher arguments, live custody checks, 45-second
supervisor safety alarm, public trust gate or thirty-second startup loop changes.
The native launcher contracts now pass 93 cases, including natural exit,
TERM/INT/HUP/KILL, owned outer teardown and foreign-process exclusion. No local
app or UI was launched.

Intel fails before readiness on this run, with test exit 143 after owned stop
and incomplete attachment export. It does not reach the product launch. The
retained bootstrap flags do not establish its last initialization phase; the
previous process-query failure is a different observed boundary. Existing Apple
CloudKit retries recover before this failure. No authentication or permission
grant is attempted.

Fixed-vocabulary bootstrap stages now also use nonce-bound stdout frames. On
readiness failure the parent retains only the highest known stage, or
unavailable, in its existing HOLD reason, even if xcresult cannot finalize.
Foreign nonces and unknown stage values remain excluded. A ready stage alone
never satisfies the separate exact Ready handshake. The existing eight stage
attachments, permissions, readiness deadline, cleanup and upload allowlist are
unchanged. Stage-output and four synthetic readiness cases cover this diagnostic
boundary; lifecycle contracts now pass 79 cases. Intel's native root cause and
both exact-head product outcomes remain HOLD pending new hosted evidence.

The full local `scripts/ci.sh` passes on the repair: 59 Swift tests with real
launchd integration, native arm64 app build, sandbox-preserving QA compilation,
all workflow/signing/recovery/publication contracts, 93 launcher, 79 lifecycle,
63 first-open, 71 filtering/privacy and the stage/protocol/export checks. Final
native launcher and stage/static checks pass again after strengthening the
natural-exit test to require the child PID to be absent, excluding zombies.
No local native UI or public product execution is claimed. Fresh XHigh review
and both hosted product outcomes are required before acceptance.

## Both native product startups pass; observer finalization remains held

[Run 41130939129](https://github.com/Dunky13/Cadence/actions/runs/41130939129)
on `09dbad1` demonstrates normal product launch, demo render and exit within the
original startup loop on both architectures. Both exported native PNGs were
inspected and show the expected read-only Cadence demo screen. This establishes
the product-startup improvement from the supervisor repair. Both native jobs
and `ci-required` still fail, and packaging skips, because observer qualification
does not finalize. It is not a passing native installation qualification.

Both consumer archives match GitHub metadata:

- arm64: `3631b52bddc668cb457b8774f6c50328c3f90dd3a64b5be73263cd2f4d5a38fa`.
- Intel: `a2218e28b299cff212e0d91e137af519bc80dc6ae403d6ea75749f53aaed1c23`.

Both final statuses retain original startup exit zero, test exit 143, cleanup
zero, collection one and bridge zero. Both passed readiness, so the older Intel
readiness/process-query failures do not describe the current failure. No finalized
Open action record survives the interrupted export. The precise in-flight XCTest
operation at termination is not established by retained diagnostics; it must not
be invented from the successful PNG.

The source continued its optional three-sample sequence after the verified
normal Open had returned and retained its action record. Parent shutdown on
product exit could then overlap later capture queries; capture also lacked stop
checks between those queries. The new exact-production loop regression reproduces
that unnecessary post-Open sampling against the parent. The controlled first-open
path now completes sampling after successful Open record retention. Read-only
mode and an unfinished confirmation retain all three original samples. Controller
or record errors still propagate as failures. Initial outer stop checks covered owner, surface, snapshot and image-call
boundaries. The internal-await cancellation gap found in independent review and
its repair are recorded below; the initial guards alone were incomplete.

Enabled first-open qualification now explicitly requires the safely exported
regular, non-symlink `first-open.json` with exactly the verified action and the
current nonce. Missing, malformed, wrong-action, foreign-nonce, extra-key, array, FIFO and symlink records
hold qualification even with a valid PNG and otherwise successful test/export.
Optional read-only imagery remains separate. A fixed completion-frame diagnostic
records only observed/not-observed/unavailable in the existing HOLD reason, to
distinguish an unfinished test from later finalization on future failures. It is
not an acceptance input. The startup log now calls a failure observer qualification
rather than attributing every controller/export failure to owned teardown.

No deadline is increased: thirty-second product startup, thirty-five readiness
iterations, forty-five-second launcher safety and the existing teardown grace
remain. Candidate/launcher/Apple-owner identity, quarantine/signature/ticket gates,
complete confirmation text, unique enabled Open, cancellation and verified export
remain mandatory. No raw log, new uploader or permission configuration is added.

Focused checks pass: 11 exact-loop session cases, 29 capture cases, 95 lifecycle/
authority cases, 63 first-open cases, 71 filtering/privacy cases, 25 export,
27 attachment, 26 broker, 12 IPC client, eight stage states and 110 workflow cases.
The session loop contract is integrated into full CI. The complete expensive suite
and 59 Swift/app tests are not repeated for this QA/control-only increment; the
full `09dbad1` repair evidence remains separate. A fresh sandbox-preserving QA
compile and static checks pass. A fresh exact-candidate XHigh review is required
before push. Hosted finalized action/export proof, both complete native jobs,
universal packaging and `ci-required` remain HOLD.

## XHigh internal image-cancellation finding and repair

The direct Sol 6.1 XHigh review of `1ecb86e` found no separate Standards issue,
but withheld Spec/source approval for one P2. The image caller's stop check ran
after the whole awaited helper returned. Stop during shareable-content discovery
still allowed frame/image capture, and stop during screenshot capture still
allowed a new snapshot query. The candidate was held locally and never pushed.
The reviewer independently passed 515 cases/states and 34 supplemental proof/
export cases, but those passes did not cover or excuse the helper gap.

The helper now checks stop internally at entry, before discovery, after each
await and before subsequent frame/image/snapshot work. The capture caller
explicitly rethrows typed observer cancellation instead of treating it as an
optional image error. Ordinary unavailable-image errors retain their existing
optional behavior. No permission request, screen-capture authorization change,
new acceptance route or deadline increase is introduced.

A new inert contract extracts the exact production isolated-image and window-ID
helpers, rather than replacing the image helper with one stub. It reproduces
both reported parent paths and five additional cancellation boundaries. All
15 cases pass after repair: seven cancellation paths issue no later work,
baseline encoding still succeeds, and absent existing permission, ambiguous or
mismatched windows, changed tree/owner and editable/authority content remain
refused. No native image/capture API or UI is invoked. The fixture has its own
eight-second safety alarm and is integrated into CI. Outer capture cases now
pass 31, including typed helper cancellation propagation and ordinary image-error
handling. Session 11, first-open 63 and filtering/privacy 71 cases pass; static
checks and a fresh sandbox-preserving QA build pass on the repair.

This fixes the source-supported P2. It does not establish the operation killed
in hosted run 41130939129 or native finalization on the next candidate. Both
parent-run product startups/PNGs remain established progress; safely finalized
Open proof, complete native jobs, packaging and `ci-required` remain HOLD.
A new exact-candidate XHigh pass is required before the existing-PR push.

## Remaining gates and cleanup

The candidate requires independent Sol 6.1 XHigh Standards and Spec validation,
then hosted arm64 and Intel verification of the same quarantined public
installation, exact normal Open action, demo PNG, final evidence export and
`ci-required`. These are HOLD until observed on the exact repaired head. If the
run fails, continue diagnosis and repair in this PR without weakening its gates.

Temporary raw-log collection/upload and its public certificate are removed.
The bounded filtered confirmation artifact remains the diagnostic path.
Pre-existing protected keys and private evidence retain their ownership and
remain outside Git until evidence closure. No plaintext client log, private key
or machine-local evidence path belongs in committed content.
Task-owned disposable builds and probes are removed after checks/review;
ignored validation logs and the offline HTML handoff remain local evidence.

No merge, Apple submission, public release or deployment is authorized or
performed. The daily change-aware scheduling policy is already implemented and
covered by the release-selection contracts, but is not live until merge.
The endpoint is a signed, DCO-signed, pushed update of PR #11. Inspect checks
from a repository checkout with `gh pr checks 11 --repo Dunky13/Cadence`.

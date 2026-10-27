# Cadence unattended Apple release handoff

The user authorized the full endpoint, including immutable public publication, and private reuse of the existing Apple-signing files and Keychain entries. PRs #3–#7 are merged. Exact main CI [40422749060](https://github.com/Dunky13/Cadence/actions/runs/40422749060) passed at automation `8b2d4a13c480c935b7855921452a09f48bd4c1b6`. Automatic [release40424220654](https://github.com/Dunky13/Cadence/actions/runs/40424220654) preserved the original build15 and Apple submissions and published immutable [v0.2.0](https://github.com/Dunky13/Cadence/releases/tag/v0.2.0). Both public native consumers passed installed-app Gatekeeper assessments but timed out at LaunchServices. That run failed; completion was skipped. Full runtime qualification is still held.

## Frozen product and tested automation

| Binding | Exact value |
| --- | --- |
| Initial frozen source | `be4551332fb7f2b37bf8e11a50a02f27177b8f37` |
| Product source | `850f8c219bdb094e324a3d47e27ff0dfb21ca103` |
| Product main CI | [40388627719](https://github.com/Dunky13/Cadence/actions/runs/40388627719), successful; version 0.2.0/build 15 |
| Credential-free build artifact | `12682676360`, `Cadence-macOS-universal-850f8c219bdb094e324a3d47e27ff0dfb21ca103` |
| Build artifact digest | `sha256:018949eab48217c2136ef238c009b00eda6b2daa6e8bde55a31f96d0fd421e37` |
| Previously qualified automation | `b1bc254df2817ed0b90dd441f1ebcad4d47a3588`; main CI [40398201193](https://github.com/Dunky13/Cadence/actions/runs/40398201193) successful |

Keep build 15 throughout recovery. New automation builds are separate CI output and cannot replace it. Automation and frozen product use separate clean pinned checkouts. Differing automation requires its own successful exact main-push CI and `ci-required`; product metadata/resources, receipts, submitted bytes, manifest, tag and publication remain bound to the original product source. The protocol is documented in [RELEASING.md](../RELEASING.md).

## Acceptance and security boundaries

Cadence uses SwiftPM, arm64+x86_64 universal binaries, macOS 14 minimum, bundle `dev.cadence.app`, committed numeric stable versions and an app-before-DMG submission topology. There is no self-update feed or independent update-signing key. Existing Developer ID team `U9GXK89565`, Apple tickets, Gatekeeper and GitHub immutable release authority remain unchanged.

The initial live snapshot had reviewer-free, main-only `apple-signing` and `production`, four public identity variables, no Apple secrets, no branch protection/rulesets, immutable releases disabled and no releases/tags. Authorized one-time changes established strict `ci-required` from Actions app 15368 with administrator enforcement and conversation resolution, version-tag update/deletion prohibition and immutable releases. Both environments remain main-only and reviewer-free; there was no recurring reviewer rule to remove. No unrelated environment changed.

Three Apple secrets were privately provisioned only in `apple-signing`, matching the existing identity. Builds/tests receive no Apple credentials. Signing uses an isolated temporary keychain, exact original search-list restoration and verified cleanup before promotion. No extra Administration-read credential is required: repository immutability was configured once, and publication must prove actual immutable status plus exact tag/bytes. No quarantine removal, Gatekeeper bypass or synthetic Apple evidence is permitted.

## Actual Apple evidence

| Stage | UUID | Submitted filename | Submitted SHA-256 |
| --- | --- | --- | --- |
| App | `eba3799b-070e-441c-9e04-8207074971da` | `Cadence-App-0.2.0-build-15-universal.zip` | `6c3992e2ea08c60ca8c1059c7dde7b8c87af9d0f0f087ad8fc921c5a939f4859` |
| Installer | `23d500e5-82c6-4bd0-aa9a-955eb07b2ea5` | `Cadence-Installer-0.2.0-build-15-universal.dmg` | `c1b354bb760cc49db9373fbaff7229548f807535c6b1c929124f27e7fe28e9c9` |

Both are Accepted. Retained diagnostics and independent read-only actual Apple info/log observations matched each stage's UUID, filename and submitted hash. The app's prepare/upload owner is run 40402517059 attempt 1; the installer's is 40404926154 attempt 1. Original submitted bytes are retained separately from stapled/repacked final downloads.

Automatic [run 40402517059](https://github.com/Dunky13/Cadence/actions/runs/40402517059) signed and submitted the app, obtained Accepted diagnostics, then failed installer preparation at ticket validation: exit 68, `NSURLErrorDomain -1005`, Apple CloudKit connection lost. Checkpoint 12689553461 retained the exact submission. Fresh no-input [run 40404926154](https://github.com/Dunky13/Cadence/actions/runs/40404926154) restored it before credentials, skipped fresh unsigned download and reused the same app UUID/hash/owners. It passed all nine distribution phases, actual app/DMG tickets/signatures/Gatekeeper, installed-copy binding, demo startup and credential cleanup before promotion.

That run failed immediate publication reconciliation after creating draft release `424798674`. A later API read found the exact bot-owned draft and no assets. Its canonical marker matches all four files in signed artifact `12691387271`, digest `sha256:aea4dd3acfeae32317d9843ab0815470a5c6041da66dab955ec2f0d3e20057f1`. Delayed list visibility is consistent with this evidence; the discarded POST response does not establish the precise service mechanism.

Fresh [run 40406885893](https://github.com/Dunky13/Cadence/actions/runs/40406885893) restored both Accepted stages unchanged, then failed another validation of the retained stapled app with the same CloudKit connection-loss diagnostic. Latest checkpoint `12691592412`, digest `sha256:25968247763fd84c9b1a121fb65a6a693340bfee5c65a295c43c9e13155f927c`, retains both original submissions and final candidate state. No additional Apple submission or publication occurred. Do not bypass validation because an earlier owner passed it.

## Failure repairs and focused validation

- Release 40382196574 failed before credentials because Actions preserved a version-directory layout. PR #4 narrowly accepts that layout while verifying ZIP consistency, complete extracted trees, immutable digest and downstream identity/slices. Its independent review found one P2, separately closed by root against unchanged witnesses; exact-head and main CI passed.
- Release 40390664671 encountered a keychain lookup failure and Bash 3.2 bare conditionals masked later phase errors; promotion still blocked. PR #5 added explicit exits, unique isolated signing-identity preflight, provider-time/run/phase checkpoint ordering and separately tested automation/product checkouts. Independent review at `c38f173962fb63d0a392e2e9b8f5df16be18c892` reported no actionable findings, 381 focused contracts and six extra selector witnesses; exact-head and main CI passed. The precise original identity-lookup mechanism remains unproven, while subsequent hosted signing passed.
- PR #6 cleanup/failure guards passed 38 source-context and 110 exact-YAML contracts and all four hosted CI jobs at `82dc65f4b3032dc2d71d977df42e7f7dc04cce96`, run [40406411218](https://github.com/Dunky13/Cadence/actions/runs/40406411218). Earlier run 40401378527 was deliberately cancelled for release capacity; its failed aggregate is preserved as cancellation fallout.
- The ticket follow-up runs the real validation command at most three times, with two-second delays, only for exit 68 plus the observed -1005 diagnostic and exact Apple production CloudKit lookup URL. Other failures stop immediately; exhaustion preserves failure; cleanup/output/delay failures reject. All nine validation sites use the wrapper. Staple mutations, submissions, byte bindings and all trust/install gates remain intact. The implementation's initial 70 ticket, 19 DMG and 20 release-recovery contracts are synthetic and do not qualify Apple. Root also passed 97 publication contracts, including delayed draft visibility followed by same-draft recovery without another create call.
- Independent source review at `979cfa30422d8bafe38c8c58a58c495a5f61dd5f` reported one P2: a handled signal during stdout replay discarded pending stderr. Root reproduced the unchanged witness, retained pending output until both streams were replayed, and made cleanup finish while preserving an existing failure or recording a newly arriving signal. The expanded 106 ticket contracts pass, covering both replay streams and cleanup under HUP/INT/TERM with both shell modes. The original review remains changes-required at its reviewed head; targeted root closure is separate evidence. Repaired-head hosted CI remains required before merge.

## Automatic recovery after PR #6 and the next repair

Main CI [40415764741](https://github.com/Dunky13/Cadence/actions/runs/40415764741) passed all four jobs at `90fcecd523011f3b7c0d1da7a96aeca229689b47`. Its build22 artifact did not replace the frozen product/build15. Scheduled [run40415788026](https://github.com/Dunky13/Cadence/actions/runs/40415788026) occurred before that CI passed and correctly failed the exact automation-origin guard before credentials. Automatic workflow_run [40417401093](https://github.com/Dunky13/Cadence/actions/runs/40417401093) then restored the retained candidate and passed all nine real distribution/trust/install/credential-cleanup phases. Both Accepted UUIDs, submitted hashes and owners stayed unchanged. Signed artifact12694344672 has exactly the same digest `sha256:aea4dd3acfeae32317d9843ab0815470a5c6041da66dab955ec2f0d3e20057f1` as artifact12691387271. Latest finish checkpoint12694369536 has digest `sha256:a287cd92575bd02d9bb13756607933d2960b81550c47e9b827995e356bf2a132`.

Publication stopped before uploads because the actual draft HTML URL is `https://github.com/Dunky13/Cadence/releases/tag/untagged-c22da6ef9564ef894853`, whereas the metadata predicate required the final stable URL even for a draft. The draft ID, owner, source/build/origin marker and all four final hashes still match. The repair permits the canonical URL or the observed same-repository `untagged-` route with exactly20 lowercase hexadecimal characters for a draft only. Published metadata must still have the exact stable tag URL and `.immutable:true`. Candidate/asset/tag/ownership checks, mutation order and permission scope stay intact. The publisher never follows the draft HTML URL. A captured real API response rejects under the old predicate and accepts under the corrected predicate using intercepted transport, with zero provider mutations; synthetic provider fixtures now model the observed URL.

A separate local retained-installer probe on macOS27.0.1/arm64 passed actual ticket/signature/Gatekeeper assessments and preserved quarantine and all four file hashes. LaunchServices waited for the normal first-open confirmation and timed out; no local startup success is claimed, no approval was granted, and quarantine was retained. Its translocated test process escaped the old path-only cleanup and was terminated using its exact unique snapshot arguments; the unrelated running Cadence instance was untouched. Cleanup now requires the same unique snapshot arguments plus the original or expected translocated Cadence executable. Eight exact-cleanup-body synthetic cases cover normal/translocated owned instances, unrelated/lookalike/disappeared processes, spaced paths and success/failure status under both shell modes. The startup timeout, Gatekeeper/LaunchServices gates and consent behavior remain unchanged.

Local checks passed 108 publication, eight startup-cleanup and20 release-recovery contracts plus ShellCheck, Bash3.2 syntax, actionlint and whitespace checks. These are synthetic/source checks. The repairs still require exact-head CI/source review and a successful tested-main automation owner before live continuation. The existing draft, original submitted bytes and both Accepted UUIDs must be reused.

Independent review at `911f961141627d873e12d0107dedd5c273d85400` found one P3 in the cleanup test driver: it re-enabled errexit, so its requested `+e` cases were not distinct. Root added an in-driver assertion that reproduced the missing mode, then preserved the requested mode while retaining nounset/pipefail. All eight cases now pass with the actual mode asserted. The reviewer reported no P0–P2 production finding and passed 22 focused URL/state probes. The original P3 verdict and targeted root closure remain separate; no independent re-review is claimed.

## Recovery and remaining work

Use a fresh scheduled or no-input dispatch owner after the repair's successful exact main CI; do not rerun stale GitHub jobs. Attempts greater than one are rejected before credentials/network work. Restore current immutable custody, both existing UUIDs and original submitted bytes. An ambiguous upload remains held for UUID/history reconciliation; missing history or expired custody never authorizes resubmission. Ninety-day retention applies.

Release `424798674` is now public and immutable. Do not create another release, replace the tag or recreate submitted artifacts. Recovery must verify its canonical marker, exact public bytes and `.immutable:true`; only the same candidate may complete qualification. Signed custody `12698094129` has outer ZIP digest `sha256:dfa106f84fc8bc6b0532d7a0bcd398584d683ac56c28d3a6a7098e0966ea2eb0`; all four inner hashes match the independently downloaded public assets:

| Asset | Public ID | SHA-256 |
| --- | --- | --- |
| Cadence-App-0.2.0-universal.zip | 679902125 | `e6f45f90d66a707f458a46dfb54f94483be117699c789392ab2dfb310d1e27e6` |
| Cadence-Installer-0.2.0-universal.dmg | 679902195 | `6fe5ac05bc5019016f1e37fcec23a2bd22dc2fad45ed2860a9ddeb9efbbc49bf` |
| SHA256SUMS | 679902250 | `a4a003ddd24717de919d4010c21839c1f100c0ef0ac59fc28309bb9f2e7e6f67` |
| distribution.json | 679902310 | `b791793da107e83c5a12806f65bf6629ef3ddfbeea7db7d0307b14eabd91f694` |

The actual arm64 job121927398357 and Intel job121927398378 both downloaded these public bytes without credentials, added browser-style quarantine and passed tickets/signatures/Gatekeeper before the30-second launch timeout. Hosted cause is not yet confirmed. A separate same-byte local probe records a first-open consent wait, but it does not establish hosted prompt identity. No consent was granted or security setting changed. Completion121927772175 correctly stayed skipped.

The current diagnostic change captures metadata/signing identity/hash, unchanged quarantine, exact owned launch/process/snapshot state, read-only GUI/automation status and Cadence-scoped policy events before cleanup. Diagnostic collection cannot change the original failing exit status or approve UI. The next tested-main continuation must reuse the same public release, candidate bytes and both submission UUIDs. First collect actual hosted failure evidence; consider one strictly bound ordinary Open interaction only if an existing authorized UI capability and exact normal prompt are established. Do not override a warning, change TCC/security settings, alter quarantine or substitute a direct-binary launch.

Remaining endpoint gates are both actual native public LaunchServices startups, completion custody and strict final recovery/publication verification. Minimum-macOS14 runtime remains unrun; macOS15 does not establish that fact.

Safe frozen settings, raw logs, exact custody archives and independent diagnostics are local chat deliverables outside version control. The final chat report provides their actual paths and hashes. Its standalone HTML stays local-only. Preserve original failures and distinguish source/local checks, hosted CI, actual Apple/trust gates and public-consumer qualification.

# Cadence macOS releases

Cadence is a Swift Package Manager app (`dev.cadence.app`) targeting macOS 14 or later. `build-app.sh` produces arm64 and x86_64 slices and combines them into one universal app. The installer is a drag-and-drop DMG containing the app, an Applications shortcut and installation instructions. It installs no privileged helper. Replacing the app preserves user LaunchAgents and logs.

## Release policy

A successful **macOS CI** main-push run automatically starts **Release latest main**. The release controller accepts only this repository's main-push CI, its exact successful `ci-required` aggregate, and its single universal build artifact ID and SHA256 digest. Main must be protected. Pull-request, fork, failed and skipped CI origins cannot sign.

The committed `CFBundleShortVersionString` in `Resources/Info.plist` is the stable `MAJOR.MINOR.PATCH` release intent. Change it on main to ship the next stable version. A version already published is a no-op when there is no pending candidate. Every new candidate must be newer than all published stable releases. CI's run number supplies `CFBundleVersion`, binding the app build to its original CI run. Recovery keeps that build number. There is no automatic version bump or prerelease channel.

The release workflow does not compile again. It verifies and promotes the bytes from the original credential-free CI run. The CI artifact, receipts and release state are retained for 90 days. A fifteen-minute schedule and no-input manual dispatch continue interrupted candidates. The oldest active candidate is completed before newer work. GitHub job/workflow reruns are rejected before credentials because they can replay stale successful-preflight outputs. Recovery uses a fresh scheduled run or `gh workflow run release.yml --ref main`, which selects current custody; routine continuation requires no click. Expired or missing custody fails closed; it does not authorize rebuilding or resubmitting an unresolved stage.

Signing and publication run automation from the pinned workflow commit and read product metadata and installer instructions from a separate clean `.release-source` checkout at the original product commit. The workflow sets `AUTOMATION_COMMIT` and `RELEASE_SOURCE_DIRECTORY`; both checkouts must match their pins and remain clean. If automation differs from the product source, its exact successful main-push CI and `ci-required` aggregate are required too. This lets tested automation repairs resume old artifacts and receipts without rebuilding them or changing the product source, version/build, tag or submitted bytes. Direct local use without split context still requires the exact product HEAD. Artifact IDs are opaque; custody ordering uses provider creation timestamps, producer run order and explicit stage order.

Cadence has no self-update feed, Sparkle key or separate update-signing authority. Stable trust remains the configured Developer ID team, Apple's notarization tickets, Gatekeeper and the repository's immutable release assets. This pipeline does not introduce an alternative trust key.

## CI gate

`ci-required` requires both native macOS runners (`macos-15` arm64 and `macos-15-intel` x86_64) and universal packaging. `ci.sh` runs Actionlint, ShellCheck, Bash syntax, focused failure contracts, Swift tests including real GUI LaunchAgent lifecycle tests, and a native app build. The universal job builds both slices and verifies the mounted installer and copied app. CI selects Xcode 26.3 explicitly. A missing GUI launchd domain fails the integration gate.

Keep main's required check bound to the GitHub Actions app, with strict branch freshness. Version tags must not permit updates or deletion. Enable GitHub immutable releases before publication. Immutable releases are enabled once in repository settings and enforced by GitHub when publication occurs. Verify that setting with an authorized administrator during initial qualification and after an intentional policy change. The workflow token has no Administration-write permission and cannot disable it. The publisher requires `.immutable: true` and exact public-byte/tag readback before reporting success. This keeps the existing GitHub administrator as policy authority and needs no additional per-release administrative credential.

## Credentials and environments

Both `apple-signing` and `production` permit only main. Routine releases have no deployment reviewers or wait timers. Merge policy remains separate. Only signing phase steps receive Apple credentials. Publication has a separate `contents: write` job in `production`, with no Apple secrets.

Configure these values in the `apple-signing` environment through a secure secret channel:

| Kind | Name | Meaning |
| --- | --- | --- |
| Secret | `APPLE_DEVELOPER_ID_P12_BASE64` | Base64 Developer ID Application identity and private key |
| Secret | `APPLE_DEVELOPER_ID_P12_PASSWORD` | P12 password |
| Secret | `APPLE_NOTARY_KEY_P8` | App Store Connect API private key PEM |
| Variable | `APPLE_SIGNING_IDENTITY` | Existing Developer ID Application identity |
| Variable | `APPLE_TEAM_ID` | Corresponding team ID |
| Variable | `APPLE_NOTARY_KEY_ID` | API key ID |
| Variable | `APPLE_NOTARY_ISSUER_ID` | API issuer UUID |

The credential wrapper creates an isolated temporary keychain, grants codesign access, restricts lookup to that keychain and requires exactly one valid configured Developer ID identity before invoking a phase. It removes private material from the child environment, restores and verifies the original search list, and deletes temporary credentials after success, failure or handled cancellation. It does not change the default/system keychain. Cleanup failure blocks advancement and promotion.

## Durable Apple stages

The distribution workflow runs one phase at a time:

```text
verified CI artifact
  prepare → checkpoint → app-claim → checkpoint → app-submit → checkpoint → app-wait
  → checkpoint → installer-prepare → checkpoint → installer-claim → checkpoint → installer-submit
  → checkpoint → installer-wait → checkpoint → finish → checkpoint
  → credential cleanup verified → exact signed-artifact upload
```

All checkpoints are immutable Actions artifacts. The envelope binds source SHA, origin CI run/artifact/digest and the state archive hash. Restoring verifies the artifact download digest, envelope, member paths and archive hash before extraction. Existing receipts are explicitly marked restored while retaining their original prepare owner. A restored durable upload claim is separately marked so it cannot authorize another upload. Artifact names alone carry no authority: checkpoint and completion markers must originate in the trusted main release workflow.

Phase bodies explicitly propagate terminal exit codes, including on macOS Bash 3.2; they do not rely on a bare conditional and shell errexit. A terminal failure skips later phases while always-retained failure checkpoints remain available. Exit 75 records pending state without readiness; only successful finish emits readiness.

Each v2 receipt binds source, bundle, version/build, architecture, team, origin CI artifact, descriptive submitted name, submitted SHA256, release run/attempt and stage. Existing v1/unbound or mismatched receipts are refused. Process locks serialize local access; workflow concurrency serializes hosted candidates. The successful checkpoint upload before each submission is mandatory.

1. `prepare` signs the exact verified app using Developer ID, hardened runtime and timestamps. It retains the original signed app and `Cadence-App-VERSION-build-BUILD-universal.zip`, then writes a submission intent.
2. `app-claim` assigns a fresh upload owner only to an unclaimed, unattempted prepared artifact. The workflow persists the claim before the separate upload step. A restored prepared artifact is therefore safe to claim without requiring nonexistent Apple history. A restored claim can be reclaimed only if the exact prior GitHub run/attempt proves the distinct upload step was skipped with no start time. Started, missing or ambiguous step evidence cannot authorize another upload.
3. `app-submit` uploads a fresh, same-owner claim once with `--no-wait`, atomically retaining the UUID promptly. An attempted/restored intent cannot upload again. A missing UUID requires exactly one history match and a final diagnostic log with the same archive name and SHA256. Missing or ambiguous history remains unresolved.
4. `app-wait` uses the UUID for info, a finite wait and diagnostic retrieval. Pending returns 75 for automatic scheduled continuation. Accepted requires matching UUID, status, filename and SHA256 in Apple's diagnostic log. Rejection and mismatched proof fail, retaining diagnostics.
5. `installer-prepare` copies and staples the accepted app, validates its ticket/signature/Gatekeeper result, then packages and signs the enclosing DMG. It retains separate original submitted bytes and writes the installer intent. Existing prepared bytes are verified and reused without signing or packaging again.
6. `installer-claim`, `installer-submit` and `installer-wait` apply the same submit-once and Accepted/log gates to `Cadence-Installer-VERSION-build-BUILD-universal.dmg`.
7. `finish` staples a separate DMG copy, validates tickets and signatures, assesses Gatekeeper, mounts read-only, checks copied-app identity against the retained app, and launches the installed app through LaunchServices in read-only demo/snapshot mode. It recreates the final ZIP from the stapled app and verifies its contents. Submitted bytes are never stapled in place.

Raw notary client output and signing keys are outside the checkpoint allowlist. Safe receipts and diagnostic logs are retained on failure. Stapling changes bytes: submitted hashes are distinct from final download hashes. No phase strips quarantine or disables Gatekeeper.

Ticket validation uses `scripts/validate-apple-ticket.sh`. It permits at most three actual `xcrun stapler validate` attempts, separated by two-second delays, only for exit 68 with the observed `NSURLErrorDomain Code=-1005` connection loss and exact Apple production ticket-delivery CloudKit lookup URL. Each attempt's diagnostics remain visible; interrupted replay may repeat a stream to retain both streams before cleanup. Success requires a real validation exit 0 and verified scratch cleanup; other failures stop immediately and exhausted retries retain the failure. Stapling mutations and notarization submissions are not retried by this wrapper.

## Transactional publication and consumer proof

Draft metadata may use the exact stable tag URL or GitHub's observed same-repository `untagged-` route with a 20-character lowercase hexadecimal suffix. The release ID, bot ownership, source/build/origin, canonical marker, tag and asset bytes remain authoritative; the publisher never follows the draft HTML URL. Published metadata must still use the exact stable URL and report `.immutable:true`.

Publication custody requires `PUBLICATION_STATE_DIRECTORY` outside the distribution payload. The workflow owns its durable upload/restore. A standalone operator must preserve that directory before retrying. Unbound or missing terminal failure evidence never authorizes deleting an uncertain upload.

The public asset set remains exactly:

- `Cadence-App-VERSION-universal.zip`
- `Cadence-Installer-VERSION-universal.dmg`
- `SHA256SUMS`
- `distribution.json`

The manifest includes source, version/build, bundle, architecture, signing team, original CI artifact binding, final trust checks, both Apple UUIDs and submitted hashes/names. The publisher validates canonical checksums and provenance, creates only a missing same-source version tag, and creates an automation-owned draft with a canonical candidate marker binding all four asset hashes.

### Read-only launch UI telemetry

The public consumer optionally observes the existing ordinary LaunchServices flow through an independent ad-hoc QA fixture and XCTest session. It never rebuilds/re-signs the product or performs UI actions. This session is restricted to hosted macOS15 with selected Xcode26.3 and a current read-only automationmodetool status explicitly stating authentication is not required. Preparation occurs before the original30-second launch deadline. Native CI compiles the fixture with `scripts/build-launch-ui-observer.sh` (build-for-testing only); local UI-test execution is not part of validation.

`LAUNCH_UI_BUILD_DIR` selects a unique private QA build; `LAUNCH_UI_EVIDENCE_DIR` selects a separate initially absent private evidence directory. The public verifier derives expected executable SHA256/version/build from the downloaded, verified public app/manifest. The session validates copied and owned translocated code and observes actual Apple-signed system-window owners using read-only queries. It does not classify a button or establish that an observed system window belongs to the product. Missing authority, authentication/permission UI, partial queries, or timeout remains explicit unavailable/HOLD evidence. Observer unavailability preserves the startup result. Unverified owned-helper teardown blocks otherwise-successful qualification, preserves an existing failure and retains private session control for diagnosis.

Each observation records completeness separately from image availability. Owner/window limits, unavailable queries, changed owners and missing safe capture surfaces prevent OBSERVED; incompleteness in any sample persists across the session. Failed process enumeration, argument/state lookups or system-window discovery throw explicit unavailable errors. Successful enumeration with no owned process remains a verified absence. If product startup succeeded but observer teardown failed, qualification fails with separate observer HOLD and the valid PNG remains the sole consumer artifact; no product-startup failure TXT is added.

`Cadence-Consumer-ARCH-RUN-ATTEMPT` retains its original one-PNG-or-one-failure-text topology. Only separate `Cadence-LaunchUI-ARCH-RUN-ATTEMPT` artifacts contain allowlisted status/bindings, safe selected UI trees and window PNGs. No raw environment, Xcode logs, test plans, secrets or client output is uploaded. Selected tree fields exclude editable text, values and identifiers; any selected label/title, child or depth truncation produces HOLD. Windows with editable input are not screenshotted. Capture uses ScreenCaptureKit's isolated window surface, bound by unique window ID, owner PID and frame, with unchanged safe tree and owner checks after capture. It requires existing screen-capture authorization, never requests access and omits the PNG on missing authorization, ambiguity or a changing window. Desktop-cropped XCTest element screenshots are prohibited because overlapping windows can expose unrelated pixels. All observations require manual source/evidence interpretation; no source or synthetic success establishes actual Apple or native runtime acceptance.

After verified observer teardown and before private-control deletion, `scripts/capture-observer-bootstrap.sh` optionally writes separate `bootstrap.json` through that same pinned LaunchUI uploader's explicit allowlist. Its only inputs are the owned private client log, owned session plan and reaped numeric client exit. A single system Perl process, using core modules, reads at most 1 MiB per input under a 12-second deadline (at most two additional seconds for failure cleanup). It rejects symlinks, nonregular files, multiple links and changed file identities, uses nonblocking/no-follow opens and publishes complete JSON atomically without overwriting an occupied path. Private scratch is exclusive and removed on handled signals and failure; failed cleanup revokes its output. Missing tools, unverified teardown, nonnumeric client status or failed capture leave this diagnostic unavailable and preserve all existing startup/observer results.

The bootstrap schema contains fixed signature flags for protocol, runner connection/launch, test-bundle load/signature, destination/plan, authorization and query errors. These are lexical observations in sampled bytes, not diagnoses. Plan fields report only whether the two private protocol variable names appear in the sample; they do not prove key layout, values or delivery to the test host. Missing/unsafe/unreadable/changed inputs and truncation are explicit. Digests cover only sampled bytes, never an asserted full-log hash. No raw strings, environments, plan values, xcresults, images or additional logs enter this JSON. Empty, unknown or truncated data cannot establish absence or a cause. `status:HOLD`, `cause:UNKNOWN`, and false runtime acceptance, authority and causality remain explicit even with a numeric zero client exit or recognized signature. This helper makes no queries of the UI, permissions, security settings or providers and cannot qualify the product or turn observer status green.

Known capture failures revoke the helper's published inode before private pending/scratch cleanup. A forced exit from stalled private cleanup can leave unuploaded scratch, but the final JSON is already revoked when that revocation is available. Combined post-publication signals/errors and stalled cleanup are covered under both shell modes; the failure budget and original caller results remain unchanged.

Apple's [desktop-independent window filter](https://developer.apple.com/documentation/screencapturekit/sccontentfilter/init(desktopindependentwindow:)) describes the isolated capture surface. Geometry and text filtering have inert policy contracts; only a hosted native observation can qualify the actual window/capture path.

`publish-release.sh --resume TAG DIRECTORY` allows automatic reconciliation of that exact candidate. An existing draft must match repository, source, build, CI artifact, bot ownership and every existing byte. Only missing allowlisted assets are uploaded. Conflicting, extra, duplicate, completed or nonempty assets are never overwritten or deleted. An allowlisted zero-byte `starter` from the automation bot is eligible for cleanup only with a persisted, candidate-bound terminal HTTP 502 receipt for that exact asset ID, name and intended hash. GitHub documents this upstream-failure state as abandoned and safe to delete. Unknown, lost-response and potentially active uploads remain untouched even if a GET reports empty. After the abandonment proof, cleanup rechecks the owned mutable draft and asset metadata and reconciles a lost DELETE response by ID. No conditional DELETE support is assumed. Safe publication receipts are uploaded on failure and restored by immutable artifact ID/digest on continuation; raw responses and tokens are excluded. After complete draft-byte verification, the publisher publishes once, reads back `.immutable: true`, resolves the tag again and compares all public bytes. A lost create/upload/publish response is reconciled before any further mutation. An already-published matching immutable candidate is verified and treated as complete.

Credential-free native arm64 and Intel consumer jobs independently download the public URLs, verify checksums/provenance and the original signing team, add browser-style quarantine, mount/copy/assess the installer, and launch its installed app through LaunchServices using `--demo --snapshot`. Native startup snapshots are retained as evidence. A completion marker is written only after both consumer jobs pass. Consumer failure leaves the candidate eligible for automatic verification/recovery; it does not replace the release.

On a failed launch, the existing evidence upload also retains `startup-failure-ARCH.txt` before owned-process cleanup. It records app metadata/signing identity and executable digest, quarantine without modifying it, the launcher and only demo processes with the exact private snapshot arguments, snapshot availability, existing GUI/automation status and two minutes of Cadence-specific Gatekeeper policy events. The policy reader has a 20-second deadline. Failed or unavailable diagnostic reads are labeled; they never turn startup into acceptance or change the original exit status. Handled signals during diagnostics finish owned teardown and preserve an existing failure. A successful trust assessment can still be followed by normal first-open consent. Diagnostics do not approve that consent, change UI permissions, remove quarantine or substitute a direct executable launch.

Hosted macOS 15 checks do not establish macOS 14 qualification. Synthetic provider contracts establish source behavior, not Apple acceptance, real signing-key cleanup, Gatekeeper success or public publication. See the [implementation handoff](handoffs/apple-release-automation.md) for the initial freeze and outstanding qualification.


Provider contracts: [release asset upload and terminal 502 recovery](https://docs.github.com/en/rest/releases/assets#upload-a-release-asset); [conditional requests are unsupported for unsafe methods unless documented](https://docs.github.com/en/rest/using-the-rest-api/best-practices-for-using-the-rest-api#use-conditional-requests).

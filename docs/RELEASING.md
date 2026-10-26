# Cadence macOS releases

Cadence is a Swift Package Manager app (`dev.cadence.app`) targeting macOS 14 or later. `build-app.sh` produces arm64 and x86_64 slices and combines them into one universal app. The installer is a drag-and-drop DMG containing the app, an Applications shortcut and installation instructions. It installs no privileged helper. Replacing the app preserves user LaunchAgents and logs.

## Release policy

A successful **macOS CI** main-push run automatically starts **Release latest main**. The release controller accepts only this repository's main-push CI, its exact successful `ci-required` aggregate, and its single universal build artifact ID and SHA256 digest. Main must be protected. Pull-request, fork, failed and skipped CI origins cannot sign.

The committed `CFBundleShortVersionString` in `Resources/Info.plist` is the stable `MAJOR.MINOR.PATCH` release intent. Change it on main to ship the next stable version. A version already published is a no-op when there is no pending candidate. Every new candidate must be newer than all published stable releases. CI's run number supplies `CFBundleVersion`, binding the app build to its original CI run. Recovery keeps that build number. There is no automatic version bump or prerelease channel.

The release workflow does not compile again. It verifies and promotes the bytes from the original credential-free CI run. The CI artifact, receipts and release state are retained for 90 days. A fifteen-minute schedule and no-input manual dispatch continue interrupted candidates. The oldest active candidate is completed before newer work. GitHub job/workflow reruns are rejected before credentials because they can replay stale successful-preflight outputs. Recovery uses a fresh scheduled run or `gh workflow run release.yml --ref main`, which selects current custody; routine continuation requires no click. Expired or missing custody fails closed; it does not authorize rebuilding or resubmitting an unresolved stage.

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

The credential wrapper creates an isolated temporary keychain, grants codesign access and removes private material from the child environment. It restores and verifies the original search list and deletes temporary credentials after success, failure or handled cancellation. It does not change the default/system keychain. Cleanup failure blocks advancement and promotion.

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

Each v2 receipt binds source, bundle, version/build, architecture, team, origin CI artifact, descriptive submitted name, submitted SHA256, release run/attempt and stage. Existing v1/unbound or mismatched receipts are refused. Process locks serialize local access; workflow concurrency serializes hosted candidates. The successful checkpoint upload before each submission is mandatory.

1. `prepare` signs the exact verified app using Developer ID, hardened runtime and timestamps. It retains the original signed app and `Cadence-App-VERSION-build-BUILD-universal.zip`, then writes a submission intent.
2. `app-claim` assigns a fresh upload owner only to an unclaimed, unattempted prepared artifact. The workflow persists the claim before the separate upload step. A restored prepared artifact is therefore safe to claim without requiring nonexistent Apple history. A restored claim can be reclaimed only if the exact prior GitHub run/attempt proves the distinct upload step was skipped with no start time. Started, missing or ambiguous step evidence cannot authorize another upload.
3. `app-submit` uploads a fresh, same-owner claim once with `--no-wait`, atomically retaining the UUID promptly. An attempted/restored intent cannot upload again. A missing UUID requires exactly one history match and a final diagnostic log with the same archive name and SHA256. Missing or ambiguous history remains unresolved.
4. `app-wait` uses the UUID for info, a finite wait and diagnostic retrieval. Pending returns 75 for automatic scheduled continuation. Accepted requires matching UUID, status, filename and SHA256 in Apple's diagnostic log. Rejection and mismatched proof fail, retaining diagnostics.
5. `installer-prepare` copies and staples the accepted app, validates its ticket/signature/Gatekeeper result, then packages and signs the enclosing DMG. It retains separate original submitted bytes and writes the installer intent. Existing prepared bytes are verified and reused without signing or packaging again.
6. `installer-claim`, `installer-submit` and `installer-wait` apply the same submit-once and Accepted/log gates to `Cadence-Installer-VERSION-build-BUILD-universal.dmg`.
7. `finish` staples a separate DMG copy, validates tickets and signatures, assesses Gatekeeper, mounts read-only, checks copied-app identity against the retained app, and launches the installed app through LaunchServices in read-only demo/snapshot mode. It recreates the final ZIP from the stapled app and verifies its contents. Submitted bytes are never stapled in place.

Raw notary client output and signing keys are outside the checkpoint allowlist. Safe receipts and diagnostic logs are retained on failure. Stapling changes bytes: submitted hashes are distinct from final download hashes. No phase strips quarantine or disables Gatekeeper.

## Transactional publication and consumer proof

Publication custody requires `PUBLICATION_STATE_DIRECTORY` outside the distribution payload. The workflow owns its durable upload/restore. A standalone operator must preserve that directory before retrying. Unbound or missing terminal failure evidence never authorizes deleting an uncertain upload.

The public asset set remains exactly:

- `Cadence-App-VERSION-universal.zip`
- `Cadence-Installer-VERSION-universal.dmg`
- `SHA256SUMS`
- `distribution.json`

The manifest includes source, version/build, bundle, architecture, signing team, original CI artifact binding, final trust checks, both Apple UUIDs and submitted hashes/names. The publisher validates canonical checksums and provenance, creates only a missing same-source version tag, and creates an automation-owned draft with a canonical candidate marker binding all four asset hashes.

`publish-release.sh --resume TAG DIRECTORY` allows automatic reconciliation of that exact candidate. An existing draft must match repository, source, build, CI artifact, bot ownership and every existing byte. Only missing allowlisted assets are uploaded. Conflicting, extra, duplicate, completed or nonempty assets are never overwritten or deleted. An allowlisted zero-byte `starter` from the automation bot is eligible for cleanup only with a persisted, candidate-bound terminal HTTP 502 receipt for that exact asset ID, name and intended hash. GitHub documents this upstream-failure state as abandoned and safe to delete. Unknown, lost-response and potentially active uploads remain untouched even if a GET reports empty. After the abandonment proof, cleanup rechecks the owned mutable draft and asset metadata and reconciles a lost DELETE response by ID. No conditional DELETE support is assumed. Safe publication receipts are uploaded on failure and restored by immutable artifact ID/digest on continuation; raw responses and tokens are excluded. After complete draft-byte verification, the publisher publishes once, reads back `.immutable: true`, resolves the tag again and compares all public bytes. A lost create/upload/publish response is reconciled before any further mutation. An already-published matching immutable candidate is verified and treated as complete.

Credential-free native arm64 and Intel consumer jobs independently download the public URLs, verify checksums/provenance and the original signing team, add browser-style quarantine, mount/copy/assess the installer, and launch its installed app through LaunchServices using `--demo --snapshot`. Native startup snapshots are retained as evidence. A completion marker is written only after both consumer jobs pass. Consumer failure leaves the candidate eligible for automatic verification/recovery; it does not replace the release.

Hosted macOS 15 checks do not establish macOS 14 qualification. Synthetic provider contracts establish source behavior, not Apple acceptance, real signing-key cleanup, Gatekeeper success or public publication. See the [implementation handoff](handoffs/apple-release-automation.md) for the initial freeze and outstanding qualification.


Provider contracts: [release asset upload and terminal 502 recovery](https://docs.github.com/en/rest/releases/assets#upload-a-release-asset); [conditional requests are unsupported for unsafe methods unless documented](https://docs.github.com/en/rest/using-the-rest-api/best-practices-for-using-the-rest-api#use-conditional-requests).

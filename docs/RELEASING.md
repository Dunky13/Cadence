# macOS installers and distribution

Cadence ships as a universal macOS app and a drag-and-drop DMG. The same executable contains Apple Silicon and Intel slices and targets macOS 14 or later. Only macOS jobs are configured in CI.

## Build a local installer

From the repository root, with Xcode's Swift 6 toolchain and `jq` installed:

```sh
./scripts/package-macos.sh universal
```

The verified outputs are:

- `dist/packages/0.2.0-universal-local/Cadence-Installer-0.2.0-universal-local.dmg`
- `dist/packages/0.2.0-universal-local/Cadence-App-0.2.0-universal-local.zip`
- `SHA256SUMS` and `build-manifest.json` in that same directory.

The directory and filenames follow the version in `Resources/Info.plist`. Local artifacts are ad-hoc signed and are **not notarized**. Their manifest explicitly records this, the source commit when available, and whether the source is dirty. An uncommitted checkout records a null commit rather than inventing provenance.

Open the DMG and drag **Cadence.app** onto **Applications**. Quit an existing copy before replacing it, then open the installed app and eject the image. App replacement preserves user LaunchAgents, their enabled states, job metadata, and log files. The installer does not run scripts or install a privileged helper.

Packaging builds both architectures, checks the actual slices, creates an HFS+ UDZO image, verifies its checksum, mounts it read-only, checks the Applications shortcut, copies the app into a temporary Applications directory, verifies both app signatures, and detaches the owned mount. It does not modify the real Applications directory during validation. Image creation retries at most three times, with two seconds between attempts, exclusively for the exact `hdiutil: create failed - Resource busy` diagnostic. Other errors stop immediately.

Existing local package output is replaced only after a complete new package set passes verification. The lower-level `scripts/package-dmg.sh` refuses an existing output unless `--force` is explicit, and preserves an existing file if image creation fails.

## CI

`.github/workflows/ci.yml` runs on pull requests, pushes to main, manual dispatch, and reusable workflow calls:

1. Native `macos-15` (Apple Silicon) and `macos-15-intel` jobs select Xcode 26.3, validate shell/workflow files, exercise packaging/signing/notarization failure contracts, run all Swift tests including isolated real LaunchAgents, and compile a native app.
2. A universal job builds both slices, packages the app and DMG, and verifies mounted/copy installation. It retains ad-hoc test packages for seven days.
3. `ci-required` passes only when both native jobs and universal packaging succeed. A failed, cancelled, or skipped dependency cannot yield a successful aggregate gate.

Checkout, upload, and download actions are pinned to verified full commit SHAs. Checkout credentials are not persisted. PR CI has read-only repository permissions and receives no Apple credentials. GUI-domain lifecycle tests are required rather than silently skipped if a runner cannot provide the logged-in launchd domain.

For the same native checks locally, install `shellcheck`, `actionlint`, and `jq`, then run:

```sh
./scripts/ci.sh
```

The lifecycle tests create and remove only uniquely named disposable jobs. The credential and notarization contracts use synthetic commands and never contact Apple.

## Signed and notarized distribution

`.github/workflows/distribution.yml` is a **manual main-branch workflow** and a reusable stage of the production release pipeline. Select its `authorize_notarization` checkbox to request a standalone signed distribution. It reruns the complete reusable CI workflow, downloads that run's immutable universal artifact ID, verifies the exact clean commit and checksum manifest, and only then loads signing credentials in the `apple-signing` environment. This workflow alone does not publish a GitHub release.

The signing job explicitly selects Xcode 26.3, matching Hikyo's working notary client. The selected version is available on both configured hosted runner images: [Apple Silicon](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-arm64-Readme.md) and [Intel](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-Readme.md). The local validation host used Xcode 27.1; hosted execution with Xcode 26.3 remains a separate check.

Set up the `apple-signing` GitHub environment before dispatching this workflow. Allow the `main` branch for standalone distributions and production releases. Configure the desired required reviewer in repository Settings. Credentials use the same names as Agent Job Queue:

| Kind | Name | Value |
| --- | --- | --- |
| Secret | `APPLE_DEVELOPER_ID_P12_BASE64` | Base64-encoded Developer ID Application certificate and private key in a P12 |
| Secret | `APPLE_DEVELOPER_ID_P12_PASSWORD` | P12 export password |
| Secret | `APPLE_NOTARY_KEY_P8` | App Store Connect API private key as PEM text |
| Variable | `APPLE_SIGNING_IDENTITY` | Full Developer ID Application identity name |
| Variable | `APPLE_TEAM_ID` | Ten-character Apple team ID |
| Variable | `APPLE_NOTARY_KEY_ID` | Ten-character App Store Connect key ID |
| Variable | `APPLE_NOTARY_ISSUER_ID` | App Store Connect issuer UUID |

Keep private values out of command arguments, repository files, and chat. With `CERTIFICATE_P12` and `NOTARY_PRIVATE_KEY_P8` pointing to existing secure files, the installed GitHub CLI accepts:

```sh
repo=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
openssl base64 -A -in "$CERTIFICATE_P12" |
  gh secret set APPLE_DEVELOPER_ID_P12_BASE64 --repo "$repo" --env apple-signing
gh secret set APPLE_DEVELOPER_ID_P12_PASSWORD --repo "$repo" --env apple-signing
gh secret set APPLE_NOTARY_KEY_P8 --repo "$repo" --env apple-signing < "$NOTARY_PRIVATE_KEY_P8"
```

The password command prompts for its value. Set the four public variables through the same environment's Settings, or `gh variable set NAME --repo "$repo" --env apple-signing` using its interactive value prompt. These instructions do not export a private key from a keychain or bypass its access controls.

The signing wrapper imports the identity into a private temporary keychain, grants codesign access, removes raw credentials from the child environment, and restores the original user keychain search list on success, error, or cancellation. It does not change the default or system keychain. Cleanup failures fail the operation.

The distribution sequence is:

1. Verify both app slices and source provenance, copy the app privately, and sign its executable and bundle with Developer ID, hardened runtime, and a secure timestamp.
2. Submit **`Cadence-App-<version>-universal.zip`**. Retain its ID and submitted SHA256 before the finite wait. Require Accepted plus a matching Apple diagnostic log, then staple and validate the app and assess it with Gatekeeper.
3. Build **`Cadence-Installer-<version>-universal.dmg`** containing that stapled app and the Applications shortcut. Sign and submit this descriptively named DMG separately, require the same verified acceptance, and staple/validate/assess it.
4. Mount the final signed image, verify the mounted and drag-copied app, create the final ZIP from the stapled app, and generate final checksums and distribution metadata in a private candidate directory. `SHA256SUMS` covers the final ZIP, DMG, and `distribution.json`; the metadata identifies the commit, version/build, bundle, signing team, architecture, and CI run. Only after the credential wrapper has verified keychain cleanup does a separate workflow step recheck the checksums and promote the complete output directory.

Finished artifacts appear under `dist/release`. Nothing is promoted there after a rejection, pending result, missing/mismatched diagnostic, failed ticket/Gatekeeper check, or cleanup error. The workflow retains successful distributions for 30 days, and retains safe receipts/verified diagnostic logs from `dist/notarization` for 30 days even on failure. Private P12/P8 material and raw client output are outside the retained paths.

Apple's history will show Cadence, the version, architecture, and submission stage instead of generic `installer.zip` or `submit.zip` entries. The app ZIP submitted before stapling and the final ZIP containing the stapled app have different bytes; the receipt records the submitted hash, while final `SHA256SUMS` records distributed bytes.

## Production releases

`.github/workflows/release.yml` provides **Release latest main**, a manual workflow with **no inputs**. In GitHub Actions, select this workflow, choose `main`, and click **Run workflow**. From a checkout of this repository, the equivalent is:

```sh
gh workflow run release.yml --ref main
```

Preflight checks out the latest remote `main` when the job starts, pins its exact SHA, and reads `CFBundleShortVersionString` from `Resources/Info.plist` to derive `vMAJOR.MINOR.PATCH`. Every native test, universal build, signing job, manifest, and publication uses that selected SHA, even if `main` advances or the dispatch event names an older commit. Dispatching workflow code from another branch fails before distribution. Production no longer starts on tag pushes and does not require a pre-created tag.

The version must already be an unused stable version on `main`; this workflow does not change source or bump versions. A published release or draft for that version blocks the run before Apple submission, as does a tag pointing to another commit. Older or equal published stable versions cannot be released again. An existing tag is reusable only when it identifies the selected commit and has no release or draft.

The production flow is:

1. Select and record the latest main SHA and app version. Validate main ancestry, any existing tag, and release eligibility with read-only permissions.
2. Call the distribution workflow to run both native CI jobs, build the universal app and installer, sign, notarize, staple, verify mounted/copied installation, and clean credentials. Recheck production eligibility immediately before loading Apple credentials.
3. Transfer the signed distribution by the immutable artifact ID returned from that same run. Missing IDs fail rather than downloading an arbitrary artifact set.
4. Enter the `production` environment in a separate publication job. This is the only job with `contents: write`; it receives no Apple credentials. Recheck release eligibility, validate the exact four-file payload, manifest provenance, and canonical checksums. Create a missing lightweight version tag through GitHub's API, targeting only the selected SHA, then fetch and verify it. Conflicting tags are never forced or replaced. A tag API failure stops the run without automatic retry; reconcile remote state before trying again.
5. Create a draft release with generated release notes. Upload only the universal DMG, app ZIP, `SHA256SUMS`, and `distribution.json`. Download the draft assets and compare their bytes with the verified local payload before publishing a stable release marked Latest. Read back the published metadata, tag, and asset bytes, and record the release URL in the job summary.

Production runs are serialized across versions, and signing is serialized with standalone distributions. An older version cannot replace a newer stable release as Latest. Existing releases and assets are never overwritten. A failed upload or verification leaves its draft for diagnosis; it does not publish a partial release. An error after publication is reported as a failed readback, not rolled back or silently republished.

Before the first release:

1. Push the source and workflows to `main` and verify hosted CI. Require `ci-required` in branch protection.
2. Configure the `apple-signing` environment and credentials above, permitting `main` deployments.
3. Configure a `production` environment permitting `main` and the desired release reviewer. Ensure repository Actions policy permits the publication job's `contents: write` token. No separate publication PAT is required.
4. Protect version tags from updates/deletion with repository rulesets while allowing the Actions token to create release tags. Enable GitHub immutable releases where available. Environment reviewers should verify the selected source SHA in the preflight summary and the exact artifacts from that run.

After the intended version and workflows are on `main`, running the workflow starts the full flow through publication, subject to the configured environment approvals. Successful output is a stable GitHub release containing `Cadence-Installer-<version>-universal.dmg`, `Cadence-App-<version>-universal.zip`, `SHA256SUMS`, and `distribution.json`. The ZIP and DMG contain the bundled Cadence icon.

Do not blindly rerun after a timeout, partial signing run, or failed publication. First inspect retained notarization receipts and any draft. Resolve pending Apple UUIDs before another submission. Reconcile a failed draft explicitly; the helper refuses to reuse or overwrite it. A manually dispatched run still executes all gates and submits fresh artifacts, so it is not a resume command. No automatic upload/submission retries are added by the production workflow.

The scripts' synthetic contract tests exercise publication without creating real tags, Apple submissions, drafts, or releases. GitHub's draft lifecycle is documented in [release creation](https://cli.github.com/manual/gh_release_create) and [release editing](https://cli.github.com/manual/gh_release_edit).

## App icon

`Resources/Cadence.icns` contains all standard macOS icon sizes, from 16 pixels through 1024 pixels. `build-app.sh` copies this checked-in asset into every app bundle before signing; `CFBundleIconFile` already points to it. `Resources/Cadence.png` is the 1024-pixel transparent preview. The menu bar retains a monochrome template waveform for native light/dark rendering.

To regenerate both assets on macOS from the AppKit artwork:

```sh
swift scripts/make-icon.swift Resources/Cadence.icns Resources/Cadence.png
```

No network access or image-generation service is required. Commit both assets when changing the artwork.

## Pending or failed Apple submissions

`notarize-artifact.sh` submits once without waiting, records the UUID and CI run/attempt, then waits with a 30-minute timeout. It does not automatically resubmit. Existing receipts and a per-stage exclusive lock prevent duplicate use of the same evidence directory. Keep the receipt if a wait times out: Apple may still be processing it.

For an existing local notary keychain profile, after setting `NOTARY_KEYCHAIN_PROFILE` to its actual name and `SUBMISSION_ID` to the retained UUID:

```sh
xcrun notarytool info "$SUBMISSION_ID" --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" --output-format json
xcrun notarytool wait "$SUBMISSION_ID" --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" --timeout 30m --output-format json
```

Resolve that submission before requesting another signed build. A valid Developer ID signature alone is not notarization acceptance. No ad-hoc fallback is used in the signed workflow.

## Latest-main pipeline validation

Validated locally on 2026-10-26 with Xcode 27.1 on Apple Silicon:

- `./scripts/ci.sh` passed: Actionlint, ShellCheck, Bash syntax, all 166 synthetic contracts (19 DMG, 14 credentials, 36 notarization, 12 artifact handoff, 36 release preflight, 49 publication), all 59 Swift tests including both real LaunchAgent lifecycle tests, and a native app build.
- `./scripts/package-macos.sh universal` passed: Apple Silicon and Intel compilation, exact executable slices, mounted installer layout, drag-copy app signature, and the app/installer/manifest checksums.
- Iconutil decoded all ten standard icon representations. The universal app's icon exactly matched the checked-in ICNS, and its bundle metadata selected that icon. The transparent 1024-pixel PNG was visually inspected.
- `git diff --check` passed. No application behavior or Swift package code changed.

Repository configuration was checked read-only: there were no GitHub environments and no repository Actions secrets or variables configured. Create `apple-signing` and `production` and supply the documented signing credentials before dispatching a production release. This change was validated locally; hosted CI, Developer ID signing, Apple acceptance, stapling/Gatekeeper, and public release publication were not executed. The locally built installer is ad-hoc signed and not notarized. Native Intel execution remains a hosted CI gate.

## Initial implementation validation

Local validation passed on Apple Silicon, macOS 27.0.1, Xcode 27.1:

- All 59 Swift tests, including both real launchd lifecycle tests, passed during the preceding installer work. Swift code is unchanged by the production pipeline addition.
- 140 synthetic release contracts: 19 DMG, 14 credential cleanup, 36 notarization, 10 artifact handoff, 22 production tag preflight, and 39 publication cases. These were rerun for the production pipeline change.
- Actionlint, ShellCheck, Bash syntax, and Git whitespace checks.
- Both architectures compiled; the universal installer was verified, mounted, drag-copied, and checked for exact architecture slices and valid ad-hoc signatures. Checksums for the ZIP, DMG, and build manifest passed.
- The drag-copied app launched on Apple Silicon in read-only demo mode, rendered its native interface to a PNG, and exited successfully. Its temporary mount was detached. macOS logged a nonfatal sandbox-extension diagnostic; no quarantine or security settings were changed.

The local host has no Rosetta translation available, so Intel execution was not claimed; native Intel execution belongs to the configured hosted Intel job. Current hdiutil commands work locally but emit deprecation notices on macOS 27; they are retained for compatibility with the supported older macOS hosts.

Pushing the app and workflows activates hosted CI; its exact results belong to the pull request and workflow run. Apple signing secrets/variables and both release environments must be configured before production use. No Apple submission or public release was performed during local validation. The provided local DMG is ready for local installation and review. The first Apple acceptance and public publication remain separate verification gates after CI and repository setup.

References: [Apple notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow), [GitHub macOS runner labels](https://docs.github.com/en/actions/reference/runners/github-hosted-runners), [Apple Silicon runner image](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-arm64-Readme.md), [Intel runner image](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-Readme.md), and [Agent Job Queue descriptive naming](https://github.com/Dunky13/agent-job-queue/pull/29).

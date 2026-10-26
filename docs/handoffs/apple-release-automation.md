# Cadence unattended Apple release handoff

Delivery: [PR #3](https://github.com/Dunky13/Cadence/pull/3).

Baseline: `be4551332fb7f2b37bf8e11a50a02f27177b8f37`, frozen 26 October 2026. The user explicitly authorized the full unattended endpoint, including immutable public publication. Scope is this repository's Apple release path. No other project's environment or stable authority is changed.

The initial live snapshot established reviewer-free, main-only `apple-signing` and `production` environments, four public identity variables, zero environment/repository Apple secrets, no branch protection or rulesets, immutable releases disabled, no release/distribution runs and no tags/releases. Existing hosted CI run [40330172283](https://github.com/Dunky13/Cadence/actions/runs/40330172283) passed at the baseline, with universal artifact `12655193214`, digest `sha256:9fb7673fea0799522c5c0f80eaf554f698c815d7c95ee6971326e3093e41ce00`. That artifact is ad-hoc signed and supplies no Apple proof.

Authorized one-time settings were applied and read back: strict `ci-required` from GitHub Actions app 15368 on main with administrator enforcement and conversation resolution; version-tag update/deletion prohibition; immutable releases enabled. Environment branch restrictions and isolated secrets were preserved. There was no reviewer rule to remove.

The implementation preserves Swift universal builds, numeric committed stable versions and app-before-DMG notarization. It adds passed-CI promotion without rebuilding, bound retained state, submit-once recovery, scheduled continuation, matching Accepted diagnostics, mandatory tickets/signatures/Gatekeeper/installed demo startup, immutable draft reconciliation, and native public consumer verification. The protocol and operator interface are in [RELEASING.md](../RELEASING.md).

The user subsequently authorized reuse of existing Apple-signing files and corresponding Keychain entries. All three Cadence Apple secrets were privately configured after matching the existing public identity; no credential value or plaintext file was exposed. Actual hosted signing, both Apple submissions, same-candidate provider recovery, stapling, public installation and publication remain unqualified. GitHub documents Administration read for the immutable-policy API, which the workflow token cannot request. Policy reads now use a separate Cadence-only read credential in `production`; publication keeps `GITHUB_TOKEN`. That read credential is a remaining provisioning dependency.

Safe source/live-setting captures and raw test evidence are local chat deliverables, not repository content. The final chat report provides their actual location and source/run/submission/asset inventory. Do not invent provider IDs or treat fake-provider test results as Apple evidence. Checkpoint custody expires after 90 days; expiration requires explicit reconciliation and never authorizes replacing submitted bytes.


Integrated review at `c722b9a9d484af5a2e65ad6c2c71a67897374c98` reported four findings, not a clean verdict. The repairs introduce a separate durable upload-claim step and narrowly proven unstarted-step recovery, select the newest authoritative checkpoint before evaluating expiry, recover only owned empty `starter` uploads, and isolate the Administration-read policy credential. Focused regression evidence and a fresh review must qualify those repairs before merge. An upload whose execution remains ambiguous is intentionally held for UUID/history reconciliation; missing history alone never permits a new upload.

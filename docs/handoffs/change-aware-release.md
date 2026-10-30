# Change-aware release and native CI repair

## Scope and behavior

The release timer changes from every fifteen minutes to daily at 05:23 UTC.
Successful trusted-main CI still starts release selection immediately. Automatic
runs skip distribution, publication and installation when the same automation
commit already reached distribution, whether that attempt passed or failed.
Preflight-only failures/skips do not suppress a later successful CI event.
An intentional no-input dispatch can retry unchanged code using current retained
custody; candidate bytes, Apple UUIDs and publication reconciliation stay intact.

The user authorized one narrowly verified ordinary Cadence first-open Open
action. The controller requires the public executable identity, unique stopped
product/snapshot process, exact LaunchServices launcher, no competing Cadence
processes or pre-existing consent window, and the unique Apple-signed system
dialog owner. Complete allowlisted normal text and exactly Cancel/Open buttons
are mandatory. It rechecks identities and the dialog tree before clicking once.
Unknown dialogs, warnings, missing controller readiness and terminal controller
failure block qualification. Quarantine, Gatekeeper, signing and permissions are
preserved. The original thirty-second demo snapshot requirement remains.

Hosted native PR/main CI now exercises this same consumer flow against the
immutable public v0.2.0/build15 fixture, without signing credentials, signing
environments or write permissions. This checks installer automation before main;
it does not qualify newly built product bytes. Safe allowlisted evidence includes
the controller action separately from product startup evidence.

## Failure evidence and review

[Release run 41066003103](https://github.com/Dunky13/Cadence/actions/runs/41066003103)
repeated automation commit `7d48bf6ddebb00914c08782ff2bffab35e34002e`.
Both consumers passed trust checks, then timed out with no native snapshot.
The arm64 witness records the exact owned translocated product stopped in state
T; XCTest exited 65 without readiness. The diagnostic cause remains UNKNOWN.
This evidence does not establish the hosted prompt identity or bootstrap cause.

Independent Standards and Spec reviews found that controller rejection could
remain optional if the product later produced its PNG. The real finish callback
and outer EXIT cleanup reproduced that failure. The repair makes enabled
controller failure authoritative while retaining optional read-only telemetry
semantics and preserving the single product-evidence artifact. Both independent
re-reviews accepted the repair at source tree
`36dc0dcf5ee9927f54aedeb0cf0e0d93bb0c9dff`, with no further source findings.

## Validation and remaining gates

PR #11's initial hosted run 41071030513 failed: arm64 passed trust gates but
XCTest still exited 65 before readiness; Intel exhausted the existing bounded
retries after repeated Apple CloudKit connection losses. The arm64 bootstrap
flags remain UNKNOWN. Compile-only inspection confirmed the generated runner,
fixture paths and test-host environment injection. No plan mismatch is proven.
An additional optional `session-stage.json` records only eight fixed bootstrap
states around candidate verification, the screen session, system-window queries
and readiness. It cannot change controller results and contains no client text,
environment, plan values or runtime acceptance. This probe does not fix or
classify the underlying hosted failure; it identifies the reached boundary.
The exact enum/writer passes all eight fixed states plus nil, missing and
occupied-output cases. The 139 bootstrap privacy/signal contracts and updated
QA compilation pass. Independent incremental Standards and Spec reviews found
no production issue. Standards identified a non-owned missing-directory test
fixture; root replaced it with an absent child of the owned temporary directory
and verified it remains absent. No independent re-review of that small fixture
repair is claimed.

Local focused checks pass: 50 release-selection contracts, 21 inert consent
controller cases, 27 dialog-policy cases, 55 observer lifecycle/cleanup cases,
21 inert capture cases, 139 bootstrap privacy/deadline/signal cases, ShellCheck
and actionlint. The full local CI script passed on arm64/macOS 27.0.1/Xcode 27.1,
including 59 Swift tests with real launchd integration, the native app build,
and all signing/recovery/publication contracts. Final changed observer sources
also passed build-for-testing; no local UI session or product launch was run.
The final controller/outer-cleanup cases were rerun after the review repair.

Hosted arm64 and Intel controller readiness, actual verified normal Open and
native startup are required before describing the CI failure as repaired.
Synthetic cases and compile-only checks do not establish those outcomes.
Any hosted failure must be diagnosed and repaired in the same PR. Public release
qualification/completion, publication, Apple submissions, merge and deployment
are not performed by this implementation task.

After merge, an intentional release recovery uses the installed GitHub CLI from
the repository root: `gh workflow run release.yml --ref main`. This is a release
operation, separate from this PR's credential-free CI validation; do not run it
as a substitute for the native PR checks.

Task failure witnesses and standalone HTML handoff are local ignored evidence;
they are not committed. Disposable helper builds and test scratch must be removed
after local validation, while retaining source-review and failure evidence.

#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $(uname -s) == Darwin ]] || { echo 'macOS is required.' >&2; exit 1; }
architecture=${CI_EXPECTED_ARCH:-$(uname -m)}
[[ $(uname -m) == "$architecture" ]] || { echo 'Runner architecture does not match the matrix.' >&2; exit 1; }
for tool in shellcheck actionlint jq; do command -v "$tool" >/dev/null || { echo "Missing prerequisite: $tool" >&2; exit 1; }; done
xcodebuild -version
swift --version
shellcheck -x scripts/*.sh scripts/tests/*.sh
for script in scripts/*.sh scripts/tests/*.sh; do bash -n "$script"; done
actionlint .github/workflows/*.yml
./scripts/tests/apple-ticket-contracts.sh
./scripts/tests/startup-cleanup-contracts.sh
./scripts/tests/startup-failure-contracts.sh
./scripts/tests/launch-ui-observer-contracts.sh
./scripts/tests/observer-bootstrap-contracts.sh
./scripts/tests/observer-tree-contracts.sh
./scripts/tests/observer-stage-contracts.sh
./scripts/tests/observer-attachment-contracts.sh
./scripts/tests/observer-export-contracts.sh
./scripts/tests/first-open-contracts.sh
./scripts/tests/observer-capture-contracts.sh
# Compile the independent QA fixture/test runner, never execute its UI session.
observer_build=$(mktemp -d "${TMPDIR:-/tmp}/cadence-observer-ci.XXXXXX")
rmdir "$observer_build"
trap 'rm -rf "$observer_build"' EXIT
./scripts/build-launch-ui-observer.sh "$observer_build"
./scripts/tests/dmg-contracts.sh
./scripts/tests/signing-credentials-contracts.sh
./scripts/tests/phase-workflow-contracts.sh
./scripts/tests/notarization-contracts.sh
./scripts/tests/apple-release-recovery-contracts.sh
./scripts/tests/checkpoint-contracts.sh
./scripts/tests/upload-claim-contracts.sh
./scripts/tests/signing-attempt-contracts.sh
./scripts/tests/source-context-contracts.sh
./scripts/tests/artifact-download-contracts.sh
./scripts/tests/release-selection-contracts.sh
./scripts/tests/release-input-contracts.sh
./scripts/tests/release-tag-contracts.sh
./scripts/tests/publication-contracts.sh
# These tests intentionally require a real logged-in GUI launchd domain. A
# missing domain fails this gate rather than silently skipping lifecycle tests.
launchctl print "gui/$(id -u)" >/dev/null
CADENCE_LAUNCHD_INTEGRATION=1 swift test --jobs 2
./scripts/build-app.sh release "$architecture"

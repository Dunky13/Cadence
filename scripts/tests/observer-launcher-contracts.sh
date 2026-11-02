#!/bin/bash
# Native process identity and invalid-target CLI only; never launches an app/UI.
set -euo pipefail
umask 077
root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/cadence-launcher-contracts.XXXXXX")
work=$(cd "$work" && pwd -P)
trap 'rm -r -- "$work"' EXIT
swiftc -j 2 "$root/qa/LaunchUIObserver/Launcher/Identity.swift" "$root/qa/LaunchUIObserver/Launcher/main.swift" -o "$work/observer-launcher"
swiftc -j 2 -parse-as-library "$root/qa/LaunchUIObserver/Launcher/Identity.swift" \
    "$root/scripts/tests/fixtures/ObserverLauncherContracts.swift" -o "$work/contracts"
"$work/contracts" "$work/observer-launcher" "$work" "$root/scripts/launch-ui-observer.sh"

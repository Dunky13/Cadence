#!/bin/bash
# QA fixture only; never builds, re-signs, or launches the product. No UI session.
set -euo pipefail
umask 077
[[ $# == 1 && ! -e $1 ]] || exit 2
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$1"
destination=$(cd "$1" && pwd -P)
xcodebuild build-for-testing -project "$root/qa/LaunchUIObserver/LaunchUIObserver.xcodeproj" \
    -scheme LaunchUIObserver -configuration Debug -destination "platform=macOS,arch=$(uname -m)" \
    -derivedDataPath "$destination" -jobs 2 ONLY_ACTIVE_ARCH=YES CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual \
    > "$destination/build-private.log" 2>&1 || {
        printf 'QA observer build-for-testing failed; private build log retained (not uploadable).\n' >&2
        exit 1
    }
runner="$destination/Build/Products/Debug/LaunchUIObserverTests-Runner.app"
codesign -d --entitlements :- "$runner" > "$destination/runner-entitlements-private.plist" 2>> "$destination/build-private.log"
[[ $(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$destination/runner-entitlements-private.plist") == true ]] || {
    printf 'QA runner sandbox was not preserved.\n' >&2
    exit 1
}
printf 'QA observer build-for-testing passed; no UI tests or product build executed.\n'

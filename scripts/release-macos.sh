#!/bin/bash
# Explicit Developer ID signing and Apple notarization; never used by PR CI.
{ set +x; } 2>/dev/null
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."
fail() { printf 'release-macos: %s\n' "$*" >&2; exit 1; }
app='' architecture=universal output=dist/.signed-candidate evidence=dist/notarization
while [[ $# -gt 0 ]]; do
    [[ $# -ge 2 ]] || fail 'Options require a value.'
    case "$1" in
        --app) app=$2 ;;
        --architecture) architecture=$2 ;;
        --output-dir) output=$2 ;;
        --evidence-dir) evidence=$2 ;;
        *) fail "Unknown option: $1" ;;
    esac
    shift 2
done
[[ $(uname -s) == Darwin ]] || fail 'macOS is required.'
for tool in codesign xcrun ditto plutil shasum jq spctl; do command -v "$tool" >/dev/null || fail "Missing prerequisite: $tool"; done
[[ -d $app && ! -L $app && -f $app/Contents/MacOS/Cadence ]] || fail 'Supply a Cadence.app bundle.'
[[ ${APPLE_TEAM_ID:-} =~ ^[A-Z0-9]{10}$ ]] || fail 'APPLE_TEAM_ID is required.'
[[ ${APPLE_SIGNING_IDENTITY:-} == "Developer ID Application: "*" ($APPLE_TEAM_ID)" ]] || fail 'A matching Developer ID Application signing identity is required.'
[[ -n ${NOTARY_KEYCHAIN_PROFILE:-} || -f ${NOTARY_KEY_FILE:-} ]] || fail 'Notary credentials are required.'
case "$architecture" in universal) archs=(arm64 x86_64) ;; arm64|x86_64) archs=("$architecture") ;; *) fail 'Invalid architecture.' ;; esac
for arch in "${archs[@]}"; do xcrun lipo "$app/Contents/MacOS/Cadence" -verify_arch "$arch"; done
[[ $(plutil -extract CFBundleIdentifier raw "$app/Contents/Info.plist") == dev.cadence.app ]] || fail 'Unexpected bundle identifier.'
version=$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")
[[ $version =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || fail 'Invalid bundle version.'
[[ $version == "$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist)" ]] || fail 'Bundle version differs from the checked-out source.'
source_commit=$(git rev-parse --verify HEAD 2>/dev/null) || fail 'Commit the source before producing a signed distribution.'
[[ ${SOURCE_COMMIT:-${GITHUB_SHA:-$source_commit}} == "$source_commit" ]] || fail 'Source commit does not match the checkout.'
[[ -z $(git status --porcelain) ]] || fail 'Signed distribution requires a clean source checkout.'
export SOURCE_COMMIT="$source_commit"
[[ ! -e $output && ! -L $output ]] || fail 'Release output already exists; choose a fresh output directory.'
if [[ -e $evidence ]]; then
    [[ -d $evidence && ! -L $evidence && -z $(ls -A "$evidence") ]] || fail 'Notarization evidence already exists. Reconcile previous submissions before retrying.'
fi
mkdir -p "$evidence" "$(dirname "$output")"
output_parent=$(cd "$(dirname "$output")" && pwd -P)
output="$output_parent/${output##*/}"
work=$(mktemp -d "$output_parent/.cadence-release.XXXXXX")
cleanup() { result=$?; trap - EXIT; rm -rf -- "$work" || result=1; exit "$result"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
signed_app="$work/Cadence.app"
ditto "$app" "$signed_app"
chmod -R u+rwX,go+rX,go-w "$signed_app"
codesign --verify --deep --strict --all-architectures "$signed_app"
keychain=()
if [[ -n ${SIGNING_KEYCHAIN:-} ]]; then keychain=(--keychain "$SIGNING_KEYCHAIN"); fi
codesign --force --timestamp --options runtime ${keychain[@]+"${keychain[@]}"} --sign "$APPLE_SIGNING_IDENTITY" "$signed_app/Contents/MacOS/Cadence"
codesign --force --timestamp --options runtime ${keychain[@]+"${keychain[@]}"} --sign "$APPLE_SIGNING_IDENTITY" "$signed_app"
codesign --verify --deep --strict "$signed_app"
codesign --display --verbose=4 "$signed_app" 2> "$work/signature.txt"
grep -qx "TeamIdentifier=$APPLE_TEAM_ID" "$work/signature.txt" || fail 'App signature has the wrong Team ID.'
grep -q '^Authority=Developer ID Application:' "$work/signature.txt" || fail 'App is not Developer ID signed.'
mkdir "$work/submissions" "$work/distribution"
app_archive="Cadence-App-$version-$architecture.zip"
ditto -c -k --sequesterRsrc --keepParent "$signed_app" "$work/submissions/$app_archive"
./scripts/notarize-artifact.sh --archive "$work/submissions/$app_archive" --stage app --version "$version" --architecture "$architecture" --evidence-dir "$evidence"
xcrun stapler staple "$signed_app"
xcrun stapler validate "$signed_app"
codesign --verify --deep --strict "$signed_app"
spctl --assess --type execute --verbose=4 "$signed_app"
./scripts/package-dmg.sh --app "$signed_app" --output-dir "$work/distribution" --version "$version" --architecture "$architecture" --release
dmg="$work/distribution/Cadence-Installer-$version-$architecture.dmg"
codesign --force --timestamp ${keychain[@]+"${keychain[@]}"} --sign "$APPLE_SIGNING_IDENTITY" "$dmg"
codesign --verify --strict "$dmg"
codesign --display --verbose=4 "$dmg" 2> "$work/image-signature.txt"
grep -qx "TeamIdentifier=$APPLE_TEAM_ID" "$work/image-signature.txt" || fail 'DMG signature has the wrong Team ID.'
./scripts/notarize-artifact.sh --archive "$dmg" --stage installer --version "$version" --architecture "$architecture" --evidence-dir "$evidence"
xcrun stapler staple "$dmg"
xcrun stapler validate "$dmg"
spctl --assess --type open --context context:primary-signature --verbose=4 "$dmg"
./scripts/check-dmg.sh "$dmg" --architecture "$architecture" --release
ditto -c -k --sequesterRsrc --keepParent "$signed_app" "$work/distribution/$app_archive"
jq -n --arg version "$version" --arg architecture "$architecture" --arg commit "$source_commit" \
    --arg app "$app_archive" --arg installer "${dmg##*/}" \
    --arg team "$APPLE_TEAM_ID" --arg build "$(plutil -extract CFBundleVersion raw "$signed_app/Contents/Info.plist")" \
    --arg run_id "${GITHUB_RUN_ID:-}" --arg run_attempt "${GITHUB_RUN_ATTEMPT:-}" \
    '{schema:"cadence/distribution/v1",version:$version,architecture:$architecture,source_commit:$commit,
      app_archive:$app,installer:$installer,bundle_id:"dev.cadence.app",build_number:$build,team_id:$team,
      ci_run:{id:(if $run_id == "" then null else $run_id end),attempt:(if $run_attempt == "" then null else $run_attempt end)},
      signing:"Developer ID",notarization:"Accepted",tickets:"stapled and validated"}' \
    > "$work/distribution/distribution.json"
(
    cd "$work/distribution"
    shasum -a 256 "$app_archive" "${dmg##*/}" distribution.json > SHA256SUMS
    shasum -a 256 --check SHA256SUMS
)
[[ ! -e $output && ! -L $output ]] || fail 'Release output appeared during signing; refusing to replace it.'
mv "$work/distribution" "$output"
printf 'Signed and verified candidate (promote only after credential cleanup): %s\n' "$output"

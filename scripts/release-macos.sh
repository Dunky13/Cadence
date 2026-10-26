#!/bin/bash
# Each invocation is one durable phase. The caller checkpoints successful phases
# (and failures) before advancing, and owns credential cleanup and publication.
{ set +x; } 2>/dev/null
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."
fail() { printf 'release-macos: %s\n' "$*" >&2; exit 1; }
# shellcheck source=scripts/apple-stage-state.sh
source scripts/apple-stage-state.sh
promotion=''
output_lock=''
app='' architecture=universal output=dist/.signed-candidate evidence='' state=dist/apple-state phase=prepare
while [[ $# -gt 0 ]]; do
    [[ $# -ge 2 && -n $2 ]] || fail 'Options require a value.'
    case "$1" in
        --app) app=$2 ;; --architecture) architecture=$2 ;; --output-dir) output=$2 ;;
        --evidence-dir) evidence=$2 ;; --state-dir) state=$2 ;; --phase) phase=$2 ;;
        *) fail "Unknown option: $1" ;;
    esac
    shift 2
done
case $phase in prepare|app-claim|app-submit|app-wait|installer-prepare|installer-claim|installer-submit|installer-wait|finish) ;; *) fail 'Invalid release phase.' ;; esac
[[ $(uname -s) == Darwin ]] || fail 'macOS is required.'
for tool in codesign xcrun ditto plutil shasum jq spctl lipo; do command -v "$tool" >/dev/null || fail "Missing prerequisite: $tool"; done
# shellcheck source=scripts/release-source-context.sh
source scripts/release-source-context.sh
release_source_context "${SOURCE_COMMIT:-}" "$PWD"
version=$(plutil -extract CFBundleShortVersionString raw "$release_source_directory/Resources/Info.plist")
build=${BUILD_NUMBER:-$(plutil -extract CFBundleVersion raw "$release_source_directory/Resources/Info.plist")}
binding=$(apple_binding "$version" "$build" "$architecture")
[[ $state == /* ]] || state="$PWD/$state"
[[ ! -L $state ]] || fail 'State must not be a symlink.'
mkdir -p "$state"
state=$(cd "$state" && pwd -P)
# Keep the process lock outside the checkpoint: it has no durable meaning.
lock="$state.lock"
mkdir "$lock" 2>/dev/null || fail 'Another release phase owns this state.'
work=''
cleanup() {
    result=$?; trap - EXIT
    if [[ -n $work ]]; then rm -rf -- "$work" || result=1; fi
    if [[ -n $promotion ]]; then rm -rf -- "$promotion" || result=1; fi
    if [[ -n $output_lock ]]; then rmdir "$output_lock" || result=1; fi
    rmdir "$lock" || result=1
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
work=$(mktemp -d "$(dirname "$state")/.cadence-release.XXXXXX")
if [[ -z $evidence ]]; then evidence="$state/evidence"; fi
[[ $evidence == /* ]] || evidence="$PWD/$evidence"
mkdir -p "$evidence"
[[ ! -L $evidence ]] || fail 'Evidence must not be a symlink.'
evidence=$(cd "$evidence" && pwd -P)
# Compatibility flag may select a nested evidence directory; all recovery data
# must still be retained in the single checkpoint directory.
[[ $evidence == "$state/"* ]] || fail '--evidence-dir must be inside --state-dir.'
candidate="$state/candidate.json"
if [[ -e $candidate || -L $candidate ]]; then
    apple_regular "$candidate"
    jq -se --argjson binding "$binding" 'length == 1 and (.[0] |
        .schema == "cadence/apple-release-state/v2" and .binding == $binding)' "$candidate" >/dev/null \
        || fail 'Unbound, legacy, or mismatched release state.'
else
    [[ $phase == prepare && -z $(find "$state" -mindepth 1 ! -type d -print) ]] || fail 'Prepare requires fresh, bound state.'
    jq -n --argjson binding "$binding" '{schema:"cadence/apple-release-state/v2",binding:$binding}' > "$work/candidate.json"
    apple_atomic "$work/candidate.json" "$candidate"
fi
app_name="Cadence-App-$version-$architecture.zip"
dmg_name="Cadence-Installer-$version-$architecture.dmg"
submitted_app_name="Cadence-App-$version-build-$build-$architecture.zip"
submitted_dmg_name="Cadence-Installer-$version-build-$build-$architecture.dmg"
prepared="$state/prepared-app"
signed_app="$prepared/Cadence.app"
app_archive="$prepared/$submitted_app_name"
ready="$state/stapled-app"
ready_app="$ready/Cadence.app"
installer="$state/prepared-installer"
dmg="$installer/$submitted_dmg_name"
keychain=()
if [[ -n ${SIGNING_KEYCHAIN:-} ]]; then keychain=(--keychain "$SIGNING_KEYCHAIN"); fi
require_signing() {
    [[ ${APPLE_SIGNING_IDENTITY:-} == "Developer ID Application: "*" ($APPLE_TEAM_ID)" ]] \
        || fail 'A matching Developer ID Application signing identity is required.'
}
check_app() {
    local target=$1 actual
    [[ -d $target && ! -L $target ]] || fail 'Missing retained app.'
    apple_regular "$target/Contents/Info.plist"
    apple_regular "$target/Contents/MacOS/Cadence"
    [[ -x $target/Contents/MacOS/Cadence ]] || fail 'App executable is not executable.'
    [[ $(plutil -extract CFBundleIdentifier raw "$target/Contents/Info.plist") == dev.cadence.app \
       && $(plutil -extract CFBundleExecutable raw "$target/Contents/Info.plist") == Cadence \
       && $(plutil -extract CFBundleShortVersionString raw "$target/Contents/Info.plist") == "$version" \
       && $(plutil -extract CFBundleVersion raw "$target/Contents/Info.plist") == "$build" ]] || fail 'App bundle/version/build differs from candidate source.'
    actual=$(lipo -archs "$target/Contents/MacOS/Cadence")
    if [[ $architecture == universal ]]; then
        [[ $actual == 'arm64 x86_64' || $actual == 'x86_64 arm64' ]] || fail 'App slices differ from candidate architecture.'
    else [[ $actual == "$architecture" ]] || fail 'App slices differ from candidate architecture.'; fi
    codesign --verify --deep --strict --all-architectures "$target"
}
check_team() {
    local target=$1 signature
    signature=$(codesign --display --verbose=4 "$target" 2>&1)
    grep -qx "TeamIdentifier=$APPLE_TEAM_ID" <<< "$signature" || fail 'Signature has the wrong Team ID.'
    grep -q '^Authority=Developer ID Application:' <<< "$signature" || fail 'Missing Developer ID signature.'
}
notary() {
    local kind=$1 operation=$2 archive=$app_archive
    [[ $kind != installer ]] || archive=$dmg
    APPLE_NOTARY_LOCK_DIRECTORY="$lock" ./scripts/notarize-artifact.sh --archive "$archive" --stage "$kind" --version "$version" --build "$build" \
        --architecture "$architecture" --evidence-dir "$evidence" --operation "$operation"
}
check_prepared_app() {
    apple_regular "$prepared/prepared.json"
    apple_regular "$app_archive"
    jq -e --argjson binding "$binding" --arg sha "$(apple_sha "$app_archive")" \
        --arg tree "$(apple_tree_sha "$signed_app")" \
        '.binding == $binding and .archive_sha256 == $sha and .app_tree_sha256 == $tree' "$prepared/prepared.json" >/dev/null \
        || fail 'Prepared app/archive bytes or binding changed.'
    check_app "$signed_app"
    check_team "$signed_app"
}
check_ready_app() {
    apple_regular "$ready/prepared.json"
    jq -e --argjson binding "$binding" --arg tree "$(apple_tree_sha "$ready_app")" \
        '.binding == $binding and .app_tree_sha256 == $tree' "$ready/prepared.json" >/dev/null || fail 'Stapled app bytes/binding changed.'
    check_app "$ready_app"
    check_team "$ready_app"
    xcrun stapler validate "$ready_app"
    spctl --assess --type execute --verbose=4 "$ready_app"
}
check_installer() {
    apple_regular "$installer/prepared.json"
    apple_regular "$dmg"
    jq -e --argjson binding "$binding" --arg sha "$(apple_sha "$dmg")" \
        '.binding == $binding and .archive_sha256 == $sha' "$installer/prepared.json" >/dev/null || fail 'Prepared installer bytes/binding changed.'
    codesign --verify --strict "$dmg"
    check_team "$dmg"
}
case $phase in
    prepare)
        if [[ ! -e $prepared && ! -L $prepared ]]; then
            [[ ! -e $evidence/app-$architecture-receipt.json ]] || fail 'Cannot recreate an app with an existing intent.'
            check_app "$app"
            require_signing
            mkdir "$work/prepared-app"
            ditto --rsrc --extattr --qtn --acl "$app" "$work/prepared-app/Cadence.app"
            chmod -R u+rwX,go+rX,go-w "$work/prepared-app/Cadence.app"
            codesign --force --timestamp --options runtime ${keychain[@]+"${keychain[@]}"} --sign "$APPLE_SIGNING_IDENTITY" "$work/prepared-app/Cadence.app/Contents/MacOS/Cadence"
            codesign --force --timestamp --options runtime ${keychain[@]+"${keychain[@]}"} --sign "$APPLE_SIGNING_IDENTITY" "$work/prepared-app/Cadence.app"
            check_app "$work/prepared-app/Cadence.app"
            check_team "$work/prepared-app/Cadence.app"
            ditto -c -k --sequesterRsrc --keepParent "$work/prepared-app/Cadence.app" "$work/prepared-app/$submitted_app_name"
            jq -n --argjson binding "$binding" --arg sha "$(apple_sha "$work/prepared-app/$submitted_app_name")" \
                --arg tree "$(apple_tree_sha "$work/prepared-app/Cadence.app")" \
                '{binding:$binding,archive_sha256:$sha,app_tree_sha256:$tree}' > "$work/prepared-app/prepared.json"
            mv "$work/prepared-app" "$prepared"
        fi
        check_prepared_app
        notary app prepare
        ;;
    app-claim|app-submit|app-wait)
        check_prepared_app
        notary app "${phase#app-}"
        ;;
    installer-prepare)
        check_prepared_app
        notary app verify
        if [[ ! -e $ready && ! -L $ready ]]; then
            mkdir "$work/stapled-app"
            ditto --rsrc --extattr --qtn --acl "$signed_app" "$work/stapled-app/Cadence.app"
            xcrun stapler staple "$work/stapled-app/Cadence.app"
            xcrun stapler validate "$work/stapled-app/Cadence.app"
            check_app "$work/stapled-app/Cadence.app"
            check_team "$work/stapled-app/Cadence.app"
            spctl --assess --type execute --verbose=4 "$work/stapled-app/Cadence.app"
            jq -n --argjson binding "$binding" --arg tree "$(apple_tree_sha "$work/stapled-app/Cadence.app")" \
                '{binding:$binding,app_tree_sha256:$tree}' > "$work/stapled-app/prepared.json"
            mv "$work/stapled-app" "$ready"
        fi
        check_ready_app
        if [[ ! -e $installer && ! -L $installer ]]; then
            [[ ! -e $evidence/installer-$architecture-receipt.json ]] || fail 'Cannot recreate an installer with an existing intent.'
            require_signing
            mkdir "$work/prepared-installer" "$work/packaged"
            ./scripts/package-dmg.sh --app "$ready_app" --output-dir "$work/packaged" --version "$version" --architecture "$architecture" --release
            mv "$work/packaged/$dmg_name" "$work/prepared-installer/$submitted_dmg_name"
            codesign --force --timestamp ${keychain[@]+"${keychain[@]}"} --sign "$APPLE_SIGNING_IDENTITY" "$work/prepared-installer/$submitted_dmg_name"
            codesign --verify --strict "$work/prepared-installer/$submitted_dmg_name"
            check_team "$work/prepared-installer/$submitted_dmg_name"
            jq -n --argjson binding "$binding" --arg sha "$(apple_sha "$work/prepared-installer/$submitted_dmg_name")" \
                '{binding:$binding,archive_sha256:$sha}' > "$work/prepared-installer/prepared.json"
            mv "$work/prepared-installer" "$installer"
        fi
        check_installer
        notary installer prepare
        ;;
    installer-claim|installer-submit|installer-wait)
        check_prepared_app
        notary app verify
        check_ready_app
        check_installer
        notary installer "${phase#installer-}"
        ;;
    finish)
        check_prepared_app
        notary app verify
        check_ready_app
        check_installer
        notary installer verify
        if [[ ! -e $state/distribution && ! -L $state/distribution ]]; then
            mkdir "$work/distribution"
            # Staple a separate copy: never change the bytes named in the receipt.
            ditto --rsrc --extattr --qtn --acl "$dmg" "$work/distribution/$dmg_name"
            xcrun stapler staple "$work/distribution/$dmg_name"
            xcrun stapler validate "$work/distribution/$dmg_name"
            codesign --verify --strict "$work/distribution/$dmg_name"
            check_team "$work/distribution/$dmg_name"
            spctl --assess --type open --context context:primary-signature --verbose=4 "$work/distribution/$dmg_name"
            ./scripts/check-dmg.sh "$work/distribution/$dmg_name" --architecture "$architecture" --version "$version" --release
            ./scripts/verify-apple-dmg-binding.sh "$work/distribution/$dmg_name" "$ready_app"
            ditto -c -k --sequesterRsrc --keepParent "$ready_app" "$work/distribution/$app_name"
            jq -n --argjson binding "$binding" --arg app "$app_name" --arg installer "$dmg_name" \
                --arg run "$GITHUB_RUN_ID" --arg attempt "$GITHUB_RUN_ATTEMPT" \
                --slurpfile app_receipt "$evidence/app-$architecture-receipt.json" \
                --slurpfile installer_receipt "$evidence/installer-$architecture-receipt.json" '
                $binding + {schema:"cadence/distribution/v1",app_archive:$app,installer:$installer,
                ci_run:{id:$run,attempt:$attempt},signing:"Developer ID",notarization:"Accepted",
                tickets:"stapled and validated",submissions:{app:{id:$app_receipt[0].submission_id,
                sha256:$app_receipt[0].submitted_sha256,filename:$app_receipt[0].archive_filename},
                installer:{id:$installer_receipt[0].submission_id,sha256:$installer_receipt[0].submitted_sha256,
                filename:$installer_receipt[0].archive_filename}}}' > "$work/distribution/distribution.json"
            (cd "$work/distribution" && shasum -a 256 "$app_name" "$dmg_name" distribution.json > SHA256SUMS)
            mv "$work/distribution" "$state/distribution"
        fi
        # Repeated finish validates retained final bytes and all real gates again.
        ./scripts/verify-apple-distribution.sh "$state/distribution" "$binding" "$ready_app" "$app_name" "$dmg_name"
        notary app verify
        notary installer verify
        jq -e --slurpfile app_receipt "$evidence/app-$architecture-receipt.json" \
            --slurpfile installer_receipt "$evidence/installer-$architecture-receipt.json" '
            .submissions.app == {id:$app_receipt[0].submission_id,sha256:$app_receipt[0].submitted_sha256,filename:$app_receipt[0].archive_filename}
            and .submissions.installer == {id:$installer_receipt[0].submission_id,sha256:$installer_receipt[0].submitted_sha256,filename:$installer_receipt[0].archive_filename}' \
            "$state/distribution/distribution.json" >/dev/null || fail 'Manifest submission evidence changed.'
        [[ $output == /* ]] || output="$PWD/$output"
        mkdir -p "$(dirname "$output")"
        mkdir "$output.lock" 2>/dev/null || fail 'Another phase owns the candidate output.'
        output_lock="$output.lock"
        if [[ -e $output || -L $output ]]; then
            ./scripts/verify-apple-distribution.sh "$output" "$binding" "$ready_app" "$app_name" "$dmg_name"
            cmp "$state/distribution/SHA256SUMS" "$output/SHA256SUMS" || fail 'Existing candidate differs from retained distribution.'
        else
            mkdir -p "$(dirname "$output")"
            promotion=$(mktemp -d "$(dirname "$output")/.cadence-promotion.XXXXXX")
            # Track the temporary copy for cleanup on every failure.
            ditto "$state/distribution" "$promotion/candidate"
            ./scripts/verify-apple-distribution.sh "$promotion/candidate" "$binding" "$ready_app" "$app_name" "$dmg_name" \
                || { rm -rf "$promotion"; fail 'Candidate copy failed verification.'; }
            mv "$promotion/candidate" "$output"
            rmdir "$promotion"
        fi
        printf 'Signed and verified candidate (promote only after credential cleanup): %s\n' "$output"
        ;;
esac
printf 'Completed Apple release phase: %s; checkpoint state before advancing: %s\n' "$phase" "$state"

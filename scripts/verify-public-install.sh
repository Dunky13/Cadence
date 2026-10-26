#!/bin/bash
# Public URLs and fresh consumer state. No Apple credentials or GitHub token.
set -euo pipefail
umask 077
fail() { printf 'verify-public-install: %s\n' "$*" >&2; exit 1; }
[[ $(uname -m) == "${EXPECTED_NATIVE_ARCH:-}" ]] || fail 'Wrong native consumer architecture.'
[[ ${RELEASE_TAG:-} =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ && ${SOURCE_COMMIT:-} =~ ^[0-9a-f]{40}$ ]] || fail 'Invalid public candidate identity.'
[[ ${GITHUB_REPOSITORY:-} == Dunky13/Cadence ]] || fail 'Unexpected publication destination.'
work=$(mktemp -d "${TMPDIR:-/tmp}/cadence-consumer.XXXXXX")
trap 'rm -rf "$work"' EXIT
version=${RELEASE_TAG#v}
archive="Cadence-App-$version-universal.zip"
image="Cadence-Installer-$version-universal.dmg"
for name in "$archive" "$image" SHA256SUMS distribution.json; do
    curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
        "https://github.com/$GITHUB_REPOSITORY/releases/download/$RELEASE_TAG/$name" --output "$work/$name"
done
expected=$(printf '%s\n' "$archive" "$image" distribution.json | LC_ALL=C sort)
actual=''
while read -r digest name extra; do
    [[ $digest =~ ^[0-9a-f]{64}$ && -z $extra ]] || fail 'Malformed public checksum entry.'
    case $name in "$archive"|"$image"|distribution.json) ;; *) fail 'Unexpected public checksum path.' ;; esac
    actual_digest=$(shasum -a 256 < "$work/$name"); actual_digest=${actual_digest%% *}
    [[ $actual_digest == "$digest" ]] || fail 'Public asset checksum mismatch.'
    actual+="$name"$'\n'
done < "$work/SHA256SUMS"
[[ $(printf '%s' "$actual" | LC_ALL=C sort) == "$expected" ]] || fail 'Public checksum set differs.'
[[ ${EXPECTED_TEAM_ID:-} =~ ^[A-Z0-9]{10}$ ]] || fail 'Missing configured signing authority.'
jq -e --arg team "$EXPECTED_TEAM_ID" --arg commit "$SOURCE_COMMIT" --arg version "$version" '.team_id == $team and .source_commit == $commit and .version == $version and .bundle_id == "dev.cadence.app" and .architecture == "universal" and .notarization == "Accepted" and .tickets == "stapled and validated"' "$work/distribution.json" >/dev/null || fail 'Wrong public candidate provenance.'
# curl does not set browser quarantine. Add it and preserve it through installation.
quarantine="0083;$(printf '%x' "$(date +%s)");CadenceReleaseVerification;$(uuidgen)"
xattr -w com.apple.quarantine "$quarantine" "$work/$image"
xattr -w com.apple.quarantine "$quarantine" "$work/$archive"
./scripts/check-dmg.sh "$work/$image" --architecture universal --version "$version" --release --launch-demo
printf 'Independent public download, native %s installation/Gatekeeper/LaunchServices verified.\n' "$EXPECTED_NATIVE_ARCH"

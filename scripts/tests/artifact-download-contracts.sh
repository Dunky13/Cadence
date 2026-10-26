#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/cadence-artifact-test.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin" "$work/payload"
cat > "$work/bin/gh" <<'STUB'
#!/bin/bash
case $2 in
    */zip) cat "$FIXTURE_ZIP" ;;
    *) jq -n --arg digest "$FIXTURE_DIGEST" '{id:300,expired:false,digest:$digest}' ;;
esac
STUB
chmod +x "$work/bin/gh"
for name in Cadence-App-1.2.3-universal-local.zip Cadence-Installer-1.2.3-universal-local.dmg SHA256SUMS build-manifest.json; do printf 'fixture bytes\n' > "$work/payload/$name"; done
export FIXTURE_ZIP="$work/artifact.zip"
(cd "$work/payload" && zip -q "$FIXTURE_ZIP" ./*)
digest=$(shasum -a 256 < "$FIXTURE_ZIP"); digest=${digest%% *}
export FIXTURE_DIGEST="sha256:$digest" GITHUB_REPOSITORY=fixture/Cadence
helper="$root/scripts/download-release-artifact.sh"
PATH="$work/bin:$PATH" bash "$helper" 300 "$FIXTURE_DIGEST" build "$work/downloaded"
cmp "$work/payload/SHA256SUMS" "$work/downloaded/SHA256SUMS"
if PATH="$work/bin:$PATH" bash "$helper" 300 sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa build "$work/wrong-digest" >/dev/null 2>&1; then exit 1; fi
cp "$FIXTURE_ZIP" "$work/original.zip"
printf 'changed network bytes' >> "$FIXTURE_ZIP"
if PATH="$work/bin:$PATH" bash "$helper" 300 "$FIXTURE_DIGEST" build "$work/tampered" >/dev/null 2>&1; then exit 1; fi
cp "$work/original.zip" "$FIXTURE_ZIP"
printf 'unexpected' > "$work/payload/extra"
(cd "$work/payload" && zip -q "$FIXTURE_ZIP" extra)
digest=$(shasum -a 256 < "$FIXTURE_ZIP"); export FIXTURE_DIGEST="sha256:${digest%% *}"
if PATH="$work/bin:$PATH" bash "$helper" 300 "$FIXTURE_DIGEST" build "$work/extra" >/dev/null 2>&1; then exit 1; fi
cp "$work/original.zip" "$FIXTURE_ZIP"
digest=$(shasum -a 256 < "$FIXTURE_ZIP"); export FIXTURE_DIGEST="sha256:${digest%% *}"
if PATH="$work/bin:$PATH" bash "$helper" 300 "$FIXTURE_DIGEST" checkpoint "$work/wrong-kind" >/dev/null 2>&1; then exit 1; fi
# Actions preserves the directory following the first wildcard in
# dist/packages/*-universal-local/*. Reproduce that real hosted archive shape.
mkdir -p "$work/wrapped/1.2.3-universal-local"
for name in Cadence-App-1.2.3-universal-local.zip Cadence-Installer-1.2.3-universal-local.dmg SHA256SUMS build-manifest.json; do
    cp "$work/payload/$name" "$work/wrapped/1.2.3-universal-local/$name"
done
rm "$FIXTURE_ZIP"
(cd "$work/wrapped" && zip -q "$FIXTURE_ZIP" 1.2.3-universal-local/*)
digest=$(shasum -a 256 < "$FIXTURE_ZIP"); export FIXTURE_DIGEST="sha256:${digest%% *}"
PATH="$work/bin:$PATH" bash "$helper" 300 "$FIXTURE_DIGEST" build "$work/wrapped-restored"
for name in Cadence-App-1.2.3-universal-local.zip Cadence-Installer-1.2.3-universal-local.dmg SHA256SUMS build-manifest.json; do
    cmp "$work/payload/$name" "$work/wrapped-restored/$name"
done
cp "$FIXTURE_ZIP" "$work/wrapped.zip"
# A mixed layout cannot hide a second root or overwrite flattened bytes.
zip -dq "$FIXTURE_ZIP" 1.2.3-universal-local/SHA256SUMS
(cd "$work/payload" && zip -q "$FIXTURE_ZIP" SHA256SUMS)
digest=$(shasum -a 256 < "$FIXTURE_ZIP"); export FIXTURE_DIGEST="sha256:${digest%% *}"
if PATH="$work/bin:$PATH" bash "$helper" 300 "$FIXTURE_DIGEST" build "$work/mixed" >/dev/null 2>&1; then exit 1; fi
# Even allowlisted basenames cannot use arbitrary nesting or a wrong version.
for prefix in arbitrary 9.9.9-universal-local 1.2.3-universal-local/nested; do
    rm "$FIXTURE_ZIP"
    mkdir -p "$work/invalid/$prefix"
    cp "$work/wrapped/1.2.3-universal-local/"* "$work/invalid/$prefix/"
    (cd "$work/invalid" && zip -q "$FIXTURE_ZIP" "$prefix/"*)
    digest=$(shasum -a 256 < "$FIXTURE_ZIP"); export FIXTURE_DIGEST="sha256:${digest%% *}"
    if PATH="$work/bin:$PATH" bash "$helper" 300 "$FIXTURE_DIGEST" build "$work/invalid-result" >/dev/null 2>&1; then exit 1; fi
done
# A wrapped link must fail without creating a usable destination.
rm "$FIXTURE_ZIP" "$work/wrapped/1.2.3-universal-local/SHA256SUMS"
ln -s ../outside "$work/wrapped/1.2.3-universal-local/SHA256SUMS"
(cd "$work/wrapped" && zip -qy "$FIXTURE_ZIP" 1.2.3-universal-local/*)
digest=$(shasum -a 256 < "$FIXTURE_ZIP"); export FIXTURE_DIGEST="sha256:${digest%% *}"
if PATH="$work/bin:$PATH" bash "$helper" 300 "$FIXTURE_DIGEST" build "$work/link" >/dev/null 2>&1; then exit 1; fi
[[ ! -e $work/link ]]
# Directory envelopes remain forbidden for all other custody kinds.
cp "$work/wrapped.zip" "$FIXTURE_ZIP"
digest=$(shasum -a 256 < "$FIXTURE_ZIP"); export FIXTURE_DIGEST="sha256:${digest%% *}"
if PATH="$work/bin:$PATH" bash "$helper" 300 "$FIXTURE_DIGEST" distribution "$work/wrapped-distribution" >/dev/null 2>&1; then exit 1; fi
mkdir "$work/publication-payload"
printf '{"receipt":"fixture"}\n' > "$work/publication-payload/publication-receipts.json"
rm "$FIXTURE_ZIP"
(cd "$work/publication-payload" && zip -q "$FIXTURE_ZIP" publication-receipts.json)
digest=$(shasum -a 256 < "$FIXTURE_ZIP"); export FIXTURE_DIGEST="sha256:${digest%% *}"
PATH="$work/bin:$PATH" bash "$helper" 300 "$FIXTURE_DIGEST" publication "$work/publication-restored"
cmp "$work/publication-payload/publication-receipts.json" "$work/publication-restored/publication-receipts.json"
rm "$FIXTURE_ZIP"
printf 'unexpected' > "$work/publication-payload/unexpected.json"
(cd "$work/publication-payload" && zip -q "$FIXTURE_ZIP" unexpected.json)
digest=$(shasum -a 256 < "$FIXTURE_ZIP"); export FIXTURE_DIGEST="sha256:${digest%% *}"
if PATH="$work/bin:$PATH" bash "$helper" 300 "$FIXTURE_DIGEST" publication "$work/unexpected-receipt" >/dev/null 2>&1; then exit 1; fi
printf '14 immutable artifact download contracts passed (synthetic only).\n'

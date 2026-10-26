#!/bin/bash
# Verify the pre-credential artifact handoff without committing or signing code.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/cadence-handoff-tests.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"
cat > "$work/bin/git" <<'STUB'
#!/bin/bash
printf '%s\n' aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
STUB
cat > "$work/bin/ditto" <<'STUB'
#!/bin/bash
printf 'extract\n' >> "$HANDOFF_CALLS"
for argument in "$@"; do destination=$argument; done
mkdir -p "$destination/Cadence.app/Contents/MacOS"
printf 'fixture\n' > "$destination/Cadence.app/Contents/MacOS/Cadence"
STUB
cat > "$work/bin/codesign" <<'STUB'
#!/bin/bash
printf 'codesign\n' >> "$HANDOFF_CALLS"
STUB
cat > "$work/bin/xcrun" <<'STUB'
#!/bin/bash
printf 'lipo\n' >> "$HANDOFF_CALLS"
if [[ $* == *-archs* ]]; then printf 'x86_64 arm64\n'; fi
STUB
chmod +x "$work/bin/"*
version=$(plutil -extract CFBundleShortVersionString raw "$root/Resources/Info.plist")
archive="Cadence-App-$version-universal-local.zip"
image="Cadence-Installer-$version-universal-local.dmg"
cases=0
fail() { printf 'FAIL handoff %s: %s\n' "$case_name" "$*" >&2; exit 1; }
new_case() {
    case_name=$1
    input="$work/$case_name/input"
    destination="$work/$case_name/extracted"
    calls="$work/$case_name/calls"
    mkdir -p "$input"
    : > "$calls"
    printf 'archive bytes\n' > "$input/$archive"
    printf 'image bytes\n' > "$input/$image"
    jq -n --arg version "$version" '{schema:"cadence/build/v1",version:$version,architecture:"universal",
        source_commit:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",source_dirty:false,
        signing:"ad-hoc",notarization:"not attempted"}' > "$input/build-manifest.json"
    checksums
}
checksums() { (cd "$input" && shasum -a 256 "$archive" "$image" build-manifest.json > SHA256SUMS); }
invoke() {
    result=0
    env PATH="$work/bin:$PATH" HANDOFF_CALLS="$calls" GITHUB_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
        /bin/bash "$root/scripts/verify-release-input.sh" "$input" "$destination" \
        > "$work/$case_name/output" 2>&1 || result=$?
}
reject() {
    invoke
    [[ $result != 0 ]] || fail 'bad handoff was accepted'
    [[ ! -s $calls ]] || fail 'extraction or signing was reached before handoff validation'
    cases=$((cases + 1))
}
new_case exact-clean-input
invoke
[[ $result == 0 && -d $destination/Cadence.app ]] || fail 'valid handoff rejected'
grep -qx extract "$calls" || fail 'verified archive was not extracted'
cases=$((cases + 1))

new_case corrupt-archive
printf 'modified\n' >> "$input/$archive"
reject
new_case corrupt-image
printf 'modified\n' >> "$input/$image"
reject
new_case wrong-source-commit
jq '.source_commit="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' "$input/build-manifest.json" > "$input/new.json"
mv "$input/new.json" "$input/build-manifest.json"
checksums
reject
new_case dirty-source
jq '.source_dirty=true' "$input/build-manifest.json" > "$input/new.json"
mv "$input/new.json" "$input/build-manifest.json"
checksums
reject
new_case wrong-architecture
jq '.architecture="arm64"' "$input/build-manifest.json" > "$input/new.json"
mv "$input/new.json" "$input/build-manifest.json"
checksums
reject
new_case extra-checksum-path
printf '%064d  ../outside\n' 0 >> "$input/SHA256SUMS"
reject
new_case duplicate-checksum-entry
head -n 1 "$input/SHA256SUMS" >> "$input/duplicate"
cat "$input/duplicate" >> "$input/SHA256SUMS"
reject
new_case symlink-archive
mv "$input/$archive" "$input/original.zip"
ln -s original.zip "$input/$archive"
reject
new_case existing-destination
mkdir "$destination"
printf 'preserve\n' > "$destination/keep"
reject
grep -qx preserve "$destination/keep" || fail 'existing destination changed'
printf 'Release handoff contracts: %s cases passed; no credentials or provider calls.\n' "$cases"

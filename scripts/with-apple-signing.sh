#!/bin/bash
# Credentials are provided only to this isolated wrapper, never printed or
# inherited by the command it runs. This script does not submit to Apple.
{ set +x; } 2>/dev/null
set -euo pipefail
umask 077

fail() { printf 'apple-signing: %s\n' "$*" >&2; exit 1; }
usage() { printf 'Usage: scripts/with-apple-signing.sh COMMAND [ARGUMENTS...]\n'; }
private_security() {
  local result=0 argument escaped command=''
  # security's command interpreter reads private stdin; passwords never enter
  # its process arguments. Reject line delimiters before constructing one command.
  for argument in "$@"; do
    [[ $argument != *$'\n'* && $argument != *$'\r'* ]] || fail 'multiline security arguments are unsupported'
    escaped=${argument//\\/\\\\}
    escaped=${escaped//\"/\\\"}
    command+="\"$escaped\" "
  done
  printf '%s\n' "$command" | security -i >/dev/null 2>&1 || result=$?
  if [[ $result != 0 ]]; then
    printf 'apple-signing: security %s failed (exit %s)\n' "$1" "$result" >&2
  fi
  return "$result"
}
if [[ ${1:-} == --help || ${1:-} == -h ]]; then usage; exit 0; fi
[[ $# -gt 0 ]] || { usage >&2; exit 2; }
[[ $(uname -s) == Darwin ]] || fail 'macOS is required'

for name in APPLE_DEVELOPER_ID_P12_BASE64 APPLE_DEVELOPER_ID_P12_PASSWORD \
  APPLE_NOTARY_KEY_P8 APPLE_SIGNING_IDENTITY APPLE_TEAM_ID APPLE_NOTARY_KEY_ID \
  APPLE_NOTARY_ISSUER_ID; do
  [[ -n ${!name:-} ]] || fail "missing required configuration: $name"
done
[[ $APPLE_TEAM_ID =~ ^[A-Z0-9]{10}$ ]] || fail 'APPLE_TEAM_ID must contain ten uppercase letters or digits'
[[ $APPLE_NOTARY_KEY_ID =~ ^[A-Z0-9]{10}$ ]] || fail 'APPLE_NOTARY_KEY_ID must contain ten uppercase letters or digits'
[[ $APPLE_NOTARY_ISSUER_ID =~ ^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$ ]] || fail 'APPLE_NOTARY_ISSUER_ID must be a UUID'
[[ ${APPLE_NOTARY_TIMEOUT:-30m} =~ ^[1-9][0-9]*[smh]$ ]] || fail 'APPLE_NOTARY_TIMEOUT must include a positive duration suffix, such as 30m'
[[ $APPLE_SIGNING_IDENTITY == "Developer ID Application: "*" ($APPLE_TEAM_ID)" \
  && $APPLE_SIGNING_IDENTITY != *$'\n'* && $APPLE_SIGNING_IDENTITY != *$'\r'* ]] \
  || fail 'APPLE_SIGNING_IDENTITY must be a Developer ID Application identity for APPLE_TEAM_ID'
for tool in security openssl mktemp cmp rm; do
  command -v "$tool" >/dev/null || fail "missing prerequisite: $tool"
done
command -v "$1" >/dev/null || fail 'the requested command is unavailable'

cadence_signing_work=$(mktemp -d "${TMPDIR:-/tmp}/cadence-apple-signing.XXXXXX")
cadence_signing_keychain="$cadence_signing_work/signing.keychain-db"
cadence_signing_original_keychains=()
cadence_signing_mutation_started=false

cleanup() {
  local result=$1 cleanup_failed=0
  trap - EXIT INT TERM
  if [[ $cadence_signing_mutation_started == true ]]; then
    if [[ -e $cadence_signing_keychain || -L $cadence_signing_keychain ]]; then
      security delete-keychain "$cadence_signing_keychain" >/dev/null 2>&1 || cleanup_failed=1
    fi
    # create-keychain can change the user search list even if a later operation
    # fails. Restore the captured list and order on an isolated signing runner.
    security list-keychains -d user -s \
      ${cadence_signing_original_keychains[@]+"${cadence_signing_original_keychains[@]}"} \
      >/dev/null 2>&1 || cleanup_failed=1
    security list-keychains -d user > "$cadence_signing_work/keychains-after.txt" 2>/dev/null || cleanup_failed=1
    cmp -s "$cadence_signing_work/keychains-before.txt" "$cadence_signing_work/keychains-after.txt" || cleanup_failed=1
    [[ ! -e $cadence_signing_keychain && ! -L $cadence_signing_keychain ]] || cleanup_failed=1
  fi
  rm -rf -- "$cadence_signing_work" >/dev/null 2>&1 || cleanup_failed=1
  if [[ $cleanup_failed != 0 ]]; then
    printf 'apple-signing: temporary credential or keychain cleanup did not verify\n' >&2
    result=1
  fi
  exit "$result"
}
trap 'cleanup "$?"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

printf '%s' "$APPLE_DEVELOPER_ID_P12_BASE64" | openssl base64 -d -A > "$cadence_signing_work/certificate.p12"
printf '%s' "$APPLE_NOTARY_KEY_P8" > "$cadence_signing_work/notary.p8"
[[ -s $cadence_signing_work/certificate.p12 && -s $cadence_signing_work/notary.p8 ]] || fail 'decoded signing material is empty'
openssl pkey -in "$cadence_signing_work/notary.p8" -noout >/dev/null 2>&1 || fail 'the notarization key is not a readable private key'

security list-keychains -d user > "$cadence_signing_work/keychains-before.txt"
cadence_signing_keychain_pattern='^[[:space:]]*"([^"]+)"[[:space:]]*$'
while IFS= read -r cadence_signing_line; do
  [[ -n $cadence_signing_line ]] || continue
  [[ $cadence_signing_line =~ $cadence_signing_keychain_pattern ]] || fail 'cannot safely parse the user keychain search list'
  cadence_signing_existing_keychain=${BASH_REMATCH[1]}
  [[ $cadence_signing_existing_keychain == /* && $cadence_signing_existing_keychain != *\\* ]] \
    || fail 'cannot safely parse a keychain path'
  cadence_signing_original_keychains+=("$cadence_signing_existing_keychain")
done < "$cadence_signing_work/keychains-before.txt"

# Unset this value before the child command even if the caller exported a
# variable with the same name. It is only needed while importing the identity.
export -n cadence_signing_keychain_password 2>/dev/null || true
cadence_signing_keychain_password=$(openssl rand -hex 32)
[[ -n $cadence_signing_keychain_password ]] || fail 'could not create a temporary keychain password'
cadence_signing_mutation_started=true
private_security create-keychain -p "$cadence_signing_keychain_password" "$cadence_signing_keychain"
private_security set-keychain-settings -lut 21600 "$cadence_signing_keychain"
private_security unlock-keychain -p "$cadence_signing_keychain_password" "$cadence_signing_keychain"
private_security import "$cadence_signing_work/certificate.p12" -k "$cadence_signing_keychain" \
  -f pkcs12 -x -P "$APPLE_DEVELOPER_ID_P12_PASSWORD" -T /usr/bin/codesign
private_security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
  -k "$cadence_signing_keychain_password" "$cadence_signing_keychain"
# Creation does not reliably add an absolute-path keychain to the search list.
# Restrict lookup to the owned keychain; cleanup restores the exact original list.
security list-keychains -d user -s "$cadence_signing_keychain" >/dev/null 2>&1 \
  || fail 'could not isolate the signing keychain search list'
security find-identity -v -p codesigning "$cadence_signing_keychain" > "$cadence_signing_work/identities.txt" 2>/dev/null \
  || fail 'could not evaluate imported code-signing identities'
cadence_signing_identity_count=0
cadence_signing_identity_pattern='^[[:space:]]*[0-9]+\)[[:space:]]+([0-9A-Fa-f]{40})[[:space:]]+"([^"]+)"[[:space:]]*$'
while IFS= read -r cadence_signing_line; do
  if [[ $cadence_signing_line =~ $cadence_signing_identity_pattern && ${BASH_REMATCH[2]} == "$APPLE_SIGNING_IDENTITY" ]]; then
    cadence_signing_identity_count=$((cadence_signing_identity_count + 1))
  fi
done < "$cadence_signing_work/identities.txt"
[[ $cadence_signing_identity_count == 1 ]] || fail 'the configured Developer ID identity is not uniquely valid in the isolated keychain'
printf 'Verified the configured Developer ID identity in the isolated keychain.\n'
rm -f -- "$cadence_signing_work/certificate.p12"
unset cadence_signing_keychain_password APPLE_DEVELOPER_ID_P12_BASE64 \
  APPLE_DEVELOPER_ID_P12_PASSWORD APPLE_NOTARY_KEY_P8
unset NOTARY_KEYCHAIN_PROFILE NOTARY_KEYCHAIN
export SIGNING_KEYCHAIN="$cadence_signing_keychain"
export NOTARY_KEY_FILE="$cadence_signing_work/notary.p8"
export NOTARY_KEY_ID="$APPLE_NOTARY_KEY_ID"
export NOTARY_ISSUER_ID="$APPLE_NOTARY_ISSUER_ID"
export APPLE_SIGNING_IDENTITY APPLE_TEAM_ID

# Do not exec: this shell must restore the keychain search list after the
# command succeeds, fails, or is interrupted.
cadence_signing_command_result=0
"$@" || cadence_signing_command_result=$?
cleanup "$cadence_signing_command_result"

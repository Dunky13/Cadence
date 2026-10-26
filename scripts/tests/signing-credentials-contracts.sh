#!/bin/bash
# Synthetic commands and credential strings only. No real security, OpenSSL,
# signing, or Apple service operation is invoked by these contract checks.
set -euo pipefail
umask 077
root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/cadence-signing-contracts.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
mkdir "$work/bin"

cat > "$work/bin/uname" <<'MOCK'
#!/bin/bash
printf 'Darwin\n'
MOCK
cat > "$work/bin/openssl" <<'MOCK'
#!/bin/bash
set -euo pipefail
case $1 in
  base64)
    [[ $(cat) == fixture-base64-certificate ]] || exit 90
    [[ ${FIXTURE_MODE:-} != empty-certificate ]] || exit 0
    printf 'fixture-decoded-certificate'
    ;;
  pkey)
    [[ $2 == -in && $4 == -noout ]] || exit 91
    [[ $(cat "$3") == fixture-private-key ]] || exit 92
    ;;
  rand) printf 'fixture-random-keychain-password\n' ;;
  *) exit 93 ;;
esac
MOCK
cat > "$work/bin/security" <<'MOCK'
#!/bin/bash
set -euo pipefail
action=$1
shift
printf '%s\n' "$action" >> "$FIXTURE_STATE/actions"
case $action in
  list-keychains)
    [[ $1 == -d && $2 == user ]] || exit 94
    if [[ ${3:-} == -s ]]; then
      [[ ${FIXTURE_MODE:-} != restore-failure ]] || exit 18
      shift 3
      : > "$FIXTURE_STATE/search-list"
      for path in "$@"; do printf '    "%s"\n' "$path" >> "$FIXTURE_STATE/search-list"; done
      if [[ ${FIXTURE_MODE:-} == readback-mismatch ]]; then printf '    "/fixture/wrong.keychain-db"\n' >> "$FIXTURE_STATE/search-list"; fi
    elif [[ ${FIXTURE_MODE:-} == malformed-list ]]; then
      printf 'unquoted and ambiguous keychain output\n'
    else
      cat "$FIXTURE_STATE/search-list"
    fi
    ;;
  create-keychain)
    [[ $1 == -p && $2 == fixture-random-keychain-password ]] || exit 95
    : > "$3"
    printf '%s\n' "$3" > "$FIXTURE_STATE/keychain-path"
    printf '    "%s"\n' "$3" >> "$FIXTURE_STATE/search-list"
    ;;
  set-keychain-settings) [[ $1 == -lut && $2 == 21600 ]] || exit 96 ;;
  unlock-keychain) [[ $1 == -p && $2 == fixture-random-keychain-password ]] || exit 97 ;;
  import)
    if [[ ${FIXTURE_MODE:-} == import-failure ]]; then printf 'fixture-certificate-password\n' >&2; exit 17; fi
    [[ $(cat "$1") == fixture-decoded-certificate ]] || exit 98
    [[ $2 == -k && $4 == -f && $5 == pkcs12 && $6 == -x && $7 == -P \
      && $8 == fixture-certificate-password && $9 == -T && ${10} == /usr/bin/codesign ]] || exit 99
    ;;
  set-key-partition-list)
    [[ $1 == -S && $2 == apple-tool:,apple:,codesign: && $3 == -s && $4 == -k \
      && $5 == fixture-random-keychain-password ]] || exit 100
    ;;
  delete-keychain)
    [[ ${FIXTURE_MODE:-} != delete-failure ]] || exit 19
    rm -f -- "$1"
    ;;
  *) exit 101 ;;
esac
MOCK
cat > "$work/bin/fixture-child" <<'MOCK'
#!/bin/bash
set -euo pipefail
[[ $1 == 'argument with spaces' && $2 == literal ]] || exit 102
[[ -z ${APPLE_DEVELOPER_ID_P12_BASE64+x} && -z ${APPLE_DEVELOPER_ID_P12_PASSWORD+x} \
  && -z ${APPLE_NOTARY_KEY_P8+x} && -z ${cadence_signing_keychain_password+x} ]] || exit 103
[[ -z ${NOTARY_KEYCHAIN_PROFILE+x} && -z ${NOTARY_KEYCHAIN+x} ]] || exit 104
[[ -f $SIGNING_KEYCHAIN && -s $NOTARY_KEY_FILE ]] || exit 105
[[ $(stat -f %Lp "$NOTARY_KEY_FILE") == 600 ]] || exit 106
[[ $(stat -f %Lp "$(dirname "$NOTARY_KEY_FILE")") == 700 ]] || exit 107
[[ $APPLE_TEAM_ID == TESTTEAM12 && $APPLE_SIGNING_IDENTITY == 'Developer ID Application: Fixture Developer (TESTTEAM12)' ]] || exit 108
[[ $NOTARY_KEY_ID == KEY1234567 && $NOTARY_ISSUER_ID == 01234567-89ab-cdef-0123-456789abcdef ]] || exit 109
[[ $APPLE_NOTARY_TIMEOUT == 17m ]] || exit 110
printf '%s\n' "$NOTARY_KEY_FILE" > "$FIXTURE_STATE/notary-path"
: > "$FIXTURE_STATE/child-ran"
if [[ ${FIXTURE_MODE:-} == signal-term ]]; then kill -TERM "$PPID"; fi
if [[ ${FIXTURE_MODE:-} == signal-int ]]; then kill -INT "$PPID"; fi
exit "${FIXTURE_CHILD_EXIT:-0}"
MOCK
chmod +x "$work/bin/"*

run_case() {
  local name=$1 mode=$2 expected=$3 child_status=${4:-0} result=0
  local state="$work/$name"
  mkdir "$state"
  printf '    "/fixture/login.keychain-db"\n    "/fixture/Keychains with spaces/build.keychain-db"\n' > "$state/original-list"
  cp "$state/original-list" "$state/search-list"
  (
    export PATH="$work/bin:$PATH" FIXTURE_STATE="$state" FIXTURE_MODE="$mode" FIXTURE_CHILD_EXIT="$child_status"
    export APPLE_DEVELOPER_ID_P12_BASE64=fixture-base64-certificate
    export APPLE_DEVELOPER_ID_P12_PASSWORD=fixture-certificate-password APPLE_NOTARY_KEY_P8=fixture-private-key
    export APPLE_SIGNING_IDENTITY='Developer ID Application: Fixture Developer (TESTTEAM12)' APPLE_TEAM_ID=TESTTEAM12
    export APPLE_NOTARY_KEY_ID=KEY1234567 APPLE_NOTARY_ISSUER_ID=01234567-89ab-cdef-0123-456789abcdef APPLE_NOTARY_TIMEOUT=17m
    export NOTARY_KEYCHAIN_PROFILE=unintended-inherited-profile NOTARY_KEYCHAIN=unintended-inherited-keychain
    export cadence_signing_keychain_password=unintended-inherited-password
    if [[ $mode == missing-secret ]]; then unset APPLE_NOTARY_KEY_P8; fi
    if [[ $mode == invalid-team ]]; then export APPLE_TEAM_ID=invalid; fi
    if [[ $mode == invalid-timeout ]]; then export APPLE_NOTARY_TIMEOUT=forever; fi
    if [[ $name == tracing ]]; then
      /bin/bash -x "$root/scripts/with-apple-signing.sh" fixture-child 'argument with spaces' literal
    else
      /bin/bash "$root/scripts/with-apple-signing.sh" fixture-child 'argument with spaces' literal
    fi
  ) > "$state/output" 2>&1 || result=$?
  [[ $result == "$expected" ]] || { printf 'FAIL %s: expected exit %s, got %s\n' "$name" "$expected" "$result" >&2; cat "$state/output" >&2; exit 1; }
  for secret in fixture-base64-certificate fixture-certificate-password fixture-private-key fixture-random-keychain-password; do
    if grep -Fq "$secret" "$state/output"; then printf 'FAIL %s: credential appeared in output\n' "$name" >&2; exit 1; fi
  done
  if [[ -f $state/keychain-path ]]; then
    local keychain
    keychain=$(cat "$state/keychain-path")
    [[ ! -e $keychain && ! -e $(dirname "$keychain") ]] || { printf 'FAIL %s: private signing files remain\n' "$name" >&2; exit 1; }
  fi
  case $mode in
    missing-secret|invalid-team|invalid-timeout|empty-certificate|malformed-list)
      [[ ! -e $state/child-ran && ! -e $state/keychain-path ]] || { printf 'FAIL %s: mutated before validation\n' "$name" >&2; exit 1; }
      ;;
    restore-failure|readback-mismatch)
      grep -Fq 'cleanup did not verify' "$state/output" || { printf 'FAIL %s: cleanup failure not reported\n' "$name" >&2; exit 1; }
      ;;
    *) cmp -s "$state/original-list" "$state/search-list" || { printf 'FAIL %s: search list not restored\n' "$name" >&2; exit 1; } ;;
  esac
  if [[ $mode == import-failure ]]; then [[ ! -e $state/child-ran ]] || exit 1; fi
  printf 'PASS %s\n' "$name"
}

run_case success success 0
run_case tracing success 0
run_case command-failure success 37 37
run_case import-failure import-failure 17
run_case malformed-list malformed-list 1
run_case missing-secret missing-secret 1
run_case invalid-team invalid-team 1
run_case invalid-timeout invalid-timeout 1
run_case empty-certificate empty-certificate 1
run_case delete-failure delete-failure 1
run_case restore-failure restore-failure 1
run_case readback-mismatch readback-mismatch 1
run_case terminate signal-term 143
run_case interrupt signal-int 130
printf 'Signing credential contracts passed (14 cases, synthetic commands only).\n'

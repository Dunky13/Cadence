#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/cadence-policy-tests.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"
cat > "$work/bin/gh" <<'STUB'
#!/bin/bash
[[ ${GH_TOKEN:-} == fixture-read-only ]] || exit 9
case ${POLICY_MODE:-} in
    auth) exit 1 ;;
    disabled) printf '{"enabled":false}' ;;
    malformed) printf 'invalid' ;;
    *) printf '{"enabled":true}' ;;
esac
STUB
chmod +x "$work/bin/gh"
for mode in enabled auth disabled malformed missing; do
    result=0
    token=fixture-read-only
    [[ $mode != missing ]] || token=''
    PATH="$work/bin:$PATH" GITHUB_REPOSITORY=Dunky13/Cadence GH_TOKEN=fixture-publisher RELEASE_POLICY_READ_TOKEN="$token" POLICY_MODE=$mode \
        bash "$root/scripts/verify-release-policy.sh" > "$work/output" 2>&1 || result=$?
    if [[ $mode == enabled ]]; then [[ $result == 0 ]]; else [[ $result != 0 ]]; fi
    if rg -q 'fixture-read-only|fixture-publisher' "$work/output"; then exit 1; fi
done
printf '5 isolated immutable-policy contracts passed (synthetic only).\n'

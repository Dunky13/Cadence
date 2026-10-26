#!/bin/bash
# A stale successful preflight must never let a partial rerun sign fresh bytes.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/cadence-attempt-contracts.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"
cat > "$work/bin/gh" <<'STUB'
#!/bin/bash
printf 'network reached\n' >> "$ATTEMPT_CALLS"
exit 99
STUB
chmod +x "$work/bin/gh"
export ATTEMPT_CALLS="$work/calls"
for attempt in 2 3 ''; do
    result=0
    PATH="$work/bin:$PATH" GITHUB_RUN_ATTEMPT="$attempt" GITHUB_REPOSITORY=Dunky13/Cadence GITHUB_REF=refs/heads/main \
        bash "$root/scripts/verify-ci-origin.sh" > "$work/output" 2>&1 || result=$?
    [[ $result != 0 && ! -e $ATTEMPT_CALLS ]]
    grep -q 'Job reruns may replay stale custody' "$work/output"
done
# A fresh controller still reaches the existing trust boundary, without bypassing it.
result=0
GITHUB_RUN_ATTEMPT=1 GITHUB_REPOSITORY=untrusted/Cadence GITHUB_REF=refs/heads/main \
    bash "$root/scripts/verify-ci-origin.sh" > "$work/output" 2>&1 || result=$?
[[ $result != 0 ]]
grep -q 'Only this repository main may sign' "$work/output"
printf '4 stale-attempt signing contracts passed (synthetic only).\n'

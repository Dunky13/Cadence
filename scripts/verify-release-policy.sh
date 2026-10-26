#!/bin/bash
# A dedicated read-only credential observes policy; it never publishes artifacts.
{ set +x; } 2>/dev/null
set -euo pipefail
umask 077
[[ ${GITHUB_REPOSITORY:-} =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || exit 2
[[ -n ${RELEASE_POLICY_READ_TOKEN:-} ]] || {
    printf 'release-policy: Configure the isolated Cadence-only Administration-read credential in production.\n' >&2
    exit 1
}
work=$(mktemp -d "${TMPDIR:-/tmp}/cadence-release-policy.XXXXXX")
trap 'rm -rf "$work"' EXIT
GH_TOKEN="$RELEASE_POLICY_READ_TOKEN" gh api --hostname github.com \
    "repos/$GITHUB_REPOSITORY/immutable-releases" > "$work/policy.json" 2> "$work/error" || {
        printf 'release-policy: Dedicated policy read failed; publication remains blocked.\n' >&2
        exit 1
    }
jq -e '.enabled == true' "$work/policy.json" >/dev/null || {
    printf 'release-policy: Immutable releases must be enabled.\n' >&2
    exit 1
}
printf 'Effective immutable-release policy verified with an isolated read-only credential.\n'

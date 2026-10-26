#!/bin/bash
# Sourced by the publisher. Only a bound, persisted HTTP 502 receipt proves an
# abandoned upload under GitHub's documented starter-asset recovery contract.
publication_custody_init() {
    local input=$1 work=$2 candidate=$3
    [[ -n ${PUBLICATION_STATE_DIRECTORY:-} ]] || fail 'A persistent PUBLICATION_STATE_DIRECTORY is required.'
    [[ ! -L $PUBLICATION_STATE_DIRECTORY ]] || fail 'Publication custody cannot be a symlink.'
    mkdir -p "$PUBLICATION_STATE_DIRECTORY"
    publication_state=$(cd "$PUBLICATION_STATE_DIRECTORY" && pwd -P)
    [[ $publication_state != "$input" && $publication_state != "$input/"* && $publication_state != "$work" && $publication_state != "$work/"* ]] \
        || fail 'Publication receipts must be retained outside payload/private scratch.'
    publication_receipts="$publication_state/publication-receipts.json"
    if [[ -e $publication_receipts || -L $publication_receipts ]]; then
        [[ -f $publication_receipts && ! -L $publication_receipts ]] || fail 'Invalid publication receipt file.'
        jq -se --argjson candidate "$candidate" '
            length == 1 and (.[0] | .schema == "cadence/publication-receipts/v1" and .candidate == $candidate
            and (.terminal_502_uploads | type == "array" and all(.[];
                .http_status == 502 and (.asset_id | type == "number" and . > 0 and . == floor)
                and (.request_id | type == "string" and test("^[A-Za-z0-9:-]+$"))
                and (.name | type == "string") and (.sha256 | type == "string" and test("^[0-9a-f]{64}$")))))' \
            "$publication_receipts" >/dev/null || fail 'Unbound or mismatched publication receipts.'
    else
        jq -n --argjson candidate "$candidate" '{schema:"cadence/publication-receipts/v1",candidate:$candidate,terminal_502_uploads:[]}' \
            > "$publication_receipts"
    fi
}
publication_record_502() {
    local name=$1 work=$2 repo=$3 release_id=$4 assets=$5 status request_id
    status=$(awk 'NR == 1 && /^HTTP\/[0-9.]+ / { print $2; exit }' "$work/upload-output")
    [[ $status == 502 ]] || return 0
    request_id=$(awk '/^\r?$/ {exit} tolower($1) == "x-github-request-id:" {gsub("\r","",$2); print $2; exit}' "$work/upload-output")
    [[ $request_id =~ ^[A-Za-z0-9:-]+$ ]] || fail 'HTTP 502 lacked a verified GitHub request ID; upload remains unresolved.'
    gh api --hostname github.com --paginate --slurp "repos/$repo/releases/$release_id/assets?per_page=100" > "$work/502-assets.json" \
        || fail 'Unable to bind the terminal upload failure to an exact asset.'
    jq --arg name "$name" '[.[][] | select(.name == $name)]' "$work/502-assets.json" > "$work/502-match.json"
    # A completed response is reconciled by exact bytes, never deleted.
    if jq -e 'length == 1 and .[0].state == "uploaded"' "$work/502-match.json" >/dev/null; then return 0; fi
    jq -e 'length == 1 and all(.[]; .state == "starter" and .size == 0
        and (.id | type == "number" and . > 0 and . == floor)
        and .uploader.login == "github-actions[bot]" and .uploader.type == "Bot" and .uploader.id == 41898282)' \
        "$work/502-match.json" >/dev/null || fail 'Terminal failure did not identify one owned empty starter.'
    jq --arg name "$name" --arg request "$request_id" --arg sha "$(jq -r --arg name "$name" '.[$name]' <<< "$assets")" \
        --argjson id "$(jq -r '.[0].id' "$work/502-match.json")" '
        .terminal_502_uploads += [{http_status:502,request_id:$request,asset_id:$id,name:$name,sha256:$sha}]' \
        "$publication_receipts" > "$work/publication-receipts.json"
    cp "$work/publication-receipts.json" "$publication_receipts.next"
    mv "$publication_receipts.next" "$publication_receipts"
}
publication_require_abandoned() {
    local name=$1 id=$2 assets=$3
    jq -e --argjson id "$id" --arg name "$name" --arg sha "$(jq -r --arg name "$name" '.[$name]' <<< "$assets")" '
        any(.terminal_502_uploads[]; .asset_id == $id and .name == $name and .sha256 == $sha and .http_status == 502)' \
        "$publication_receipts" >/dev/null || fail 'Starter has no bound terminal HTTP 502 receipt. Uncertain uploads are preserved.'
}

#!/bin/bash
# Shared, credential-free identity and evidence checks for durable Apple stages.
# Sourced by release-macos.sh and notarize-artifact.sh (caller supplies fail).
apple_binding() {
    local version=$1 build=$2 architecture=$3
    [[ ${SOURCE_COMMIT:-} =~ ^[0-9a-f]{40}$ ]] || fail 'SOURCE_COMMIT must be a full lowercase SHA.'
    [[ ${BUILD_CI_RUN_ID:-} =~ ^[1-9][0-9]*$ && ${BUILD_ARTIFACT_ID:-} =~ ^[1-9][0-9]*$ ]] || fail 'Exact origin CI run/artifact IDs are required.'
    [[ ${BUILD_ARTIFACT_DIGEST:-} =~ ^sha256:[0-9a-f]{64}$ ]] || fail 'BUILD_ARTIFACT_DIGEST must be an immutable sha256 digest.'
    [[ ${GITHUB_RUN_ID:-} =~ ^[1-9][0-9]*$ && ${GITHUB_RUN_ATTEMPT:-} =~ ^[1-9][0-9]*$ ]] || fail 'Release run ID and attempt are required.'
    [[ ${APPLE_TEAM_ID:-} =~ ^[A-Z0-9]{10}$ ]] || fail 'APPLE_TEAM_ID is required.'
    [[ $version =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || fail 'Version must be numeric x.y.z.'
    [[ $build =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || fail 'A numeric bundle build is required.'
    case $architecture in arm64|x86_64|universal) ;; *) fail 'Invalid architecture.' ;; esac
    jq -cn --arg source "$SOURCE_COMMIT" --arg version "$version" --arg build "$build" \
        --arg architecture "$architecture" --arg team "$APPLE_TEAM_ID" \
        --arg run "$BUILD_CI_RUN_ID" --arg artifact "$BUILD_ARTIFACT_ID" --arg digest "$BUILD_ARTIFACT_DIGEST" \
        '{source_commit:$source,version:$version,build_number:$build,bundle_id:"dev.cadence.app",
          architecture:$architecture,team_id:$team,
          origin:{build_ci_run_id:$run,build_artifact_id:$artifact,build_artifact_digest:$digest}}'
}
apple_sha() { local digest; digest=$(shasum -a 256 < "$1") || return; printf '%s\n' "${digest%% *}"; }
apple_regular() { [[ -f $1 && ! -L $1 ]] || fail "Missing regular file: $1"; }
apple_atomic() {
    # Caller holds the stage lock. No raw client output is ever passed here.
    local temporary
    temporary=$(mktemp "$2.tmp.XXXXXX") || return
    cp "$1" "$temporary" && mv -f "$temporary" "$2"
}
apple_log_matches() {
    jq -se --arg id "$2" --arg status "$3" --arg filename "$4" --arg sha "$5" '
        length == 1 and (.[0] | type == "object" and
        (.jobId | type == "string" and ascii_downcase == $id) and
        .status == $status and .archiveFilename == $filename and
        (.sha256 | type == "string" and ascii_downcase == $sha) and
        (.issues == null or (.issues | type == "array" and all(.[];
          type == "object" and (.severity | type == "string")))))' "$1" >/dev/null 2>&1
}
apple_tree_sha() {
    # Relative paths keep the retained content inventory independent of runner paths.
    local digest
    digest=$( (cd "$1" && find . -print | LC_ALL=C sort | while IFS= read -r path; do
        [[ $path != *$'\r'* && $path != *$'\t'* ]] || exit 1
        if [[ -L $path ]]; then printf 'link %s %s\n' "$path" "$(readlink "$path")"
        elif [[ -f $path ]]; then shasum -a 256 "$path"
        elif [[ -d $path ]]; then printf 'directory %s\n' "$path"
        else exit 1; fi
    done) | shasum -a 256 | cut -d ' ' -f 1) || return 1
    printf '%s\n' "$digest"
}

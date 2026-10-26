#!/bin/bash
# Shared candidate identity. Callers supply fail(), jq and the selected build environment.
# origin values are strings from the selected *build*, not the publication run.
publication_origin() {
    [[ ${BUILD_CI_RUN_ID:-} =~ ^[1-9][0-9]*$ && ${BUILD_ARTIFACT_ID:-} =~ ^[1-9][0-9]*$ ]] \
        || fail 'Candidate requires BUILD_CI_RUN_ID and BUILD_ARTIFACT_ID from the selected build.'
    [[ ${BUILD_ARTIFACT_DIGEST:-} =~ ^sha256:[0-9a-f]{64}$ ]] \
        || fail 'Candidate requires the selected BUILD_ARTIFACT_DIGEST (sha256:...).'
    jq -cnS --arg run "$BUILD_CI_RUN_ID" --arg artifact "$BUILD_ARTIFACT_ID" --arg digest "$BUILD_ARTIFACT_DIGEST" \
        '{build_ci_run_id:$run,build_artifact_id:$artifact,build_artifact_digest:$digest}'
}
# Exact body comparison rejects duplicate markers, ambiguous JSON and edited metadata.
# The entire body is deterministic; generated notes are deliberately not appended.
publication_body() {
    printf '<!-- cadence-publication/v1 %s -->' "$1"
}
publication_binding() {
    local document=$1 repository=$2 build=$3 origin=$4 tag=$5 version=$6 source_commit=$7
    jq -e --arg repo "$repository" --arg tag "$tag" --arg source "$source_commit" \
        --arg version "$version" --arg build "$build" --argjson origin "$origin" '
        .author.login == "github-actions[bot]" and .author.type == "Bot" and .author.id == 41898282
        and (.id | type == "number" and . > 0 and . == floor)
        and .tag_name == $tag and .target_commitish == $source
        and .name == ("Cadence " + $tag) and .prerelease == false
        and (.body | type == "string")
        and (.body as $body | ($body | capture("^<!-- cadence-publication/v1 (?<candidate>[^\\n]+) -->$").candidate) as $raw
        | ($raw | fromjson) as $c
        | $body == ("<!-- cadence-publication/v1 " + $raw + " -->")
        and $raw == ($c | walk(if type == "object" then to_entries | sort_by(.key) | from_entries else . end) | tojson)
        and ($c | keys == ["assets","build_number","origin","repository","schema","source_commit","tag","version"])
        and $c.schema == "cadence/publication/v1" and $c.repository == $repo and $c.tag == $tag
        and $c.source_commit == $source and $c.version == $version and $c.build_number == $build
        and $c.origin == $origin
        and ($c.assets | type == "object" and keys ==
            ["Cadence-App-" + $version + "-universal.zip", "Cadence-Installer-" + $version + "-universal.dmg",
             "SHA256SUMS", "distribution.json"])
        and all($c.assets[]; type == "string" and test("^[0-9a-f]{64}$")))
        ' "$document" >/dev/null
}

#!/usr/bin/env bash
set -euo pipefail

image=${1:?usage: tests/m18-sbom.sh IMAGE OUTPUT}
output=${2:?usage: tests/m18-sbom.sh IMAGE OUTPUT}
packages=$(mktemp)
inspect=$(mktemp)
trap 'rm -f "$packages" "$inspect"' EXIT
python3 tests/m18-lock-packages.py >"$packages"
docker image inspect "$image" >"$inspect"
image_id=$(jq -r '.[0].Id' "$inspect")
image_digest=$(jq -r '.[0].RepoDigests[0] // empty' "$inspect")
image_digest=${image_digest##*@}
jq -S -n --arg image "$image" --arg image_id "$image_id" --arg image_digest "$image_digest" \
  --slurpfile packages "$packages" \
  '$packages[0] as $cargo |
   {spdxVersion:"SPDX-2.3", dataLicense:"CC0-1.0", SPDXID:"SPDXRef-DOCUMENT",
    name:($image + " SBOM"), documentNamespace:("https://github.com/trickle-labs/pg-react/sbom/" + $image_id),
    creationInfo:{created:"1970-01-01T00:00:00Z", creators:["Tool: pg-react-m18-sbom"]},
    packages:([{SPDXID:"SPDXRef-OCI-Image",name:$image,versionInfo:$image_id,
                 downloadLocation:"NOASSERTION",filesAnalyzed:false,
                 licenseConcluded:"NOASSERTION",licenseDeclared:"NOASSERTION",
                 copyrightText:"NOASSERTION",
                 externalRefs:(if $image_digest == "" then [] else [{referenceCategory:"OTHER",referenceType:"ociDigest",referenceLocator:$image_digest}] end)}]
                + ($cargo | map({SPDXID:("SPDXRef-Cargo-" + ((.name + "-" + .version) | gsub("[^A-Za-z0-9.-]";"-"))),name:.name,versionInfo:.version,downloadLocation:"NOASSERTION",filesAnalyzed:false,licenseConcluded:"NOASSERTION",licenseDeclared:(.license // "NOASSERTION"),copyrightText:"NOASSERTION"}))),
    relationships:([{spdxElementId:"SPDXRef-DOCUMENT",relationshipType:"DESCRIBES",relatedSpdxElement:"SPDXRef-OCI-Image"}]
                    + ($cargo | map({spdxElementId:"SPDXRef-OCI-Image",relationshipType:"CONTAINS",relatedSpdxElement:("SPDXRef-Cargo-" + ((.name + "-" + .version) | gsub("[^A-Za-z0-9.-]";"-")))})))}' >"$output"

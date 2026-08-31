# NVIDIA Embedding Demo Validation

This procedure validates the published `kb-query` and `kb-index` Aliases
through the live `light-gateway`. The model-provider credential remains an
environment variable of the gateway container and is never an argument to the
validation helper.

Run from `portal-config-dev/llm-gateway-rust`.

## 1. Confirm the intended config snapshot was loaded

Before testing, complete the Portal publication and config-snapshot workflow.
Restart the selected gateway or explicitly reload the `llm-router` module, and
require a successful result from the standard startup/reload operation. Confirm
that the operation reports the intended immutable config-snapshot version.

Do not treat Alias visibility alone as proof that the intended revision was
loaded; an older snapshot can expose the same Alias. Stop if startup or reload
fails. The gateway keeps its last-known-good LLM snapshot when reload validation
fails.

## 2. Provision only the gateway deployment

Put the NVIDIA credential in the protected Portal environment file used by the
Compose deployment, then restart or reload the selected gateway. Do not put it
in the gateway client header file, helper arguments, shell history, report, or
evidence directory.

The dedicated gateway profile is enabled when any one of the supported provider
credentials is configured. The rest of the Portal stack remains runnable when
none is configured.

## 3. Prepare the gateway client header

```bash
set -euo pipefail
umask 077

gateway_header_file=$(mktemp)
trap 'rm -f -- "$gateway_header_file"' EXIT
read -rsp 'Gateway client bearer token: ' gateway_client_token
printf '\n'
printf 'Authorization: Bearer %s\n' "$gateway_client_token" >"$gateway_header_file"
unset gateway_client_token
chmod 600 "$gateway_header_file"
```

## 4. Run independent query and index lanes

Create evidence outside the source checkout:

```bash
evidence_dir=$(mktemp -d)
chmod 700 "$evidence_dir"

validation/validate-embedding.sh \
  --gateway-url https://localhost:8444 \
  --alias kb-query \
  --header-file "$gateway_header_file" \
  --ca-file config/ca.pem \
  --expected-space-id nvidia-nemotron-3-embed-1b \
  --expected-space-revision 1 \
  --expected-dimension 2048 \
  --timeout-seconds 30 \
  >"$evidence_dir/kb-query-report.json"

validation/validate-embedding.sh \
  --gateway-url https://localhost:8444 \
  --alias kb-index \
  --header-file "$gateway_header_file" \
  --ca-file config/ca.pem \
  --expected-space-id nvidia-nemotron-3-embed-1b \
  --expected-space-revision 1 \
  --expected-dimension 2048 \
  --timeout-seconds 30 \
  >"$evidence_dir/kb-index-report.json"

jq -e '.status == "pass" and .category == "validated"' \
  "$evidence_dir/kb-query-report.json"
jq -e '.status == "pass" and .category == "validated"' \
  "$evidence_dir/kb-index-report.json"
```

Each report has its own request ID and must carry the intended applied
configuration generation. A success report has schema version
`lightapi.llm.embedding-validation/v1`.

For a publicly trusted production gateway, omit the `--ca-file` option and use
the system trust store.

## 5. Record sanitized smoke evidence

Record the source revision and running image identity without copying container
environment variables:

```bash
source_revision=$(git -C /path/to/light-fabric rev-parse HEAD)
container_image_digest=$(docker inspect --format '{{.Image}}' llm-gateway)
recorded_at=$(date -u +'%Y-%m-%dT%H:%M:%SZ')

jq -n \
  --arg schemaVersion lightapi.llm.embedding-smoke-evidence/v1 \
  --arg sourceRevision "$source_revision" \
  --arg containerImageDigest "$container_image_digest" \
  --arg recordedAt "$recorded_at" \
  --slurpfile query "$evidence_dir/kb-query-report.json" \
  --slurpfile index "$evidence_dir/kb-index-report.json" '
    {
      schemaVersion: $schemaVersion,
      sourceRevision: $sourceRevision,
      containerImageDigest: $containerImageDigest,
      recordedAt: $recordedAt,
      lanes: {
        query: $query[0],
        index: $index[0]
      }
    }
  ' >"$evidence_dir/nvidia-smoke-evidence.json"

chmod 600 "$evidence_dir/nvidia-smoke-evidence.json"
jq -e '
  .lanes.query.status == "pass" and
  .lanes.index.status == "pass" and
  .lanes.query.configGeneration == .lanes.index.configGeneration and
  .lanes.query.requestId != .lanes.index.requestId
' "$evidence_dir/nvidia-smoke-evidence.json"
```

Do not add the evidence directory to git. Retain only the three sanitized JSON
files when operational policy requires evidence. The helper deletes raw model
responses and response-header scratch files before it exits.

## Result categories

| Category | Meaning |
| --- | --- |
| `aliasNotVisible` | The Alias did not become visible before the timeout. Confirm publication acknowledgement and active snapshot. |
| `gatewayAuthorization` | The gateway rejected the client credential or policy. |
| `providerError` | Credential materialization, provider authentication, physical-model selection, or another bounded provider failure occurred. |
| `providerRateLimited` | The model provider returned a bounded rate-limit response. |
| `providerTimeout` | The model-provider request timed out. |
| `embeddingContract` | Response shape, embedding space, revision, dimension, or required success metadata differed. |
| `transport` | DNS, connection, or TLS verification failed. |
| `gatewayError` | Another bounded gateway failure occurred. |

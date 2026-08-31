#!/usr/bin/env bash
set -euo pipefail

readonly schema_version="lightapi.llm.embedding-validation/v1"
readonly fixed_text="light-gateway configuration validation"

usage() {
  printf '%s\n' \
    "Usage: $0 --gateway-url URL --alias NAME --header-file PATH [--ca-file PATH]" \
    "          --expected-space-id ID --expected-space-revision N" \
    "          --expected-dimension N --timeout-seconds N" >&2
}

emit_report() {
  local status=$1
  local category=$2
  local alias_value=$3
  local request_id_value=${4:-}
  local http_status_value=${5:-0}
  local config_generation_value=${6:-0}
  local billed_cost_value=${7:-0}
  local vector_count_value=${8:-0}
  local dimension_value=${9:-0}
  local actual_space_id_value=${10:-}
  local actual_space_revision_value=${11:-0}
  local timestamp
  timestamp=$(date -u +'%Y-%m-%dT%H:%M:%SZ')

  jq -n \
    --arg schemaVersion "$schema_version" \
    --arg status "$status" \
    --arg category "$category" \
    --arg alias "$alias_value" \
    --arg requestId "$request_id_value" \
    --arg timestamp "$timestamp" \
    --arg expectedSpaceId "$expected_space_id" \
    --arg actualSpaceId "$actual_space_id_value" \
    --argjson httpStatus "$http_status_value" \
    --argjson expectedSpaceRevision "$expected_space_revision" \
    --argjson actualSpaceRevision "$actual_space_revision_value" \
    --argjson expectedDimension "$expected_dimension" \
    --argjson dimension "$dimension_value" \
    --argjson vectorCount "$vector_count_value" \
    --argjson configGeneration "$config_generation_value" \
    --argjson billedCostMicros "$billed_cost_value" '
      {
        schemaVersion: $schemaVersion,
        status: $status,
        category: $category,
        alias: $alias,
        timestamp: $timestamp,
        requestId: (if $requestId == "" then null else $requestId end),
        httpStatus: $httpStatus,
        contract: {
          expected: {
            spaceId: $expectedSpaceId,
            spaceRevision: $expectedSpaceRevision,
            dimension: $expectedDimension
          },
          actual: {
            spaceId: (if $actualSpaceId == "" then null else $actualSpaceId end),
            spaceRevision: (if $actualSpaceRevision == 0 then null else $actualSpaceRevision end),
            dimension: (if $dimension == 0 then null else $dimension end)
          }
        },
        vectorCount: $vectorCount,
        configGeneration: (if $configGeneration == 0 then null else $configGeneration end),
        billedCostMicros: (if $billedCostMicros == 0 then 0 else $billedCostMicros end)
      }
    '
}

fail_report() {
  local exit_code=$1
  local category=$2
  local request_id_value=${3:-}
  local http_status_value=${4:-0}
  emit_report "fail" "$category" "$model_alias" "$request_id_value" "$http_status_value"
  exit "$exit_code"
}

header_value() {
  local header_name=$1
  local header_file=$2
  awk -v expected="$header_name" '
    {
      sub(/\r$/, "")
      name = $0
      sub(/:.*/, "", name)
      if (tolower(name) == tolower(expected)) {
        value = $0
        sub(/^[^:]*:[[:space:]]*/, "", value)
      }
    }
    END {
      if (value == "") exit 1
      print value
    }
  ' "$header_file"
}

gateway_url=""
model_alias=""
gateway_header_file=""
ca_file=""
expected_space_id=""
expected_space_revision=""
expected_dimension=""
timeout_seconds=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --gateway-url) gateway_url=${2:-}; shift 2 ;;
    --alias) model_alias=${2:-}; shift 2 ;;
    --header-file) gateway_header_file=${2:-}; shift 2 ;;
    --ca-file) ca_file=${2:-}; shift 2 ;;
    --expected-space-id) expected_space_id=${2:-}; shift 2 ;;
    --expected-space-revision) expected_space_revision=${2:-}; shift 2 ;;
    --expected-dimension) expected_dimension=${2:-}; shift 2 ;;
    --timeout-seconds) timeout_seconds=${2:-}; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) usage; exit 10 ;;
  esac
done

for dependency in curl jq awk date id mktemp sleep stat; do
  command -v "$dependency" >/dev/null || {
    printf '{"schemaVersion":"%s","status":"fail","category":"localDependency"}\n' \
      "$schema_version"
    exit 11
  }
done

if [[ -z "$gateway_url" || -z "$model_alias" || -z "$gateway_header_file" ||
      -z "$expected_space_id" || -z "$expected_space_revision" ||
      -z "$expected_dimension" || -z "$timeout_seconds" ]]; then
  usage
  exit 10
fi

gateway_url=${gateway_url%/}
if [[ ! $gateway_url =~ ^https://[^/?#@[:space:]]+$ ||
      ! $model_alias =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ||
      ! $expected_space_id =~ ^[A-Za-z0-9][A-Za-z0-9._:/-]{0,254}$ ||
      ! $expected_space_revision =~ ^[1-9][0-9]*$ ||
      ! $expected_dimension =~ ^[1-9][0-9]*$ ||
      ! $timeout_seconds =~ ^[1-9][0-9]*$ ||
      $timeout_seconds -gt 300 ]]; then
  usage
  exit 10
fi

if [[ -L "$gateway_header_file" || ! -f "$gateway_header_file" ||
      ! -r "$gateway_header_file" || $(stat -c '%a' "$gateway_header_file") != "600" ||
      $(stat -c '%u' "$gateway_header_file") != "$(id -u)" ]] ||
   ! awk '
      NR == 1 && /^Authorization: Bearer [^[:space:]]+$/ { valid = 1; next }
      { valid = 0 }
      END { exit(valid && NR == 1 ? 0 : 1) }
    ' "$gateway_header_file"; then
  fail_report 12 "protectedHeaderFile"
fi

tls_arguments=()
if [[ -n "$ca_file" ]]; then
  if [[ -L "$ca_file" || ! -f "$ca_file" || ! -r "$ca_file" ]]; then
    fail_report 12 "caFile"
  fi
  tls_arguments=(--cacert "$ca_file")
fi

tmp_dir=$(mktemp -d)
chmod 700 "$tmp_dir"
cleanup() {
  rm -rf -- "$tmp_dir"
}
trap cleanup EXIT

curl_arguments=(
  --silent
  --show-error
  --fail-with-body
  --proto '=https'
  --tlsv1.2
  --connect-timeout "$timeout_seconds"
  --max-time "$timeout_seconds"
  --max-redirs 0
  --max-filesize 33554432
  "${tls_arguments[@]}"
  --header "@$gateway_header_file"
)

alias_body="$tmp_dir/alias.json"
alias_headers="$tmp_dir/alias.headers"
curl_stderr="$tmp_dir/curl.stderr"
alias_deadline=$((SECONDS + timeout_seconds))
alias_status="000"
alias_exit=0

while true; do
  set +e
  alias_status=$(curl "${curl_arguments[@]}" \
    --output "$alias_body" \
    --dump-header "$alias_headers" \
    --write-out '%{http_code}' \
    "$gateway_url/v1/models/$model_alias" 2>"$curl_stderr")
  alias_exit=$?
  set -e

  if [[ $alias_exit -eq 0 ]] && jq -e --arg alias "$model_alias" '
      .id == $alias and .object == "model" and .owned_by == "light-gateway"
    ' "$alias_body" >/dev/null 2>&1; then
    break
  fi

  alias_request_id=$(header_value x-request-id "$alias_headers" 2>/dev/null || true)
  if [[ $alias_status == "401" || $alias_status == "403" ]]; then
    fail_report 21 "gatewayAuthorization" "$alias_request_id" "$alias_status"
  fi
  if [[ $alias_exit -ne 0 && $alias_exit -ne 22 ]]; then
    fail_report 13 "transport" "$alias_request_id"
  fi
  if [[ $alias_status != "404" ]]; then
    fail_report 26 "gatewayError" "$alias_request_id" "$alias_status"
  fi
  if (( SECONDS >= alias_deadline )); then
    fail_report 20 "aliasNotVisible" "$alias_request_id" "$alias_status"
  fi
  sleep 1
done

request_body="$tmp_dir/request.json"
response_body="$tmp_dir/response.json"
response_headers="$tmp_dir/response.headers"
jq -n --arg model "$model_alias" --arg text "$fixed_text" \
  '{model:$model,input:$text}' >"$request_body"
chmod 600 "$request_body"

set +e
embedding_status=$(curl "${curl_arguments[@]}" \
  --request POST \
  --header 'content-type: application/json' \
  --header "X-Light-Expected-Embedding-Space-Id: $expected_space_id" \
  --header "X-Light-Expected-Embedding-Space-Revision: $expected_space_revision" \
  --data-binary "@$request_body" \
  --output "$response_body" \
  --dump-header "$response_headers" \
  --write-out '%{http_code}' \
  "$gateway_url/v1/embeddings" 2>"$curl_stderr")
embedding_exit=$?
set -e

request_id=$(header_value x-request-id "$response_headers" 2>/dev/null || true)
if [[ $embedding_exit -ne 0 && $embedding_exit -ne 22 ]]; then
  fail_report 13 "transport" "$request_id"
fi

if [[ $embedding_status != "200" ]]; then
  error_code=$(jq -r '.error.code // .error.type // empty' "$response_body" 2>/dev/null || true)
  case "$embedding_status:$error_code" in
    401:*|403:*) fail_report 21 "gatewayAuthorization" "$request_id" "$embedding_status" ;;
    404:model_not_found) fail_report 20 "aliasNotVisible" "$request_id" "$embedding_status" ;;
    429:rate_limit_exceeded) fail_report 23 "providerRateLimited" "$request_id" "$embedding_status" ;;
    504:provider_error) fail_report 24 "providerTimeout" "$request_id" "$embedding_status" ;;
    400:provider_error|502:provider_error)
      fail_report 22 "providerError" "$request_id" "$embedding_status" ;;
    400:invalid_request|400:unsupported_feature)
      fail_report 25 "embeddingContract" "$request_id" "$embedding_status" ;;
    429:capacity_exhausted|429:budget_exhausted|503:model_unavailable|503:service_unavailable)
      fail_report 26 "gatewayError" "$request_id" "$embedding_status" ;;
    *) fail_report 26 "gatewayError" "$request_id" "$embedding_status" ;;
  esac
fi

if ! jq -e --arg alias "$model_alias" --argjson dimension "$expected_dimension" '
    .object == "list" and
    .model == $alias and
    (.data | type) == "array" and
    (.data | length) == 1 and
    (.data[0].embedding | type) == "array" and
    (.data[0].embedding | length) == $dimension
  ' "$response_body" >/dev/null 2>&1; then
  fail_report 25 "embeddingContract" "$request_id" "$embedding_status"
fi

actual_space_id=$(header_value x-light-embedding-space-id "$response_headers" 2>/dev/null || true)
actual_space_revision=$(header_value x-light-embedding-space-revision "$response_headers" 2>/dev/null || true)
config_generation=$(header_value x-light-config-generation "$response_headers" 2>/dev/null || true)
billed_cost_micros=$(header_value x-light-billed-cost-micros "$response_headers" 2>/dev/null || true)

if [[ $actual_space_id != "$expected_space_id" ||
      $actual_space_revision != "$expected_space_revision" ||
      ! $config_generation =~ ^[1-9][0-9]*$ ||
      ! $billed_cost_micros =~ ^[0-9]+$ ||
      -z "$request_id" ]]; then
  fail_report 25 "embeddingContract" "$request_id" "$embedding_status"
fi

actual_dimension=$(jq -er '.data[0].embedding | length' "$response_body")
vector_count=$(jq -er '.data | length' "$response_body")
emit_report \
  "pass" "validated" "$model_alias" "$request_id" "$embedding_status" \
  "$config_generation" "$billed_cost_micros" "$vector_count" "$actual_dimension" \
  "$actual_space_id" "$actual_space_revision"

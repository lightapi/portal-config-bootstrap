#!/usr/bin/env bash
set -euo pipefail

log() {
  printf '[import-instance-event-deltas] %s\n' "$*"
}

die() {
  printf '[import-instance-event-deltas] error: %s\n' "$*" >&2
  exit 1
}

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd -- "$script_dir/.." && pwd)"
stack_dir="${PORTAL_STACK_DIR:-$repo_dir}"
delta_dir="${PORTAL_INSTANCE_EVENT_DELTA_DIR:-$repo_dir/data/private-event-deltas}"
manifest="${PORTAL_INSTANCE_EVENT_DELTA_MANIFEST:-$delta_dir/manifest.json}"
verify_delta_sql="${EVENT_DELTA_VERIFY_SQL:-$repo_dir/events/deltas/verify-event-delta.sql}"
container_cmd="${CONTAINER_CMD:-docker}"
release_image_env_file="${RELEASE_IMAGE_ENV_FILE:-$repo_dir/docker-images.env}"

[[ -d "$delta_dir" ]] || {
  log "private delta directory is absent; nothing to import: $delta_dir"
  exit 0
}

shopt -s nullglob
private_json=("$delta_dir"/*.json)
shopt -u nullglob
if ((${#private_json[@]} == 0)); then
  log "no private event deltas found in $delta_dir"
  exit 0
fi

command -v jq >/dev/null 2>&1 || die "jq is required to validate the private delta manifest"
[[ -f "$manifest" ]] || die "private delta manifest is required: $manifest"
[[ -f "$verify_delta_sql" ]] || die "event delta verification SQL is missing: $verify_delta_sql"

load_env_file_var() {
  local name="$1"
  local value

  [[ -z "${!name:-}" && -f "$release_image_env_file" ]] || return 0
  value="$(awk -F= -v key="$name" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$release_image_env_file")"
  [[ -z "$value" ]] || export "$name=$value"
}

default_event_import_network() {
  local network

  network="$("$container_cmd" inspect -f '{{range $name, $_ := .NetworkSettings.Networks}}{{println $name}}{{end}}' postgres 2>/dev/null | head -n 1 || true)"
  [[ -n "$network" ]] && printf '%s\n' "$network" || printf '%s_default\n' "$(basename "$stack_dir")"
}

wait_for_postgres() {
  local attempts="${POSTGRES_READY_ATTEMPTS:-180}"
  local interval="${POSTGRES_READY_INTERVAL:-2}"
  local attempt=1

  while [[ "$attempt" -le "$attempts" ]]; do
    if "$container_cmd" exec postgres psql -h localhost -p 5432 -U postgres \
        -d configserver -tAc "select 1;" >/dev/null 2>&1; then
      return 0
    fi
    if ! "$container_cmd" inspect -f '{{.State.Running}}' postgres 2>/dev/null | grep -qx true; then
      "$container_cmd" logs --tail "${POSTGRES_READY_LOG_LINES:-120}" postgres >&2 || true
      die "postgres exited before private event delta import"
    fi
    sleep "$interval"
    attempt=$((attempt + 1))
  done
  die "postgres did not become ready before private event delta import"
}

verify_delta_applied() {
  local delta="$1"

  {
    printf '%s\n' \
      'CREATE TEMP TABLE expected_delta_input_t (payload_base64 TEXT NOT NULL);' \
      'COPY expected_delta_input_t (payload_base64) FROM STDIN;'
    base64 < "$delta" | tr -d '\n'
    printf '\n\\.\n'
    printf '%s\n' \
      "SELECT convert_from(decode(payload_base64, 'base64'), 'UTF8') AS expected_json FROM expected_delta_input_t \\gset"
    cat "$verify_delta_sql"
  } | "$container_cmd" exec -i postgres psql \
        -h localhost -p 5432 -U postgres -d configserver -v ON_ERROR_STOP=1
}

manifest_rows="$(mktemp "${TMPDIR:-/tmp}/portal-instance-deltas.XXXXXX")"
trap 'rm -f "$manifest_rows"' EXIT

jq -e '
  (.format == "lightapi.portal-instance-event-deltas") and
  (.formatVersion == 1) and
  (.instanceId | type == "string" and test("^[A-Za-z0-9._-]{1,128}$")) and
  (.eventDeltas | type == "array") and
  (([.eventDeltas[].id] | length) == ([.eventDeltas[].id] | unique | length)) and
  (([.eventDeltas[].file] | length) == ([.eventDeltas[].file] | unique | length)) and
  (all(.eventDeltas[];
    (.id | type == "string" and test("^[A-Za-z0-9._-]{1,128}$")) and
    (.file | type == "string" and test("^[A-Za-z0-9._-]+\\.json$") and . != "manifest.json") and
    (.sha256 | type == "string" and test("^[0-9a-f]{64}$"))))
' "$manifest" >/dev/null || die "invalid private delta manifest contract: $manifest"

jq -r '
  .instanceId as $instance
  | .eventDeltas[]
  | [$instance, .id, .file, .sha256] | @tsv
' "$manifest" > "$manifest_rows"

instance_id="$(jq -er '.instanceId' "$manifest")"
declared_count="$(jq -er '.eventDeltas | length' "$manifest")"
actual_count="$(wc -l < "$manifest_rows" | tr -d '[:space:]')"
[[ "$actual_count" == "$declared_count" ]] || die "one or more private delta manifest entries are invalid"

declare -A authorized_files=()
while IFS=$'\t' read -r -u 3 _ delta_id delta_file expected_checksum; do
  delta="$delta_dir/$delta_file"
  [[ -f "$delta" ]] || die "private event delta is missing: $delta_file"
  jq -e 'type == "array" and length > 0' "$delta" >/dev/null ||
    die "private event delta must be a non-empty JSON array: $delta_file"
  actual_checksum="$(sha256sum "$delta" | awk '{print $1}')"
  [[ "$actual_checksum" == "$expected_checksum" ]] ||
    die "checksum mismatch for private delta $delta_id: manifest=$expected_checksum file=$actual_checksum"
  authorized_files["$delta_file"]=1
done 3< "$manifest_rows"

for path in "${private_json[@]}"; do
  name="$(basename -- "$path")"
  [[ "$name" == "$(basename -- "$manifest")" ]] && continue
  [[ -n "${authorized_files[$name]:-}" ]] || die "private delta is not authorized by the manifest: $name"
done

if [[ "$declared_count" == "0" ]]; then
  log "private delta manifest contains no event deltas: $manifest"
  exit 0
fi

wait_for_postgres
"$container_cmd" exec -i postgres psql -h localhost -p 5432 -U postgres -d configserver -v ON_ERROR_STOP=1 <<'SQL'
CREATE TABLE IF NOT EXISTS portal_instance_event_delta_t (
  instance_id VARCHAR(128) NOT NULL,
  delta_id VARCHAR(128) NOT NULL,
  checksum VARCHAR(128) NOT NULL,
  imported_ts TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (instance_id, delta_id)
);
SQL

load_env_file_var EVENT_IMPORTER_IMAGE
[[ -n "${EVENT_IMPORTER_IMAGE:-}" ]] ||
  die "EVENT_IMPORTER_IMAGE is not configured; refusing an unversioned importer"
importer_image="$EVENT_IMPORTER_IMAGE"
import_network="${EVENT_IMPORT_NETWORK:-$(default_event_import_network)}"

while IFS=$'\t' read -r -u 3 _ delta_id delta_file checksum; do
  delta="$delta_dir/$delta_file"
  existing_checksum="$("$container_cmd" exec postgres psql -h localhost -p 5432 -U postgres -d configserver -tAc \
    "select checksum from portal_instance_event_delta_t where instance_id = '$instance_id' and delta_id = '$delta_id';" | tr -d '[:space:]' || true)"
  if [[ -n "$existing_checksum" ]]; then
    [[ "$existing_checksum" == "$checksum" ]] ||
      die "checksum drift for imported private delta $instance_id/$delta_id"
    log "already imported $instance_id/$delta_id"
    continue
  fi

  log "importing $instance_id/$delta_id with $importer_image"
  "$container_cmd" run --rm -i \
    --network "$import_network" \
    -e DB_JDBC_URL="${EVENT_IMPORT_DB_JDBC_URL:-jdbc:postgresql://postgres:5432/configserver}" \
    -e DB_USERNAME="${EVENT_IMPORT_DB_USERNAME:-postgres}" \
    -e DB_PASSWORD="${EVENT_IMPORT_DB_PASSWORD:-secret}" \
    -e DB_MAXIMUM_POOL_SIZE="${EVENT_IMPORT_DB_MAXIMUM_POOL_SIZE:-3}" \
    "$importer_image" --filename /dev/stdin --fail-on-error < "$delta" ||
      die "failed to import private delta $instance_id/$delta_id"
  verify_delta_applied "$delta" ||
    die "private delta $instance_id/$delta_id was not fully applied"
  "$container_cmd" exec postgres psql -h localhost -p 5432 -U postgres -d configserver -v ON_ERROR_STOP=1 \
    -c "INSERT INTO portal_instance_event_delta_t (instance_id, delta_id, checksum) VALUES ('$instance_id', '$delta_id', '$checksum');"
done 3< "$manifest_rows"

log "private instance event deltas completed for $instance_id"

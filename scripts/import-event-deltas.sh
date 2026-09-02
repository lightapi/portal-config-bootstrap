#!/usr/bin/env bash
set -euo pipefail

log() {
  printf '[import-event-deltas] %s\n' "$*"
}

die() {
  printf '[import-event-deltas] error: %s\n' "$*" >&2
  exit 1
}

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd -- "$script_dir/.." && pwd)"
delta_dir="${EVENT_DELTA_DIR:-$repo_dir/events/deltas}"
superseded_delta_file="${EVENT_SUPERSEDED_DELTA_FILE:-$delta_dir/superseded-deltas.list}"
verify_delta_sql="${EVENT_DELTA_VERIFY_SQL:-$delta_dir/verify-event-delta.sql}"
compose=(docker compose)
light_portal_env_file="${LIGHT_PORTAL_ENV_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/lightapi/light-portal.env}"

if [[ -f "$repo_dir/docker-images.env" ]]; then
  compose+=(--env-file "$repo_dir/docker-images.env")
fi

if [[ -f "$light_portal_env_file" ]]; then
  compose+=(--env-file "$light_portal_env_file")
fi

load_env_file_var() {
  local name="$1"
  local value

  [[ -z "${!name:-}" && -f "$repo_dir/docker-images.env" ]] || return 0
  value="$(awk -F= -v key="$name" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$repo_dir/docker-images.env")"
  [[ -z "$value" ]] || export "$name=$value"
}

default_event_import_network() {
  local network

  network="$(docker inspect -f '{{range $name, $_ := .NetworkSettings.Networks}}{{println $name}}{{end}}' postgres 2>/dev/null | head -n 1 || true)"
  if [[ -n "$network" ]]; then
    printf '%s\n' "$network"
  else
    printf '%s_default\n' "$(basename "$repo_dir")"
  fi
}

verify_delta_applied() {
  local delta="$1"

  [[ -f "$verify_delta_sql" ]] || die "event delta verification SQL is missing: $verify_delta_sql"

  {
    printf '%s\n' \
      'CREATE TEMP TABLE expected_delta_input_t (payload_base64 TEXT NOT NULL);' \
      'COPY expected_delta_input_t (payload_base64) FROM STDIN;'
    base64 < "$delta" | tr -d '\n'
    printf '\n\\.\n'
    printf '%s\n' \
      "SELECT convert_from(decode(payload_base64, 'base64'), 'UTF8') AS expected_json FROM expected_delta_input_t \\gset"
    cat "$verify_delta_sql"
  } | docker exec -i postgres psql \
        -h localhost -p 5432 -U postgres -d configserver \
        -v ON_ERROR_STOP=1
}

is_superseded_delta() {
  local delta_id="$1"

  [[ -f "$superseded_delta_file" ]] || return 1
  awk '
    /^[[:space:]]*(#|$)/ { next }
    { sub(/^[[:space:]]+/, ""); sub(/[[:space:]]+$/, "") }
    $0 == target { found = 1 }
    END { exit(found ? 0 : 1) }
  ' target="$delta_id" "$superseded_delta_file"
}

"$script_dir/wait-for-postgres.sh"
"${compose[@]}" up -d --no-deps hybrid-command hybrid-query

docker exec -i postgres psql -h localhost -p 5432 -U postgres -d configserver -v ON_ERROR_STOP=1 <<'SQL'
CREATE TABLE IF NOT EXISTS portal_event_delta_t (
  delta_id VARCHAR(128) PRIMARY KEY,
  checksum VARCHAR(128) NOT NULL,
  imported_ts TIMESTAMPTZ NOT NULL DEFAULT now()
);
SQL

shopt -s nullglob
deltas=("$delta_dir"/*.json)
shopt -u nullglob

if ((${#deltas[@]} == 0)); then
  log "no event deltas found in $delta_dir"
  exit 0
fi

IFS=$'\n' deltas=($(printf '%s\n' "${deltas[@]}" | sort))
unset IFS

load_env_file_var EVENT_IMPORTER_IMAGE
importer_image="${EVENT_IMPORTER_IMAGE:-networknt/event-importer:latest}"
import_network="${EVENT_IMPORT_NETWORK:-$(default_event_import_network)}"

for delta in "${deltas[@]}"; do
  delta_id="$(basename -- "$delta" .json)"
  checksum="$(sha256sum "$delta" | awk '{print $1}')"
  existing_checksum="$(docker exec postgres psql -h localhost -p 5432 -U postgres -d configserver -tAc "select checksum from portal_event_delta_t where delta_id = '$delta_id';" | tr -d '[:space:]' || true)"

  if [[ -n "$existing_checksum" ]]; then
    [[ "$existing_checksum" == "$checksum" ]] ||
      die "checksum drift for imported delta $delta_id: database=$existing_checksum file=$checksum"
    log "already imported $delta_id"
    continue
  fi

  if is_superseded_delta "$delta_id"; then
    log "skipping superseded delta $delta_id"
    docker exec -i postgres psql -h localhost -p 5432 -U postgres -d configserver -v ON_ERROR_STOP=1 \
      -c "INSERT INTO portal_event_delta_t (delta_id, checksum) VALUES ('$delta_id', '$checksum');"
    continue
  fi

  log "importing $delta_id with $importer_image"
  if ! docker run --rm -i \
    --network "$import_network" \
    -e DB_JDBC_URL="${EVENT_IMPORT_DB_JDBC_URL:-jdbc:postgresql://postgres:5432/configserver}" \
    -e DB_USERNAME="${EVENT_IMPORT_DB_USERNAME:-postgres}" \
    -e DB_PASSWORD="${EVENT_IMPORT_DB_PASSWORD:-secret}" \
    -e DB_MAXIMUM_POOL_SIZE="${EVENT_IMPORT_DB_MAXIMUM_POOL_SIZE:-3}" \
    "$importer_image" \
    --filename /dev/stdin \
    --fail-on-error < "$delta"; then
    die "failed to import $delta_id"
  fi

  if ! verify_delta_applied "$delta"; then
    die "event importer exited successfully but $delta_id was not fully applied"
  fi
  log "verified event effects for $delta_id"

  docker exec -i postgres psql -h localhost -p 5432 -U postgres -d configserver -v ON_ERROR_STOP=1 \
    -c "INSERT INTO portal_event_delta_t (delta_id, checksum) VALUES ('$delta_id', '$checksum');"
done

log "event deltas completed"

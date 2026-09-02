#!/usr/bin/env bash
set -euo pipefail

log() {
  printf '[restart-bootstrap-stack] %s\n' "$*"
}

die() {
  printf '[restart-bootstrap-stack] error: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'USAGE'
Usage: ./scripts/restart-bootstrap-stack.sh [options]

Options:
  --recreate-database  Download and verify the latest signed events.zip,
                       preserve the current database as a timestamped backup,
                       initialize a fresh database, and force the full baseline
                       import.
  -h, --help           Show this help.

Environment overrides for --recreate-database:
  BOOTSTRAP_EVENTS_ARCHIVE_URL  Default: https://cdn.networknt.com/events.zip
  BOOTSTRAP_EVENTS_FILE         Default: <repo>/data/events.json
  BOOTSTRAP_POSTGRES_DATA_DIR   Default: <repo>/postgres-db/data
  EVENT_BUNDLE_KEY_DIR          Trusted public keys named <keyId>.pem. Default:
                                <repo>/release-keys
  BOOTSTRAP_EVENTS_REQUIRE_BUNDLE_MATCH
                                Also require an adjacent verified bundle digest
                                for a non-default BOOTSTRAP_EVENTS_FILE.
  EVENT_IMPORT_PHYSICAL_CHUNK_EVENTS
                          Physical commits may contain this many singleton
                          transactions. Default: 1; qualification maximum: 500
  EVENT_IMPORT_PHYSICAL_CHUNK_BYTES
                          Soft physical chunk byte limit. Default: 16777216
  EVENT_IMPORT_MAX_EVENT_BYTES
                          Hard per-event byte limit. Default: 67108864
  EVENT_IMPORT_GRAPH_WAIT_TIMEOUT_SECONDS
                          Per-graph-barrier timeout. Default: 120
  EVENT_IMPORT_TOTAL_BARRIER_TIMEOUT_SECONDS
                          Whole-import graph-barrier budget. Default: 900
  EVENT_IMPORT_SYNCHRONOUS_COMMIT_OFF
                          Use SET LOCAL synchronous_commit=off. Default: false
  EVENT_IMPORT_DIAGNOSE_FAILED_CHUNK
                          Diagnose the first event in a failed chunk. Default: false
  EVENT_IMPORT_PHYSICAL_CHUNKING_DISABLED
                          Force one physical commit per event. Default: false
USAGE
}

recreate_database=false
while (($#)); do
  case "$1" in
    --recreate-database)
      recreate_database=true
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
  shift
done

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd -- "$script_dir/.." && pwd)"
compose=(docker compose -f "$repo_dir/docker-compose.yml" -f "$repo_dir/docker-compose.bootstrap.yml")
light_portal_env_file="${LIGHT_PORTAL_ENV_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/lightapi/light-portal.env}"
bootstrap_env_file="${BOOTSTRAP_ENV_FILE:-$repo_dir/.env.bootstrap}"

if [[ -f "$repo_dir/docker-images.env" ]]; then
  compose+=(--env-file "$repo_dir/docker-images.env")
fi

if [[ -f "$light_portal_env_file" ]]; then
  compose+=(--env-file "$light_portal_env_file")
fi

if [[ -f "$bootstrap_env_file" ]]; then
  compose+=(--env-file "$bootstrap_env_file")
else
  die "bootstrap environment file is missing: $bootstrap_env_file (copy .env.bootstrap.example)"
fi

bootstrap_env_value() {
  local name="$1"

  awk -F= -v key="$name" '
    $1 == key {
      sub(/^[^=]*=/, "")
      gsub(/^"|"$/, "")
      print
      exit
    }
  ' "$bootstrap_env_file"
}

compose_project_name="$(bootstrap_env_value COMPOSE_PROJECT_NAME)"
compose_project_name="${compose_project_name:-light-portal-bootstrap}"
[[ "$compose_project_name" =~ ^[a-z0-9][a-z0-9_-]*$ ]] ||
  die "invalid COMPOSE_PROJECT_NAME: $compose_project_name"
export COMPOSE_PROJECT_NAME="$compose_project_name"

validate_sso_assets() {
  local required_file
  local required_var
  local required_value
  local sso_asset_root="${BOOTSTRAP_SSO_ASSET_ROOT:-$repo_dir/portal-bff-sso}"

  for required_file in \
    "$sso_asset_root/tls/ca.pem" \
    "$sso_asset_root/tls/cert.pem" \
    "$sso_asset_root/tls/key.pem" \
    "$sso_asset_root/lightapi/dist/index.html"; do
    [[ -s "$required_file" ]] || die "required SSO asset is missing: $required_file"
  done

  for required_var in \
    MSAL_TENANT_ID \
    MSAL_CLIENT_ID \
    MSAL_REDIRECT_URI \
    MSAL_EXCHANGE_CLIENT_ID \
    MSAL_EXCHANGE_CLIENT_SECRET \
    PORTAL_BFF_SSO_LIGHT_PORTAL_AUTHORIZATION; do
    required_value="$(bootstrap_env_value "$required_var")"
    [[ -n "$required_value" && "$required_value" != *replace-* ]] ||
      die "$required_var is not configured in $bootstrap_env_file"
  done

  "${compose[@]}" config --quiet
}

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

event_store_count() {
  docker exec postgres psql -h localhost -p 5432 -U postgres -d configserver -tAc "select count(*) from event_store_t;" 2>/dev/null | tr -d '[:space:]'
}

verify_baseline_bundle() {
  local events_bundle="$1"
  local bundle_key_dir="${EVENT_BUNDLE_KEY_DIR:-$repo_dir/release-keys}"
  local importer_image

  [[ "$events_bundle" == /* ]] || events_bundle="$repo_dir/$events_bundle"
  [[ "$bundle_key_dir" == /* ]] || bundle_key_dir="$repo_dir/$bundle_key_dir"
  [[ -f "$events_bundle" ]] || die "signed baseline bundle is missing: $events_bundle"
  [[ -d "$bundle_key_dir" ]] || die "trusted bundle key directory is missing: $bundle_key_dir"

  load_env_file_var EVENT_IMPORTER_IMAGE
  importer_image="${EVENT_IMPORTER_IMAGE:-networknt/event-importer:latest}"
  log "verifying signed baseline bundle before extraction"
  docker run --rm \
    -v "$(dirname -- "$events_bundle"):/bundle:ro,z" \
    -v "$bundle_key_dir:/bundle-keys:ro,z" \
    "$importer_image" \
    --verify-bundle \
    --bundle "/bundle/$(basename -- "$events_bundle")" \
    --bundle-key-dir /bundle-keys ||
    die "signed baseline bundle verification failed"
}

record_verified_bundle_digest() {
  local events_bundle="$1"
  local events_file="$2"
  local digest_file="${BOOTSTRAP_EVENTS_SOURCE_BUNDLE_SHA256_FILE:-$events_file.source-bundle.sha256}"
  local bundle_digest

  bundle_digest="$(sha256sum "$events_bundle" | awk '{print $1}')"
  [[ "$bundle_digest" =~ ^[0-9a-f]{64}$ ]] ||
    die "cannot calculate the verified bundle digest: $events_bundle"
  printf '%s\n' "$bundle_digest" > "$digest_file.tmp"
  mv "$digest_file.tmp" "$digest_file"
}

require_matching_verified_bundle() {
  local events_file="$1"
  local default_events_file="$repo_dir/data/events.json"
  local events_bundle
  local digest_file
  local expected_digest
  local actual_digest

  [[ "$events_file" == /* ]] || events_file="$repo_dir/$events_file"
  if [[ "$events_file" != "$default_events_file" &&
        ! "${BOOTSTRAP_EVENTS_REQUIRE_BUNDLE_MATCH:-false}" =~ ^(1|true|TRUE|yes|YES)$ ]]; then
    return 0
  fi

  events_bundle="${BOOTSTRAP_EVENTS_BUNDLE:-$(dirname -- "$events_file")/events.zip}"
  [[ "$events_bundle" == /* ]] || events_bundle="$repo_dir/$events_bundle"
  digest_file="${BOOTSTRAP_EVENTS_SOURCE_BUNDLE_SHA256_FILE:-$events_file.source-bundle.sha256}"
  [[ "$digest_file" == /* ]] || digest_file="$repo_dir/$digest_file"

  [[ -f "$events_bundle" ]] || die "verified source bundle is missing: $events_bundle"
  [[ -f "$digest_file" ]] || die "verified source-bundle digest is missing: $digest_file"
  expected_digest="$(tr -d '[:space:]' < "$digest_file")"
  [[ "$expected_digest" =~ ^[0-9a-f]{64}$ ]] ||
    die "verified source-bundle digest is invalid: $digest_file"
  actual_digest="$(sha256sum "$events_bundle" | awk '{print $1}')"
  [[ "$actual_digest" == "$expected_digest" ]] ||
    die "baseline events source bundle no longer matches its verified digest; recreate the editable baseline"
}

replace_literal_in_file() {
  local file="$1"
  local source="$2"
  local target="$3"

  awk -v src="$source" -v dst="$target" '
    {
      out = ""
      line = $0
      while ((pos = index(line, src)) > 0) {
        out = out substr(line, 1, pos - 1) dst
        line = substr(line, pos + length(src))
      }
      print out line
    }
  ' "$file" > "$file.tmp"
  mv "$file.tmp" "$file"
}

normalize_events_json() {
  local events_file="$1"
  local source_redirect_uri="${BOOTSTRAP_SOURCE_CLIENT_REDIRECT_URI:-https://localhost:3000/authorization}"
  local target_redirect_uri="${BOOTSTRAP_CLIENT_REDIRECT_URI:-https://dev.lightapi.net/authorization}"

  [[ -f "$events_file" ]] || return 0
  [[ "$source_redirect_uri" != "$target_redirect_uri" ]] || return 0

  if grep -Fq "$source_redirect_uri" "$events_file"; then
    log "normalizing OAuth client redirectUri to $target_redirect_uri"
    replace_literal_in_file "$events_file" "$source_redirect_uri" "$target_redirect_uri"
  fi
}

import_baseline_events_if_needed() {
  local import_mode="${IMPORT_EVENTS:-auto}"
  local import_mode_lower="${import_mode,,}"
  local events_file="${BOOTSTRAP_EVENTS_FILE:-$repo_dir/data/events.json}"
  local event_count
  local importer_image
  local import_network
  local extra_args=()

  case "$import_mode_lower" in
    false|no|0|"")
      log "baseline event import skipped"
      return 0
      ;;
    auto|true|yes|1|force)
      ;;
    *)
      die "invalid IMPORT_EVENTS value: $import_mode"
      ;;
  esac

  event_count="$(event_store_count || true)"
  [[ "$event_count" =~ ^[0-9]+$ ]] || die "cannot read event_store_t before baseline event import"

  if [[ "$import_mode_lower" == "auto" && "$event_count" -gt 0 ]]; then
    log "event_store_t already has $event_count rows; skipping baseline event import"
    return 0
  fi

  [[ -f "$events_file" ]] || die "baseline events file is missing: $events_file"
  require_matching_verified_bundle "$events_file"
  normalize_events_json "$events_file"

  load_env_file_var EVENT_IMPORTER_IMAGE
  importer_image="${EVENT_IMPORTER_IMAGE:-networknt/event-importer:latest}"
  import_network="${EVENT_IMPORT_NETWORK:-$(default_event_import_network)}"

  if [[ "$event_count" -eq 0 ]]; then
    extra_args+=(
      --bootstrap-import
      --physical-chunk-events "${EVENT_IMPORT_PHYSICAL_CHUNK_EVENTS:-500}"
      --physical-chunk-bytes "${EVENT_IMPORT_PHYSICAL_CHUNK_BYTES:-16777216}"
      --max-event-bytes "${EVENT_IMPORT_MAX_EVENT_BYTES:-67108864}"
    )
    [[ "${EVENT_IMPORT_SYNCHRONOUS_COMMIT_OFF:-false}" =~ ^(1|true|TRUE|yes|YES)$ ]] &&
      extra_args+=(--bootstrap-synchronous-commit-off)
    [[ "${EVENT_IMPORT_DIAGNOSE_FAILED_CHUNK:-false}" =~ ^(1|true|TRUE|yes|YES)$ ]] &&
      extra_args+=(--diagnose-failed-chunk)
    [[ "${EVENT_IMPORT_PHYSICAL_CHUNKING_DISABLED:-false}" =~ ^(1|true|TRUE|yes|YES)$ ]] &&
      extra_args+=(--physical-chunking-disabled)
    log "empty destination detected; enabling direct event-table bootstrap import"
  fi

  log "importing baseline events from $events_file with $importer_image"
  docker run --rm -i \
    --network "$import_network" \
    -e DB_JDBC_URL="${EVENT_IMPORT_DB_JDBC_URL:-jdbc:postgresql://postgres:5432/configserver}" \
    -e DB_USERNAME="${EVENT_IMPORT_DB_USERNAME:-postgres}" \
    -e DB_PASSWORD="${EVENT_IMPORT_DB_PASSWORD:-secret}" \
    -e DB_MAXIMUM_POOL_SIZE="${EVENT_IMPORT_DB_MAXIMUM_POOL_SIZE:-3}" \
    "$importer_image" \
    --filename /dev/stdin \
    "${extra_args[@]}" < "$events_file"
}

prepare_operational_database_secret() {
  local prepare_script="$repo_dir/postgres-db/operations/bin/prepare-operational-secret.sh"
  local secret_dir="${BOOTSTRAP_OPERATIONAL_SECRET_DIR:-$repo_dir/postgres-db/secrets}"

  [[ -x "$prepare_script" ]] || die "operational database secret initializer is missing: $prepare_script"
  OPERATIONAL_SECRET_DIR="$secret_dir" "$prepare_script" >/dev/null
  log "operational database URL file is ready (content redacted)"
}

wait_for_curl() {
  local label="$1"
  shift
  local attempts="${BOOTSTRAP_HEALTHCHECK_ATTEMPTS:-60}"
  local interval="${BOOTSTRAP_HEALTHCHECK_INTERVAL:-2}"
  local attempt=1

  while [[ "$attempt" -le "$attempts" ]]; do
    if curl "$@" >/dev/null 2>&1; then
      return 0
    fi

    sleep "$interval"
    attempt=$((attempt + 1))
  done

  die "$label did not become ready after $attempts attempts"
}

wait_for_baseline_projection_cursor() {
  local attempts="${BOOTSTRAP_PROJECTION_CURSOR_ATTEMPTS:-300}"
  local interval="${BOOTSTRAP_PROJECTION_CURSOR_INTERVAL:-1}"
  local attempt=1
  local state

  while [[ "$attempt" -le "$attempts" ]]; do
    state="$(docker exec postgres psql -h localhost -p 5432 -U postgres \
      -d configserver -tAc "
        SELECT CASE WHEN COALESCE((
          SELECT next_offset
          FROM consumer_offsets
          WHERE group_id = 'user-query-group'
            AND topic_id = 1
            AND partition_id = 0
        ), 0) >= (SELECT next_offset FROM log_counter WHERE id = 1)
        THEN 'ready' ELSE 'waiting' END;
      " 2>/dev/null | tr -d '[:space:]' || true)"
    [[ "$state" == "ready" ]] && return 0
    sleep "$interval"
    attempt=$((attempt + 1))
  done

  die "event projection cursor did not catch up after $attempts attempts"
}

recreate_database_from_latest_events() {
  local events_file="${BOOTSTRAP_EVENTS_FILE:-$repo_dir/data/events.json}"
  local archive_url="${BOOTSTRAP_EVENTS_ARCHIVE_URL:-https://cdn.networknt.com/events.zip}"
  local archive_request_url="$archive_url"
  local postgres_data_dir="${BOOTSTRAP_POSTGRES_DATA_DIR:-$repo_dir/postgres-db/data}"
  local events_dir
  local archive_file
  local archive_tmp
  local events_tmp
  local backup_dir

  command -v curl >/dev/null 2>&1 || die "curl is required to recreate the database"
  command -v unzip >/dev/null 2>&1 || die "unzip is required to recreate the database"
  command -v sha256sum >/dev/null 2>&1 || die "sha256sum is required to recreate the database"

  if [[ "$postgres_data_dir" != /* ]]; then
    postgres_data_dir="$repo_dir/$postgres_data_dir"
  fi
  if [[ "$postgres_data_dir" != "/" ]]; then
    postgres_data_dir="${postgres_data_dir%/}"
  fi
  case "$postgres_data_dir" in
    ""|/|"$HOME"|"$repo_dir")
      die "unsafe database directory for recreation: $postgres_data_dir"
      ;;
  esac

  events_dir="$(dirname -- "$events_file")"
  archive_file="$events_dir/events.zip"
  archive_tmp="$archive_file.tmp"
  events_tmp="$events_file.tmp"
  mkdir -p "$events_dir"

  if [[ "$archive_request_url" == "https://cdn.networknt.com/events.zip" ]]; then
    archive_request_url="${archive_request_url}?cachebust=$(date -u +%Y%m%d%H%M%S)"
  fi

  log "downloading latest baseline events from $archive_request_url"
  curl -fsSL "$archive_request_url" -o "$archive_tmp" ||
    die "failed to download baseline events archive: $archive_request_url"
  verify_baseline_bundle "$archive_tmp"
  mv "$archive_tmp" "$archive_file"

  unzip -p "$archive_file" events.json > "$events_tmp" ||
    die "failed to extract events.json from $archive_file"
  [[ -s "$events_tmp" ]] || die "extracted events.json is empty"
  mv "$events_tmp" "$events_file"
  record_verified_bundle_digest "$archive_file" "$events_file"
  log "latest baseline installed at $events_file"

  log "stopping the current stack before replacing the database"
  "${compose[@]}" down

  if [[ -d "$postgres_data_dir" ]]; then
    backup_dir="${postgres_data_dir}.before-reset-$(date +%Y%m%d-%H%M%S)"
    [[ ! -e "$backup_dir" ]] || die "database backup path already exists: $backup_dir"
    mv "$postgres_data_dir" "$backup_dir"
    log "previous database preserved at $backup_dir"
  else
    log "database directory does not exist; creating a fresh database"
  fi

  export IMPORT_EVENTS=force
  # init-environment.sh renders the current canonical Config Server and
  # Knowledge DDL into the dedicated dev database/schema pair. Incremental
  # patches upgrade retained environments and must not be replayed over a
  # freshly initialized pair.
  export BOOTSTRAP_DEPLOY_SKIP_DB_PATCHES=true
}

cd "$repo_dir"

validate_sso_assets
prepare_operational_database_secret

if [[ "$recreate_database" == true ]]; then
  recreate_database_from_latest_events
fi

log "starting postgres"
"${compose[@]}" up -d postgres
"$script_dir/wait-for-postgres.sh"

defer_db_patches=false
if [[ "${BOOTSTRAP_DEPLOY_SKIP_DB_PATCHES:-false}" != "true" ]]; then
  initial_event_count="$(event_store_count || true)"
  import_mode_lower="${IMPORT_EVENTS:-auto}"
  import_mode_lower="${import_mode_lower,,}"

  # Data-seeding patches such as the LLM endpoint publication clone existing
  # baseline access-control rows. On a fresh database those prerequisites only
  # exist after the baseline event import. Existing databases still receive
  # schema patches before any new event deltas are projected.
  if [[ "$initial_event_count" == "0" && "$import_mode_lower" =~ ^(auto|true|yes|1|force)$ ]]; then
    defer_db_patches=true
    log "deferring database patches until after the fresh baseline event import"
  else
    "$script_dir/apply-db-patches.sh"
  fi
else
  log "skipping database patches"
fi

log "starting event processors"
"${compose[@]}" up -d --no-deps hybrid-command hybrid-query
import_baseline_events_if_needed

log "waiting for asynchronous baseline projection cursor"
wait_for_baseline_projection_cursor

if [[ "$defer_db_patches" == true ]]; then
  "$script_dir/apply-db-patches.sh"
fi

if [[ "${BOOTSTRAP_DEPLOY_SKIP_EVENT_DELTAS:-false}" != "true" ]]; then
  "$script_dir/import-event-deltas.sh"
else
  log "skipping event deltas"
fi

if [[ "${BOOTSTRAP_DEPLOY_SKIP_CONFIG_SNAPSHOT_REFRESH:-false}" != "true" ]]; then
  "$script_dir/refresh-config-snapshots.sh"
else
  log "skipping config snapshot refresh"
fi

if [[ "${BOOTSTRAP_DEPLOY_SKIP_PULL:-false}" != "true" ]]; then
  log "pulling configured images"
  "${compose[@]}" pull || log "image pull reported failures; continuing with local images"
fi

log "starting full stack"
"${compose[@]}" up -d --remove-orphans

log "restarting mounted-asset services"
"${compose[@]}" restart hybrid-command hybrid-query light-gateway portal-bff-sso

log "compose status"
"${compose[@]}" ps

if [[ "${BOOTSTRAP_DEPLOY_SKIP_HEALTHCHECK:-false}" != "true" ]]; then
  log "checking OAuth JWKS"
  wait_for_curl "OAuth JWKS" -k -f https://localhost:6881/oauth2/AZZRJE52eXu3t1hseacnGQ/keys
  log "checking portal host"
  wait_for_curl "portal host" -k -f -H 'Host: dev.lightapi.net' https://localhost/
  log "checking signin host"
  wait_for_curl "signin host" -k -f -H 'Host: devsignin.lightapi.net' https://localhost/
  customer_portal_host="$(bootstrap_env_value CUSTOMER_PORTAL_HOST)"
  customer_portal_host="${customer_portal_host:-dev.yourcompany.com}"
  portal_bff_sso_host_port="$(bootstrap_env_value PORTAL_BFF_SSO_HOST_PORT)"
  portal_bff_sso_host_port="${portal_bff_sso_host_port:-8445}"
  log "checking customer SSO portal host"
  wait_for_curl "customer SSO portal host" -k -f \
    --resolve "$customer_portal_host:$portal_bff_sso_host_port:127.0.0.1" \
    "https://$customer_portal_host:$portal_bff_sso_host_port/"
  log "checking dedicated LLM gateway"
  wait_for_curl "LLM gateway" -k -sS https://localhost:${LLM_GATEWAY_HOST_PORT:-8444}/v1/models
fi

log "bootstrap stack restart completed"

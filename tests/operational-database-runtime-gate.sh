#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -d "$repo_root/all-in-lt" ]]; then
  stack_root="$repo_root/all-in-lt"
else
  stack_root="$repo_root"
fi
image="${OPERATIONAL_POSTGRES_TEST_IMAGE:-timescale/timescaledb:latest-pg17}"
container_name="operational-p3-gate-${RANDOM}-$$"
secret_dir="$(mktemp -d /tmp/operational-p3-secrets.XXXXXX)"

cleanup() {
  docker rm -f "$container_name" >/dev/null 2>&1 || true
  case "$secret_dir" in
    /tmp/operational-p3-secrets.*)
      docker run --rm -v "$secret_dir:/cleanup" "$image" sh -c 'rm -rf /cleanup/operational-hosts' >/dev/null 2>&1 || true
      rmdir "$secret_dir" >/dev/null 2>&1 || true
      ;;
  esac
}
trap cleanup EXIT

docker run -d --name "$container_name"   -e POSTGRES_PASSWORD=secret   -v "$stack_root/postgres-db/operations/bin:/opt/operational-store/bin:ro"   -v "$stack_root/postgres-db/operations/bundle:/opt/operational-store/bundle:ro"   -v "$stack_root/postgres-db/operations/operational-databases.tsv:/opt/operational-store/operational-databases.tsv:ro"   -v "$secret_dir:/run/secrets"   "$image" >/dev/null

ready=false
for _attempt in $(seq 1 30); do
  if docker exec "$container_name" sh -c \
      '[ "$(cat /proc/1/comm)" = postgres ]' >/dev/null 2>&1 && \
      docker exec "$container_name" pg_isready -U postgres -d postgres >/dev/null 2>&1; then
    ready=true
    break
  fi
  sleep 1
done
[[ "$ready" == true ]] || {
  docker logs "$container_name" >&2
  exit 1
}

docker exec "$container_name" createdb -U postgres configserver
docker exec "$container_name" createdb -U postgres knowledge

run_bootstrap() {
  docker exec     -e PGHOST=/var/run/postgresql     -e POSTGRES_USER=postgres     -e OPERATIONAL_DATABASE_HOST=postgres     -e OPERATIONAL_DATABASE_PORT=5432     "$container_name" /bin/bash /opt/operational-store/bin/bootstrap-operational-databases.sh
}

run_bootstrap
docker exec "$container_name" psql -U postgres -d operations_networknt -X --set=ON_ERROR_STOP=1 \
  -c "UPDATE operational_meta.operational_database_identity_t SET scope_root_id='6b1c2a42-b8dc-4d5f-8c94-188b58559001';" >/dev/null
docker exec "$container_name" psql -U postgres -d operations_taiji -X --set=ON_ERROR_STOP=1 \
  -c "UPDATE operational_meta.operational_database_identity_t SET scope_root_id='6b1c2a42-b8dc-4d5f-8c94-188b58559002';" >/dev/null
run_bootstrap
run_bootstrap

docker exec   -e PGHOST=/var/run/postgresql   -e POSTGRES_USER=postgres   -e OPERATIONAL_DATABASE_HOST=postgres   -e OPERATIONAL_DATABASE_PORT=5432   "$container_name" /bin/bash /opt/operational-store/bin/validate-operational-databases.sh

catalog="$(docker exec "$container_name" psql -U postgres -d postgres -X -tAc   "SELECT string_agg(datname, ',' ORDER BY datname) FROM pg_database WHERE datname IN ('configserver','knowledge','operations','operations_networknt','operations_taiji')")"
[[ "$catalog" == "configserver,knowledge,operations,operations_networknt,operations_taiji" ]] || {
  echo "runtime gate: operational database catalog mismatch: $catalog" >&2
  exit 1
}

baseline_ledger=""
for database_name in operations operations_networknt operations_taiji; do
  ledger="$(docker exec "$container_name" psql -U postgres -d "$database_name" -X -tAc     "SELECT string_agg(migration_owner || ':' || schema_name || ':' || migration_id || ':' || migration_digest, ',' ORDER BY migration_owner, schema_name, migration_id) FROM operational_meta.operational_schema_migration_t")"
  if [[ -z "$baseline_ledger" ]]; then
    baseline_ledger="$ledger"
  else
    [[ "$ledger" == "$baseline_ledger" ]] || {
      echo "runtime gate: migration ledger differs for $database_name" >&2
      exit 1
    }
  fi
done

runtime_role_suffixes=(
  execution_runtime
  agent_runtime
  a2a_runtime
  workflow_runtime
  gateway_runtime
  audit_publisher
  artifact_runtime
  deployer_runtime
)
for database_name in operations operations_networknt operations_taiji; do
  for role_suffix in "${runtime_role_suffixes[@]}"; do
    runtime_role="${database_name}_${role_suffix}"
    identity_privileges="$(docker exec "$container_name" psql -U postgres -d "$database_name" -X -tA -F '|' -c \
      "SELECT has_table_privilege('$runtime_role', 'operational_meta.operational_database_identity_t', 'SELECT'), has_table_privilege('$runtime_role', 'operational_meta.operational_database_identity_t', 'INSERT') OR has_table_privilege('$runtime_role', 'operational_meta.operational_database_identity_t', 'UPDATE') OR has_table_privilege('$runtime_role', 'operational_meta.operational_database_identity_t', 'DELETE')")"
    [[ "$identity_privileges" == "t|f" ]] || {
      echo "runtime gate: identity-table privileges for $runtime_role are $identity_privileges, expected t|f" >&2
      exit 1
    }
  done
done

lightapi_url="/run/secrets/operational-hosts/dev.lightapi.net/gateway-database-url"
networknt_url="/run/secrets/operational-hosts/dev.networknt.com/gateway-database-url"
docker exec "$container_name" cp "$lightapi_url" /tmp/lightapi-gateway-url
docker exec "$container_name" cp "$networknt_url" /tmp/networknt-gateway-url
docker exec "$container_name" cp /tmp/networknt-gateway-url "$lightapi_url"
docker exec "$container_name" cp /tmp/lightapi-gateway-url "$networknt_url"
set +e
docker exec -e PGHOST=/var/run/postgresql -e POSTGRES_USER=postgres \
  -e OPERATIONAL_DATABASE_HOST=postgres -e OPERATIONAL_DATABASE_PORT=5432 \
  "$container_name" /bin/bash /opt/operational-store/bin/validate-operational-databases.sh >/dev/null 2>&1
swapped_status=$?
set -e
docker exec "$container_name" cp /tmp/lightapi-gateway-url "$lightapi_url"
docker exec "$container_name" cp /tmp/networknt-gateway-url "$networknt_url"
[[ "$swapped_status" -ne 0 ]] || {
  echo "runtime gate: swapped Host URL files did not fail readiness" >&2
  exit 1
}
docker exec -e PGHOST=/var/run/postgresql -e POSTGRES_USER=postgres \
  -e OPERATIONAL_DATABASE_HOST=postgres -e OPERATIONAL_DATABASE_PORT=5432 \
  "$container_name" /bin/bash /opt/operational-store/bin/validate-operational-databases.sh >/dev/null

echo "Operational database fresh/install-upgrade runtime gate passed for $stack_root"

#!/usr/bin/env bash
set -euo pipefail

database_user="${POSTGRES_USER:-postgres}"
bundle_root="${OPERATIONAL_BUNDLE_ROOT:-/opt/operational-store/bundle}"
manifest="${OPERATIONAL_DATABASE_MANIFEST:-/opt/operational-store/operational-databases.tsv}"
secret_root="${OPERATIONAL_HOST_SECRET_ROOT:-/run/secrets/operational-hosts}"
database_host="${OPERATIONAL_DATABASE_HOST:-postgres}"
database_port="${OPERATIONAL_DATABASE_PORT:-5432}"
contract_generation="${OPERATIONAL_CONTRACT_GENERATION:-2}"

fail() {
  echo "operational-databases-validation: $*" >&2
  exit 1
}

[[ -f "$manifest" && -f "$bundle_root/migration-order.tsv" ]] || fail "manifest or migration order is missing"
expected_migration_count="$(awk -F '\t' 'NF && $1 !~ /^#/ { count++ } END { print count + 0 }' "$bundle_root/migration-order.tsv")"
[[ "$expected_migration_count" -gt 0 ]] || fail "migration order is empty"

service_contracts=(
  "agent_runtime|agent_ops|operational-database-url"
  "execution_runtime|execution_ops|execution-database-url"
  "workflow_runtime|workflow_ops|workflow-database-url"
  "a2a_runtime|a2a_ops|a2a-database-url"
  "gateway_runtime|gateway_ops|gateway-database-url"
  "audit_publisher|audit_ops|audit-database-url"
  "artifact_runtime|artifact_ops|artifact-database-url"
  "deployer_runtime|operational_meta|deployer-database-url"
)

declare -a databases=()
declare -a hosts=()
declare -a roots=()
declare -a binding_ids=()
declare -a binding_digests=()
while IFS=$'\t' read -r database_name host_fqdn scope_root_id binding_id binding_digest extra; do
  [[ -n "$database_name" && "$database_name" != \#* ]] || continue
  [[ -z "${extra:-}" ]] || fail "unexpected manifest column for $database_name"
  databases+=("$database_name")
  hosts+=("$host_fqdn")
  roots+=("$scope_root_id")
  binding_ids+=("$binding_id")
  binding_digests+=("$binding_digest")
done <"$manifest"
[[ "${#databases[@]}" == 3 ]] || fail "manifest must define exactly three operational databases"

for index in "${!databases[@]}"; do
  database_name="${databases[$index]}"
  host_fqdn="${hosts[$index]}"
  scope_root_id="${roots[$index]}"
  binding_id="${binding_ids[$index]}"
  binding_digest="${binding_digests[$index]}"
  actual_identity="$(psql -U "$database_user" -d "$database_name" -X -tA -F '|' -c     "SELECT scope_root_id, database_identity, host_fqdn FROM operational_meta.operational_database_identity_t")"
  [[ "$actual_identity" == "$scope_root_id|$database_name|$host_fqdn" ]] ||
    fail "database identity mismatch for $database_name"
  actual_binding="$(psql -U "$database_user" -d "$database_name" -X -tA -F '|' -c \
    "SELECT binding_id,binding_digest,host_id,database_identity,schema_contract_generation FROM operational_meta.operational_store_binding_t WHERE active")"
  [[ "$actual_binding" == "$binding_id|$binding_digest|$scope_root_id|$database_name|$contract_generation" ]] ||
    fail "active Host registration mismatch for $database_name"

  schema_ready="$(psql -U "$database_user" -d "$database_name" -X -tA <<'SQL'
SELECT NOT EXISTS (
    SELECT required.schema_name
    FROM (VALUES
        ('operational_meta'), ('execution_ops'), ('agent_ops'), ('a2a_ops'),
        ('workflow_ops'), ('gateway_ops'), ('audit_ops'), ('artifact_ops')
    ) AS required(schema_name)
    WHERE to_regnamespace(required.schema_name) IS NULL
);
SQL
)"
  [[ "$schema_ready" == "t" ]] || fail "schema contract is incomplete for $database_name"

  actual_migration_count="$(psql -U "$database_user" -d "$database_name" -X -tAc     "SELECT count(*) FROM operational_meta.operational_schema_migration_t")"
  [[ "$actual_migration_count" == "$expected_migration_count" ]] ||
    fail "migration ledger cardinality mismatch for $database_name"
  while IFS=$'\t' read -r order migration_owner schema_name migration_id migration_path migration_sha256; do
    [[ -n "$order" && "$order" != \#* ]] || continue
    recorded_digest="$(psql -U "$database_user" -d "$database_name" -X -tAc       "SELECT migration_digest FROM operational_meta.operational_schema_migration_t WHERE migration_owner = '$migration_owner' AND schema_name = '$schema_name' AND migration_id = '$migration_id'")"
    [[ "$recorded_digest" == "sha256:$migration_sha256" ]] ||
      fail "migration ledger mismatch for $database_name/$migration_id"
  done <"$bundle_root/migration-order.tsv"

  for contract in "${service_contracts[@]}"; do
    IFS='|' read -r role_suffix schema_name url_name <<<"$contract"
    role_name="${database_name}_${role_suffix}"
    role_ready="$(psql -U "$database_user" -d "$database_name" -X -tA       --set=runtime_role="$role_name" --set=database_name="$database_name" --set=schema_name="$schema_name" <<'SQL'
SELECT rolcanlogin
   AND NOT rolsuper
   AND NOT rolcreatedb
   AND NOT rolcreaterole
   AND has_database_privilege(:'runtime_role', :'database_name', 'CONNECT')
   AND has_schema_privilege(:'runtime_role', :'schema_name', 'USAGE')
FROM pg_roles
WHERE rolname = :'runtime_role';
SQL
)"
    [[ "$role_ready" == "t" ]] || fail "runtime role boundary is invalid for $role_name"

    for other_database in "${databases[@]}"; do
      [[ "$other_database" == "$database_name" ]] && continue
      cross_connect="$(psql -U "$database_user" -d postgres -X -tA --set=runtime_role="$role_name" --set=database_name="$other_database" <<'SQL'
SELECT has_database_privilege(:'runtime_role', :'database_name', 'CONNECT');
SQL
)"
      [[ "$cross_connect" == "f" ]] || fail "$role_name can connect to $other_database"
    done

    url_file="$secret_root/$host_fqdn/$url_name"
    [[ -f "$url_file" && ! -L "$url_file" ]] || fail "missing runtime URL $url_file"
    mode="$(stat -c '%a' "$url_file")"
    mode_value=$((8#$mode))
    (( (mode_value & 0037) == 0 )) || fail "runtime URL permissions are too broad: $url_file"
    database_url="$(<"$url_file")"
    url_pattern="^postgres://${role_name}:[0-9a-f]{64}@${database_host}:${database_port}/${database_name}$"
    [[ "$database_url" =~ $url_pattern ]] || fail "runtime URL contract mismatch for $role_name"
  done
done

echo "Validated three isolated operational databases and their Host-specific runtime URL files."

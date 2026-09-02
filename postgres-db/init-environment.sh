#!/bin/bash
set -euo pipefail

topology="${PORTAL_DB_TOPOLOGY:-separate}"
environment_name="${PORTAL_DB_ENVIRONMENT:-local}"
configserver_database="${PORTAL_DB_NAME:-configserver}"
knowledge_database="${PORTAL_DB_KNOWLEDGE_NAME:-knowledge}"
operational_database_names="${PORTAL_DB_OPERATIONAL_NAMES:-operations,operations_networknt,operations_taiji}"
IFS=',' read -r -a operational_databases <<<"$operational_database_names"
database_user="${POSTGRES_USER:-postgres}"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if [[ -n "${PORTAL_DB_SOURCE_ROOT:-}" ]]; then
  source_root="$PORTAL_DB_SOURCE_ROOT"
elif [[ -f "$script_dir/../ddl.sql" ]]; then
  source_root="$script_dir/.."
else
  source_root="/docker-entrypoint-initdb.d/schema-source"
fi

if [[ -n "${PORTAL_DB_RENDERER:-}" ]]; then
  renderer="$PORTAL_DB_RENDERER"
elif [[ -x "$script_dir/../bin/render-schema.sh" ]]; then
  renderer="$script_dir/../bin/render-schema.sh"
else
  renderer="/docker-entrypoint-initdb.d/lib/render-schema.sh"
fi

if [[ "$topology" != "separate" && "$topology" != "shared" ]]; then
  echo "init-environment: PORTAL_DB_TOPOLOGY must be separate or shared" >&2
  exit 2
fi
if [[ "$topology" == "shared" && ! "$environment_name" =~ ^[a-z][a-z0-9_]{0,24}$ ]]; then
  echo "init-environment: invalid PORTAL_DB_ENVIRONMENT '$environment_name'" >&2
  exit 2
fi
if [[ "${#operational_databases[@]}" != 3 ]]; then
  echo "init-environment: PORTAL_DB_OPERATIONAL_NAMES must contain exactly three databases" >&2
  exit 2
fi
declare -A seen_operational_databases=()
for database_name in "$configserver_database" "$knowledge_database" "${operational_databases[@]}"; do
  if [[ ! "$database_name" =~ ^[a-z][a-z0-9_]{0,62}$ ]]; then
    echo "init-environment: invalid database name '$database_name'" >&2
    exit 2
  fi
done
for database_name in "${operational_databases[@]}"; do
  if [[ -n "${seen_operational_databases[$database_name]:-}" ]]; then
    echo "init-environment: duplicate operational database '$database_name'" >&2
    exit 2
  fi
  seen_operational_databases["$database_name"]=1
done

if [[ "$topology" == "shared" ]]; then
  knowledge_database="$configserver_database"
  configserver_schema="configserver_${environment_name}"
  knowledge_schema="knowledge_${environment_name}"
else
  [[ "$configserver_database" != "$knowledge_database" ]] || {
    echo "init-environment: separate topology requires different Config Server and Knowledge databases" >&2
    exit 2
  }
  configserver_schema="configserver"
  knowledge_schema="knowledge"
fi

for operational_database in "${operational_databases[@]}"; do
  if [[ "$operational_database" == "$configserver_database" || "$operational_database" == "$knowledge_database" ]]; then
    echo "init-environment: operational databases must be separate from Config Server and Knowledge" >&2
    exit 2
  fi
done

temporary_dir="$(mktemp -d)"
trap 'rm -rf -- "$temporary_dir"' EXIT

ensure_database() {
  local database_name="$1"
  local exists
  exists="$(psql -U "$database_user" -d postgres -tAc \
    "SELECT 1 FROM pg_database WHERE datname = '$database_name'")"
  if [[ "$exists" != "1" ]]; then
    createdb -U "$database_user" "$database_name"
  fi
}

ensure_database "$configserver_database"
if [[ "$topology" == "separate" ]]; then
  ensure_database "$knowledge_database"
fi
for operational_database in "${operational_databases[@]}"; do
  ensure_database "$operational_database"
done

export PORTAL_DB_CONFIGSERVER_SOURCE="$source_root/configserver.sql"
if [[ ! -f "$PORTAL_DB_CONFIGSERVER_SOURCE" && -f "$source_root/ddl.sql" ]]; then
  export PORTAL_DB_CONFIGSERVER_SOURCE="$source_root/ddl.sql"
fi
export PORTAL_DB_BOOTSTRAP_SOURCE="${PORTAL_DB_BOOTSTRAP_SOURCE:-$source_root/bootstrap.sql}"
if [[ ! -f "$PORTAL_DB_BOOTSTRAP_SOURCE" && -f "$source_root/init-lightapi.sql" ]]; then
  export PORTAL_DB_BOOTSTRAP_SOURCE="$source_root/init-lightapi.sql"
fi
export PORTAL_DB_KNOWLEDGE_SOURCE="${PORTAL_DB_KNOWLEDGE_SOURCE:-$source_root/knowledge/ddl.sql}"
export PORTAL_DB_KNOWLEDGE_ROLES_SOURCE="${PORTAL_DB_KNOWLEDGE_ROLES_SOURCE:-$source_root/knowledge/roles.sql}"
export PORTAL_DB_STRIP_TOP_LEVEL_TRANSACTIONS=true

"$renderer" configserver "$configserver_schema" "$temporary_dir/configserver.sql"
"$renderer" knowledge "$knowledge_schema" "$temporary_dir/knowledge.sql"
"$renderer" knowledge-roles "$knowledge_schema" "$temporary_dir/knowledge-roles.sql"
bootstrap_source_present=false
if [[ -f "$PORTAL_DB_BOOTSTRAP_SOURCE" ]]; then
  "$renderer" bootstrap "$configserver_schema" "$temporary_dir/bootstrap.sql"
  bootstrap_source_present=true
fi

runtime_grants_source="${PORTAL_DB_RUNTIME_GRANTS_SOURCE:-$source_root/runtime-grants.sql}"

if [[ "$topology" == "shared" ]]; then
  printf '%s\n' \
    'REVOKE CREATE ON SCHEMA public FROM PUBLIC;' \
    'CREATE SCHEMA :"configserver_schema";' \
    'CREATE SCHEMA :"knowledge_schema";' \
    "SELECT format('ALTER ROLE %I IN DATABASE %I SET search_path = %I, public', :'database_user', :'configserver_database', :'configserver_schema') \\gexec" \
    >"$temporary_dir/shared-prologue.sql"

  psql_files=(
    --file="$temporary_dir/shared-prologue.sql"
    --file="$temporary_dir/knowledge-roles.sql"
    --file="$temporary_dir/configserver.sql"
    --file="$temporary_dir/knowledge.sql"
  )
  if [[ "$bootstrap_source_present" == true ]]; then
    psql_files+=(--file="$temporary_dir/bootstrap.sql")
  fi
  psql -U "$database_user" -d "$configserver_database" -X --quiet --single-transaction \
    --set=ON_ERROR_STOP=1 \
    --set=database_user="$database_user" \
    --set=configserver_database="$configserver_database" \
    --set=knowledge_database="$knowledge_database" \
    --set=configserver_schema="$configserver_schema" \
    --set=knowledge_schema="$knowledge_schema" \
    "${psql_files[@]}" >/dev/null

  # Runtime grants may use \connect. Keep them outside --single-transaction:
  # psql ends the transaction when reconnecting and can otherwise roll back a
  # successful schema load while still returning exit status zero.
  if [[ -f "$runtime_grants_source" ]]; then
    psql -U "$database_user" -d postgres -X --quiet --set=ON_ERROR_STOP=1 \
      --set=database_user="$database_user" \
      --set=configserver_database="$configserver_database" \
      --set=knowledge_database="$knowledge_database" \
      --set=configserver_schema="$configserver_schema" \
      --set=knowledge_schema="$knowledge_schema" \
      --file="$runtime_grants_source" >/dev/null
  fi
else
  printf '%s\n' \
    'REVOKE CREATE ON SCHEMA public FROM PUBLIC;' \
    'CREATE SCHEMA :"configserver_schema";' \
    "SELECT format('ALTER ROLE %I IN DATABASE %I SET search_path = %I, public', :'database_user', :'configserver_database', :'configserver_schema') \\gexec" \
    >"$temporary_dir/configserver-prologue.sql"
  printf '%s\n' \
    'REVOKE CREATE ON SCHEMA public FROM PUBLIC;' \
    'CREATE SCHEMA :"knowledge_schema";' \
    "SELECT format('ALTER ROLE %I IN DATABASE %I SET search_path = %I, public', :'database_user', :'knowledge_database', :'knowledge_schema') \\gexec" \
    >"$temporary_dir/knowledge-prologue.sql"

  configserver_files=(
    --file="$temporary_dir/configserver-prologue.sql"
    --file="$temporary_dir/configserver.sql"
  )
  if [[ "$bootstrap_source_present" == true ]]; then
    configserver_files+=(--file="$temporary_dir/bootstrap.sql")
  fi
  psql -U "$database_user" -d "$configserver_database" -X --quiet --single-transaction \
    --set=ON_ERROR_STOP=1 \
    --set=database_user="$database_user" \
    --set=configserver_database="$configserver_database" \
    --set=configserver_schema="$configserver_schema" \
    "${configserver_files[@]}" >/dev/null

  psql -U "$database_user" -d "$knowledge_database" -X --quiet --single-transaction \
    --set=ON_ERROR_STOP=1 \
    --set=database_user="$database_user" \
    --set=knowledge_database="$knowledge_database" \
    --set=knowledge_schema="$knowledge_schema" \
    --file="$temporary_dir/knowledge-prologue.sql" \
    --file="$temporary_dir/knowledge-roles.sql" \
    --file="$temporary_dir/knowledge.sql" >/dev/null

  if [[ -f "$runtime_grants_source" ]]; then
    psql -U "$database_user" -d postgres -X --quiet --set=ON_ERROR_STOP=1 \
      --set=database_user="$database_user" \
      --set=configserver_database="$configserver_database" \
      --set=knowledge_database="$knowledge_database" \
      --set=configserver_schema="$configserver_schema" \
      --set=knowledge_schema="$knowledge_schema" \
      --file="$runtime_grants_source" >/dev/null
  fi
fi

if [[ ! -f "$runtime_grants_source" ]]; then
  echo "init-environment: no runtime-grants.sql supplied; deployment-specific login roles must be created before application startup" >&2
fi

if [[ "$topology" == "shared" ]]; then
  echo "Initialized shared database '$configserver_database' with '$configserver_schema' and '$knowledge_schema', plus operational databases '$operational_database_names'."
else
  echo "Initialized '$configserver_database.$configserver_schema', '$knowledge_database.$knowledge_schema', and operational databases '$operational_database_names'."
fi

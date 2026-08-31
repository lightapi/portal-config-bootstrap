#!/bin/bash
set -euo pipefail

topology="${PORTAL_DB_TOPOLOGY:-separate}"
environment_name="${PORTAL_DB_ENVIRONMENT:-local}"
configserver_database="${PORTAL_DB_NAME:-configserver}"
knowledge_database="${PORTAL_DB_KNOWLEDGE_NAME:-knowledge}"
database_user="${POSTGRES_USER:-postgres}"
require_bootstrap="${PORTAL_DB_REQUIRE_BOOTSTRAP:-true}"

if [[ "$topology" != "separate" && "$topology" != "shared" ]]; then
  echo "validate-environment: PORTAL_DB_TOPOLOGY must be separate or shared" >&2
  exit 2
fi
if [[ "$topology" == "shared" && ! "$environment_name" =~ ^[a-z][a-z0-9_]{0,24}$ ]]; then
  echo "validate-environment: invalid PORTAL_DB_ENVIRONMENT '$environment_name'" >&2
  exit 2
fi
if [[ "$require_bootstrap" != "true" && "$require_bootstrap" != "false" ]]; then
  echo "validate-environment: PORTAL_DB_REQUIRE_BOOTSTRAP must be true or false" >&2
  exit 2
fi

if [[ "$topology" == "shared" ]]; then
  knowledge_database="$configserver_database"
  configserver_schema="configserver_${environment_name}"
  knowledge_schema="knowledge_${environment_name}"
else
  configserver_schema="configserver"
  knowledge_schema="knowledge"
fi

configserver_ready="$(psql -U "$database_user" -d "$configserver_database" -X --tuples-only --no-align \
  --set=ON_ERROR_STOP=1 --set=configserver_schema="$configserver_schema" <<'SQL'
SELECT to_regclass(format('%I.host_t', :'configserver_schema')) IS NOT NULL
   AND to_regclass(format('%I.event_store_t', :'configserver_schema')) IS NOT NULL;
SQL
)"

knowledge_ready="$(psql -U "$database_user" -d "$knowledge_database" -X --tuples-only --no-align \
  --set=ON_ERROR_STOP=1 --set=knowledge_schema="$knowledge_schema" <<'SQL'
SELECT to_regclass(format('%I.knowledge_job_t', :'knowledge_schema')) IS NOT NULL
   AND to_regclass(format('%I.knowledge_control_snapshot_t', :'knowledge_schema')) IS NOT NULL
   AND to_regclass(format('%I.knowledge_embedding_profile_runtime_v', :'knowledge_schema')) IS NOT NULL
   AND to_regclass(format('%I.event_store_t', :'knowledge_schema')) IS NULL;
SQL
)"

if [[ "$configserver_ready" != "t" || "$knowledge_ready" != "t" ]]; then
  echo "database topology '$topology' does not contain complete '$configserver_database.$configserver_schema' and '$knowledge_database.$knowledge_schema' schemas" >&2
  exit 1
fi

if [[ "$require_bootstrap" == "true" ]]; then
  bootstrap_ready="$(psql -U "$database_user" -d "$configserver_database" -X --quiet --tuples-only --no-align \
    --set=ON_ERROR_STOP=1 --set=configserver_schema="$configserver_schema" <<'SQL'
SET search_path = :"configserver_schema", public;
SELECT EXISTS (SELECT 1 FROM host_t)
   AND EXISTS (SELECT 1 FROM user_t);
SQL
)"
  if [[ "$bootstrap_ready" != "t" ]]; then
    echo "database '$configserver_database' has an empty '$configserver_schema' bootstrap catalog" >&2
    exit 1
  fi
fi

echo "Validated '$configserver_database.$configserver_schema' and '$knowledge_database.$knowledge_schema'."

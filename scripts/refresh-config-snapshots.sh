#!/usr/bin/env bash
set -euo pipefail

log() {
  printf '[refresh-config-snapshots] %s\n' "$*"
}

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

"$script_dir/wait-for-postgres.sh"

snapshot_user_id="${DEV_CONFIG_SNAPSHOT_USER_ID:-01964b05-5532-7c79-8cde-191dcbd421b8}"
snapshot_type="${DEV_CONFIG_SNAPSHOT_TYPE:-DEPLOY_REFRESH}"
snapshot_description="${DEV_CONFIG_SNAPSHOT_DESCRIPTION:-Refresh config snapshots after deployment event deltas}"
host_filter="${DEV_CONFIG_SNAPSHOT_HOST_ID:-}"
env_filter="${DEV_CONFIG_SNAPSHOT_ENV_TAG:-dev}"
service_filter="${DEV_CONFIG_SNAPSHOT_SERVICE_ID:-}"

log "refreshing current config snapshots"

docker exec -i postgres psql -h localhost -p 5432 -U postgres -d configserver -v ON_ERROR_STOP=1 \
  -v snapshot_user_id="$snapshot_user_id" \
  -v snapshot_type="$snapshot_type" \
  -v snapshot_description="$snapshot_description" \
  -v host_filter="$host_filter" \
  -v env_filter="$env_filter" \
  -v service_filter="$service_filter" <<'SQL'
SELECT set_config('dev.snapshot_user_id', :'snapshot_user_id', false);
SELECT set_config('dev.snapshot_type', :'snapshot_type', false);
SELECT set_config('dev.snapshot_description', :'snapshot_description', false);
SELECT set_config('dev.snapshot_host_filter', :'host_filter', false);
SELECT set_config('dev.snapshot_env_filter', :'env_filter', false);
SELECT set_config('dev.snapshot_service_filter', :'service_filter', false);

DO $$
DECLARE
    r record;
    refreshed_count integer := 0;
    v_snapshot_id uuid;
    v_user_id uuid := current_setting('dev.snapshot_user_id')::uuid;
    v_snapshot_type text := current_setting('dev.snapshot_type');
    v_description text := current_setting('dev.snapshot_description');
    v_host_filter text := NULLIF(current_setting('dev.snapshot_host_filter', true), '');
    v_env_filter text := NULLIF(current_setting('dev.snapshot_env_filter', true), '');
    v_service_filter text := NULLIF(current_setting('dev.snapshot_service_filter', true), '');
BEGIN
    FOR r IN
        SELECT DISTINCT cs.host_id, cs.instance_id, cs.service_id,
               COALESCE(NULLIF(i.env_tag, ''), i.environment, '') AS env_tag
        FROM config_snapshot_t cs
        JOIN instance_t i ON i.host_id = cs.host_id
                         AND i.instance_id = cs.instance_id
        WHERE cs.current = true
          AND i.active = true
          -- A snapshot can be the authoritative current configuration for an
          -- active instance even when the legacy instance.current flag is
          -- false (for example, the local portal gateway).  cs.current is the
          -- source of truth for refresh eligibility.
          AND (v_host_filter IS NULL OR cs.host_id::text = v_host_filter)
          AND (v_env_filter IS NULL OR COALESCE(NULLIF(i.env_tag, ''), i.environment, '') = v_env_filter)
          AND (v_service_filter IS NULL OR cs.service_id = v_service_filter)
        ORDER BY cs.service_id, cs.instance_id
    LOOP
        v_snapshot_id := gen_random_uuid();
        RAISE NOTICE 'Refreshing config snapshot for service_id %, instance_id %', r.service_id, r.instance_id;

        CALL create_snapshot(
            r.host_id,
            r.instance_id,
            v_snapshot_type,
            v_description,
            v_user_id,
            NULL::uuid,
            v_snapshot_id
        );

        UPDATE config_snapshot_t
        SET current = false
        WHERE host_id = r.host_id
          AND instance_id = r.instance_id
          AND snapshot_id <> v_snapshot_id;

        UPDATE config_snapshot_t
        SET current = true
        WHERE snapshot_id = v_snapshot_id;

        refreshed_count := refreshed_count + 1;
    END LOOP;

    RAISE NOTICE 'Refreshed % current config snapshots', refreshed_count;
END $$;
SQL

log "config snapshot refresh completed"

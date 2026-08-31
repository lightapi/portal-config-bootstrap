#!/usr/bin/env bash
set -euo pipefail

instance_id="${LIGHT_WORKFLOW_CONFIG_INSTANCE_ID:-01a011cf-03d6-73fc-ac30-6b592cc86a80}"
target_snapshot="${1:-${LIGHT_WORKFLOW_ROLLBACK_SNAPSHOT_ID:-}}"
dry_run="${LIGHT_WORKFLOW_SNAPSHOT_DRY_RUN:-false}"

run_psql() {
  if [[ -n "${LIGHT_WORKFLOW_DATABASE_URL:-}" ]]; then
    psql "$LIGHT_WORKFLOW_DATABASE_URL" "$@"
  else
    docker exec -i postgres psql -U postgres -d configserver "$@"
  fi
}

if [[ -z "$target_snapshot" ]]; then
  echo "usage: $0 <previously-reviewed-snapshot-id>" >&2
  exit 2
fi

run_psql -v ON_ERROR_STOP=1 \
  -v instance_id="$instance_id" -v target_snapshot="$target_snapshot" -v dry_run="$dry_run" <<'SQL'
BEGIN;
SELECT set_config('workflow.instance_id', :'instance_id', false);
SELECT set_config('workflow.target_snapshot', :'target_snapshot', false);
DO $$
DECLARE
    target_instance uuid := current_setting('workflow.instance_id')::uuid;
    requested_snapshot uuid := current_setting('workflow.target_snapshot')::uuid;
    target_host uuid;
    current_snapshot uuid;
BEGIN
    SELECT host_id INTO STRICT target_host
    FROM instance_t
    WHERE instance_id = target_instance
      AND active = true
      AND service_id = 'com.networknt.workflow-1.0.0';

    PERFORM 1
    FROM config_snapshot_t
    WHERE snapshot_id = requested_snapshot
      AND host_id = target_host
      AND instance_id = target_instance
      AND service_id = 'com.networknt.workflow-1.0.0';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'snapshot % is not a Light Workflow snapshot for instance %',
            requested_snapshot, target_instance;
    END IF;

    SELECT snapshot_id INTO current_snapshot
    FROM config_snapshot_t
    WHERE host_id = target_host
      AND instance_id = target_instance
      AND current = true
    FOR UPDATE;

    UPDATE config_snapshot_t
       SET current = false
     WHERE host_id = target_host
       AND instance_id = target_instance
       AND current = true;

    UPDATE config_snapshot_t
       SET current = true
     WHERE snapshot_id = requested_snapshot;

    RAISE NOTICE 'Restored Light Workflow snapshot % for instance %; replaced snapshot %',
        requested_snapshot, target_instance, COALESCE(current_snapshot::text, 'none');
END $$;
\if :dry_run
ROLLBACK;
\else
COMMIT;
\endif
SQL

echo "Snapshot current pointer updated. Reload only light-workflow/runtime-config in the Portal Control Pane, or restart light-workflow if review classified any change as restart-required."

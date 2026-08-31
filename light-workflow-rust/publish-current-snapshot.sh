#!/usr/bin/env bash
set -euo pipefail

instance_id="${LIGHT_WORKFLOW_CONFIG_INSTANCE_ID:-01a011cf-03d6-73fc-ac30-6b592cc86a80}"
user_id="${LIGHT_WORKFLOW_SNAPSHOT_USER_ID:-01964b05-5532-7c79-8cde-191dcbd421b8}"
description="${LIGHT_WORKFLOW_SNAPSHOT_DESCRIPTION:-Light Workflow Phase 1a managed configuration}"
dry_run="${LIGHT_WORKFLOW_SNAPSHOT_DRY_RUN:-false}"

docker exec -i postgres psql -U postgres -d configserver -v ON_ERROR_STOP=1 \
  -v instance_id="$instance_id" -v user_id="$user_id" -v description="$description" -v dry_run="$dry_run" <<'SQL'
BEGIN;
SELECT set_config('workflow.instance_id', :'instance_id', false);
SELECT set_config('workflow.user_id', :'user_id', false);
SELECT set_config('workflow.description', :'description', false);
DO $$
DECLARE
    target_instance uuid := current_setting('workflow.instance_id')::uuid;
    actor uuid := current_setting('workflow.user_id')::uuid;
    next_snapshot uuid := gen_random_uuid();
    target_host uuid;
    previous_snapshot uuid;
BEGIN
    SELECT host_id INTO STRICT target_host
    FROM instance_t
    WHERE instance_id = target_instance
      AND active = true
      AND service_id = 'com.networknt.workflow-1.0.0';

    SELECT snapshot_id INTO previous_snapshot
    FROM config_snapshot_t
    WHERE host_id = target_host
      AND instance_id = target_instance
      AND current = true;

    CALL create_snapshot(
        target_host,
        target_instance,
        'WORKFLOW_PHASE1A',
        current_setting('workflow.description'),
        actor,
        NULL::uuid,
        next_snapshot
    );

    UPDATE config_snapshot_t
       SET current = false
     WHERE host_id = target_host
       AND instance_id = target_instance
       AND snapshot_id <> next_snapshot;

    UPDATE config_snapshot_t
       SET current = true
     WHERE snapshot_id = next_snapshot;

    RAISE NOTICE 'Promoted Light Workflow snapshot % for instance %; previous snapshot %',
        next_snapshot, target_instance, COALESCE(previous_snapshot::text, 'none');
END $$;
\if :dry_run
ROLLBACK;
\else
COMMIT;
\endif
SQL

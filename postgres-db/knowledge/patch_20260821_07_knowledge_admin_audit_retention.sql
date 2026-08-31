-- Extend the administration audit to cover tenant-level snapshot applies and
-- operational commands, and allow the admin service to enforce bounded
-- retention for superseded control snapshots.
ALTER TABLE public.knowledge_admin_audit_t
    ALTER COLUMN knowledge_base_id DROP NOT NULL,
    DROP CONSTRAINT knowledge_admin_audit_operation_check,
    ADD CONSTRAINT knowledge_admin_audit_operation_check CHECK ((operation)::text = ANY (ARRAY[
        'EMBEDDING_MIGRATION_ESTIMATE'::text, 'AUTHORIZATION_SIMULATION'::text,
        'CONTROL_SNAPSHOT_APPLY'::text, 'OPERATIONAL_COMMAND_SUBMIT'::text])),
    DROP CONSTRAINT knowledge_admin_audit_latency_check,
    ADD CONSTRAINT knowledge_admin_audit_latency_check
        CHECK (latency_ms >= 0 AND latency_ms <= 120000);

COMMENT ON TABLE public.knowledge_admin_audit_t IS
    'Content-safe audit evidence for Light Knowledge administration reads, commands, and control snapshots.';

GRANT DELETE ON TABLE public.knowledge_control_snapshot_t TO light_knowledge_admin_api_role;


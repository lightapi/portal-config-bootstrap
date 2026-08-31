-- Forward-only migration for a Knowledge database created by the former
-- Config Server clone-and-filter bootstrap.
BEGIN;

DO $$
BEGIN
    IF to_regclass('event_store_t') IS NOT NULL THEN
        RAISE EXCEPTION 'refusing to migrate a database that still contains event_store_t';
    END IF;
    IF to_regclass('knowledge_job_t') IS NULL
       OR to_regclass('knowledge_base_t') IS NULL THEN
        RAISE EXCEPTION 'canonical Knowledge boundary patch requires a Knowledge database';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_roles
         WHERE rolname = 'light_knowledge_snapshot_loader_role'
    ) THEN
        CREATE ROLE light_knowledge_snapshot_loader_role NOLOGIN;
    END IF;
END
$$;

DROP VIEW IF EXISTS knowledge_qualified_embedding_alias_v CASCADE;
DROP TABLE IF EXISTS
    knowledge_base_import_identity_map_t,
    knowledge_base_import_t,
    knowledge_base_manifest_export_t
CASCADE;

DROP FUNCTION IF EXISTS enforce_knowledge_import_identity_immutable() CASCADE;
DROP FUNCTION IF EXISTS enforce_knowledge_import_identity_map_append_only() CASCADE;
DROP FUNCTION IF EXISTS enforce_knowledge_manifest_export_immutable() CASCADE;
DROP FUNCTION IF EXISTS qualify_knowledge_embedding_profile() CASCADE;

-- Clone-and-filter removed unrelated relations but left their routines behind.
-- Keep extension-owned routines, Knowledge routines, and the local cascade
-- policy helpers; remove every other public routine.
DO $$
DECLARE routine record;
BEGIN
    FOR routine IN
        SELECT p.proname,
               pg_get_function_identity_arguments(p.oid) AS arguments,
               CASE p.prokind WHEN 'p' THEN 'PROCEDURE' ELSE 'FUNCTION' END AS kind
          FROM pg_proc p
          JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'public'
           AND NOT EXISTS (
               SELECT 1
                 FROM pg_depend d
                 JOIN pg_extension e ON e.oid = d.refobjid
                WHERE d.classid = 'pg_proc'::regclass
                  AND d.objid = p.oid
                  AND d.deptype = 'e'
           )
           AND p.proname NOT LIKE 'knowledge\_%' ESCAPE '\'
           AND p.proname NOT LIKE '%knowledge%'
           AND p.proname NOT IN (
               'smart_cascade_delete',
               'validate_cascade_relationship_policies'
           )
    LOOP
        EXECUTE format(
            'DROP %s %I(%s) CASCADE',
            routine.kind,
            routine.proname,
            routine.arguments
        );
    END LOOP;
END
$$;

GRANT USAGE ON SCHEMA public TO light_knowledge_snapshot_loader_role;
GRANT SELECT, INSERT, UPDATE ON TABLE
    agent_knowledge_base_t,
    knowledge_base_strategy_qualification_t,
    knowledge_base_t,
    knowledge_embedding_profile_t,
    knowledge_ingestion_policy_t,
    knowledge_retrieval_profile_t,
    knowledge_source_t
TO light_knowledge_snapshot_loader_role;

GRANT USAGE ON SCHEMA public TO light_knowledge_admin_api_role;
GRANT SELECT ON TABLE
    agent_knowledge_base_t,
    knowledge_acl_reconciliation_t,
    knowledge_acl_subject_t,
    knowledge_acl_transition_t,
    knowledge_anti_entropy_run_t,
    knowledge_backup_checkpoint_t,
    knowledge_base_strategy_qualification_t,
    knowledge_base_t,
    knowledge_chunk_t,
    knowledge_compaction_run_t,
    knowledge_connector_object_t,
    knowledge_document_acl_t,
    knowledge_document_t,
    knowledge_embedding_migration_t,
    knowledge_embedding_profile_runtime_v,
    knowledge_generation_retention_t,
    knowledge_index_generation_t,
    knowledge_index_pointer_t,
    knowledge_index_segment_t,
    knowledge_ingestion_policy_t,
    knowledge_job_t,
    knowledge_migration_evaluation_t,
    knowledge_operational_policy_t,
    knowledge_passage_anchor_t,
    knowledge_purge_evidence_t,
    knowledge_retrieval_profile_t,
    knowledge_source_acl_state_t,
    knowledge_source_change_t,
    knowledge_source_t,
    knowledge_sync_run_t,
    knowledge_upload_t
TO light_knowledge_admin_api_role;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
ON ALL TABLES IN SCHEMA public FROM light_knowledge_admin_api_role;
REVOKE CREATE ON SCHEMA public FROM light_knowledge_admin_api_role;

REVOKE INSERT, UPDATE ON TABLE
    agent_knowledge_base_t,
    knowledge_base_strategy_qualification_t,
    knowledge_base_t,
    knowledge_embedding_profile_t,
    knowledge_ingestion_policy_t,
    knowledge_retrieval_profile_t,
    knowledge_source_t
FROM light_knowledge_portal_projector_role;

-- Transitional compatibility only; Phase 2 removes this membership.
GRANT light_knowledge_snapshot_loader_role
   TO light_knowledge_portal_projector_role;

SELECT validate_cascade_relationship_policies();

COMMIT;

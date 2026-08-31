-- Apply only to the Knowledge database.
BEGIN;

DO $$
BEGIN
    IF current_database() <> 'knowledge' THEN
        RAISE EXCEPTION 'knowledge administration boundary patch requires the knowledge database';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_roles WHERE rolname = 'light_knowledge_admin_api_role'
    ) THEN
        CREATE ROLE light_knowledge_admin_api_role NOLOGIN;
    END IF;
END
$$;

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

COMMIT;

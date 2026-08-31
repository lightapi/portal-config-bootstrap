BEGIN;

CREATE TABLE IF NOT EXISTS knowledge_admin_audit_t (
    admin_audit_id uuid PRIMARY KEY,
    request_id varchar(128) NOT NULL,
    knowledge_base_id uuid NOT NULL REFERENCES knowledge_base_t(knowledge_base_id) ON DELETE CASCADE,
    consumer_host_id uuid NOT NULL,
    environment varchar(16) NOT NULL,
    operation varchar(64) NOT NULL,
    input_digest char(64) NOT NULL,
    subject_ref varchar(128),
    result_count bigint NOT NULL,
    latency_ms bigint NOT NULL,
    created_ts timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT knowledge_admin_audit_operation_check CHECK ((operation)::text = ANY (ARRAY[
        'EMBEDDING_MIGRATION_ESTIMATE'::text, 'AUTHORIZATION_SIMULATION'::text])),
    CONSTRAINT knowledge_admin_audit_input_digest_check CHECK (input_digest ~ '^[a-f0-9]{64}$'),
    CONSTRAINT knowledge_admin_audit_result_count_check CHECK (result_count >= 0),
    CONSTRAINT knowledge_admin_audit_latency_check CHECK (latency_ms >= 0 AND latency_ms <= 2000)
);

COMMENT ON TABLE knowledge_admin_audit_t IS
    'Content-safe audit evidence for read-only Light Knowledge administration computations.';

CREATE INDEX IF NOT EXISTS knowledge_admin_audit_page_idx ON knowledge_admin_audit_t
    (knowledge_base_id, created_ts DESC, admin_audit_id DESC);
CREATE INDEX IF NOT EXISTS knowledge_admin_sync_runs_page_idx ON knowledge_sync_run_t
    (knowledge_base_id, requested_ts DESC, sync_run_id DESC);
CREATE INDEX IF NOT EXISTS knowledge_admin_documents_page_idx ON knowledge_document_t
    (knowledge_base_id, update_ts DESC, document_id DESC);
CREATE INDEX IF NOT EXISTS knowledge_admin_generations_page_idx ON knowledge_index_generation_t
    (knowledge_base_id, created_ts DESC, index_generation_id DESC);
CREATE INDEX IF NOT EXISTS knowledge_admin_segments_page_idx ON knowledge_index_segment_t
    (knowledge_base_id, created_ts DESC, index_segment_id DESC);
CREATE INDEX IF NOT EXISTS knowledge_admin_uploads_page_idx ON knowledge_upload_t
    (knowledge_base_id, staged_ts DESC, upload_id DESC);
CREATE INDEX IF NOT EXISTS knowledge_admin_changes_page_idx ON knowledge_source_change_t
    (knowledge_base_id, observed_ts DESC, source_change_id DESC);
CREATE INDEX IF NOT EXISTS knowledge_admin_anchors_page_idx ON knowledge_passage_anchor_t
    (knowledge_base_id, created_ts DESC, passage_anchor_id DESC, document_version_id DESC);
CREATE INDEX IF NOT EXISTS knowledge_admin_compactions_page_idx ON knowledge_compaction_run_t
    (knowledge_base_id, created_ts DESC, compaction_run_id DESC);
CREATE INDEX IF NOT EXISTS knowledge_admin_anti_entropy_page_idx ON knowledge_anti_entropy_run_t
    (knowledge_base_id, started_ts DESC, anti_entropy_run_id DESC);
CREATE INDEX IF NOT EXISTS knowledge_admin_acl_freshness_page_idx ON knowledge_source_acl_state_t
    (knowledge_base_id, update_ts DESC, source_id DESC);
CREATE INDEX IF NOT EXISTS knowledge_admin_acl_reconciliation_page_idx ON knowledge_acl_reconciliation_t
    (knowledge_base_id, started_ts DESC, reconciliation_id DESC);
CREATE INDEX IF NOT EXISTS knowledge_admin_acl_transition_page_idx ON knowledge_acl_transition_t
    (knowledge_base_id, recorded_ts DESC, acl_transition_id DESC);
CREATE INDEX IF NOT EXISTS knowledge_admin_connector_objects_page_idx ON knowledge_connector_object_t
    (knowledge_base_id, observed_ts DESC, connector_object_id DESC);
CREATE INDEX IF NOT EXISTS knowledge_admin_migrations_page_idx ON knowledge_embedding_migration_t
    (knowledge_base_id, created_ts DESC, migration_id DESC);
CREATE INDEX IF NOT EXISTS knowledge_admin_evaluations_page_idx ON knowledge_migration_evaluation_t
    (knowledge_base_id, created_ts DESC, evaluation_evidence_id DESC);
CREATE INDEX IF NOT EXISTS knowledge_admin_retention_page_idx ON knowledge_generation_retention_t
    (knowledge_base_id, update_ts DESC, index_generation_id DESC);
CREATE INDEX IF NOT EXISTS knowledge_admin_checkpoints_page_idx ON knowledge_backup_checkpoint_t
    (knowledge_base_id, created_ts DESC, checkpoint_id DESC);
CREATE INDEX IF NOT EXISTS knowledge_admin_purge_page_idx ON knowledge_purge_evidence_t
    (knowledge_base_id, created_ts DESC, purge_evidence_id DESC);
CREATE INDEX IF NOT EXISTS knowledge_admin_promotion_receipts_page_idx ON knowledge_promotion_receipt_t
    (knowledge_base_id, committed_ts DESC, promotion_id DESC);
CREATE INDEX IF NOT EXISTS knowledge_admin_estimate_documents_idx ON knowledge_document_t
    (knowledge_base_id, lifecycle_state, current_document_version_id);
CREATE INDEX IF NOT EXISTS knowledge_admin_estimate_chunks_idx ON knowledge_chunk_t
    (document_version_id) INCLUDE (token_count);
CREATE INDEX IF NOT EXISTS knowledge_admin_simulation_acl_idx ON knowledge_document_acl_t
    (document_id, acl_sequence DESC);

REVOKE ALL ON knowledge_admin_audit_t FROM PUBLIC;
GRANT INSERT ON knowledge_admin_audit_t TO light_knowledge_admin_api_role;
GRANT SELECT ON knowledge_admin_audit_t TO light_knowledge_ops_read_role;

COMMIT;

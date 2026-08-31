BEGIN;

CREATE TABLE IF NOT EXISTS knowledge_control_snapshot_t (
    snapshot_id uuid PRIMARY KEY,
    host_id uuid NOT NULL,
    environment varchar(32) NOT NULL,
    publication_sequence bigint NOT NULL CHECK (publication_sequence >= 0),
    source_event_watermark jsonb NOT NULL CHECK (jsonb_typeof(source_event_watermark)='object'),
    compatibility_generation integer NOT NULL CHECK (compatibility_generation > 0),
    payload_digest char(64) NOT NULL CHECK (payload_digest ~ '^[a-f0-9]{64}$'),
    signature_digest char(64) NOT NULL CHECK (signature_digest ~ '^[a-f0-9]{64}$'),
    state varchar(16) NOT NULL DEFAULT 'APPLIED' CHECK (
      state::text = ANY (ARRAY[
        'APPLIED'::varchar::text,'SUPERSEDED'::varchar::text])),
    applied_ts timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    lease_expires_ts timestamptz NOT NULL DEFAULT (CURRENT_TIMESTAMP + interval '5 minutes'),
    UNIQUE(host_id, environment, publication_sequence)
);

CREATE TABLE IF NOT EXISTS knowledge_promotion_receipt_t (
    promotion_id uuid PRIMARY KEY,
    knowledge_base_id uuid NOT NULL REFERENCES knowledge_base_t(knowledge_base_id) ON DELETE RESTRICT,
    environment varchar(32) NOT NULL,
    index_generation_id uuid NOT NULL REFERENCES knowledge_index_generation_t(index_generation_id) ON DELETE RESTRICT,
    pointer_version bigint NOT NULL CHECK (pointer_version > 0),
    evidence_digest char(64) NOT NULL CHECK (evidence_digest ~ '^[a-f0-9]{64}$'),
    authorized_by varchar(255) NOT NULL,
    committed_ts timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO knowledge_promotion_receipt_t(
    promotion_id,knowledge_base_id,environment,index_generation_id,
    pointer_version,evidence_digest,authorized_by,committed_ts)
SELECT o.promotion_id,o.knowledge_base_id,o.environment,o.index_generation_id,
       o.pointer_version,o.evidence_digest,'actor:v1:legacy-promotion',
       COALESCE(o.acknowledged_ts,o.created_ts)
  FROM knowledge_promotion_outbox_t o
ON CONFLICT (promotion_id) DO NOTHING;

ALTER TABLE knowledge_runtime_authorization_t
    DROP CONSTRAINT IF EXISTS knowledge_runtime_authorization_t_projector_id_fkey;

DROP TABLE IF EXISTS knowledge_promotion_ack_t;
DROP TABLE IF EXISTS knowledge_promotion_outbox_t;
DROP TABLE IF EXISTS knowledge_projection_ack_t;
DROP TABLE IF EXISTS knowledge_projection_inbox_t;
DROP TABLE IF EXISTS knowledge_projection_source_cursor_t;
DROP TABLE IF EXISTS knowledge_projection_heartbeat_t;

DROP FUNCTION IF EXISTS promote_knowledge_base_generation(
    uuid,uuid,uuid,varchar,uuid,bigint,varchar,text,jsonb,char,timestamptz);

CREATE OR REPLACE FUNCTION promote_knowledge_base_generation(
    p_promotion_id uuid,p_history_id uuid,p_knowledge_base_id uuid,
    p_environment varchar,p_generation_id uuid,p_expected_pointer_version bigint,
    p_authorized_by varchar,p_reason text,p_evidence jsonb,
    p_evidence_digest varchar,p_rollback_deadline timestamptz) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE
    current_version bigint;
    previous_generation uuid;
    next_version bigint;
    existing_receipt knowledge_promotion_receipt_t%ROWTYPE;
BEGIN
    SELECT * INTO existing_receipt FROM knowledge_promotion_receipt_t
     WHERE promotion_id=p_promotion_id;
    IF FOUND THEN
        IF existing_receipt.knowledge_base_id<>p_knowledge_base_id
           OR existing_receipt.environment<>p_environment
           OR existing_receipt.index_generation_id<>p_generation_id
           OR existing_receipt.pointer_version<>p_expected_pointer_version+1
           OR existing_receipt.evidence_digest<>p_evidence_digest
           OR existing_receipt.authorized_by<>p_authorized_by THEN
            RAISE EXCEPTION 'KNOWLEDGE_PROMOTION_IDEMPOTENCY_CONFLICT';
        END IF;
        RETURN existing_receipt.pointer_version;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM knowledge_base_t WHERE knowledge_base_id=p_knowledge_base_id AND environment=p_environment) THEN
        RAISE EXCEPTION 'KNOWLEDGE_BASE_ENVIRONMENT_MISMATCH';
    END IF;
    IF EXISTS (SELECT 1 FROM knowledge_index_pointer_t WHERE knowledge_base_id=p_knowledge_base_id AND environment<>p_environment) THEN
        RAISE EXCEPTION 'KNOWLEDGE_POINTER_ENVIRONMENT_MISMATCH';
    END IF;
    SELECT pointer_version,index_generation_id INTO current_version,previous_generation
      FROM knowledge_index_pointer_t WHERE knowledge_base_id=p_knowledge_base_id
       AND environment=p_environment FOR UPDATE;
    current_version := COALESCE(current_version,0);
    IF current_version<>p_expected_pointer_version THEN RAISE EXCEPTION 'KNOWLEDGE_POINTER_VERSION_CONFLICT'; END IF;
    IF NOT EXISTS (
        SELECT 1 FROM knowledge_index_generation_t generation
        JOIN knowledge_generation_segment_t member USING(index_generation_id)
        JOIN knowledge_index_segment_t segment USING(index_segment_id)
        WHERE generation.index_generation_id=p_generation_id
          AND generation.knowledge_base_id=p_knowledge_base_id
          AND generation.state='READY' AND member.ordinal=0
          AND segment.segment_kind='BASE' AND segment.state='READY'
    ) OR EXISTS (
        SELECT 1 FROM knowledge_generation_segment_t member
        JOIN knowledge_index_segment_t segment USING(index_segment_id)
        WHERE member.index_generation_id=p_generation_id AND segment.state<>'READY'
    ) THEN RAISE EXCEPTION 'KNOWLEDGE_GENERATION_NOT_READY_SEGMENT_SET'; END IF;
    next_version := current_version+1;
    UPDATE knowledge_index_generation_t SET state='SUPERSEDED'
      WHERE index_generation_id=previous_generation AND state='PROMOTED';
    UPDATE knowledge_index_generation_t SET state='PROMOTED',promoted_ts=CURRENT_TIMESTAMP
      WHERE index_generation_id=p_generation_id;
    INSERT INTO knowledge_index_pointer_t(knowledge_base_id,environment,index_generation_id,pointer_version,update_user)
      VALUES(p_knowledge_base_id,p_environment,p_generation_id,next_version,p_authorized_by)
      ON CONFLICT(knowledge_base_id) DO UPDATE SET
        index_generation_id=EXCLUDED.index_generation_id,pointer_version=EXCLUDED.pointer_version,
        update_ts=CURRENT_TIMESTAMP,update_user=EXCLUDED.update_user
      WHERE knowledge_index_pointer_t.environment=EXCLUDED.environment;
    INSERT INTO knowledge_index_pointer_history_t(pointer_history_id,knowledge_base_id,environment,
      previous_generation_id,selected_generation_id,pointer_version,evaluation_evidence,
      authorized_by,reason,rollback_deadline)
      VALUES(p_history_id,p_knowledge_base_id,p_environment,previous_generation,p_generation_id,
      next_version,p_evidence,p_authorized_by,p_reason,p_rollback_deadline);
    INSERT INTO knowledge_promotion_receipt_t(promotion_id,knowledge_base_id,environment,
      index_generation_id,pointer_version,evidence_digest,authorized_by)
      VALUES(p_promotion_id,p_knowledge_base_id,p_environment,p_generation_id,next_version,
      p_evidence_digest,p_authorized_by) ON CONFLICT(promotion_id) DO NOTHING;
    RETURN next_version;
END
$$;

REVOKE ALL ON FUNCTION promote_knowledge_base_generation(
    uuid,uuid,uuid,varchar,uuid,bigint,varchar,text,jsonb,varchar,timestamptz)
FROM PUBLIC;
GRANT EXECUTE ON FUNCTION promote_knowledge_base_generation(
    uuid,uuid,uuid,varchar,uuid,bigint,varchar,text,jsonb,varchar,timestamptz)
TO light_knowledge_worker_role;

REVOKE light_knowledge_snapshot_loader_role FROM light_knowledge_portal_projector_role;
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM light_knowledge_portal_projector_role;
REVOKE USAGE ON SCHEMA public FROM light_knowledge_portal_projector_role;

GRANT SELECT,INSERT,UPDATE ON knowledge_control_snapshot_t TO light_knowledge_admin_api_role;
GRANT SELECT,INSERT,UPDATE ON knowledge_job_t TO light_knowledge_admin_api_role;
GRANT SELECT ON knowledge_promotion_receipt_t TO light_knowledge_admin_api_role,light_knowledge_ops_read_role;
GRANT SELECT,INSERT ON knowledge_promotion_receipt_t TO light_knowledge_worker_role;
GRANT SELECT ON knowledge_control_snapshot_t TO light_knowledge_api_role,light_knowledge_worker_role;
GRANT SELECT,INSERT,UPDATE ON knowledge_control_snapshot_t TO light_knowledge_snapshot_loader_role;
GRANT SELECT,INSERT,UPDATE ON knowledge_runtime_authorization_t TO light_knowledge_snapshot_loader_role;

COMMIT;

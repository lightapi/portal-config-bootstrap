BEGIN;

DROP INDEX IF EXISTS idx_event_store_event_ts_id;

-- Upgrades may still contain the former co-located operational tables. Keep a
-- dependency-free, owner-only copy for the declared rollback window before
-- removing those relations from the runtime schema. CREATE TABLE AS copies
-- columns and rows but deliberately carries no foreign keys, triggers, views,
-- or functions across the database boundary.
CREATE SCHEMA IF NOT EXISTS knowledge_rollback_evidence;
REVOKE ALL ON SCHEMA knowledge_rollback_evidence FROM PUBLIC;

CREATE TABLE IF NOT EXISTS knowledge_rollback_evidence.capture_manifest_t (
    relation_name text PRIMARY KEY,
    captured_at timestamp with time zone NOT NULL,
    row_count bigint NOT NULL
);

CREATE TEMP TABLE phase6_removed_knowledge_relation_t (
    relation_name text PRIMARY KEY
) ON COMMIT DROP;
INSERT INTO phase6_removed_knowledge_relation_t (relation_name)
SELECT c.relname
  FROM pg_class c
  JOIN pg_namespace n ON n.oid=c.relnamespace
 WHERE n.nspname='public' AND c.relkind IN ('r','p')
   AND (c.relname LIKE 'knowledge\_%' ESCAPE '\'
        OR c.relname='agent_knowledge_base_t')
   AND c.relname NOT IN (
     'knowledge_embedding_profile_t','knowledge_ingestion_policy_t',
     'knowledge_retrieval_profile_t','knowledge_base_t',
     'knowledge_source_t','agent_knowledge_base_t',
     'knowledge_base_strategy_qualification_t',
     'knowledge_base_import_identity_map_t','knowledge_base_import_t',
     'knowledge_base_manifest_export_t');

DO $$
DECLARE relation_name text;
BEGIN
    FOR relation_name IN
        SELECT removed.relation_name
          FROM phase6_removed_knowledge_relation_t removed
         ORDER BY removed.relation_name
    LOOP
        EXECUTE format(
            'CREATE TABLE IF NOT EXISTS knowledge_rollback_evidence.%I AS TABLE public.%I WITH DATA',
            relation_name, relation_name
        );
        EXECUTE format(
            'INSERT INTO knowledge_rollback_evidence.capture_manifest_t '
            'VALUES (%L, clock_timestamp(), (SELECT count(*) FROM knowledge_rollback_evidence.%I)) '
            'ON CONFLICT (relation_name) DO NOTHING',
            relation_name, relation_name
        );
        EXECUTE format('DROP TABLE public.%I CASCADE',relation_name);
    END LOOP;
END
$$;

REVOKE ALL ON ALL TABLES IN SCHEMA knowledge_rollback_evidence FROM PUBLIC;

-- PL/pgSQL bodies loaded with check_function_bodies=off do not always acquire
-- catalog dependencies on the operational tables they reference. Remove the
-- former co-located routines explicitly.
DROP FUNCTION IF EXISTS enforce_knowledge_embedding_migration_contract() CASCADE;
DROP FUNCTION IF EXISTS enforce_knowledge_segment_vector_dimension() CASCADE;
DROP FUNCTION IF EXISTS knowledge_document_acl_authorized(uuid,text,text,text[],text[]) CASCADE;
DROP FUNCTION IF EXISTS knowledge_resolved_generation_chunk(uuid) CASCADE;
DROP FUNCTION IF EXISTS notify_knowledge_job_eligible() CASCADE;
DROP FUNCTION IF EXISTS promote_knowledge_base_generation(
    uuid,uuid,uuid,character varying,uuid,bigint,character varying,text,jsonb,
    character,timestamp with time zone
) CASCADE;
DROP FUNCTION IF EXISTS validate_knowledge_generation_segment_phase1b() CASCADE;
DROP FUNCTION IF EXISTS validate_knowledge_index_generation_profile() CASCADE;
DROP FUNCTION IF EXISTS validate_knowledge_index_pointer() CASCADE;

DO $$
DECLARE routine_identity text;
BEGIN
    FOR routine_identity IN
        SELECT routine.oid::regprocedure::text
          FROM pg_proc routine
          JOIN pg_namespace namespace ON namespace.oid = routine.pronamespace
         WHERE namespace.nspname = 'public'
           AND routine.prokind <> 'a'
           AND EXISTS (
             SELECT 1
               FROM phase6_removed_knowledge_relation_t removed
              WHERE position(
                removed.relation_name IN pg_get_functiondef(routine.oid)
              ) > 0
           )
    LOOP
        EXECUTE 'DROP ROUTINE ' || routine_identity || ' CASCADE';
    END LOOP;
END
$$;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles
                WHERE rolname='light_knowledge_portal_projector_role') THEN
        REVOKE ALL ON event_store_t FROM light_knowledge_portal_projector_role;
        REVOKE USAGE ON SCHEMA public FROM light_knowledge_portal_projector_role;
        REVOKE ALL ON SCHEMA knowledge_rollback_evidence
            FROM light_knowledge_portal_projector_role;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname='light_knowledge_api_role') THEN
        REVOKE ALL ON SCHEMA knowledge_rollback_evidence
            FROM light_knowledge_api_role;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname='light_knowledge_worker_role') THEN
        REVOKE ALL ON SCHEMA knowledge_rollback_evidence
            FROM light_knowledge_worker_role;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname='light_knowledge_ops_read_role') THEN
        REVOKE ALL ON SCHEMA knowledge_rollback_evidence
            FROM light_knowledge_ops_read_role;
    END IF;
END
$$;

COMMIT;

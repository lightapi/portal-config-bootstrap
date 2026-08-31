--
-- PostgreSQL database dump
--

\restrict cAc57KIIf2l6uz2LledZrfAk6Bp8LAVD3YQy7cVo8QyIqLI5Ew8gMjW7e7GsWPI

-- Dumped from database version 17.10 (Debian 17.10-1.pgdg12+1)
-- Dumped by pg_dump version 17.10 (Debian 17.10-1.pgdg12+1)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: pg_trgm; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA public;


--
-- Name: EXTENSION pg_trgm; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION pg_trgm IS 'text similarity measurement and index searching based on trigrams';


--
-- Name: pgcrypto; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA public;


--
-- Name: EXTENSION pgcrypto; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION pgcrypto IS 'cryptographic functions';


--
-- Name: vector; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS vector WITH SCHEMA public;


--
-- Name: EXTENSION vector; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION vector IS 'vector data type and ivfflat and hnsw access methods';


--
-- Name: enforce_knowledge_embedding_migration_contract(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_knowledge_embedding_migration_contract() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF TG_OP = 'UPDATE' AND ROW(
        NEW.migration_id, NEW.knowledge_base_id, NEW.environment,
        NEW.source_generation_id, NEW.candidate_generation_id,
        NEW.target_profile_id, NEW.target_profile_revision,
        NEW.target_space_id, NEW.target_space_revision, NEW.target_dimension,
        NEW.estimate_version, NEW.estimated_chunk_count,
        NEW.estimated_token_count, NEW.estimated_cost_micros,
        NEW.estimated_duration_seconds, NEW.estimated_temporary_bytes,
        NEW.accepted_cost_ceiling_micros, NEW.rollback_window_seconds,
        NEW.start_watermark,
        NEW.snapshot_watermark, NEW.requested_by, NEW.created_ts
    ) IS DISTINCT FROM ROW(
        OLD.migration_id, OLD.knowledge_base_id, OLD.environment,
        OLD.source_generation_id, OLD.candidate_generation_id,
        OLD.target_profile_id, OLD.target_profile_revision,
        OLD.target_space_id, OLD.target_space_revision, OLD.target_dimension,
        OLD.estimate_version, OLD.estimated_chunk_count,
        OLD.estimated_token_count, OLD.estimated_cost_micros,
        OLD.estimated_duration_seconds, OLD.estimated_temporary_bytes,
        OLD.accepted_cost_ceiling_micros, OLD.rollback_window_seconds,
        OLD.start_watermark,
        OLD.snapshot_watermark, OLD.requested_by, OLD.created_ts
    ) THEN
        RAISE EXCEPTION 'KNOWLEDGE_MIGRATION_IMMUTABLE_CONTRACT';
    END IF;
    IF TG_OP = 'UPDATE' AND NEW.version <= OLD.version THEN
        RAISE EXCEPTION 'KNOWLEDGE_MIGRATION_VERSION_CONFLICT';
    END IF;
    IF NEW.consumed_cost_micros + NEW.reserved_cost_micros
        > NEW.accepted_cost_ceiling_micros THEN
        RAISE EXCEPTION 'KNOWLEDGE_MIGRATION_COST_CEILING_EXCEEDED';
    END IF;
    RETURN NEW;
END
$$;


--
-- Name: enforce_knowledge_embedding_profile_immutable(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_knowledge_embedding_profile_immutable() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF ROW(NEW.host_id,NEW.alias_owner_host_id,NEW.public_alias_id,NEW.expected_space_id,
        NEW.expected_space_revision,NEW.dimension,NEW.normalization,NEW.distance_metric,
        NEW.document_input_transform_version,NEW.query_input_transform_version,NEW.qualification_digest)
       IS DISTINCT FROM ROW(OLD.host_id,OLD.alias_owner_host_id,OLD.public_alias_id,OLD.expected_space_id,
        OLD.expected_space_revision,OLD.dimension,OLD.normalization,OLD.distance_metric,
        OLD.document_input_transform_version,OLD.query_input_transform_version,OLD.qualification_digest) THEN
        RAISE EXCEPTION 'knowledge embedding profiles are immutable; create a new revision';
    END IF;
    RETURN NEW;
END; $$;


--
-- Name: enforce_knowledge_segment_vector_dimension(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_knowledge_segment_vector_dimension() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE expected_dimension INTEGER;
BEGIN
    SELECT generation.dimension INTO expected_dimension
      FROM knowledge_index_segment_t segment
      JOIN knowledge_index_generation_t generation
        ON generation.index_generation_id = segment.index_generation_id
     WHERE segment.index_segment_id = NEW.index_segment_id;
    IF expected_dimension IS NULL OR NEW.dimension <> expected_dimension THEN
        RAISE EXCEPTION 'KNOWLEDGE_SEGMENT_VECTOR_DIMENSION_MISMATCH';
    END IF;
    RETURN NEW;
END
$$;


--
-- Name: knowledge_document_acl_authorized(uuid, text, text, text[], text[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.knowledge_document_acl_authorized(p_document_id uuid, p_subject_id text, p_subject_type text, p_groups text[], p_organizations text[]) RETURNS boolean
    LANGUAGE sql STABLE
    AS $$
    SELECT COALESCE(bool_or(
        source.acl_mode='UNIFORM_SCOPE' OR (
            source.acl_mode='MIRROR_SOURCE_ACL'
            AND acl.visibility_mode='MIRROR_SOURCE_ACL'
            AND acl.completeness_state='COMPLETE'
            AND acl.provider_effective_decision
            AND source_acl.state='COMPLETE'
            AND source_acl.observed_ts<=now()
            AND source_acl.fresh_until_ts>now()
            AND source_acl.covered_object_count=source_acl.discovered_object_count
            AND source_acl.unresolved_subject_count=0
            AND NOT EXISTS (
                SELECT 1 FROM knowledge_acl_subject_t unresolved
                 WHERE unresolved.acl_revision_id=acl.acl_revision_id
                   AND (NOT unresolved.mapping_complete
                        OR unresolved.normalized_subject_type='UNRESOLVED')
            )
            AND NOT EXISTS (
                SELECT 1 FROM knowledge_acl_subject_t denied
                 WHERE denied.acl_revision_id=acl.acl_revision_id
                   AND denied.effect='DENY'
                   AND ((denied.normalized_subject_type='EVERYONE'
                         AND denied.normalized_subject_id='*')
                     OR (denied.normalized_subject_type='USER'
                         AND upper(p_subject_type) IN ('USER','PERSON')
                         AND denied.normalized_subject_id=p_subject_id)
                     OR (denied.normalized_subject_type='GROUP'
                         AND denied.normalized_subject_id=ANY(p_groups))
                     OR (denied.normalized_subject_type='ORGANIZATION'
                         AND denied.normalized_subject_id=ANY(p_organizations)))
            )
            AND EXISTS (
                SELECT 1 FROM knowledge_acl_subject_t allowed
                 WHERE allowed.acl_revision_id=acl.acl_revision_id
                   AND allowed.effect='ALLOW'
                   AND ((allowed.normalized_subject_type='EVERYONE'
                         AND allowed.normalized_subject_id='*')
                     OR (allowed.normalized_subject_type='USER'
                         AND upper(p_subject_type) IN ('USER','PERSON')
                         AND allowed.normalized_subject_id=p_subject_id)
                     OR (allowed.normalized_subject_type='GROUP'
                         AND allowed.normalized_subject_id=ANY(p_groups))
                     OR (allowed.normalized_subject_type='ORGANIZATION'
                         AND allowed.normalized_subject_id=ANY(p_organizations)))
            )
        )
    ),FALSE)
      FROM knowledge_document_t document
      JOIN knowledge_source_t source ON source.source_id=document.source_id
      JOIN LATERAL (
        SELECT revision.* FROM knowledge_document_acl_t revision
         WHERE revision.document_id=document.document_id
         ORDER BY revision.acl_sequence DESC LIMIT 1
      ) acl ON TRUE
      LEFT JOIN knowledge_source_acl_state_t source_acl
        ON source_acl.source_id=source.source_id
     WHERE document.document_id=p_document_id
       AND document.lifecycle_state='ACTIVE'
       AND source.status='ACTIVE'
$$;


--
-- Name: knowledge_resolved_generation_chunk(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.knowledge_resolved_generation_chunk(p_index_generation_id uuid) RETURNS TABLE(chunk_id uuid, document_id uuid, document_version_id uuid, acl_revision_id uuid)
    LANGUAGE sql STABLE
    AS $$
    WITH generation_segments AS (
        SELECT member.index_segment_id, member.ordinal
          FROM knowledge_generation_segment_t member
          JOIN knowledge_index_segment_t segment
            ON segment.index_segment_id=member.index_segment_id
           AND segment.state IN ('READY', 'BUILDING')
         WHERE member.index_generation_id=p_index_generation_id
    ), eligible AS (
        SELECT DISTINCT ON(segment_chunk.chunk_id)
               segment_chunk.chunk_id,
               document_version.document_id,
               chunk.document_version_id,
               segment_chunk.acl_revision_id,
               generation_segment.ordinal
          FROM generation_segments generation_segment
          JOIN knowledge_segment_chunk_t segment_chunk
            ON segment_chunk.index_segment_id=generation_segment.index_segment_id
          JOIN knowledge_chunk_t chunk ON chunk.chunk_id=segment_chunk.chunk_id
          JOIN knowledge_document_version_t document_version
            ON document_version.document_version_id=chunk.document_version_id
         WHERE NOT EXISTS (
             SELECT 1
               FROM generation_segments later
               JOIN knowledge_segment_operation_t operation
                 ON operation.index_segment_id=later.index_segment_id
              WHERE later.ordinal>generation_segment.ordinal
                AND operation.document_id=document_version.document_id
                AND (operation.operation_kind IN (
                      'SUPERSEDE_DOCUMENT', 'TOMBSTONE_DOCUMENT')
                     OR (operation.operation_kind='TOMBSTONE_CHUNK'
                         AND operation.chunk_id=segment_chunk.chunk_id))
         )
         ORDER BY segment_chunk.chunk_id, generation_segment.ordinal DESC
    )
    SELECT eligible.chunk_id, eligible.document_id,
           eligible.document_version_id, eligible.acl_revision_id
      FROM eligible
$$;


--
-- Name: notify_knowledge_job_eligible(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.notify_knowledge_job_eligible() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF NEW.state = 'QUEUED'
       AND (NEW.next_attempt_ts IS NULL OR NEW.next_attempt_ts <= CURRENT_TIMESTAMP)
       AND (TG_OP = 'INSERT'
            OR OLD.state IS DISTINCT FROM NEW.state
            OR OLD.next_attempt_ts IS DISTINCT FROM NEW.next_attempt_ts) THEN
        PERFORM pg_notify('knowledge_job_channel', NEW.job_id::text);
    END IF;
    RETURN NEW;
END;
$$;


--
-- Name: prevent_knowledge_acl_mode_downgrade(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.prevent_knowledge_acl_mode_downgrade() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF OLD.acl_mode='MIRROR_SOURCE_ACL'
       AND NEW.acl_mode='UNIFORM_SCOPE' THEN
        RAISE EXCEPTION 'MIRROR_SOURCE_ACL cannot be downgraded in place; create a new source identity';
    END IF;
    RETURN NEW;
END
$$;


--
-- Name: promote_knowledge_base_generation(uuid, uuid, uuid, character varying, uuid, bigint, character varying, text, jsonb, character varying, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.promote_knowledge_base_generation(p_promotion_id uuid, p_history_id uuid, p_knowledge_base_id uuid, p_environment character varying, p_generation_id uuid, p_expected_pointer_version bigint, p_authorized_by character varying, p_reason text, p_evidence jsonb, p_evidence_digest character varying, p_rollback_deadline timestamp with time zone) RETURNS bigint
    LANGUAGE plpgsql
    AS $$
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


--
-- Name: smart_cascade_delete(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.smart_cascade_delete() RETURNS trigger
    LANGUAGE plpgsql
    AS $_$
DECLARE
    relationship RECORD;
    where_clause TEXT;
    query_text TEXT;
    column_index INTEGER;
    deletion_context_token TEXT;
    delete_timestamp TIMESTAMP WITH TIME ZONE;
BEGIN
    IF NEW.active = FALSE AND OLD.active = TRUE THEN
        delete_timestamp := CURRENT_TIMESTAMP;
        FOR relationship IN
            SELECT *
            FROM cascade_relationships_v
            WHERE parent_schema = TG_TABLE_SCHEMA
              AND parent_table = TG_TABLE_NAME
            ORDER BY constraint_name
            LOOP
            where_clause := '';

            FOR column_index IN 1..relationship.column_count LOOP
                IF column_index > 1 THEN
                    where_clause := where_clause || ' AND ';
                END IF;

                where_clause := where_clause || format(
                    '%I = ($1).%I',
                    relationship.child_columns[column_index],
                    relationship.parent_columns[column_index]
                );
            END LOOP;

            deletion_context_token := md5(format(
                '%s.%s:%s',
                relationship.parent_schema,
                relationship.parent_table,
                relationship.constraint_name
            ));

            IF relationship.delete_action = 'SOFT_DELETE' THEN
                query_text := format(
                    'UPDATE %I.%I
                        SET active = FALSE,
                            delete_ts = CASE WHEN active THEN $2 ELSE delete_ts END,
                            delete_user = CASE
                                WHEN active THEN ''PARENT_CASCADE:'' || $3
                                WHEN NOT ($3 = ANY(string_to_array(substring(delete_user FROM 16), '','')))
                                    THEN delete_user || '','' || $3
                                ELSE delete_user
                            END,
                            update_ts = $2,
                            update_user = $4
                      WHERE %s
                        AND (
                            active = TRUE
                            OR left(delete_user, 15) = ''PARENT_CASCADE:''
                        )',
                    relationship.child_schema,
                    relationship.child_table,
                    where_clause
                );

                EXECUTE query_text
                    USING OLD, delete_timestamp, deletion_context_token, current_user;
            ELSIF relationship.delete_action = 'HARD_DELETE' THEN
                query_text := format(
                    'DELETE FROM %I.%I WHERE %s',
                    relationship.child_schema,
                    relationship.child_table,
                    where_clause
                );

                EXECUTE query_text USING OLD;
            END IF;
        END LOOP;
    ELSIF NEW.active = TRUE AND OLD.active = FALSE THEN
        FOR relationship IN
            SELECT *
            FROM cascade_relationships_v
            WHERE parent_schema = TG_TABLE_SCHEMA
              AND parent_table = TG_TABLE_NAME
              AND delete_action = 'SOFT_DELETE'
              AND restore_action = 'RESTORE'
            ORDER BY constraint_name
            LOOP
            where_clause := '';

            FOR column_index IN 1..relationship.column_count LOOP
                IF column_index > 1 THEN
                    where_clause := where_clause || ' AND ';
                END IF;

                where_clause := where_clause || format(
                    '%I = ($1).%I',
                    relationship.child_columns[column_index],
                    relationship.parent_columns[column_index]
                );
            END LOOP;

            deletion_context_token := md5(format(
                '%s.%s:%s',
                relationship.parent_schema,
                relationship.parent_table,
                relationship.constraint_name
            ));

            query_text := format(
                'UPDATE %I.%I
                    SET active = CASE
                            WHEN left(delete_user, 15) = ''PARENT_CASCADE:''
                                THEN cardinality(array_remove(
                                    string_to_array(substring(delete_user FROM 16), '',''), $2
                                )) = 0
                            ELSE TRUE
                        END,
                        delete_ts = CASE
                            WHEN left(delete_user, 15) = ''PARENT_CASCADE:''
                             AND cardinality(array_remove(
                                    string_to_array(substring(delete_user FROM 16), '',''), $2
                                 )) > 0
                                THEN delete_ts
                            ELSE NULL
                        END,
                        delete_user = CASE
                            WHEN left(delete_user, 15) = ''PARENT_CASCADE:''
                             AND cardinality(array_remove(
                                    string_to_array(substring(delete_user FROM 16), '',''), $2
                                 )) > 0
                                THEN ''PARENT_CASCADE:'' || array_to_string(
                                    array_remove(string_to_array(substring(delete_user FROM 16), '',''), $2), '',''
                                )
                            ELSE NULL
                        END,
                        update_ts = CURRENT_TIMESTAMP,
                        update_user = $3
                  WHERE %s
                    AND active = FALSE
                    AND (
                        (
                            left(delete_user, 15) = ''PARENT_CASCADE:''
                            AND $2 = ANY(string_to_array(substring(delete_user FROM 16), '',''))
                        )
                        OR left(delete_user, length($4)) = $4
                    )',
                relationship.child_schema,
                relationship.child_table,
                where_clause
            );

            EXECUTE query_text
                USING OLD, deletion_context_token, current_user,
                    'PARENT_CASCADE_' || TG_TABLE_NAME || '_';
        END LOOP;
    END IF;

    RETURN NEW;
END;
$_$;


--
-- Name: validate_cascade_relationship_policies(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.validate_cascade_relationship_policies() RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    invalid_policy RECORD;
    invalid_width RECORD;
    unclassified_relationship RECORD;
BEGIN
    SELECT policy.*
      INTO invalid_policy
      FROM cascade_relationship_policy_t policy
      LEFT JOIN pg_namespace pn
        ON pn.nspname = policy.parent_schema
      LEFT JOIN pg_class pc
        ON pc.relnamespace = pn.oid
       AND pc.relname = policy.parent_table
      LEFT JOIN pg_namespace cn
        ON cn.nspname = policy.child_schema
      LEFT JOIN pg_class cc
        ON cc.relnamespace = cn.oid
       AND cc.relname = policy.child_table
      LEFT JOIN pg_constraint constraint_row
        ON constraint_row.contype = 'f'
       AND constraint_row.conname = policy.constraint_name
       AND constraint_row.confrelid = pc.oid
       AND constraint_row.conrelid = cc.oid
     WHERE constraint_row.oid IS NULL
     ORDER BY
        policy.parent_schema,
        policy.parent_table,
        policy.child_schema,
        policy.child_table,
        policy.constraint_name
     LIMIT 1;

    IF FOUND THEN
        RAISE EXCEPTION
            'cascade policy references missing or mismatched foreign key: %.% -> %.% (%)',
            invalid_policy.parent_schema,
            invalid_policy.parent_table,
            invalid_policy.child_schema,
            invalid_policy.child_table,
            invalid_policy.constraint_name;
    END IF;

    SELECT *
      INTO invalid_policy
      FROM cascade_relationships_v
     WHERE delete_action IN ('SOFT_DELETE', 'HARD_DELETE')
       AND NOT (
           parent_has_active
           AND parent_has_delete_ts
           AND parent_has_delete_user
           AND parent_has_update_ts
           AND parent_has_update_user
       )
     ORDER BY parent_schema, parent_table, child_schema, child_table, constraint_name
     LIMIT 1;

    IF FOUND THEN
        RAISE EXCEPTION
            'cascade parent %.% does not implement the complete soft-delete contract for constraint %',
            invalid_policy.parent_schema,
            invalid_policy.parent_table,
            invalid_policy.constraint_name;
    END IF;

    SELECT *
      INTO invalid_policy
      FROM cascade_relationships_v
     WHERE delete_action = 'SOFT_DELETE'
       AND NOT (
           child_has_active
           AND child_has_delete_ts
           AND child_has_delete_user
           AND child_has_update_ts
           AND child_has_update_user
       )
     ORDER BY parent_schema, parent_table, child_schema, child_table, constraint_name
     LIMIT 1;

    IF FOUND THEN
        RAISE EXCEPTION
            'soft-delete child %.% does not implement the complete contract for constraint %',
            invalid_policy.child_schema,
            invalid_policy.child_table,
            invalid_policy.constraint_name;
    END IF;

    WITH soft_child_requirements AS (
        SELECT
            child_schema,
            child_table,
            count(*)::integer AS relationship_count,
            (14 + 33 * count(*))::integer AS required_length
        FROM cascade_relationships_v
        WHERE delete_action = 'SOFT_DELETE'
        GROUP BY child_schema, child_table
    )
    SELECT
        requirement.child_schema,
        requirement.child_table,
        requirement.relationship_count,
        requirement.required_length,
        (attribute_row.atttypmod - 4)::integer AS actual_length
      INTO invalid_width
      FROM soft_child_requirements requirement
      JOIN pg_namespace namespace_row
        ON namespace_row.nspname = requirement.child_schema
      JOIN pg_class class_row
        ON class_row.relnamespace = namespace_row.oid
       AND class_row.relname = requirement.child_table
      JOIN pg_attribute attribute_row
        ON attribute_row.attrelid = class_row.oid
       AND attribute_row.attname = 'delete_user'
       AND NOT attribute_row.attisdropped
     WHERE attribute_row.atttypid IN ('varchar'::regtype, 'bpchar'::regtype)
       AND attribute_row.atttypmod >= 0
       AND attribute_row.atttypmod - 4 < requirement.required_length
     ORDER BY requirement.child_schema, requirement.child_table
     LIMIT 1;

    IF FOUND THEN
        RAISE EXCEPTION
            'soft-delete child %.% delete_user width % is smaller than required % for % cascade relationships',
            invalid_width.child_schema,
            invalid_width.child_table,
            invalid_width.actual_length,
            invalid_width.required_length,
            invalid_width.relationship_count;
    END IF;

    SELECT *
      INTO invalid_policy
      FROM cascade_relationships_v
     WHERE delete_action = 'HARD_DELETE'
       AND foreign_key_delete_action <> 'CASCADE'
     ORDER BY parent_schema, parent_table, child_schema, child_table, constraint_name
     LIMIT 1;

    IF FOUND THEN
        RAISE EXCEPTION
            'hard-delete policy requires ON DELETE CASCADE for constraint %',
            invalid_policy.constraint_name;
    END IF;

    SELECT
        relationship.child_schema,
        relationship.child_table,
        downstream_namespace.nspname::text AS downstream_schema,
        downstream_table.relname::text AS downstream_table,
        downstream_constraint.conname::text AS downstream_constraint
      INTO invalid_policy
      FROM cascade_relationships_v relationship
      JOIN pg_constraint downstream_constraint
        ON downstream_constraint.contype = 'f'
       AND downstream_constraint.confrelid = relationship.child_table_oid
      JOIN pg_class downstream_table
        ON downstream_table.oid = downstream_constraint.conrelid
      JOIN pg_namespace downstream_namespace
        ON downstream_namespace.oid = downstream_table.relnamespace
     WHERE relationship.delete_action = 'HARD_DELETE'
       AND downstream_constraint.confdeltype <> 'c'
     ORDER BY
        relationship.child_schema,
        relationship.child_table,
        downstream_namespace.nspname,
        downstream_table.relname,
        downstream_constraint.conname
     LIMIT 1;

    IF FOUND THEN
        RAISE EXCEPTION
            'hard-delete child %.% is referenced by non-cascading constraint %.% (%)',
            invalid_policy.child_schema,
            invalid_policy.child_table,
            invalid_policy.downstream_schema,
            invalid_policy.downstream_table,
            invalid_policy.downstream_constraint;
    END IF;

    WITH candidate_relationships AS (
        SELECT
            pn.nspname::text AS parent_schema,
            pc.relname::text AS parent_table,
            cn.nspname::text AS child_schema,
            cc.relname::text AS child_table,
            constraint_row.conname::text AS constraint_name
        FROM pg_constraint constraint_row
        JOIN pg_class pc ON pc.oid = constraint_row.confrelid
        JOIN pg_namespace pn ON pn.oid = pc.relnamespace
        JOIN pg_class cc ON cc.oid = constraint_row.conrelid
        JOIN pg_namespace cn ON cn.oid = cc.relnamespace
        WHERE constraint_row.contype = 'f'
          AND pn.nspname = 'public'
          AND cn.nspname = 'public'
          AND EXISTS (
              SELECT 1
              FROM pg_attribute a
              WHERE a.attrelid = pc.oid
                AND a.attname = 'delete_ts'
                AND NOT a.attisdropped
          )
          AND EXISTS (
              SELECT 1
              FROM pg_attribute a
              WHERE a.attrelid = pc.oid
                AND a.attname = 'active'
                AND NOT a.attisdropped
          )
    )
    SELECT candidate.*
      INTO unclassified_relationship
      FROM candidate_relationships candidate
      LEFT JOIN cascade_relationship_policy_t policy
        ON policy.parent_schema = candidate.parent_schema
       AND policy.parent_table = candidate.parent_table
       AND policy.child_schema = candidate.child_schema
       AND policy.child_table = candidate.child_table
       AND policy.constraint_name = candidate.constraint_name
     WHERE policy.constraint_name IS NULL
     ORDER BY
        candidate.parent_schema,
        candidate.parent_table,
        candidate.child_schema,
        candidate.child_table,
        candidate.constraint_name
     LIMIT 1;

    IF FOUND THEN
        RAISE EXCEPTION
            'unclassified cascade relationship: %.% -> %.% (%)',
            unclassified_relationship.parent_schema,
            unclassified_relationship.parent_table,
            unclassified_relationship.child_schema,
            unclassified_relationship.child_table,
            unclassified_relationship.constraint_name;
    END IF;
END;
$$;


--
-- Name: validate_knowledge_generation_segment_phase1b(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.validate_knowledge_generation_segment_phase1b() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    expected RECORD;
    candidate RECORD;
BEGIN
    SELECT g.knowledge_base_id, g.space_id, g.space_revision,
           g.dimension, s.parser_contract_digest, s.chunker_contract_digest,
           s.lexical_contract_digest, s.embedding_contract_digest,
           s.acl_contract_digest
      INTO candidate
      FROM knowledge_index_generation_t g
      JOIN knowledge_index_segment_t s
        ON s.index_segment_id = NEW.index_segment_id
       AND s.knowledge_base_id = g.knowledge_base_id
     WHERE g.index_generation_id = NEW.index_generation_id
    ;
    IF candidate IS NULL THEN
        RAISE EXCEPTION 'KNOWLEDGE_GENERATION_SEGMENT_IDENTITY_MISMATCH';
    END IF;
    SELECT g.knowledge_base_id, g.space_id, g.space_revision,
           g.dimension, s.parser_contract_digest, s.chunker_contract_digest,
           s.lexical_contract_digest, s.embedding_contract_digest,
           s.acl_contract_digest
      INTO expected
      FROM knowledge_generation_segment_t gs
      JOIN knowledge_index_generation_t g
        ON g.index_generation_id = gs.index_generation_id
      JOIN knowledge_index_segment_t s
        ON s.index_segment_id = gs.index_segment_id
     WHERE gs.index_generation_id = NEW.index_generation_id
     ORDER BY gs.ordinal LIMIT 1;
    IF expected IS NOT NULL AND expected IS DISTINCT FROM candidate THEN
        RAISE EXCEPTION 'KNOWLEDGE_GENERATION_SEGMENT_CONTRACT_MISMATCH';
    END IF;
    RETURN NEW;
END
$$;


--
-- Name: validate_knowledge_index_generation_profile(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.validate_knowledge_index_generation_profile() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
          FROM knowledge_embedding_profile_t profile
         WHERE profile.profile_id = NEW.embedding_profile_id
           AND profile.profile_revision = NEW.embedding_profile_revision
           AND profile.expected_space_id = NEW.space_id
           AND profile.expected_space_revision = NEW.space_revision
           AND profile.dimension = NEW.dimension
           AND profile.query_input_transform_version
               = NEW.query_input_transform_version
    ) THEN
        RAISE EXCEPTION
            'index generation must preserve its immutable embedding profile contract';
    END IF;
    RETURN NEW;
END
$$;


--
-- Name: validate_knowledge_index_pointer(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.validate_knowledge_index_pointer() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
          FROM knowledge_index_generation_t generation
          JOIN knowledge_base_t knowledge_base
            ON knowledge_base.knowledge_base_id = generation.knowledge_base_id
         WHERE generation.index_generation_id = NEW.index_generation_id
           AND generation.knowledge_base_id = NEW.knowledge_base_id
           AND generation.state = 'PROMOTED'
           AND knowledge_base.environment = NEW.environment
    ) THEN
        RAISE EXCEPTION
            'index pointer must select one matching promoted generation and environment';
    END IF;
    RETURN NEW;
END
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: agent_knowledge_base_t; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.agent_knowledge_base_t (
    host_id uuid NOT NULL,
    agent_id uuid NOT NULL,
    knowledge_base_id uuid NOT NULL,
    environment character varying(32) NOT NULL,
    retrieval_profile_id uuid NOT NULL,
    priority integer DEFAULT 50 NOT NULL,
    version bigint DEFAULT 1 NOT NULL,
    active boolean DEFAULT true NOT NULL,
    update_ts timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    update_user character varying(126) DEFAULT SESSION_USER NOT NULL,
    evidence_required boolean DEFAULT false NOT NULL,
    allowed_source_trust_tiers jsonb DEFAULT '[]'::jsonb NOT NULL,
    CONSTRAINT agent_knowledge_base_t_allowed_source_trust_tiers_check CHECK ((jsonb_typeof(allowed_source_trust_tiers) = 'array'::text)),
    CONSTRAINT agent_knowledge_base_t_environment_check CHECK ((length((environment)::text) > 0)),
    CONSTRAINT agent_knowledge_base_t_priority_check CHECK (((priority >= 1) AND (priority <= 100))),
    CONSTRAINT agent_knowledge_base_t_version_check CHECK ((version > 0))
);


--
-- Name: TABLE agent_knowledge_base_t; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.agent_knowledge_base_t IS 'Stores agent knowledge base records used by the Light Workflow, Light Agent, and execution runtime services.';


--
-- Name: COLUMN agent_knowledge_base_t.host_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.agent_knowledge_base_t.host_id IS 'Tenant host identifier that scopes this record.';


--
-- Name: COLUMN agent_knowledge_base_t.agent_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.agent_knowledge_base_t.agent_id IS 'Identifier for the related agent.';


--
-- Name: COLUMN agent_knowledge_base_t.knowledge_base_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.agent_knowledge_base_t.knowledge_base_id IS 'Identifier for the related knowledge base.';


--
-- Name: COLUMN agent_knowledge_base_t.environment; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.agent_knowledge_base_t.environment IS 'Environment value for this agent knowledge base record.';


--
-- Name: COLUMN agent_knowledge_base_t.retrieval_profile_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.agent_knowledge_base_t.retrieval_profile_id IS 'Identifier for the related retrieval profile.';


--
-- Name: COLUMN agent_knowledge_base_t.priority; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.agent_knowledge_base_t.priority IS 'Priority value for this agent knowledge base record.';


--
-- Name: COLUMN agent_knowledge_base_t.version; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.agent_knowledge_base_t.version IS 'Version value for version.';


--
-- Name: COLUMN agent_knowledge_base_t.active; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.agent_knowledge_base_t.active IS 'Indicates whether this record is active.';


--
-- Name: COLUMN agent_knowledge_base_t.update_ts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.agent_knowledge_base_t.update_ts IS 'Timestamp when this record was last updated.';


--
-- Name: COLUMN agent_knowledge_base_t.update_user; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.agent_knowledge_base_t.update_user IS 'User or service principal that last updated this record.';


--
-- Name: COLUMN agent_knowledge_base_t.evidence_required; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.agent_knowledge_base_t.evidence_required IS 'Evidence Required value for this agent knowledge base record.';


--
-- Name: COLUMN agent_knowledge_base_t.allowed_source_trust_tiers; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.agent_knowledge_base_t.allowed_source_trust_tiers IS 'Allowed Source Trust Tiers value for this agent knowledge base record.';


--
-- Name: cascade_relationship_policy_t; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.cascade_relationship_policy_t (
    parent_schema character varying(63) DEFAULT 'public'::character varying NOT NULL,
    parent_table character varying(63) NOT NULL,
    child_schema character varying(63) DEFAULT 'public'::character varying NOT NULL,
    child_table character varying(63) NOT NULL,
    constraint_name character varying(63) NOT NULL,
    delete_action character varying(16) NOT NULL,
    restore_action character varying(16) DEFAULT 'NONE'::character varying NOT NULL,
    policy_description character varying(1024),
    update_user character varying(255) DEFAULT SESSION_USER NOT NULL,
    update_ts timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT cascade_relationship_policy_t_check CHECK (((((delete_action)::text = 'SOFT_DELETE'::text) AND ((restore_action)::text = 'RESTORE'::text)) OR (((delete_action)::text = ANY (ARRAY[('HARD_DELETE'::character varying)::text, ('IGNORE'::character varying)::text])) AND ((restore_action)::text = 'NONE'::text)))),
    CONSTRAINT cascade_relationship_policy_t_delete_action_check CHECK (((delete_action)::text = ANY (ARRAY[('SOFT_DELETE'::character varying)::text, ('HARD_DELETE'::character varying)::text, ('IGNORE'::character varying)::text]))),
    CONSTRAINT cascade_relationship_policy_t_restore_action_check CHECK (((restore_action)::text = ANY (ARRAY[('RESTORE'::character varying)::text, ('NONE'::character varying)::text])))
);


--
-- Name: TABLE cascade_relationship_policy_t; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.cascade_relationship_policy_t IS 'Stores cascade relationship policy records used by the Light Portal platform services.';


--
-- Name: COLUMN cascade_relationship_policy_t.parent_schema; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.cascade_relationship_policy_t.parent_schema IS 'Parent Schema value for this cascade relationship policy record.';


--
-- Name: COLUMN cascade_relationship_policy_t.parent_table; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.cascade_relationship_policy_t.parent_table IS 'Parent Table value for this cascade relationship policy record.';


--
-- Name: COLUMN cascade_relationship_policy_t.child_schema; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.cascade_relationship_policy_t.child_schema IS 'Child Schema value for this cascade relationship policy record.';


--
-- Name: COLUMN cascade_relationship_policy_t.child_table; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.cascade_relationship_policy_t.child_table IS 'Child Table value for this cascade relationship policy record.';


--
-- Name: COLUMN cascade_relationship_policy_t.constraint_name; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.cascade_relationship_policy_t.constraint_name IS 'Constraint Name value for this cascade relationship policy record.';


--
-- Name: COLUMN cascade_relationship_policy_t.delete_action; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.cascade_relationship_policy_t.delete_action IS 'Delete Action value for this cascade relationship policy record.';


--
-- Name: COLUMN cascade_relationship_policy_t.restore_action; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.cascade_relationship_policy_t.restore_action IS 'Restore Action value for this cascade relationship policy record.';


--
-- Name: COLUMN cascade_relationship_policy_t.policy_description; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.cascade_relationship_policy_t.policy_description IS 'Policy Description value for this cascade relationship policy record.';


--
-- Name: COLUMN cascade_relationship_policy_t.update_user; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.cascade_relationship_policy_t.update_user IS 'User or service principal that last updated this record.';


--
-- Name: COLUMN cascade_relationship_policy_t.update_ts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.cascade_relationship_policy_t.update_ts IS 'Timestamp when this record was last updated.';


--
-- Name: cascade_relationships_v; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.cascade_relationships_v AS
 WITH fk_details AS (
         SELECT (pn.nspname)::text AS parent_schema,
            (pc.relname)::text AS parent_table,
            (cn.nspname)::text AS child_schema,
            (cc.relname)::text AS child_table,
            (c.conname)::text AS constraint_name,
            c.oid AS constraint_id,
            cc.oid AS child_table_oid,
            pc.oid AS parent_table_oid,
            c.confdeltype,
            array_agg((pa.attname)::text ORDER BY keys.ord) AS parent_columns,
            array_agg((ca.attname)::text ORDER BY keys.ord) AS child_columns,
            (count(*))::integer AS column_count
           FROM (((((((pg_constraint c
             JOIN pg_class pc ON ((pc.oid = c.confrelid)))
             JOIN pg_namespace pn ON ((pn.oid = pc.relnamespace)))
             JOIN pg_class cc ON ((cc.oid = c.conrelid)))
             JOIN pg_namespace cn ON ((cn.oid = cc.relnamespace)))
             JOIN LATERAL UNNEST(c.confkey, c.conkey) WITH ORDINALITY keys(parent_attnum, child_attnum, ord) ON (true))
             JOIN pg_attribute pa ON (((pa.attrelid = pc.oid) AND (pa.attnum = keys.parent_attnum) AND (NOT pa.attisdropped))))
             JOIN pg_attribute ca ON (((ca.attrelid = cc.oid) AND (ca.attnum = keys.child_attnum) AND (NOT ca.attisdropped))))
          WHERE (c.contype = 'f'::"char")
          GROUP BY pn.nspname, pc.relname, cn.nspname, cc.relname, c.conname, c.oid, cc.oid, pc.oid, c.confdeltype
        )
 SELECT fk.parent_schema,
    fk.parent_table,
    fk.child_schema,
    fk.child_table,
    fk.constraint_name,
    fk.constraint_id,
    fk.parent_columns,
    fk.child_columns,
    fk.column_count,
    fk.child_table_oid,
    fk.parent_table_oid,
        CASE fk.confdeltype
            WHEN 'a'::"char" THEN 'NO ACTION'::text
            WHEN 'r'::"char" THEN 'RESTRICT'::text
            WHEN 'c'::"char" THEN 'CASCADE'::text
            WHEN 'n'::"char" THEN 'SET NULL'::text
            WHEN 'd'::"char" THEN 'SET DEFAULT'::text
            ELSE 'UNKNOWN'::text
        END AS foreign_key_delete_action,
    policy.delete_action,
    policy.restore_action,
    (EXISTS ( SELECT 1
           FROM pg_attribute a
          WHERE ((a.attrelid = fk.parent_table_oid) AND (a.attname = 'active'::name) AND (NOT a.attisdropped)))) AS parent_has_active,
    (EXISTS ( SELECT 1
           FROM pg_attribute a
          WHERE ((a.attrelid = fk.parent_table_oid) AND (a.attname = 'delete_ts'::name) AND (NOT a.attisdropped)))) AS parent_has_delete_ts,
    (EXISTS ( SELECT 1
           FROM pg_attribute a
          WHERE ((a.attrelid = fk.parent_table_oid) AND (a.attname = 'delete_user'::name) AND (NOT a.attisdropped)))) AS parent_has_delete_user,
    (EXISTS ( SELECT 1
           FROM pg_attribute a
          WHERE ((a.attrelid = fk.parent_table_oid) AND (a.attname = 'update_ts'::name) AND (NOT a.attisdropped)))) AS parent_has_update_ts,
    (EXISTS ( SELECT 1
           FROM pg_attribute a
          WHERE ((a.attrelid = fk.parent_table_oid) AND (a.attname = 'update_user'::name) AND (NOT a.attisdropped)))) AS parent_has_update_user,
    (EXISTS ( SELECT 1
           FROM pg_attribute a
          WHERE ((a.attrelid = fk.child_table_oid) AND (a.attname = 'active'::name) AND (NOT a.attisdropped)))) AS child_has_active,
    (EXISTS ( SELECT 1
           FROM pg_attribute a
          WHERE ((a.attrelid = fk.child_table_oid) AND (a.attname = 'delete_ts'::name) AND (NOT a.attisdropped)))) AS child_has_delete_ts,
    (EXISTS ( SELECT 1
           FROM pg_attribute a
          WHERE ((a.attrelid = fk.child_table_oid) AND (a.attname = 'delete_user'::name) AND (NOT a.attisdropped)))) AS child_has_delete_user,
    (EXISTS ( SELECT 1
           FROM pg_attribute a
          WHERE ((a.attrelid = fk.child_table_oid) AND (a.attname = 'update_ts'::name) AND (NOT a.attisdropped)))) AS child_has_update_ts,
    (EXISTS ( SELECT 1
           FROM pg_attribute a
          WHERE ((a.attrelid = fk.child_table_oid) AND (a.attname = 'update_user'::name) AND (NOT a.attisdropped)))) AS child_has_update_user
   FROM (fk_details fk
     JOIN public.cascade_relationship_policy_t policy ON ((((policy.parent_schema)::text = fk.parent_schema) AND ((policy.parent_table)::text = fk.parent_table) AND ((policy.child_schema)::text = fk.child_schema) AND ((policy.child_table)::text = fk.child_table) AND ((policy.constraint_name)::text = fk.constraint_name))));


--
-- Name: knowledge_acl_reconciliation_t; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.knowledge_acl_reconciliation_t (
    reconciliation_id uuid NOT NULL,
    knowledge_base_id uuid NOT NULL,
    source_id uuid NOT NULL,
    provider character varying(16) NOT NULL,
    reconciliation_mode character varying(12) NOT NULL,
    state character varying(16) NOT NULL,
    input_cursor_digest character(64),
    output_cursor_digest character(64),
    discovered_object_count bigint DEFAULT 0 NOT NULL,
    applied_acl_count bigint DEFAULT 0 NOT NULL,
    denied_object_count bigint DEFAULT 0 NOT NULL,
    unresolved_subject_count bigint DEFAULT 0 NOT NULL,
    provider_evidence jsonb DEFAULT '{}'::jsonb NOT NULL,
    evidence_digest character(64) NOT NULL,
    started_ts timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    finished_ts timestamp with time zone,
    fresh_until_ts timestamp with time zone,
    error_code character varying(96),
    CONSTRAINT knowledge_acl_reconciliation_t_applied_acl_count_check CHECK ((applied_acl_count >= 0)),
    CONSTRAINT knowledge_acl_reconciliation_t_check CHECK ((((state)::text <> 'COMPLETE'::text) OR ((finished_ts IS NOT NULL) AND (fresh_until_ts IS NOT NULL) AND (fresh_until_ts >= finished_ts) AND (fresh_until_ts <= (finished_ts + '00:15:00'::interval)) AND (unresolved_subject_count = 0)))),
    CONSTRAINT knowledge_acl_reconciliation_t_denied_object_count_check CHECK ((denied_object_count >= 0)),
    CONSTRAINT knowledge_acl_reconciliation_t_discovered_object_count_check CHECK ((discovered_object_count >= 0)),
    CONSTRAINT knowledge_acl_reconciliation_t_evidence_digest_check CHECK ((evidence_digest ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT knowledge_acl_reconciliation_t_input_cursor_digest_check CHECK (((input_cursor_digest IS NULL) OR (input_cursor_digest ~ '^[a-f0-9]{64}$'::text))),
    CONSTRAINT knowledge_acl_reconciliation_t_output_cursor_digest_check CHECK (((output_cursor_digest IS NULL) OR (output_cursor_digest ~ '^[a-f0-9]{64}$'::text))),
    CONSTRAINT knowledge_acl_reconciliation_t_provider_check CHECK (((provider)::text = ANY (ARRAY[('SHAREPOINT'::character varying)::text, ('CONFLUENCE'::character varying)::text]))),
    CONSTRAINT knowledge_acl_reconciliation_t_provider_evidence_check CHECK ((jsonb_typeof(provider_evidence) = 'object'::text)),
    CONSTRAINT knowledge_acl_reconciliation_t_reconciliation_mode_check CHECK (((reconciliation_mode)::text = ANY (ARRAY[('FULL'::character varying)::text, ('DELTA'::character varying)::text, ('HINT'::character varying)::text]))),
    CONSTRAINT knowledge_acl_reconciliation_t_state_check CHECK (((state)::text = ANY (ARRAY[('REQUESTED'::character varying)::text, ('RUNNING'::character varying)::text, ('COMPLETE'::character varying)::text, ('FAILED'::character varying)::text, ('INCOMPLETE'::character varying)::text]))),
    CONSTRAINT knowledge_acl_reconciliation_t_unresolved_subject_count_check CHECK ((unresolved_subject_count >= 0))
);


--
-- Name: TABLE knowledge_acl_reconciliation_t; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.knowledge_acl_reconciliation_t IS 'Stores knowledge acl reconciliation records used by the Light Knowledge ingestion, retrieval, indexing, and operations services.';


--
-- Name: COLUMN knowledge_acl_reconciliation_t.reconciliation_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_acl_reconciliation_t.reconciliation_id IS 'Identifier for the related reconciliation.';


--
-- Name: COLUMN knowledge_acl_reconciliation_t.knowledge_base_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_acl_reconciliation_t.knowledge_base_id IS 'Identifier for the related knowledge base.';


--
-- Name: COLUMN knowledge_acl_reconciliation_t.source_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_acl_reconciliation_t.source_id IS 'Identifier for the related source.';


--
-- Name: COLUMN knowledge_acl_reconciliation_t.provider; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_acl_reconciliation_t.provider IS 'Provider value for this knowledge acl reconciliation record.';


--
-- Name: COLUMN knowledge_acl_reconciliation_t.reconciliation_mode; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_acl_reconciliation_t.reconciliation_mode IS 'Reconciliation Mode value for this knowledge acl reconciliation record.';


--
-- Name: COLUMN knowledge_acl_reconciliation_t.state; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_acl_reconciliation_t.state IS 'State value for this knowledge acl reconciliation record.';


--
-- Name: COLUMN knowledge_acl_reconciliation_t.input_cursor_digest; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_acl_reconciliation_t.input_cursor_digest IS 'Integrity digest for input cursor.';


--
-- Name: COLUMN knowledge_acl_reconciliation_t.output_cursor_digest; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_acl_reconciliation_t.output_cursor_digest IS 'Integrity digest for output cursor.';


--
-- Name: COLUMN knowledge_acl_reconciliation_t.discovered_object_count; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_acl_reconciliation_t.discovered_object_count IS 'Count of discovered object.';


--
-- Name: COLUMN knowledge_acl_reconciliation_t.applied_acl_count; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_acl_reconciliation_t.applied_acl_count IS 'Count of applied acl.';


--
-- Name: COLUMN knowledge_acl_reconciliation_t.denied_object_count; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_acl_reconciliation_t.denied_object_count IS 'Count of denied object.';


--
-- Name: COLUMN knowledge_acl_reconciliation_t.unresolved_subject_count; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_acl_reconciliation_t.unresolved_subject_count IS 'Count of unresolved subject.';


--
-- Name: COLUMN knowledge_acl_reconciliation_t.provider_evidence; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_acl_reconciliation_t.provider_evidence IS 'Provider Evidence value for this knowledge acl reconciliation record.';


--
-- Name: COLUMN knowledge_acl_reconciliation_t.evidence_digest; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_acl_reconciliation_t.evidence_digest IS 'Integrity digest for evidence.';


--
-- Name: COLUMN knowledge_acl_reconciliation_t.started_ts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_acl_reconciliation_t.started_ts IS 'Timestamp for the started event or state.';


--
-- Name: COLUMN knowledge_acl_reconciliation_t.finished_ts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_acl_reconciliation_t.finished_ts IS 'Timestamp for the finished event or state.';


--
-- Name: COLUMN knowledge_acl_reconciliation_t.fresh_until_ts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_acl_reconciliation_t.fresh_until_ts IS 'Timestamp for the fresh until event or state.';


--
-- Name: COLUMN knowledge_acl_reconciliation_t.error_code; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_acl_reconciliation_t.error_code IS 'Error Code value for this knowledge acl reconciliation record.';


--
-- Name: knowledge_acl_subject_t; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.knowledge_acl_subject_t (
    acl_revision_id uuid NOT NULL,
    subject_ordinal integer NOT NULL,
    knowledge_base_id uuid NOT NULL,
    document_id uuid NOT NULL,
    provider_subject_type character varying(32) NOT NULL,
    provider_subject_id character varying(1024) NOT NULL,
    normalized_subject_type character varying(16) NOT NULL,
    normalized_subject_id character varying(1024),
    effect character varying(8) NOT NULL,
    mapping_complete boolean NOT NULL,
    evidence_digest character(64) NOT NULL,
    CONSTRAINT knowledge_acl_subject_t_check CHECK ((mapping_complete = (((normalized_subject_type)::text <> 'UNRESOLVED'::text) AND (normalized_subject_id IS NOT NULL)))),
    CONSTRAINT knowledge_acl_subject_t_effect_check CHECK (((effect)::text = ANY (ARRAY[('ALLOW'::character varying)::text, ('DENY'::character varying)::text]))),
    CONSTRAINT knowledge_acl_subject_t_evidence_digest_check CHECK ((evidence_digest ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT knowledge_acl_subject_t_normalized_subject_type_check CHECK (((normalized_subject_type)::text = ANY (ARRAY[('USER'::character varying)::text, ('GROUP'::character varying)::text, ('ORGANIZATION'::character varying)::text, ('EVERYONE'::character varying)::text, ('UNRESOLVED'::character varying)::text]))),
    CONSTRAINT knowledge_acl_subject_t_subject_ordinal_check CHECK ((subject_ordinal >= 0))
);


--
-- Name: TABLE knowledge_acl_subject_t; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.knowledge_acl_subject_t IS 'Stores knowledge acl subject records used by the Light Knowledge ingestion, retrieval, indexing, and operations services.';


--
-- Name: COLUMN knowledge_acl_subject_t.acl_revision_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_acl_subject_t.acl_revision_id IS 'Identifier for the related acl revision.';


--
-- Name: COLUMN knowledge_acl_subject_t.subject_ordinal; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_acl_subject_t.subject_ordinal IS 'Subject Ordinal value for this knowledge acl subject record.';


--
-- Name: COLUMN knowledge_acl_subject_t.knowledge_base_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_acl_subject_t.knowledge_base_id IS 'Identifier for the related knowledge base.';


--
-- Name: COLUMN knowledge_acl_subject_t.document_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_acl_subject_t.document_id IS 'Identifier for the related document.';


--
-- Name: COLUMN knowledge_acl_subject_t.provider_subject_type; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_acl_subject_t.provider_subject_type IS 'Provider Subject Type value for this knowledge acl subject record.';


--
-- Name: COLUMN knowledge_acl_subject_t.provider_subject_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_acl_subject_t.provider_subject_id IS 'Identifier for the related provider subject.';


--
-- Name: COLUMN knowledge_acl_subject_t.normalized_subject_type; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_acl_subject_t.normalized_subject_type IS 'Normalized Subject Type value for this knowledge acl subject record.';


--
-- Name: COLUMN knowledge_acl_subject_t.normalized_subject_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_acl_subject_t.normalized_subject_id IS 'Identifier for the related normalized subject.';


--
-- Name: COLUMN knowledge_acl_subject_t.effect; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_acl_subject_t.effect IS 'Effect value for this knowledge acl subject record.';


--
-- Name: COLUMN knowledge_acl_subject_t.mapping_complete; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_acl_subject_t.mapping_complete IS 'Mapping Complete value for this knowledge acl subject record.';


--
-- Name: COLUMN knowledge_acl_subject_t.evidence_digest; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_acl_subject_t.evidence_digest IS 'Integrity digest for evidence.';


--
-- Name: knowledge_acl_transition_t; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.knowledge_acl_transition_t (
    acl_transition_id uuid NOT NULL,
    reconciliation_id uuid NOT NULL,
    knowledge_base_id uuid NOT NULL,
    source_id uuid NOT NULL,
    document_id uuid NOT NULL,
    previous_acl_digest character(64) NOT NULL,
    current_acl_digest character(64) NOT NULL,
    transition_kind character varying(32) NOT NULL,
    observed_ts timestamp with time zone NOT NULL,
    recorded_ts timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT knowledge_acl_transition_t_check CHECK ((previous_acl_digest <> current_acl_digest)),
    CONSTRAINT knowledge_acl_transition_t_current_acl_digest_check CHECK ((current_acl_digest ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT knowledge_acl_transition_t_previous_acl_digest_check CHECK ((previous_acl_digest ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT knowledge_acl_transition_t_transition_kind_check CHECK (((transition_kind)::text = 'PERMISSION_CHANGED'::text))
);


--
-- Name: TABLE knowledge_acl_transition_t; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.knowledge_acl_transition_t IS 'Stores knowledge acl transition records used by the Light Knowledge ingestion, retrieval, indexing, and operations services.';


--
-- Name: COLUMN knowledge_acl_transition_t.acl_transition_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_acl_transition_t.acl_transition_id IS 'Identifier for the related acl transition.';


--
-- Name: COLUMN knowledge_acl_transition_t.reconciliation_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_acl_transition_t.reconciliation_id IS 'Identifier for the related reconciliation.';


--
-- Name: COLUMN knowledge_acl_transition_t.knowledge_base_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_acl_transition_t.knowledge_base_id IS 'Identifier for the related knowledge base.';


--
-- Name: COLUMN knowledge_acl_transition_t.source_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_acl_transition_t.source_id IS 'Identifier for the related source.';


--
-- Name: COLUMN knowledge_acl_transition_t.document_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_acl_transition_t.document_id IS 'Identifier for the related document.';


--
-- Name: COLUMN knowledge_acl_transition_t.previous_acl_digest; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_acl_transition_t.previous_acl_digest IS 'Integrity digest for previous acl.';


--
-- Name: COLUMN knowledge_acl_transition_t.current_acl_digest; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_acl_transition_t.current_acl_digest IS 'Integrity digest for current acl.';


--
-- Name: COLUMN knowledge_acl_transition_t.transition_kind; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_acl_transition_t.transition_kind IS 'Transition Kind value for this knowledge acl transition record.';


--
-- Name: COLUMN knowledge_acl_transition_t.observed_ts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_acl_transition_t.observed_ts IS 'Timestamp for the observed event or state.';


--
-- Name: COLUMN knowledge_acl_transition_t.recorded_ts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_acl_transition_t.recorded_ts IS 'Timestamp for the recorded event or state.';


--
-- Name: knowledge_anti_entropy_run_t; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.knowledge_anti_entropy_run_t (
    anti_entropy_run_id uuid NOT NULL,
    knowledge_base_id uuid NOT NULL,
    index_generation_id uuid NOT NULL,
    state character varying(16) DEFAULT 'RUNNING'::character varying NOT NULL,
    expected_manifest_digest character(64) NOT NULL,
    observed_manifest_digest character(64),
    mismatch_counts jsonb DEFAULT '{}'::jsonb NOT NULL,
    started_ts timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    finished_ts timestamp with time zone,
    CONSTRAINT knowledge_anti_entropy_run_t_expected_manifest_digest_check CHECK ((expected_manifest_digest ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT knowledge_anti_entropy_run_t_mismatch_counts_check CHECK ((jsonb_typeof(mismatch_counts) = 'object'::text)),
    CONSTRAINT knowledge_anti_entropy_run_t_state_check CHECK (((state)::text = ANY (ARRAY[('RUNNING'::character varying)::text, ('CONSISTENT'::character varying)::text, ('DRIFTED'::character varying)::text, ('FAILED'::character varying)::text])))
);


--
-- Name: TABLE knowledge_anti_entropy_run_t; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.knowledge_anti_entropy_run_t IS 'Stores knowledge anti entropy run records used by the Light Knowledge ingestion, retrieval, indexing, and operations services.';


--
-- Name: COLUMN knowledge_anti_entropy_run_t.anti_entropy_run_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_anti_entropy_run_t.anti_entropy_run_id IS 'Identifier for the related anti entropy run.';


--
-- Name: COLUMN knowledge_anti_entropy_run_t.knowledge_base_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_anti_entropy_run_t.knowledge_base_id IS 'Identifier for the related knowledge base.';


--
-- Name: COLUMN knowledge_anti_entropy_run_t.index_generation_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_anti_entropy_run_t.index_generation_id IS 'Identifier for the related index generation.';


--
-- Name: COLUMN knowledge_anti_entropy_run_t.state; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_anti_entropy_run_t.state IS 'State value for this knowledge anti entropy run record.';


--
-- Name: COLUMN knowledge_anti_entropy_run_t.expected_manifest_digest; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_anti_entropy_run_t.expected_manifest_digest IS 'Integrity digest for expected manifest.';


--
-- Name: COLUMN knowledge_anti_entropy_run_t.observed_manifest_digest; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_anti_entropy_run_t.observed_manifest_digest IS 'Integrity digest for observed manifest.';


--
-- Name: COLUMN knowledge_anti_entropy_run_t.mismatch_counts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_anti_entropy_run_t.mismatch_counts IS 'Mismatch Counts value for this knowledge anti entropy run record.';


--
-- Name: COLUMN knowledge_anti_entropy_run_t.started_ts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_anti_entropy_run_t.started_ts IS 'Timestamp for the started event or state.';


--
-- Name: COLUMN knowledge_anti_entropy_run_t.finished_ts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_anti_entropy_run_t.finished_ts IS 'Timestamp for the finished event or state.';


--
-- Name: knowledge_backup_checkpoint_t; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.knowledge_backup_checkpoint_t (
    checkpoint_id uuid NOT NULL,
    knowledge_base_id uuid NOT NULL,
    index_generation_id uuid NOT NULL,
    environment character varying(32) NOT NULL,
    pointer_version bigint NOT NULL,
    object_manifest_digest character(64) NOT NULL,
    database_checkpoint_reference character varying(512) NOT NULL,
    encrypted_object_checkpoint_reference character varying(2048) NOT NULL,
    state character varying(20) NOT NULL,
    verification_evidence jsonb DEFAULT '{}'::jsonb NOT NULL,
    retain_until_ts timestamp with time zone NOT NULL,
    created_ts timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    verified_ts timestamp with time zone,
    CONSTRAINT knowledge_backup_checkpoint_t_check CHECK ((retain_until_ts > created_ts)),
    CONSTRAINT knowledge_backup_checkpoint_t_object_manifest_digest_check CHECK ((object_manifest_digest ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT knowledge_backup_checkpoint_t_pointer_version_check CHECK ((pointer_version > 0)),
    CONSTRAINT knowledge_backup_checkpoint_t_state_check CHECK (((state)::text = ANY (ARRAY[('REQUESTED'::character varying)::text, ('VERIFIED'::character varying)::text, ('RESTORED'::character varying)::text, ('FAILED'::character varying)::text, ('EXPIRED'::character varying)::text]))),
    CONSTRAINT knowledge_backup_checkpoint_t_verification_evidence_check CHECK ((jsonb_typeof(verification_evidence) = 'object'::text))
);


--
-- Name: TABLE knowledge_backup_checkpoint_t; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.knowledge_backup_checkpoint_t IS 'Stores knowledge backup checkpoint records used by the Light Knowledge ingestion, retrieval, indexing, and operations services.';


--
-- Name: COLUMN knowledge_backup_checkpoint_t.checkpoint_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_backup_checkpoint_t.checkpoint_id IS 'Identifier for the related checkpoint.';


--
-- Name: COLUMN knowledge_backup_checkpoint_t.knowledge_base_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_backup_checkpoint_t.knowledge_base_id IS 'Identifier for the related knowledge base.';


--
-- Name: COLUMN knowledge_backup_checkpoint_t.index_generation_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_backup_checkpoint_t.index_generation_id IS 'Identifier for the related index generation.';


--
-- Name: COLUMN knowledge_backup_checkpoint_t.environment; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_backup_checkpoint_t.environment IS 'Environment value for this knowledge backup checkpoint record.';


--
-- Name: COLUMN knowledge_backup_checkpoint_t.pointer_version; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_backup_checkpoint_t.pointer_version IS 'Version value for pointer.';


--
-- Name: COLUMN knowledge_backup_checkpoint_t.object_manifest_digest; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_backup_checkpoint_t.object_manifest_digest IS 'Integrity digest for object manifest.';


--
-- Name: COLUMN knowledge_backup_checkpoint_t.database_checkpoint_reference; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_backup_checkpoint_t.database_checkpoint_reference IS 'Database Checkpoint Reference value for this knowledge backup checkpoint record.';


--
-- Name: COLUMN knowledge_backup_checkpoint_t.encrypted_object_checkpoint_reference; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_backup_checkpoint_t.encrypted_object_checkpoint_reference IS 'Encrypted Object Checkpoint Reference value for this knowledge backup checkpoint record.';


--
-- Name: COLUMN knowledge_backup_checkpoint_t.state; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_backup_checkpoint_t.state IS 'State value for this knowledge backup checkpoint record.';


--
-- Name: COLUMN knowledge_backup_checkpoint_t.verification_evidence; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_backup_checkpoint_t.verification_evidence IS 'Verification Evidence value for this knowledge backup checkpoint record.';


--
-- Name: COLUMN knowledge_backup_checkpoint_t.retain_until_ts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_backup_checkpoint_t.retain_until_ts IS 'Timestamp for the retain until event or state.';


--
-- Name: COLUMN knowledge_backup_checkpoint_t.created_ts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_backup_checkpoint_t.created_ts IS 'Timestamp for the created event or state.';


--
-- Name: COLUMN knowledge_backup_checkpoint_t.verified_ts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_backup_checkpoint_t.verified_ts IS 'Timestamp for the verified event or state.';


--
-- Name: knowledge_base_strategy_qualification_t; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.knowledge_base_strategy_qualification_t (
    knowledge_base_id uuid NOT NULL,
    strategy character varying(24) NOT NULL,
    status character varying(24) NOT NULL,
    compatible_profile_constraints jsonb DEFAULT '{}'::jsonb NOT NULL,
    qualification_evidence_id character varying(255) NOT NULL,
    qualified_at timestamp with time zone NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    version bigint DEFAULT 1 NOT NULL,
    CONSTRAINT knowledge_base_strategy_qual_compatible_profile_constrain_check CHECK ((jsonb_typeof(compatible_profile_constraints) = 'object'::text)),
    CONSTRAINT knowledge_base_strategy_qualification_t_check CHECK ((expires_at > qualified_at)),
    CONSTRAINT knowledge_base_strategy_qualification_t_status_check CHECK (((status)::text = ANY (ARRAY[('QUALIFIED'::character varying)::text, ('REVOKED'::character varying)::text, ('EXPIRED'::character varying)::text]))),
    CONSTRAINT knowledge_base_strategy_qualification_t_strategy_check CHECK (((strategy)::text = ANY (ARRAY[('HYBRID'::character varying)::text, ('GRAPH_ASSISTED'::character varying)::text]))),
    CONSTRAINT knowledge_base_strategy_qualification_t_version_check CHECK ((version > 0))
);


--
-- Name: TABLE knowledge_base_strategy_qualification_t; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.knowledge_base_strategy_qualification_t IS 'Stores knowledge base strategy qualification records used by the Light Knowledge ingestion, retrieval, indexing, and operations services.';


--
-- Name: COLUMN knowledge_base_strategy_qualification_t.knowledge_base_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_base_strategy_qualification_t.knowledge_base_id IS 'Identifier for the related knowledge base.';


--
-- Name: COLUMN knowledge_base_strategy_qualification_t.strategy; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_base_strategy_qualification_t.strategy IS 'Strategy value for this knowledge base strategy qualification record.';


--
-- Name: COLUMN knowledge_base_strategy_qualification_t.status; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_base_strategy_qualification_t.status IS 'Status value for this knowledge base strategy qualification record.';


--
-- Name: COLUMN knowledge_base_strategy_qualification_t.compatible_profile_constraints; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_base_strategy_qualification_t.compatible_profile_constraints IS 'Compatible Profile Constraints value for this knowledge base strategy qualification record.';


--
-- Name: COLUMN knowledge_base_strategy_qualification_t.qualification_evidence_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_base_strategy_qualification_t.qualification_evidence_id IS 'Identifier for the related qualification evidence.';


--
-- Name: COLUMN knowledge_base_strategy_qualification_t.qualified_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_base_strategy_qualification_t.qualified_at IS 'Timestamp when qualified occurred.';


--
-- Name: COLUMN knowledge_base_strategy_qualification_t.expires_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_base_strategy_qualification_t.expires_at IS 'Timestamp when expires occurred.';


--
-- Name: COLUMN knowledge_base_strategy_qualification_t.version; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_base_strategy_qualification_t.version IS 'Version value for version.';


--
-- Name: knowledge_base_t; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.knowledge_base_t (
    knowledge_base_id uuid NOT NULL,
    host_id uuid,
    name character varying(255) NOT NULL,
    description text,
    environment character varying(32) NOT NULL,
    status character varying(24) DEFAULT 'DRAFT'::character varying NOT NULL,
    desired_embedding_profile_id uuid,
    desired_embedding_profile_revision bigint,
    retention_policy jsonb DEFAULT '{}'::jsonb NOT NULL,
    replacement_knowledge_base_id uuid,
    deprecation_deadline timestamp with time zone,
    version bigint DEFAULT 1 NOT NULL,
    update_ts timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    update_user character varying(126) DEFAULT SESSION_USER NOT NULL,
    CONSTRAINT knowledge_base_t_check CHECK (((desired_embedding_profile_id IS NULL) = (desired_embedding_profile_revision IS NULL))),
    CONSTRAINT knowledge_base_t_check1 CHECK (((replacement_knowledge_base_id IS NULL) OR (replacement_knowledge_base_id <> knowledge_base_id))),
    CONSTRAINT knowledge_base_t_desired_embedding_profile_revision_check CHECK (((desired_embedding_profile_revision IS NULL) OR (desired_embedding_profile_revision > 0))),
    CONSTRAINT knowledge_base_t_environment_check CHECK ((length((environment)::text) > 0)),
    CONSTRAINT knowledge_base_t_retention_policy_check CHECK ((jsonb_typeof(retention_policy) = 'object'::text)),
    CONSTRAINT knowledge_base_t_status_check CHECK (((status)::text = ANY (ARRAY[('DRAFT'::character varying)::text, ('ACTIVE'::character varying)::text, ('DEPRECATED'::character varying)::text, ('INACTIVE'::character varying)::text, ('DELETING'::character varying)::text, ('DELETED'::character varying)::text]))),
    CONSTRAINT knowledge_base_t_version_check CHECK ((version > 0))
);


--
-- Name: TABLE knowledge_base_t; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.knowledge_base_t IS 'Stores knowledge base records used by the Light Knowledge ingestion, retrieval, indexing, and operations services.';


--
-- Name: COLUMN knowledge_base_t.knowledge_base_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_base_t.knowledge_base_id IS 'Identifier for the related knowledge base.';


--
-- Name: COLUMN knowledge_base_t.host_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_base_t.host_id IS 'Tenant host identifier that scopes this record.';


--
-- Name: COLUMN knowledge_base_t.name; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_base_t.name IS 'Name value for this knowledge base record.';


--
-- Name: COLUMN knowledge_base_t.description; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_base_t.description IS 'Description value for this knowledge base record.';


--
-- Name: COLUMN knowledge_base_t.environment; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_base_t.environment IS 'Environment value for this knowledge base record.';


--
-- Name: COLUMN knowledge_base_t.status; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_base_t.status IS 'Status value for this knowledge base record.';


--
-- Name: COLUMN knowledge_base_t.desired_embedding_profile_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_base_t.desired_embedding_profile_id IS 'Identifier for the related desired embedding profile.';


--
-- Name: COLUMN knowledge_base_t.desired_embedding_profile_revision; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_base_t.desired_embedding_profile_revision IS 'Desired Embedding Profile Revision value for this knowledge base record.';


--
-- Name: COLUMN knowledge_base_t.retention_policy; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_base_t.retention_policy IS 'Retention Policy value for this knowledge base record.';


--
-- Name: COLUMN knowledge_base_t.replacement_knowledge_base_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_base_t.replacement_knowledge_base_id IS 'Identifier for the related replacement knowledge base.';


--
-- Name: COLUMN knowledge_base_t.deprecation_deadline; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_base_t.deprecation_deadline IS 'Deprecation Deadline value for this knowledge base record.';


--
-- Name: COLUMN knowledge_base_t.version; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_base_t.version IS 'Version value for version.';


--
-- Name: COLUMN knowledge_base_t.update_ts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_base_t.update_ts IS 'Timestamp when this record was last updated.';


--
-- Name: COLUMN knowledge_base_t.update_user; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_base_t.update_user IS 'User or service principal that last updated this record.';


--
-- Name: knowledge_chunk_embedding_t; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.knowledge_chunk_embedding_t (
    chunk_id uuid NOT NULL,
    embedding_artifact_id uuid NOT NULL,
    knowledge_base_id uuid NOT NULL,
    embedding_profile_id uuid NOT NULL,
    embedding_profile_revision bigint NOT NULL,
    request_id character varying(255) NOT NULL,
    reused boolean DEFAULT false NOT NULL,
    created_ts timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL
);


--
-- Name: TABLE knowledge_chunk_embedding_t; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.knowledge_chunk_embedding_t IS 'Stores knowledge chunk embedding records used by the Light Knowledge ingestion, retrieval, indexing, and operations services.';


--
-- Name: COLUMN knowledge_chunk_embedding_t.chunk_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_chunk_embedding_t.chunk_id IS 'Identifier for the related chunk.';


--
-- Name: COLUMN knowledge_chunk_embedding_t.embedding_artifact_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_chunk_embedding_t.embedding_artifact_id IS 'Identifier for the related embedding artifact.';


--
-- Name: COLUMN knowledge_chunk_embedding_t.knowledge_base_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_chunk_embedding_t.knowledge_base_id IS 'Identifier for the related knowledge base.';


--
-- Name: COLUMN knowledge_chunk_embedding_t.embedding_profile_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_chunk_embedding_t.embedding_profile_id IS 'Identifier for the related embedding profile.';


--
-- Name: COLUMN knowledge_chunk_embedding_t.embedding_profile_revision; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_chunk_embedding_t.embedding_profile_revision IS 'Embedding Profile Revision value for this knowledge chunk embedding record.';


--
-- Name: COLUMN knowledge_chunk_embedding_t.request_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_chunk_embedding_t.request_id IS 'Identifier for the related request.';


--
-- Name: COLUMN knowledge_chunk_embedding_t.reused; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_chunk_embedding_t.reused IS 'Reused value for this knowledge chunk embedding record.';


--
-- Name: COLUMN knowledge_chunk_embedding_t.created_ts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_chunk_embedding_t.created_ts IS 'Timestamp for the created event or state.';


--
-- Name: knowledge_chunk_t; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.knowledge_chunk_t (
    chunk_id uuid NOT NULL,
    knowledge_base_id uuid NOT NULL,
    document_version_id uuid NOT NULL,
    ordinal integer NOT NULL,
    section_path jsonb DEFAULT '[]'::jsonb NOT NULL,
    start_offset bigint NOT NULL,
    end_offset bigint NOT NULL,
    chunk_text text NOT NULL,
    token_count integer NOT NULL,
    content_digest character(64) NOT NULL,
    parser_output_digest character(64) NOT NULL,
    chunker_contract_digest character(64) NOT NULL,
    lexical_input tsvector NOT NULL,
    lexical_input_digest character(64) NOT NULL,
    metadata_schema_version character varying(64) NOT NULL,
    created_ts timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT knowledge_chunk_t_check CHECK ((end_offset > start_offset)),
    CONSTRAINT knowledge_chunk_t_chunker_contract_digest_check CHECK ((chunker_contract_digest ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT knowledge_chunk_t_content_digest_check CHECK ((content_digest ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT knowledge_chunk_t_lexical_input_digest_check CHECK ((lexical_input_digest ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT knowledge_chunk_t_ordinal_check CHECK ((ordinal >= 0)),
    CONSTRAINT knowledge_chunk_t_parser_output_digest_check CHECK ((parser_output_digest ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT knowledge_chunk_t_section_path_check CHECK ((jsonb_typeof(section_path) = 'array'::text)),
    CONSTRAINT knowledge_chunk_t_start_offset_check CHECK ((start_offset >= 0)),
    CONSTRAINT knowledge_chunk_t_token_count_check CHECK ((token_count > 0))
);


--
-- Name: TABLE knowledge_chunk_t; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.knowledge_chunk_t IS 'Stores knowledge chunk records used by the Light Knowledge ingestion, retrieval, indexing, and operations services.';


--
-- Name: COLUMN knowledge_chunk_t.chunk_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_chunk_t.chunk_id IS 'Identifier for the related chunk.';


--
-- Name: COLUMN knowledge_chunk_t.knowledge_base_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_chunk_t.knowledge_base_id IS 'Identifier for the related knowledge base.';


--
-- Name: COLUMN knowledge_chunk_t.document_version_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_chunk_t.document_version_id IS 'Identifier for the related document version.';


--
-- Name: COLUMN knowledge_chunk_t.ordinal; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_chunk_t.ordinal IS 'Ordinal value for this knowledge chunk record.';


--
-- Name: COLUMN knowledge_chunk_t.section_path; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_chunk_t.section_path IS 'Section Path value for this knowledge chunk record.';


--
-- Name: COLUMN knowledge_chunk_t.start_offset; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_chunk_t.start_offset IS 'Start Offset value for this knowledge chunk record.';


--
-- Name: COLUMN knowledge_chunk_t.end_offset; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_chunk_t.end_offset IS 'End Offset value for this knowledge chunk record.';


--
-- Name: COLUMN knowledge_chunk_t.chunk_text; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_chunk_t.chunk_text IS 'Chunk Text value for this knowledge chunk record.';


--
-- Name: COLUMN knowledge_chunk_t.token_count; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_chunk_t.token_count IS 'Count of token.';


--
-- Name: COLUMN knowledge_chunk_t.content_digest; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_chunk_t.content_digest IS 'Integrity digest for content.';


--
-- Name: COLUMN knowledge_chunk_t.parser_output_digest; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_chunk_t.parser_output_digest IS 'Integrity digest for parser output.';


--
-- Name: COLUMN knowledge_chunk_t.chunker_contract_digest; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_chunk_t.chunker_contract_digest IS 'Integrity digest for chunker contract.';


--
-- Name: COLUMN knowledge_chunk_t.lexical_input; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_chunk_t.lexical_input IS 'Lexical Input value for this knowledge chunk record.';


--
-- Name: COLUMN knowledge_chunk_t.lexical_input_digest; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_chunk_t.lexical_input_digest IS 'Integrity digest for lexical input.';


--
-- Name: COLUMN knowledge_chunk_t.metadata_schema_version; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_chunk_t.metadata_schema_version IS 'Version value for metadata schema.';


--
-- Name: COLUMN knowledge_chunk_t.created_ts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_chunk_t.created_ts IS 'Timestamp for the created event or state.';


--
-- Name: knowledge_compaction_run_t; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.knowledge_compaction_run_t (
    compaction_run_id uuid NOT NULL,
    knowledge_base_id uuid NOT NULL,
    source_generation_id uuid NOT NULL,
    candidate_generation_id uuid,
    canonical_watermark bigint NOT NULL,
    state character varying(16) DEFAULT 'REQUESTED'::character varying NOT NULL,
    source_manifest_digest character(64) NOT NULL,
    resolved_corpus_digest character(64),
    verification_evidence jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_ts timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    finished_ts timestamp with time zone,
    CONSTRAINT knowledge_compaction_run_t_canonical_watermark_check CHECK ((canonical_watermark >= 0)),
    CONSTRAINT knowledge_compaction_run_t_source_manifest_digest_check CHECK ((source_manifest_digest ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT knowledge_compaction_run_t_state_check CHECK (((state)::text = ANY (ARRAY[('REQUESTED'::character varying)::text, ('RUNNING'::character varying)::text, ('VERIFIED'::character varying)::text, ('PROMOTED'::character varying)::text, ('FAILED'::character varying)::text]))),
    CONSTRAINT knowledge_compaction_run_t_verification_evidence_check CHECK ((jsonb_typeof(verification_evidence) = 'object'::text))
);


--
-- Name: TABLE knowledge_compaction_run_t; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.knowledge_compaction_run_t IS 'Stores knowledge compaction run records used by the Light Knowledge ingestion, retrieval, indexing, and operations services.';


--
-- Name: COLUMN knowledge_compaction_run_t.compaction_run_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_compaction_run_t.compaction_run_id IS 'Identifier for the related compaction run.';


--
-- Name: COLUMN knowledge_compaction_run_t.knowledge_base_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_compaction_run_t.knowledge_base_id IS 'Identifier for the related knowledge base.';


--
-- Name: COLUMN knowledge_compaction_run_t.source_generation_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_compaction_run_t.source_generation_id IS 'Identifier for the related source generation.';


--
-- Name: COLUMN knowledge_compaction_run_t.candidate_generation_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_compaction_run_t.candidate_generation_id IS 'Identifier for the related candidate generation.';


--
-- Name: COLUMN knowledge_compaction_run_t.canonical_watermark; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_compaction_run_t.canonical_watermark IS 'Canonical Watermark value for this knowledge compaction run record.';


--
-- Name: COLUMN knowledge_compaction_run_t.state; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_compaction_run_t.state IS 'State value for this knowledge compaction run record.';


--
-- Name: COLUMN knowledge_compaction_run_t.source_manifest_digest; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_compaction_run_t.source_manifest_digest IS 'Integrity digest for source manifest.';


--
-- Name: COLUMN knowledge_compaction_run_t.resolved_corpus_digest; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_compaction_run_t.resolved_corpus_digest IS 'Integrity digest for resolved corpus.';


--
-- Name: COLUMN knowledge_compaction_run_t.verification_evidence; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_compaction_run_t.verification_evidence IS 'Verification Evidence value for this knowledge compaction run record.';


--
-- Name: COLUMN knowledge_compaction_run_t.created_ts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_compaction_run_t.created_ts IS 'Timestamp for the created event or state.';


--
-- Name: COLUMN knowledge_compaction_run_t.finished_ts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_compaction_run_t.finished_ts IS 'Timestamp for the finished event or state.';


--
-- Name: knowledge_connector_notification_t; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.knowledge_connector_notification_t (
    connector_notification_id uuid NOT NULL,
    source_id uuid NOT NULL,
    provider character varying(16) NOT NULL,
    provider_notification_id character varying(1024) NOT NULL,
    state character varying(12) NOT NULL,
    received_ts timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    applied_ts timestamp with time zone,
    evidence_digest character(64) NOT NULL,
    CONSTRAINT knowledge_connector_notification_t_evidence_digest_check CHECK ((evidence_digest ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT knowledge_connector_notification_t_provider_check CHECK (((provider)::text = ANY (ARRAY[('SHAREPOINT'::character varying)::text, ('CONFLUENCE'::character varying)::text]))),
    CONSTRAINT knowledge_connector_notification_t_state_check CHECK (((state)::text = ANY (ARRAY[('RECEIVED'::character varying)::text, ('APPLIED'::character varying)::text, ('DISCARDED'::character varying)::text])))
);


--
-- Name: TABLE knowledge_connector_notification_t; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.knowledge_connector_notification_t IS 'Stores knowledge connector notification records used by the Light Knowledge ingestion, retrieval, indexing, and operations services.';


--
-- Name: COLUMN knowledge_connector_notification_t.connector_notification_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_connector_notification_t.connector_notification_id IS 'Identifier for the related connector notification.';


--
-- Name: COLUMN knowledge_connector_notification_t.source_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_connector_notification_t.source_id IS 'Identifier for the related source.';


--
-- Name: COLUMN knowledge_connector_notification_t.provider; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_connector_notification_t.provider IS 'Provider value for this knowledge connector notification record.';


--
-- Name: COLUMN knowledge_connector_notification_t.provider_notification_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_connector_notification_t.provider_notification_id IS 'Identifier for the related provider notification.';


--
-- Name: COLUMN knowledge_connector_notification_t.state; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_connector_notification_t.state IS 'State value for this knowledge connector notification record.';


--
-- Name: COLUMN knowledge_connector_notification_t.received_ts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_connector_notification_t.received_ts IS 'Timestamp for the received event or state.';


--
-- Name: COLUMN knowledge_connector_notification_t.applied_ts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_connector_notification_t.applied_ts IS 'Timestamp for the applied event or state.';


--
-- Name: COLUMN knowledge_connector_notification_t.evidence_digest; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_connector_notification_t.evidence_digest IS 'Integrity digest for evidence.';


--
-- Name: knowledge_connector_object_t; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.knowledge_connector_object_t (
    connector_object_id uuid NOT NULL,
    knowledge_base_id uuid NOT NULL,
    source_id uuid NOT NULL,
    provider character varying(16) NOT NULL,
    external_id character varying(1024) NOT NULL,
    provider_version character varying(255) NOT NULL,
    canonical_uri character varying(2048) NOT NULL,
    document_id uuid,
    parent_external_id character varying(1024),
    relationship_kind character varying(16) DEFAULT 'NONE'::character varying NOT NULL,
    deleted boolean DEFAULT false NOT NULL,
    last_reconciliation_id uuid NOT NULL,
    observed_ts timestamp with time zone NOT NULL,
    CONSTRAINT knowledge_connector_object_t_provider_check CHECK (((provider)::text = ANY (ARRAY[('SHAREPOINT'::character varying)::text, ('CONFLUENCE'::character varying)::text]))),
    CONSTRAINT knowledge_connector_object_t_relationship_kind_check CHECK (((relationship_kind)::text = ANY (ARRAY[('NONE'::character varying)::text, ('CONTAINMENT'::character varying)::text, ('REFERENCE'::character varying)::text])))
);


--
-- Name: TABLE knowledge_connector_object_t; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.knowledge_connector_object_t IS 'Stores knowledge connector object records used by the Light Knowledge ingestion, retrieval, indexing, and operations services.';


--
-- Name: COLUMN knowledge_connector_object_t.connector_object_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_connector_object_t.connector_object_id IS 'Identifier for the related connector object.';


--
-- Name: COLUMN knowledge_connector_object_t.knowledge_base_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_connector_object_t.knowledge_base_id IS 'Identifier for the related knowledge base.';


--
-- Name: COLUMN knowledge_connector_object_t.source_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_connector_object_t.source_id IS 'Identifier for the related source.';


--
-- Name: COLUMN knowledge_connector_object_t.provider; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_connector_object_t.provider IS 'Provider value for this knowledge connector object record.';


--
-- Name: COLUMN knowledge_connector_object_t.external_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_connector_object_t.external_id IS 'Identifier for the related external.';


--
-- Name: COLUMN knowledge_connector_object_t.provider_version; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_connector_object_t.provider_version IS 'Version value for provider.';


--
-- Name: COLUMN knowledge_connector_object_t.canonical_uri; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_connector_object_t.canonical_uri IS 'Canonical Uri value for this knowledge connector object record.';


--
-- Name: COLUMN knowledge_connector_object_t.document_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_connector_object_t.document_id IS 'Identifier for the related document.';


--
-- Name: COLUMN knowledge_connector_object_t.parent_external_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_connector_object_t.parent_external_id IS 'Identifier for the related parent external.';


--
-- Name: COLUMN knowledge_connector_object_t.relationship_kind; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_connector_object_t.relationship_kind IS 'Relationship Kind value for this knowledge connector object record.';


--
-- Name: COLUMN knowledge_connector_object_t.deleted; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_connector_object_t.deleted IS 'Deleted value for this knowledge connector object record.';


--
-- Name: COLUMN knowledge_connector_object_t.last_reconciliation_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_connector_object_t.last_reconciliation_id IS 'Identifier for the related last reconciliation.';


--
-- Name: COLUMN knowledge_connector_object_t.observed_ts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_connector_object_t.observed_ts IS 'Timestamp for the observed event or state.';


--
-- Name: knowledge_consumer_quota_t; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.knowledge_consumer_quota_t (
    knowledge_base_id uuid NOT NULL,
    consumer_host_id uuid NOT NULL,
    max_concurrency integer NOT NULL,
    requests_per_minute integer NOT NULL,
    max_cost_micros_per_day bigint NOT NULL,
    active boolean DEFAULT true NOT NULL,
    update_ts timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT knowledge_consumer_quota_t_max_concurrency_check CHECK ((max_concurrency > 0)),
    CONSTRAINT knowledge_consumer_quota_t_max_cost_micros_per_day_check CHECK ((max_cost_micros_per_day > 0)),
    CONSTRAINT knowledge_consumer_quota_t_requests_per_minute_check CHECK ((requests_per_minute > 0))
);


--
-- Name: TABLE knowledge_consumer_quota_t; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.knowledge_consumer_quota_t IS 'Stores knowledge consumer quota records used by the Light Knowledge ingestion, retrieval, indexing, and operations services.';


--
-- Name: COLUMN knowledge_consumer_quota_t.knowledge_base_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_consumer_quota_t.knowledge_base_id IS 'Identifier for the related knowledge base.';


--
-- Name: COLUMN knowledge_consumer_quota_t.consumer_host_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_consumer_quota_t.consumer_host_id IS 'Identifier for the related consumer host.';


--
-- Name: COLUMN knowledge_consumer_quota_t.max_concurrency; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_consumer_quota_t.max_concurrency IS 'Max Concurrency value for this knowledge consumer quota record.';


--
-- Name: COLUMN knowledge_consumer_quota_t.requests_per_minute; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_consumer_quota_t.requests_per_minute IS 'Requests Per Minute value for this knowledge consumer quota record.';


--
-- Name: COLUMN knowledge_consumer_quota_t.max_cost_micros_per_day; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_consumer_quota_t.max_cost_micros_per_day IS 'Max Cost Micros Per Day value for this knowledge consumer quota record.';


--
-- Name: COLUMN knowledge_consumer_quota_t.active; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_consumer_quota_t.active IS 'Indicates whether this record is active.';


--
-- Name: COLUMN knowledge_consumer_quota_t.update_ts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_consumer_quota_t.update_ts IS 'Timestamp when this record was last updated.';


--
-- Name: knowledge_control_snapshot_t; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.knowledge_control_snapshot_t (
    snapshot_id uuid NOT NULL,
    host_id uuid NOT NULL,
    environment character varying(32) NOT NULL,
    publication_sequence bigint NOT NULL,
    source_event_watermark jsonb NOT NULL,
    compatibility_generation integer NOT NULL,
    payload_digest character(64) NOT NULL,
    signature_digest character(64) NOT NULL,
    state character varying(16) DEFAULT 'APPLIED'::character varying NOT NULL,
    applied_ts timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    lease_expires_ts timestamp with time zone DEFAULT (CURRENT_TIMESTAMP + '00:05:00'::interval) NOT NULL,
    CONSTRAINT knowledge_control_snapshot_t_compatibility_generation_check CHECK ((compatibility_generation > 0)),
    CONSTRAINT knowledge_control_snapshot_t_payload_digest_check CHECK ((payload_digest ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT knowledge_control_snapshot_t_publication_sequence_check CHECK ((publication_sequence >= 0)),
    CONSTRAINT knowledge_control_snapshot_t_signature_digest_check CHECK ((signature_digest ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT knowledge_control_snapshot_t_source_event_watermark_check CHECK ((jsonb_typeof(source_event_watermark) = 'object'::text)),
    CONSTRAINT knowledge_control_snapshot_t_state_check CHECK (((state)::text = ANY ((ARRAY['APPLIED'::character varying, 'SUPERSEDED'::character varying])::text[])))
);


--
-- Name: knowledge_document_acl_t; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.knowledge_document_acl_t (
    acl_revision_id uuid NOT NULL,
    document_id uuid NOT NULL,
    knowledge_base_id uuid NOT NULL,
    acl_sequence bigint NOT NULL,
    visibility_mode character varying(24) NOT NULL,
    normalized_acl jsonb NOT NULL,
    normalization_contract_digest character(64) NOT NULL,
    completeness_state character varying(16) NOT NULL,
    observed_ts timestamp with time zone NOT NULL,
    fresh_until_ts timestamp with time zone NOT NULL,
    evidence_digest character(64) NOT NULL,
    reconciliation_id uuid,
    provider_effective_decision boolean DEFAULT true NOT NULL,
    CONSTRAINT knowledge_document_acl_freshness_ck CHECK ((((visibility_mode)::text <> 'MIRROR_SOURCE_ACL'::text) OR (fresh_until_ts <= (observed_ts + '00:15:00'::interval)))),
    CONSTRAINT knowledge_document_acl_mirror_evidence_ck CHECK ((((visibility_mode)::text <> 'MIRROR_SOURCE_ACL'::text) OR (reconciliation_id IS NOT NULL))),
    CONSTRAINT knowledge_document_acl_t_acl_sequence_check CHECK ((acl_sequence > 0)),
    CONSTRAINT knowledge_document_acl_t_check CHECK ((fresh_until_ts >= observed_ts)),
    CONSTRAINT knowledge_document_acl_t_completeness_state_check CHECK (((completeness_state)::text = ANY (ARRAY[('COMPLETE'::character varying)::text, ('STALE'::character varying)::text, ('INCOMPLETE'::character varying)::text]))),
    CONSTRAINT knowledge_document_acl_t_evidence_digest_check CHECK ((evidence_digest ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT knowledge_document_acl_t_normalization_contract_digest_check CHECK ((normalization_contract_digest ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT knowledge_document_acl_t_normalized_acl_check CHECK ((jsonb_typeof(normalized_acl) = 'object'::text)),
    CONSTRAINT knowledge_document_acl_t_visibility_mode_check CHECK (((visibility_mode)::text = ANY (ARRAY[('UNIFORM_SCOPE'::character varying)::text, ('MIRROR_SOURCE_ACL'::character varying)::text])))
);


--
-- Name: TABLE knowledge_document_acl_t; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.knowledge_document_acl_t IS 'Stores knowledge document acl records used by the Light Knowledge ingestion, retrieval, indexing, and operations services.';


--
-- Name: COLUMN knowledge_document_acl_t.acl_revision_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_document_acl_t.acl_revision_id IS 'Identifier for the related acl revision.';


--
-- Name: COLUMN knowledge_document_acl_t.document_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_document_acl_t.document_id IS 'Identifier for the related document.';


--
-- Name: COLUMN knowledge_document_acl_t.knowledge_base_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_document_acl_t.knowledge_base_id IS 'Identifier for the related knowledge base.';


--
-- Name: COLUMN knowledge_document_acl_t.acl_sequence; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_document_acl_t.acl_sequence IS 'Acl Sequence value for this knowledge document acl record.';


--
-- Name: COLUMN knowledge_document_acl_t.visibility_mode; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_document_acl_t.visibility_mode IS 'Visibility Mode value for this knowledge document acl record.';


--
-- Name: COLUMN knowledge_document_acl_t.normalized_acl; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_document_acl_t.normalized_acl IS 'Normalized Acl value for this knowledge document acl record.';


--
-- Name: COLUMN knowledge_document_acl_t.normalization_contract_digest; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_document_acl_t.normalization_contract_digest IS 'Integrity digest for normalization contract.';


--
-- Name: COLUMN knowledge_document_acl_t.completeness_state; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_document_acl_t.completeness_state IS 'Completeness State value for this knowledge document acl record.';


--
-- Name: COLUMN knowledge_document_acl_t.observed_ts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_document_acl_t.observed_ts IS 'Timestamp for the observed event or state.';


--
-- Name: COLUMN knowledge_document_acl_t.fresh_until_ts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_document_acl_t.fresh_until_ts IS 'Timestamp for the fresh until event or state.';


--
-- Name: COLUMN knowledge_document_acl_t.evidence_digest; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_document_acl_t.evidence_digest IS 'Integrity digest for evidence.';


--
-- Name: COLUMN knowledge_document_acl_t.reconciliation_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_document_acl_t.reconciliation_id IS 'Identifier for the related reconciliation.';


--
-- Name: COLUMN knowledge_document_acl_t.provider_effective_decision; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_document_acl_t.provider_effective_decision IS 'Provider Effective Decision value for this knowledge document acl record.';


--
-- Name: knowledge_document_t; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.knowledge_document_t (
    document_id uuid NOT NULL,
    knowledge_base_id uuid NOT NULL,
    source_id uuid NOT NULL,
    source_object_id character varying(1024) NOT NULL,
    canonical_uri character varying(2048) NOT NULL,
    lifecycle_state character varying(16) DEFAULT 'ACTIVE'::character varying NOT NULL,
    current_document_version_id uuid,
    observed_ts timestamp with time zone NOT NULL,
    update_ts timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT knowledge_document_t_lifecycle_state_check CHECK (((lifecycle_state)::text = ANY (ARRAY[('ACTIVE'::character varying)::text, ('DELETED'::character varying)::text, ('EXCLUDED'::character varying)::text])))
);


--
-- Name: TABLE knowledge_document_t; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.knowledge_document_t IS 'Stores knowledge document records used by the Light Knowledge ingestion, retrieval, indexing, and operations services.';


--
-- Name: COLUMN knowledge_document_t.document_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_document_t.document_id IS 'Identifier for the related document.';


--
-- Name: COLUMN knowledge_document_t.knowledge_base_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_document_t.knowledge_base_id IS 'Identifier for the related knowledge base.';


--
-- Name: COLUMN knowledge_document_t.source_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_document_t.source_id IS 'Identifier for the related source.';


--
-- Name: COLUMN knowledge_document_t.source_object_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_document_t.source_object_id IS 'Identifier for the related source object.';


--
-- Name: COLUMN knowledge_document_t.canonical_uri; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_document_t.canonical_uri IS 'Canonical Uri value for this knowledge document record.';


--
-- Name: COLUMN knowledge_document_t.lifecycle_state; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_document_t.lifecycle_state IS 'Lifecycle State value for this knowledge document record.';


--
-- Name: COLUMN knowledge_document_t.current_document_version_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_document_t.current_document_version_id IS 'Identifier for the related current document version.';


--
-- Name: COLUMN knowledge_document_t.observed_ts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_document_t.observed_ts IS 'Timestamp for the observed event or state.';


--
-- Name: COLUMN knowledge_document_t.update_ts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_document_t.update_ts IS 'Timestamp when this record was last updated.';


--
-- Name: knowledge_document_version_t; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.knowledge_document_version_t (
    document_version_id uuid NOT NULL,
    document_id uuid NOT NULL,
    knowledge_base_id uuid NOT NULL,
    source_version character varying(255) NOT NULL,
    content_digest character(64) NOT NULL,
    parser_contract_digest character(64) NOT NULL,
    metadata_schema_version character varying(64) NOT NULL,
    object_locator character varying(2048) NOT NULL,
    object_digest character(64) NOT NULL,
    normalized_bytes bigint NOT NULL,
    source_modified_ts timestamp with time zone,
    created_ts timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT knowledge_document_version_t_content_digest_check CHECK ((content_digest ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT knowledge_document_version_t_normalized_bytes_check CHECK ((normalized_bytes >= 0)),
    CONSTRAINT knowledge_document_version_t_object_digest_check CHECK ((object_digest ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT knowledge_document_version_t_parser_contract_digest_check CHECK ((parser_contract_digest ~ '^[a-f0-9]{64}$'::text))
);


--
-- Name: TABLE knowledge_document_version_t; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.knowledge_document_version_t IS 'Stores knowledge document version records used by the Light Knowledge ingestion, retrieval, indexing, and operations services.';


--
-- Name: COLUMN knowledge_document_version_t.document_version_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_document_version_t.document_version_id IS 'Identifier for the related document version.';


--
-- Name: COLUMN knowledge_document_version_t.document_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_document_version_t.document_id IS 'Identifier for the related document.';


--
-- Name: COLUMN knowledge_document_version_t.knowledge_base_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_document_version_t.knowledge_base_id IS 'Identifier for the related knowledge base.';


--
-- Name: COLUMN knowledge_document_version_t.source_version; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_document_version_t.source_version IS 'Version value for source.';


--
-- Name: COLUMN knowledge_document_version_t.content_digest; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_document_version_t.content_digest IS 'Integrity digest for content.';


--
-- Name: COLUMN knowledge_document_version_t.parser_contract_digest; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_document_version_t.parser_contract_digest IS 'Integrity digest for parser contract.';


--
-- Name: COLUMN knowledge_document_version_t.metadata_schema_version; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_document_version_t.metadata_schema_version IS 'Version value for metadata schema.';


--
-- Name: COLUMN knowledge_document_version_t.object_locator; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_document_version_t.object_locator IS 'Object Locator value for this knowledge document version record.';


--
-- Name: COLUMN knowledge_document_version_t.object_digest; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_document_version_t.object_digest IS 'Integrity digest for object.';


--
-- Name: COLUMN knowledge_document_version_t.normalized_bytes; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_document_version_t.normalized_bytes IS 'Normalized Bytes value for this knowledge document version record.';


--
-- Name: COLUMN knowledge_document_version_t.source_modified_ts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_document_version_t.source_modified_ts IS 'Timestamp for the source modified event or state.';


--
-- Name: COLUMN knowledge_document_version_t.created_ts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_document_version_t.created_ts IS 'Timestamp for the created event or state.';


--
-- Name: knowledge_embedding_artifact_t; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.knowledge_embedding_artifact_t (
    embedding_artifact_id uuid NOT NULL,
    knowledge_base_id uuid NOT NULL,
    owner_host_id uuid,
    transformed_input_digest character(64) NOT NULL,
    space_id character varying(255) NOT NULL,
    space_revision bigint NOT NULL,
    dimension integer NOT NULL,
    document_input_transform_version character varying(255) NOT NULL,
    embedding public.vector NOT NULL,
    created_ts timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT knowledge_embedding_artifact_t_check CHECK ((public.vector_dims(embedding) = dimension)),
    CONSTRAINT knowledge_embedding_artifact_t_dimension_check CHECK ((dimension > 0)),
    CONSTRAINT knowledge_embedding_artifact_t_space_revision_check CHECK ((space_revision > 0)),
    CONSTRAINT knowledge_embedding_artifact_t_transformed_input_digest_check CHECK ((transformed_input_digest ~ '^[a-f0-9]{64}$'::text))
);


--
-- Name: TABLE knowledge_embedding_artifact_t; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.knowledge_embedding_artifact_t IS 'Stores knowledge embedding artifact records used by the Light Knowledge ingestion, retrieval, indexing, and operations services.';


--
-- Name: COLUMN knowledge_embedding_artifact_t.embedding_artifact_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_embedding_artifact_t.embedding_artifact_id IS 'Identifier for the related embedding artifact.';


--
-- Name: COLUMN knowledge_embedding_artifact_t.knowledge_base_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_embedding_artifact_t.knowledge_base_id IS 'Identifier for the related knowledge base.';


--
-- Name: COLUMN knowledge_embedding_artifact_t.owner_host_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_embedding_artifact_t.owner_host_id IS 'Identifier for the related owner host.';


--
-- Name: COLUMN knowledge_embedding_artifact_t.transformed_input_digest; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_embedding_artifact_t.transformed_input_digest IS 'Integrity digest for transformed input.';


--
-- Name: COLUMN knowledge_embedding_artifact_t.space_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_embedding_artifact_t.space_id IS 'Identifier for the related space.';


--
-- Name: COLUMN knowledge_embedding_artifact_t.space_revision; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_embedding_artifact_t.space_revision IS 'Space Revision value for this knowledge embedding artifact record.';


--
-- Name: COLUMN knowledge_embedding_artifact_t.dimension; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_embedding_artifact_t.dimension IS 'Dimension value for this knowledge embedding artifact record.';


--
-- Name: COLUMN knowledge_embedding_artifact_t.document_input_transform_version; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_embedding_artifact_t.document_input_transform_version IS 'Version value for document input transform.';


--
-- Name: COLUMN knowledge_embedding_artifact_t.embedding; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_embedding_artifact_t.embedding IS 'Embedding value for this knowledge embedding artifact record.';


--
-- Name: COLUMN knowledge_embedding_artifact_t.created_ts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_embedding_artifact_t.created_ts IS 'Timestamp for the created event or state.';


--
-- Name: knowledge_embedding_migration_chunk_t; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.knowledge_embedding_migration_chunk_t (
    migration_id uuid NOT NULL,
    chunk_id uuid NOT NULL,
    knowledge_base_id uuid NOT NULL,
    transformed_input_digest character(64) NOT NULL,
    embedding_artifact_id uuid,
    state character varying(16) DEFAULT 'PENDING'::character varying NOT NULL,
    claim_token uuid,
    claim_expires_ts timestamp with time zone,
    token_count integer NOT NULL,
    reserved_cost_micros bigint DEFAULT 0 NOT NULL,
    cost_micros bigint DEFAULT 0 NOT NULL,
    attempt_count integer DEFAULT 0 NOT NULL,
    update_ts timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT knowledge_embedding_migration_ch_transformed_input_digest_check CHECK ((transformed_input_digest ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT knowledge_embedding_migration_chunk__reserved_cost_micros_check CHECK ((reserved_cost_micros >= 0)),
    CONSTRAINT knowledge_embedding_migration_chunk_t_attempt_count_check CHECK ((attempt_count >= 0)),
    CONSTRAINT knowledge_embedding_migration_chunk_t_check CHECK ((((state)::text = ANY (ARRAY[('EMBEDDED'::character varying)::text, ('VERIFIED'::character varying)::text])) = (embedding_artifact_id IS NOT NULL))),
    CONSTRAINT knowledge_embedding_migration_chunk_t_check1 CHECK ((((state)::text = 'CLAIMED'::text) = ((claim_token IS NOT NULL) AND (claim_expires_ts IS NOT NULL)))),
    CONSTRAINT knowledge_embedding_migration_chunk_t_cost_micros_check CHECK ((cost_micros >= 0)),
    CONSTRAINT knowledge_embedding_migration_chunk_t_state_check CHECK (((state)::text = ANY (ARRAY[('PENDING'::character varying)::text, ('CLAIMED'::character varying)::text, ('EMBEDDED'::character varying)::text, ('VERIFIED'::character varying)::text, ('FAILED'::character varying)::text]))),
    CONSTRAINT knowledge_embedding_migration_chunk_t_token_count_check CHECK ((token_count > 0))
);


--
-- Name: TABLE knowledge_embedding_migration_chunk_t; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.knowledge_embedding_migration_chunk_t IS 'Stores knowledge embedding migration chunk records used by the Light Knowledge ingestion, retrieval, indexing, and operations services.';


--
-- Name: COLUMN knowledge_embedding_migration_chunk_t.migration_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_embedding_migration_chunk_t.migration_id IS 'Identifier for the related migration.';


--
-- Name: COLUMN knowledge_embedding_migration_chunk_t.chunk_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_embedding_migration_chunk_t.chunk_id IS 'Identifier for the related chunk.';


--
-- Name: COLUMN knowledge_embedding_migration_chunk_t.knowledge_base_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_embedding_migration_chunk_t.knowledge_base_id IS 'Identifier for the related knowledge base.';


--
-- Name: COLUMN knowledge_embedding_migration_chunk_t.transformed_input_digest; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_embedding_migration_chunk_t.transformed_input_digest IS 'Integrity digest for transformed input.';


--
-- Name: COLUMN knowledge_embedding_migration_chunk_t.embedding_artifact_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_embedding_migration_chunk_t.embedding_artifact_id IS 'Identifier for the related embedding artifact.';


--
-- Name: COLUMN knowledge_embedding_migration_chunk_t.state; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_embedding_migration_chunk_t.state IS 'State value for this knowledge embedding migration chunk record.';


--
-- Name: COLUMN knowledge_embedding_migration_chunk_t.claim_token; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_embedding_migration_chunk_t.claim_token IS 'Claim Token value for this knowledge embedding migration chunk record.';


--
-- Name: COLUMN knowledge_embedding_migration_chunk_t.claim_expires_ts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_embedding_migration_chunk_t.claim_expires_ts IS 'Timestamp for the claim expires event or state.';


--
-- Name: COLUMN knowledge_embedding_migration_chunk_t.token_count; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_embedding_migration_chunk_t.token_count IS 'Count of token.';


--
-- Name: COLUMN knowledge_embedding_migration_chunk_t.reserved_cost_micros; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_embedding_migration_chunk_t.reserved_cost_micros IS 'Reserved Cost Micros value for this knowledge embedding migration chunk record.';


--
-- Name: COLUMN knowledge_embedding_migration_chunk_t.cost_micros; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_embedding_migration_chunk_t.cost_micros IS 'Cost Micros value for this knowledge embedding migration chunk record.';


--
-- Name: COLUMN knowledge_embedding_migration_chunk_t.attempt_count; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_embedding_migration_chunk_t.attempt_count IS 'Count of attempt.';


--
-- Name: COLUMN knowledge_embedding_migration_chunk_t.update_ts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_embedding_migration_chunk_t.update_ts IS 'Timestamp when this record was last updated.';


--
-- Name: knowledge_embedding_migration_t; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.knowledge_embedding_migration_t (
    migration_id uuid NOT NULL,
    knowledge_base_id uuid NOT NULL,
    environment character varying(32) NOT NULL,
    source_generation_id uuid NOT NULL,
    candidate_generation_id uuid NOT NULL,
    target_profile_id uuid NOT NULL,
    target_profile_revision bigint NOT NULL,
    target_space_id character varying(255) NOT NULL,
    target_space_revision bigint NOT NULL,
    target_dimension integer NOT NULL,
    estimate_version bigint NOT NULL,
    estimated_chunk_count bigint NOT NULL,
    estimated_token_count bigint NOT NULL,
    estimated_cost_micros bigint NOT NULL,
    estimated_duration_seconds bigint NOT NULL,
    estimated_temporary_bytes bigint NOT NULL,
    accepted_cost_ceiling_micros bigint NOT NULL,
    rollback_window_seconds bigint NOT NULL,
    consumed_token_count bigint DEFAULT 0 NOT NULL,
    consumed_cost_micros bigint DEFAULT 0 NOT NULL,
    reserved_cost_micros bigint DEFAULT 0 NOT NULL,
    completed_chunk_count bigint DEFAULT 0 NOT NULL,
    catchup_chunk_count bigint DEFAULT 0 NOT NULL,
    reused_canonical_chunk_count bigint DEFAULT 0 NOT NULL,
    start_watermark bigint NOT NULL,
    snapshot_watermark bigint NOT NULL,
    final_watermark bigint,
    predecessor_reconciled_watermark bigint DEFAULT 0 NOT NULL,
    state character varying(24) DEFAULT 'REQUESTED'::character varying NOT NULL,
    version bigint DEFAULT 1 NOT NULL,
    evaluation_evidence_id uuid,
    evaluation_evidence_digest character(64),
    promotion_watermark bigint,
    rollback_deadline timestamp with time zone,
    pause_reason character varying(96),
    failure_code character varying(96),
    requested_by character varying(255) NOT NULL,
    authorized_by character varying(255),
    created_ts timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    update_ts timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    finished_ts timestamp with time zone,
    CONSTRAINT knowledge_embedding_migratio_accepted_cost_ceiling_micros_check CHECK ((accepted_cost_ceiling_micros >= 0)),
    CONSTRAINT knowledge_embedding_migratio_predecessor_reconciled_water_check CHECK ((predecessor_reconciled_watermark >= 0)),
    CONSTRAINT knowledge_embedding_migratio_reused_canonical_chunk_count_check CHECK ((reused_canonical_chunk_count >= 0)),
    CONSTRAINT knowledge_embedding_migration__estimated_duration_seconds_check CHECK ((estimated_duration_seconds >= 0)),
    CONSTRAINT knowledge_embedding_migration__evaluation_evidence_digest_check CHECK (((evaluation_evidence_digest IS NULL) OR (evaluation_evidence_digest ~ '^[a-f0-9]{64}$'::text))),
    CONSTRAINT knowledge_embedding_migration_t_catchup_chunk_count_check CHECK ((catchup_chunk_count >= 0)),
    CONSTRAINT knowledge_embedding_migration_t_check CHECK ((snapshot_watermark >= start_watermark)),
    CONSTRAINT knowledge_embedding_migration_t_check1 CHECK (((final_watermark IS NULL) OR (final_watermark >= snapshot_watermark))),
    CONSTRAINT knowledge_embedding_migration_t_check2 CHECK ((accepted_cost_ceiling_micros >= estimated_cost_micros)),
    CONSTRAINT knowledge_embedding_migration_t_check3 CHECK ((completed_chunk_count <= (estimated_chunk_count + catchup_chunk_count))),
    CONSTRAINT knowledge_embedding_migration_t_check4 CHECK ((reused_canonical_chunk_count <= completed_chunk_count)),
    CONSTRAINT knowledge_embedding_migration_t_check5 CHECK (((consumed_cost_micros + reserved_cost_micros) <= accepted_cost_ceiling_micros)),
    CONSTRAINT knowledge_embedding_migration_t_check6 CHECK ((((state)::text = ANY (ARRAY[('PROMOTED'::character varying)::text, ('SOAKING'::character varying)::text, ('ROLLED_BACK'::character varying)::text, ('RETIRED'::character varying)::text])) = (promotion_watermark IS NOT NULL))),
    CONSTRAINT knowledge_embedding_migration_t_check7 CHECK (((((state)::text = ANY (ARRAY[('PROMOTED'::character varying)::text, ('SOAKING'::character varying)::text])) IS FALSE) OR (rollback_deadline IS NOT NULL))),
    CONSTRAINT knowledge_embedding_migration_t_completed_chunk_count_check CHECK ((completed_chunk_count >= 0)),
    CONSTRAINT knowledge_embedding_migration_t_consumed_cost_micros_check CHECK ((consumed_cost_micros >= 0)),
    CONSTRAINT knowledge_embedding_migration_t_consumed_token_count_check CHECK ((consumed_token_count >= 0)),
    CONSTRAINT knowledge_embedding_migration_t_environment_check CHECK ((length((environment)::text) > 0)),
    CONSTRAINT knowledge_embedding_migration_t_estimate_version_check CHECK ((estimate_version > 0)),
    CONSTRAINT knowledge_embedding_migration_t_estimated_chunk_count_check CHECK ((estimated_chunk_count >= 0)),
    CONSTRAINT knowledge_embedding_migration_t_estimated_cost_micros_check CHECK ((estimated_cost_micros >= 0)),
    CONSTRAINT knowledge_embedding_migration_t_estimated_temporary_bytes_check CHECK ((estimated_temporary_bytes >= 0)),
    CONSTRAINT knowledge_embedding_migration_t_estimated_token_count_check CHECK ((estimated_token_count >= 0)),
    CONSTRAINT knowledge_embedding_migration_t_reserved_cost_micros_check CHECK ((reserved_cost_micros >= 0)),
    CONSTRAINT knowledge_embedding_migration_t_rollback_window_seconds_check CHECK (((rollback_window_seconds >= 300) AND (rollback_window_seconds <= 2592000))),
    CONSTRAINT knowledge_embedding_migration_t_start_watermark_check CHECK ((start_watermark >= 0)),
    CONSTRAINT knowledge_embedding_migration_t_state_check CHECK (((state)::text = ANY (ARRAY[('REQUESTED'::character varying)::text, ('PREFLIGHTED'::character varying)::text, ('BACKFILLING'::character varying)::text, ('PAUSED'::character varying)::text, ('CATCHING_UP'::character varying)::text, ('VALIDATING'::character varying)::text, ('READY'::character varying)::text, ('PROMOTED'::character varying)::text, ('SOAKING'::character varying)::text, ('ROLLED_BACK'::character varying)::text, ('CANCELLED'::character varying)::text, ('FAILED'::character varying)::text, ('RETIRED'::character varying)::text]))),
    CONSTRAINT knowledge_embedding_migration_t_target_dimension_check CHECK ((target_dimension > 0)),
    CONSTRAINT knowledge_embedding_migration_t_target_profile_revision_check CHECK ((target_profile_revision > 0)),
    CONSTRAINT knowledge_embedding_migration_t_target_space_revision_check CHECK ((target_space_revision > 0)),
    CONSTRAINT knowledge_embedding_migration_t_version_check CHECK ((version > 0))
);


--
-- Name: TABLE knowledge_embedding_migration_t; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.knowledge_embedding_migration_t IS 'Stores knowledge embedding migration records used by the Light Knowledge ingestion, retrieval, indexing, and operations services.';


--
-- Name: COLUMN knowledge_embedding_migration_t.migration_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_embedding_migration_t.migration_id IS 'Identifier for the related migration.';


--
-- Name: COLUMN knowledge_embedding_migration_t.knowledge_base_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_embedding_migration_t.knowledge_base_id IS 'Identifier for the related knowledge base.';


--
-- Name: COLUMN knowledge_embedding_migration_t.environment; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_embedding_migration_t.environment IS 'Environment value for this knowledge embedding migration record.';


--
-- Name: COLUMN knowledge_embedding_migration_t.source_generation_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_embedding_migration_t.source_generation_id IS 'Identifier for the related source generation.';


--
-- Name: COLUMN knowledge_embedding_migration_t.candidate_generation_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_embedding_migration_t.candidate_generation_id IS 'Identifier for the related candidate generation.';


--
-- Name: COLUMN knowledge_embedding_migration_t.target_profile_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_embedding_migration_t.target_profile_id IS 'Identifier for the related target profile.';


--
-- Name: COLUMN knowledge_embedding_migration_t.target_profile_revision; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_embedding_migration_t.target_profile_revision IS 'Target Profile Revision value for this knowledge embedding migration record.';


--
-- Name: COLUMN knowledge_embedding_migration_t.target_space_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_embedding_migration_t.target_space_id IS 'Identifier for the related target space.';


--
-- Name: COLUMN knowledge_embedding_migration_t.target_space_revision; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_embedding_migration_t.target_space_revision IS 'Target Space Revision value for this knowledge embedding migration record.';


--
-- Name: COLUMN knowledge_embedding_migration_t.target_dimension; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_embedding_migration_t.target_dimension IS 'Target Dimension value for this knowledge embedding migration record.';


--
-- Name: COLUMN knowledge_embedding_migration_t.estimate_version; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_embedding_migration_t.estimate_version IS 'Version value for estimate.';


--
-- Name: COLUMN knowledge_embedding_migration_t.estimated_chunk_count; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_embedding_migration_t.estimated_chunk_count IS 'Count of estimated chunk.';


--
-- Name: COLUMN knowledge_embedding_migration_t.estimated_token_count; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_embedding_migration_t.estimated_token_count IS 'Count of estimated token.';


--
-- Name: COLUMN knowledge_embedding_migration_t.estimated_cost_micros; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_embedding_migration_t.estimated_cost_micros IS 'Estimated Cost Micros value for this knowledge embedding migration record.';


--
-- Name: COLUMN knowledge_embedding_migration_t.estimated_duration_seconds; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_embedding_migration_t.estimated_duration_seconds IS 'Estimated Duration Seconds value for this knowledge embedding migration record.';


--
-- Name: COLUMN knowledge_embedding_migration_t.estimated_temporary_bytes; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_embedding_migration_t.estimated_temporary_bytes IS 'Estimated Temporary Bytes value for this knowledge embedding migration record.';


--
-- Name: COLUMN knowledge_embedding_migration_t.accepted_cost_ceiling_micros; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_embedding_migration_t.accepted_cost_ceiling_micros IS 'Accepted Cost Ceiling Micros value for this knowledge embedding migration record.';


--
-- Name: COLUMN knowledge_embedding_migration_t.rollback_window_seconds; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_embedding_migration_t.rollback_window_seconds IS 'Rollback Window Seconds value for this knowledge embedding migration record.';


--
-- Name: COLUMN knowledge_embedding_migration_t.consumed_token_count; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_embedding_migration_t.consumed_token_count IS 'Count of consumed token.';


--
-- Name: COLUMN knowledge_embedding_migration_t.consumed_cost_micros; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_embedding_migration_t.consumed_cost_micros IS 'Consumed Cost Micros value for this knowledge embedding migration record.';


--
-- Name: COLUMN knowledge_embedding_migration_t.reserved_cost_micros; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_embedding_migration_t.reserved_cost_micros IS 'Reserved Cost Micros value for this knowledge embedding migration record.';


--
-- Name: COLUMN knowledge_embedding_migration_t.completed_chunk_count; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_embedding_migration_t.completed_chunk_count IS 'Count of completed chunk.';


--
-- Name: COLUMN knowledge_embedding_migration_t.catchup_chunk_count; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_embedding_migration_t.catchup_chunk_count IS 'Count of catchup chunk.';


--
-- Name: COLUMN knowledge_embedding_migration_t.reused_canonical_chunk_count; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_embedding_migration_t.reused_canonical_chunk_count IS 'Count of reused canonical chunk.';


--
-- Name: COLUMN knowledge_embedding_migration_t.start_watermark; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_embedding_migration_t.start_watermark IS 'Start Watermark value for this knowledge embedding migration record.';


--
-- Name: COLUMN knowledge_embedding_migration_t.snapshot_watermark; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_embedding_migration_t.snapshot_watermark IS 'Snapshot Watermark value for this knowledge embedding migration record.';


--
-- Name: COLUMN knowledge_embedding_migration_t.final_watermark; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_embedding_migration_t.final_watermark IS 'Final Watermark value for this knowledge embedding migration record.';


--
-- Name: COLUMN knowledge_embedding_migration_t.predecessor_reconciled_watermark; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_embedding_migration_t.predecessor_reconciled_watermark IS 'Predecessor Reconciled Watermark value for this knowledge embedding migration record.';


--
-- Name: COLUMN knowledge_embedding_migration_t.state; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_embedding_migration_t.state IS 'State value for this knowledge embedding migration record.';


--
-- Name: COLUMN knowledge_embedding_migration_t.version; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_embedding_migration_t.version IS 'Version value for version.';


--
-- Name: COLUMN knowledge_embedding_migration_t.evaluation_evidence_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_embedding_migration_t.evaluation_evidence_id IS 'Identifier for the related evaluation evidence.';


--
-- Name: COLUMN knowledge_embedding_migration_t.evaluation_evidence_digest; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_embedding_migration_t.evaluation_evidence_digest IS 'Integrity digest for evaluation evidence.';


--
-- Name: COLUMN knowledge_embedding_migration_t.promotion_watermark; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_embedding_migration_t.promotion_watermark IS 'Promotion Watermark value for this knowledge embedding migration record.';


--
-- Name: COLUMN knowledge_embedding_migration_t.rollback_deadline; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_embedding_migration_t.rollback_deadline IS 'Rollback Deadline value for this knowledge embedding migration record.';


--
-- Name: COLUMN knowledge_embedding_migration_t.pause_reason; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_embedding_migration_t.pause_reason IS 'Pause Reason value for this knowledge embedding migration record.';


--
-- Name: COLUMN knowledge_embedding_migration_t.failure_code; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_embedding_migration_t.failure_code IS 'Failure Code value for this knowledge embedding migration record.';


--
-- Name: COLUMN knowledge_embedding_migration_t.requested_by; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_embedding_migration_t.requested_by IS 'Requested By value for this knowledge embedding migration record.';


--
-- Name: COLUMN knowledge_embedding_migration_t.authorized_by; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_embedding_migration_t.authorized_by IS 'Authorized By value for this knowledge embedding migration record.';


--
-- Name: COLUMN knowledge_embedding_migration_t.created_ts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_embedding_migration_t.created_ts IS 'Timestamp for the created event or state.';


--
-- Name: COLUMN knowledge_embedding_migration_t.update_ts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_embedding_migration_t.update_ts IS 'Timestamp when this record was last updated.';


--
-- Name: COLUMN knowledge_embedding_migration_t.finished_ts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_embedding_migration_t.finished_ts IS 'Timestamp for the finished event or state.';


--
-- Name: knowledge_embedding_profile_t; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.knowledge_embedding_profile_t (
    profile_id uuid NOT NULL,
    profile_revision bigint NOT NULL,
    host_id uuid,
    alias_owner_host_id uuid NOT NULL,
    public_alias_id uuid NOT NULL,
    expected_space_id character varying(255) NOT NULL,
    expected_space_revision bigint NOT NULL,
    dimension integer NOT NULL,
    normalization character varying(16) NOT NULL,
    distance_metric character varying(24) NOT NULL,
    document_input_transform_version character varying(255) NOT NULL,
    query_input_transform_version character varying(255) NOT NULL,
    qualification_digest character varying(128) NOT NULL,
    active boolean DEFAULT true NOT NULL,
    update_ts timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    update_user character varying(126) DEFAULT SESSION_USER NOT NULL,
    alias_name character varying(255) DEFAULT 'kb-index'::character varying NOT NULL,
    CONSTRAINT knowledge_embedding_profile__document_input_transform_ver_check CHECK ((length((document_input_transform_version)::text) > 0)),
    CONSTRAINT knowledge_embedding_profile__query_input_transform_versio_check CHECK ((length((query_input_transform_version)::text) > 0)),
    CONSTRAINT knowledge_embedding_profile_alias_name_ck CHECK ((length(TRIM(BOTH FROM alias_name)) > 0)),
    CONSTRAINT knowledge_embedding_profile_t_dimension_check CHECK ((dimension > 0)),
    CONSTRAINT knowledge_embedding_profile_t_distance_metric_check CHECK (((distance_metric)::text = ANY (ARRAY[('cosine'::character varying)::text, ('inner_product'::character varying)::text, ('l2'::character varying)::text]))),
    CONSTRAINT knowledge_embedding_profile_t_expected_space_id_check CHECK ((length((expected_space_id)::text) > 0)),
    CONSTRAINT knowledge_embedding_profile_t_expected_space_revision_check CHECK ((expected_space_revision > 0)),
    CONSTRAINT knowledge_embedding_profile_t_normalization_check CHECK (((normalization)::text = ANY (ARRAY[('none'::character varying)::text, ('l2'::character varying)::text]))),
    CONSTRAINT knowledge_embedding_profile_t_profile_revision_check CHECK ((profile_revision > 0)),
    CONSTRAINT knowledge_embedding_profile_t_qualification_digest_check CHECK ((length((qualification_digest)::text) >= 64))
);


--
-- Name: TABLE knowledge_embedding_profile_t; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.knowledge_embedding_profile_t IS 'Stores knowledge embedding profile records used by the Light Knowledge ingestion, retrieval, indexing, and operations services.';


--
-- Name: COLUMN knowledge_embedding_profile_t.profile_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_embedding_profile_t.profile_id IS 'Identifier for the related profile.';


--
-- Name: COLUMN knowledge_embedding_profile_t.profile_revision; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_embedding_profile_t.profile_revision IS 'Profile Revision value for this knowledge embedding profile record.';


--
-- Name: COLUMN knowledge_embedding_profile_t.host_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_embedding_profile_t.host_id IS 'Tenant host identifier that scopes this record.';


--
-- Name: COLUMN knowledge_embedding_profile_t.alias_owner_host_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_embedding_profile_t.alias_owner_host_id IS 'Identifier for the related alias owner host.';


--
-- Name: COLUMN knowledge_embedding_profile_t.public_alias_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_embedding_profile_t.public_alias_id IS 'Identifier for the related public alias.';


--
-- Name: COLUMN knowledge_embedding_profile_t.expected_space_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_embedding_profile_t.expected_space_id IS 'Identifier for the related expected space.';


--
-- Name: COLUMN knowledge_embedding_profile_t.expected_space_revision; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_embedding_profile_t.expected_space_revision IS 'Expected Space Revision value for this knowledge embedding profile record.';


--
-- Name: COLUMN knowledge_embedding_profile_t.dimension; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_embedding_profile_t.dimension IS 'Dimension value for this knowledge embedding profile record.';


--
-- Name: COLUMN knowledge_embedding_profile_t.normalization; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_embedding_profile_t.normalization IS 'Normalization value for this knowledge embedding profile record.';


--
-- Name: COLUMN knowledge_embedding_profile_t.distance_metric; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_embedding_profile_t.distance_metric IS 'Distance Metric value for this knowledge embedding profile record.';


--
-- Name: COLUMN knowledge_embedding_profile_t.document_input_transform_version; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_embedding_profile_t.document_input_transform_version IS 'Version value for document input transform.';


--
-- Name: COLUMN knowledge_embedding_profile_t.query_input_transform_version; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_embedding_profile_t.query_input_transform_version IS 'Version value for query input transform.';


--
-- Name: COLUMN knowledge_embedding_profile_t.qualification_digest; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_embedding_profile_t.qualification_digest IS 'Integrity digest for qualification.';


--
-- Name: COLUMN knowledge_embedding_profile_t.active; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_embedding_profile_t.active IS 'Indicates whether this record is active.';


--
-- Name: COLUMN knowledge_embedding_profile_t.update_ts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_embedding_profile_t.update_ts IS 'Timestamp when this record was last updated.';


--
-- Name: COLUMN knowledge_embedding_profile_t.update_user; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_embedding_profile_t.update_user IS 'User or service principal that last updated this record.';


--
-- Name: COLUMN knowledge_embedding_profile_t.alias_name; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_embedding_profile_t.alias_name IS 'Alias Name value for this knowledge embedding profile record.';


--
-- Name: knowledge_embedding_profile_runtime_v; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.knowledge_embedding_profile_runtime_v WITH (security_barrier='true') AS
 SELECT profile_id,
    profile_revision,
    expected_space_id,
    expected_space_revision,
    dimension,
    document_input_transform_version,
    query_input_transform_version,
    alias_name
   FROM public.knowledge_embedding_profile_t profile
  WHERE (active = true);


--
-- Name: knowledge_embedding_reference_t; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.knowledge_embedding_reference_t (
    embedding_artifact_id uuid NOT NULL,
    knowledge_base_id uuid NOT NULL,
    chunk_id uuid NOT NULL,
    input_digest character(64) NOT NULL,
    transform_contract_digest character(64) NOT NULL,
    reference_state character varying(12) DEFAULT 'ACTIVE'::character varying NOT NULL,
    created_ts timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    released_ts timestamp with time zone,
    CONSTRAINT knowledge_embedding_reference_t_input_digest_check CHECK ((input_digest ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT knowledge_embedding_reference_t_reference_state_check CHECK (((reference_state)::text = ANY (ARRAY[('ACTIVE'::character varying)::text, ('RELEASED'::character varying)::text, ('PURGED'::character varying)::text]))),
    CONSTRAINT knowledge_embedding_reference_t_transform_contract_digest_check CHECK ((transform_contract_digest ~ '^[a-f0-9]{64}$'::text))
);


--
-- Name: TABLE knowledge_embedding_reference_t; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.knowledge_embedding_reference_t IS 'Stores knowledge embedding reference records used by the Light Knowledge ingestion, retrieval, indexing, and operations services.';


--
-- Name: COLUMN knowledge_embedding_reference_t.embedding_artifact_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_embedding_reference_t.embedding_artifact_id IS 'Identifier for the related embedding artifact.';


--
-- Name: COLUMN knowledge_embedding_reference_t.knowledge_base_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_embedding_reference_t.knowledge_base_id IS 'Identifier for the related knowledge base.';


--
-- Name: COLUMN knowledge_embedding_reference_t.chunk_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_embedding_reference_t.chunk_id IS 'Identifier for the related chunk.';


--
-- Name: COLUMN knowledge_embedding_reference_t.input_digest; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_embedding_reference_t.input_digest IS 'Integrity digest for input.';


--
-- Name: COLUMN knowledge_embedding_reference_t.transform_contract_digest; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_embedding_reference_t.transform_contract_digest IS 'Integrity digest for transform contract.';


--
-- Name: COLUMN knowledge_embedding_reference_t.reference_state; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_embedding_reference_t.reference_state IS 'Reference State value for this knowledge embedding reference record.';


--
-- Name: COLUMN knowledge_embedding_reference_t.created_ts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_embedding_reference_t.created_ts IS 'Timestamp for the created event or state.';


--
-- Name: COLUMN knowledge_embedding_reference_t.released_ts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_embedding_reference_t.released_ts IS 'Timestamp for the released event or state.';


--
-- Name: knowledge_generation_retention_t; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.knowledge_generation_retention_t (
    index_generation_id uuid NOT NULL,
    knowledge_base_id uuid NOT NULL,
    retention_state character varying(20) DEFAULT 'RETAINED'::character varying NOT NULL,
    retain_until_ts timestamp with time zone,
    legal_hold boolean DEFAULT false NOT NULL,
    backup_reference_count integer DEFAULT 0 NOT NULL,
    migration_reference_count integer DEFAULT 0 NOT NULL,
    last_reference_check_ts timestamp with time zone,
    update_ts timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT knowledge_generation_retention__migration_reference_count_check CHECK ((migration_reference_count >= 0)),
    CONSTRAINT knowledge_generation_retention_t_backup_reference_count_check CHECK ((backup_reference_count >= 0)),
    CONSTRAINT knowledge_generation_retention_t_check CHECK ((((retention_state)::text <> 'PURGE_APPROVED'::text) OR ((legal_hold = false) AND (backup_reference_count = 0) AND (migration_reference_count = 0)))),
    CONSTRAINT knowledge_generation_retention_t_retention_state_check CHECK (((retention_state)::text = ANY (ARRAY[('ACTIVE'::character varying)::text, ('ROLLBACK_ELIGIBLE'::character varying)::text, ('RETAINED'::character varying)::text, ('PURGE_APPROVED'::character varying)::text, ('PURGED'::character varying)::text])))
);


--
-- Name: TABLE knowledge_generation_retention_t; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.knowledge_generation_retention_t IS 'Stores knowledge generation retention records used by the Light Knowledge ingestion, retrieval, indexing, and operations services.';


--
-- Name: COLUMN knowledge_generation_retention_t.index_generation_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_generation_retention_t.index_generation_id IS 'Identifier for the related index generation.';


--
-- Name: COLUMN knowledge_generation_retention_t.knowledge_base_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_generation_retention_t.knowledge_base_id IS 'Identifier for the related knowledge base.';


--
-- Name: COLUMN knowledge_generation_retention_t.retention_state; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_generation_retention_t.retention_state IS 'Retention State value for this knowledge generation retention record.';


--
-- Name: COLUMN knowledge_generation_retention_t.retain_until_ts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_generation_retention_t.retain_until_ts IS 'Timestamp for the retain until event or state.';


--
-- Name: COLUMN knowledge_generation_retention_t.legal_hold; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_generation_retention_t.legal_hold IS 'Legal Hold value for this knowledge generation retention record.';


--
-- Name: COLUMN knowledge_generation_retention_t.backup_reference_count; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_generation_retention_t.backup_reference_count IS 'Count of backup reference.';


--
-- Name: COLUMN knowledge_generation_retention_t.migration_reference_count; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_generation_retention_t.migration_reference_count IS 'Count of migration reference.';


--
-- Name: COLUMN knowledge_generation_retention_t.last_reference_check_ts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_generation_retention_t.last_reference_check_ts IS 'Timestamp for the last reference check event or state.';


--
-- Name: COLUMN knowledge_generation_retention_t.update_ts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_generation_retention_t.update_ts IS 'Timestamp when this record was last updated.';


--
-- Name: knowledge_generation_segment_t; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.knowledge_generation_segment_t (
    index_generation_id uuid NOT NULL,
    ordinal integer NOT NULL,
    index_segment_id uuid NOT NULL,
    CONSTRAINT knowledge_generation_segment_ordinal_ck CHECK ((ordinal >= 0))
);


--
-- Name: TABLE knowledge_generation_segment_t; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.knowledge_generation_segment_t IS 'Stores knowledge generation segment records used by the Light Knowledge ingestion, retrieval, indexing, and operations services.';


--
-- Name: COLUMN knowledge_generation_segment_t.index_generation_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_generation_segment_t.index_generation_id IS 'Identifier for the related index generation.';


--
-- Name: COLUMN knowledge_generation_segment_t.ordinal; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_generation_segment_t.ordinal IS 'Ordinal value for this knowledge generation segment record.';


--
-- Name: COLUMN knowledge_generation_segment_t.index_segment_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_generation_segment_t.index_segment_id IS 'Identifier for the related index segment.';


--
-- Name: knowledge_graph_entity_contribution_t; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.knowledge_graph_entity_contribution_t (
    graph_entity_id uuid NOT NULL,
    graph_generation_id uuid NOT NULL,
    knowledge_base_id uuid NOT NULL,
    chunk_id uuid NOT NULL,
    document_version_id uuid NOT NULL
);


--
-- Name: TABLE knowledge_graph_entity_contribution_t; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.knowledge_graph_entity_contribution_t IS 'Stores knowledge graph entity contribution records used by the Light Knowledge ingestion, retrieval, indexing, and operations services.';


--
-- Name: COLUMN knowledge_graph_entity_contribution_t.graph_entity_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_graph_entity_contribution_t.graph_entity_id IS 'Identifier for the related graph entity.';


--
-- Name: COLUMN knowledge_graph_entity_contribution_t.graph_generation_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_graph_entity_contribution_t.graph_generation_id IS 'Identifier for the related graph generation.';


--
-- Name: COLUMN knowledge_graph_entity_contribution_t.knowledge_base_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_graph_entity_contribution_t.knowledge_base_id IS 'Identifier for the related knowledge base.';


--
-- Name: COLUMN knowledge_graph_entity_contribution_t.chunk_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_graph_entity_contribution_t.chunk_id IS 'Identifier for the related chunk.';


--
-- Name: COLUMN knowledge_graph_entity_contribution_t.document_version_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_graph_entity_contribution_t.document_version_id IS 'Identifier for the related document version.';


--
-- Name: knowledge_graph_entity_t; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.knowledge_graph_entity_t (
    graph_entity_id uuid NOT NULL,
    graph_generation_id uuid NOT NULL,
    knowledge_base_id uuid NOT NULL,
    entity_type character varying(32) NOT NULL,
    normalized_key character varying(2048) NOT NULL,
    display_name character varying(2048) NOT NULL,
    origin character varying(16) NOT NULL,
    contract_version character varying(64) NOT NULL,
    CONSTRAINT knowledge_graph_entity_t_entity_type_check CHECK (((entity_type)::text = ANY (ARRAY[('REPOSITORY'::character varying)::text, ('DOCUMENT'::character varying)::text, ('HEADING'::character varying)::text, ('LINK_TARGET'::character varying)::text, ('API_OPERATION'::character varying)::text, ('CONFIGURATION_KEY'::character varying)::text, ('SERVICE'::character varying)::text, ('COMPONENT'::character varying)::text, ('DESIGN_REFERENCE'::character varying)::text]))),
    CONSTRAINT knowledge_graph_entity_t_origin_check CHECK (((origin)::text = ANY (ARRAY[('STRUCTURAL'::character varying)::text, ('EXPLICIT'::character varying)::text, ('EXTRACTED'::character varying)::text])))
);


--
-- Name: TABLE knowledge_graph_entity_t; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.knowledge_graph_entity_t IS 'Stores knowledge graph entity records used by the Light Knowledge ingestion, retrieval, indexing, and operations services.';


--
-- Name: COLUMN knowledge_graph_entity_t.graph_entity_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_graph_entity_t.graph_entity_id IS 'Identifier for the related graph entity.';


--
-- Name: COLUMN knowledge_graph_entity_t.graph_generation_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_graph_entity_t.graph_generation_id IS 'Identifier for the related graph generation.';


--
-- Name: COLUMN knowledge_graph_entity_t.knowledge_base_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_graph_entity_t.knowledge_base_id IS 'Identifier for the related knowledge base.';


--
-- Name: COLUMN knowledge_graph_entity_t.entity_type; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_graph_entity_t.entity_type IS 'Entity Type value for this knowledge graph entity record.';


--
-- Name: COLUMN knowledge_graph_entity_t.normalized_key; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_graph_entity_t.normalized_key IS 'Normalized Key value for this knowledge graph entity record.';


--
-- Name: COLUMN knowledge_graph_entity_t.display_name; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_graph_entity_t.display_name IS 'Display Name value for this knowledge graph entity record.';


--
-- Name: COLUMN knowledge_graph_entity_t.origin; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_graph_entity_t.origin IS 'Origin value for this knowledge graph entity record.';


--
-- Name: COLUMN knowledge_graph_entity_t.contract_version; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_graph_entity_t.contract_version IS 'Version value for contract.';


--
-- Name: knowledge_graph_generation_t; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.knowledge_graph_generation_t (
    graph_generation_id uuid NOT NULL,
    knowledge_base_id uuid NOT NULL,
    index_generation_id uuid NOT NULL,
    state character varying(16) NOT NULL,
    visibility_mode character varying(24) DEFAULT 'UNIFORM_SCOPE'::character varying NOT NULL,
    contract_version character varying(64) NOT NULL,
    contract_digest character(64) NOT NULL,
    manifest_digest character(64),
    entity_count bigint DEFAULT 0 NOT NULL,
    relation_count bigint DEFAULT 0 NOT NULL,
    failure_code character varying(96),
    created_ts timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    completed_ts timestamp with time zone,
    CONSTRAINT knowledge_graph_generation_t_contract_digest_check CHECK ((contract_digest ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT knowledge_graph_generation_t_entity_count_check CHECK ((entity_count >= 0)),
    CONSTRAINT knowledge_graph_generation_t_manifest_digest_check CHECK ((manifest_digest ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT knowledge_graph_generation_t_relation_count_check CHECK ((relation_count >= 0)),
    CONSTRAINT knowledge_graph_generation_t_state_check CHECK (((state)::text = ANY (ARRAY[('BUILDING'::character varying)::text, ('READY'::character varying)::text, ('FAILED'::character varying)::text, ('STALE'::character varying)::text]))),
    CONSTRAINT knowledge_graph_generation_t_visibility_mode_check CHECK (((visibility_mode)::text = 'UNIFORM_SCOPE'::text))
);


--
-- Name: TABLE knowledge_graph_generation_t; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.knowledge_graph_generation_t IS 'Stores knowledge graph generation records used by the Light Knowledge ingestion, retrieval, indexing, and operations services.';


--
-- Name: COLUMN knowledge_graph_generation_t.graph_generation_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_graph_generation_t.graph_generation_id IS 'Identifier for the related graph generation.';


--
-- Name: COLUMN knowledge_graph_generation_t.knowledge_base_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_graph_generation_t.knowledge_base_id IS 'Identifier for the related knowledge base.';


--
-- Name: COLUMN knowledge_graph_generation_t.index_generation_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_graph_generation_t.index_generation_id IS 'Identifier for the related index generation.';


--
-- Name: COLUMN knowledge_graph_generation_t.state; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_graph_generation_t.state IS 'State value for this knowledge graph generation record.';


--
-- Name: COLUMN knowledge_graph_generation_t.visibility_mode; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_graph_generation_t.visibility_mode IS 'Visibility Mode value for this knowledge graph generation record.';


--
-- Name: COLUMN knowledge_graph_generation_t.contract_version; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_graph_generation_t.contract_version IS 'Version value for contract.';


--
-- Name: COLUMN knowledge_graph_generation_t.contract_digest; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_graph_generation_t.contract_digest IS 'Integrity digest for contract.';


--
-- Name: COLUMN knowledge_graph_generation_t.manifest_digest; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_graph_generation_t.manifest_digest IS 'Integrity digest for manifest.';


--
-- Name: COLUMN knowledge_graph_generation_t.entity_count; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_graph_generation_t.entity_count IS 'Count of entity.';


--
-- Name: COLUMN knowledge_graph_generation_t.relation_count; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_graph_generation_t.relation_count IS 'Count of relation.';


--
-- Name: COLUMN knowledge_graph_generation_t.failure_code; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_graph_generation_t.failure_code IS 'Failure Code value for this knowledge graph generation record.';


--
-- Name: COLUMN knowledge_graph_generation_t.created_ts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_graph_generation_t.created_ts IS 'Timestamp for the created event or state.';


--
-- Name: COLUMN knowledge_graph_generation_t.completed_ts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_graph_generation_t.completed_ts IS 'Timestamp for the completed event or state.';


--
-- Name: knowledge_graph_relation_contribution_t; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.knowledge_graph_relation_contribution_t (
    graph_relation_id uuid NOT NULL,
    graph_generation_id uuid NOT NULL,
    knowledge_base_id uuid NOT NULL,
    chunk_id uuid NOT NULL,
    document_version_id uuid NOT NULL
);


--
-- Name: TABLE knowledge_graph_relation_contribution_t; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.knowledge_graph_relation_contribution_t IS 'Stores knowledge graph relation contribution records used by the Light Knowledge ingestion, retrieval, indexing, and operations services.';


--
-- Name: COLUMN knowledge_graph_relation_contribution_t.graph_relation_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_graph_relation_contribution_t.graph_relation_id IS 'Identifier for the related graph relation.';


--
-- Name: COLUMN knowledge_graph_relation_contribution_t.graph_generation_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_graph_relation_contribution_t.graph_generation_id IS 'Identifier for the related graph generation.';


--
-- Name: COLUMN knowledge_graph_relation_contribution_t.knowledge_base_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_graph_relation_contribution_t.knowledge_base_id IS 'Identifier for the related knowledge base.';


--
-- Name: COLUMN knowledge_graph_relation_contribution_t.chunk_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_graph_relation_contribution_t.chunk_id IS 'Identifier for the related chunk.';


--
-- Name: COLUMN knowledge_graph_relation_contribution_t.document_version_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_graph_relation_contribution_t.document_version_id IS 'Identifier for the related document version.';


--
-- Name: knowledge_graph_relation_t; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.knowledge_graph_relation_t (
    graph_relation_id uuid NOT NULL,
    graph_generation_id uuid NOT NULL,
    knowledge_base_id uuid NOT NULL,
    subject_entity_id uuid NOT NULL,
    object_entity_id uuid NOT NULL,
    relation_type character varying(64) NOT NULL,
    origin character varying(16) NOT NULL,
    contract_version character varying(64) NOT NULL,
    CONSTRAINT knowledge_graph_relation_t_origin_check CHECK (((origin)::text = ANY (ARRAY[('STRUCTURAL'::character varying)::text, ('EXPLICIT'::character varying)::text, ('EXTRACTED'::character varying)::text])))
);


--
-- Name: TABLE knowledge_graph_relation_t; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.knowledge_graph_relation_t IS 'Stores knowledge graph relation records used by the Light Knowledge ingestion, retrieval, indexing, and operations services.';


--
-- Name: COLUMN knowledge_graph_relation_t.graph_relation_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_graph_relation_t.graph_relation_id IS 'Identifier for the related graph relation.';


--
-- Name: COLUMN knowledge_graph_relation_t.graph_generation_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_graph_relation_t.graph_generation_id IS 'Identifier for the related graph generation.';


--
-- Name: COLUMN knowledge_graph_relation_t.knowledge_base_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_graph_relation_t.knowledge_base_id IS 'Identifier for the related knowledge base.';


--
-- Name: COLUMN knowledge_graph_relation_t.subject_entity_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_graph_relation_t.subject_entity_id IS 'Identifier for the related subject entity.';


--
-- Name: COLUMN knowledge_graph_relation_t.object_entity_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_graph_relation_t.object_entity_id IS 'Identifier for the related object entity.';


--
-- Name: COLUMN knowledge_graph_relation_t.relation_type; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_graph_relation_t.relation_type IS 'Relation Type value for this knowledge graph relation record.';


--
-- Name: COLUMN knowledge_graph_relation_t.origin; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_graph_relation_t.origin IS 'Origin value for this knowledge graph relation record.';


--
-- Name: COLUMN knowledge_graph_relation_t.contract_version; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_graph_relation_t.contract_version IS 'Version value for contract.';


--
-- Name: knowledge_index_generation_t; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.knowledge_index_generation_t (
    index_generation_id uuid NOT NULL,
    knowledge_base_id uuid NOT NULL,
    embedding_profile_id uuid NOT NULL,
    embedding_profile_revision bigint NOT NULL,
    space_id character varying(255) NOT NULL,
    space_revision bigint NOT NULL,
    dimension integer NOT NULL,
    parser_contract_digest character(64) NOT NULL,
    chunker_contract_digest character(64) NOT NULL,
    metadata_contract_digest character(64) NOT NULL,
    citation_contract_digest character(64) NOT NULL,
    acl_normalization_contract_digest character(64) NOT NULL,
    lexical_contract_digest character(64) NOT NULL,
    contract_set_digest character(64) NOT NULL,
    query_input_transform_version character varying(255) NOT NULL,
    snapshot_watermark bigint NOT NULL,
    final_watermark bigint,
    ordered_segment_manifest_digest character(64),
    strategy_projections jsonb DEFAULT '{}'::jsonb NOT NULL,
    state character varying(16) NOT NULL,
    evidence jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_ts timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    promoted_ts timestamp with time zone,
    CONSTRAINT knowledge_index_generation_t_acl_normalization_contract_d_check CHECK ((acl_normalization_contract_digest ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT knowledge_index_generation_t_check CHECK (((final_watermark IS NULL) OR (final_watermark >= snapshot_watermark))),
    CONSTRAINT knowledge_index_generation_t_chunker_contract_digest_check CHECK ((chunker_contract_digest ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT knowledge_index_generation_t_citation_contract_digest_check CHECK ((citation_contract_digest ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT knowledge_index_generation_t_contract_set_digest_check CHECK ((contract_set_digest ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT knowledge_index_generation_t_dimension_check CHECK ((dimension > 0)),
    CONSTRAINT knowledge_index_generation_t_evidence_check CHECK ((jsonb_typeof(evidence) = 'object'::text)),
    CONSTRAINT knowledge_index_generation_t_lexical_contract_digest_check CHECK ((lexical_contract_digest ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT knowledge_index_generation_t_metadata_contract_digest_check CHECK ((metadata_contract_digest ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT knowledge_index_generation_t_ordered_segment_manifest_dig_check CHECK (((ordered_segment_manifest_digest IS NULL) OR (ordered_segment_manifest_digest ~ '^[a-f0-9]{64}$'::text))),
    CONSTRAINT knowledge_index_generation_t_parser_contract_digest_check CHECK ((parser_contract_digest ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT knowledge_index_generation_t_snapshot_watermark_check CHECK ((snapshot_watermark >= 0)),
    CONSTRAINT knowledge_index_generation_t_space_revision_check CHECK ((space_revision > 0)),
    CONSTRAINT knowledge_index_generation_t_state_check CHECK (((state)::text = ANY (ARRAY[('BUILDING'::character varying)::text, ('CATCHING_UP'::character varying)::text, ('VALIDATING'::character varying)::text, ('READY'::character varying)::text, ('PROMOTED'::character varying)::text, ('FAILED'::character varying)::text, ('SUPERSEDED'::character varying)::text, ('PURGED'::character varying)::text]))),
    CONSTRAINT knowledge_index_generation_t_strategy_projections_check CHECK ((jsonb_typeof(strategy_projections) = 'object'::text))
);


--
-- Name: TABLE knowledge_index_generation_t; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.knowledge_index_generation_t IS 'Stores knowledge index generation records used by the Light Knowledge ingestion, retrieval, indexing, and operations services.';


--
-- Name: COLUMN knowledge_index_generation_t.index_generation_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_index_generation_t.index_generation_id IS 'Identifier for the related index generation.';


--
-- Name: COLUMN knowledge_index_generation_t.knowledge_base_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_index_generation_t.knowledge_base_id IS 'Identifier for the related knowledge base.';


--
-- Name: COLUMN knowledge_index_generation_t.embedding_profile_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_index_generation_t.embedding_profile_id IS 'Identifier for the related embedding profile.';


--
-- Name: COLUMN knowledge_index_generation_t.embedding_profile_revision; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_index_generation_t.embedding_profile_revision IS 'Embedding Profile Revision value for this knowledge index generation record.';


--
-- Name: COLUMN knowledge_index_generation_t.space_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_index_generation_t.space_id IS 'Identifier for the related space.';


--
-- Name: COLUMN knowledge_index_generation_t.space_revision; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_index_generation_t.space_revision IS 'Space Revision value for this knowledge index generation record.';


--
-- Name: COLUMN knowledge_index_generation_t.dimension; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_index_generation_t.dimension IS 'Dimension value for this knowledge index generation record.';


--
-- Name: COLUMN knowledge_index_generation_t.parser_contract_digest; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_index_generation_t.parser_contract_digest IS 'Integrity digest for parser contract.';


--
-- Name: COLUMN knowledge_index_generation_t.chunker_contract_digest; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_index_generation_t.chunker_contract_digest IS 'Integrity digest for chunker contract.';


--
-- Name: COLUMN knowledge_index_generation_t.metadata_contract_digest; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_index_generation_t.metadata_contract_digest IS 'Integrity digest for metadata contract.';


--
-- Name: COLUMN knowledge_index_generation_t.citation_contract_digest; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_index_generation_t.citation_contract_digest IS 'Integrity digest for citation contract.';


--
-- Name: COLUMN knowledge_index_generation_t.acl_normalization_contract_digest; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_index_generation_t.acl_normalization_contract_digest IS 'Integrity digest for acl normalization contract.';


--
-- Name: COLUMN knowledge_index_generation_t.lexical_contract_digest; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_index_generation_t.lexical_contract_digest IS 'Integrity digest for lexical contract.';


--
-- Name: COLUMN knowledge_index_generation_t.contract_set_digest; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_index_generation_t.contract_set_digest IS 'Integrity digest for contract set.';


--
-- Name: COLUMN knowledge_index_generation_t.query_input_transform_version; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_index_generation_t.query_input_transform_version IS 'Version value for query input transform.';


--
-- Name: COLUMN knowledge_index_generation_t.snapshot_watermark; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_index_generation_t.snapshot_watermark IS 'Snapshot Watermark value for this knowledge index generation record.';


--
-- Name: COLUMN knowledge_index_generation_t.final_watermark; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_index_generation_t.final_watermark IS 'Final Watermark value for this knowledge index generation record.';


--
-- Name: COLUMN knowledge_index_generation_t.ordered_segment_manifest_digest; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_index_generation_t.ordered_segment_manifest_digest IS 'Integrity digest for ordered segment manifest.';


--
-- Name: COLUMN knowledge_index_generation_t.strategy_projections; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_index_generation_t.strategy_projections IS 'Strategy Projections value for this knowledge index generation record.';


--
-- Name: COLUMN knowledge_index_generation_t.state; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_index_generation_t.state IS 'State value for this knowledge index generation record.';


--
-- Name: COLUMN knowledge_index_generation_t.evidence; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_index_generation_t.evidence IS 'Evidence value for this knowledge index generation record.';


--
-- Name: COLUMN knowledge_index_generation_t.created_ts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_index_generation_t.created_ts IS 'Timestamp for the created event or state.';


--
-- Name: COLUMN knowledge_index_generation_t.promoted_ts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_index_generation_t.promoted_ts IS 'Timestamp for the promoted event or state.';


--
-- Name: knowledge_index_pointer_history_t; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.knowledge_index_pointer_history_t (
    pointer_history_id uuid NOT NULL,
    knowledge_base_id uuid NOT NULL,
    environment character varying(32) NOT NULL,
    previous_generation_id uuid,
    selected_generation_id uuid NOT NULL,
    pointer_version bigint NOT NULL,
    evaluation_evidence jsonb NOT NULL,
    authorized_by character varying(255) NOT NULL,
    reason text NOT NULL,
    release_notes text,
    rollback_deadline timestamp with time zone NOT NULL,
    promoted_ts timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT knowledge_index_pointer_history_t_evaluation_evidence_check CHECK ((jsonb_typeof(evaluation_evidence) = 'object'::text)),
    CONSTRAINT knowledge_index_pointer_history_t_pointer_version_check CHECK ((pointer_version > 0))
);


--
-- Name: TABLE knowledge_index_pointer_history_t; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.knowledge_index_pointer_history_t IS 'Stores knowledge index pointer history records used by the Light Knowledge ingestion, retrieval, indexing, and operations services.';


--
-- Name: COLUMN knowledge_index_pointer_history_t.pointer_history_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_index_pointer_history_t.pointer_history_id IS 'Identifier for the related pointer history.';


--
-- Name: COLUMN knowledge_index_pointer_history_t.knowledge_base_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_index_pointer_history_t.knowledge_base_id IS 'Identifier for the related knowledge base.';


--
-- Name: COLUMN knowledge_index_pointer_history_t.environment; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_index_pointer_history_t.environment IS 'Environment value for this knowledge index pointer history record.';


--
-- Name: COLUMN knowledge_index_pointer_history_t.previous_generation_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_index_pointer_history_t.previous_generation_id IS 'Identifier for the related previous generation.';


--
-- Name: COLUMN knowledge_index_pointer_history_t.selected_generation_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_index_pointer_history_t.selected_generation_id IS 'Identifier for the related selected generation.';


--
-- Name: COLUMN knowledge_index_pointer_history_t.pointer_version; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_index_pointer_history_t.pointer_version IS 'Version value for pointer.';


--
-- Name: COLUMN knowledge_index_pointer_history_t.evaluation_evidence; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_index_pointer_history_t.evaluation_evidence IS 'Evaluation Evidence value for this knowledge index pointer history record.';


--
-- Name: COLUMN knowledge_index_pointer_history_t.authorized_by; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_index_pointer_history_t.authorized_by IS 'Authorized By value for this knowledge index pointer history record.';


--
-- Name: COLUMN knowledge_index_pointer_history_t.reason; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_index_pointer_history_t.reason IS 'Reason value for this knowledge index pointer history record.';


--
-- Name: COLUMN knowledge_index_pointer_history_t.release_notes; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_index_pointer_history_t.release_notes IS 'Release Notes value for this knowledge index pointer history record.';


--
-- Name: COLUMN knowledge_index_pointer_history_t.rollback_deadline; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_index_pointer_history_t.rollback_deadline IS 'Rollback Deadline value for this knowledge index pointer history record.';


--
-- Name: COLUMN knowledge_index_pointer_history_t.promoted_ts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_index_pointer_history_t.promoted_ts IS 'Timestamp for the promoted event or state.';


--
-- Name: knowledge_index_pointer_t; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.knowledge_index_pointer_t (
    knowledge_base_id uuid NOT NULL,
    environment character varying(32) NOT NULL,
    index_generation_id uuid NOT NULL,
    pointer_version bigint NOT NULL,
    update_ts timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    update_user character varying(126) DEFAULT SESSION_USER NOT NULL,
    CONSTRAINT knowledge_index_pointer_t_environment_check CHECK ((length((environment)::text) > 0)),
    CONSTRAINT knowledge_index_pointer_t_pointer_version_check CHECK ((pointer_version > 0))
);


--
-- Name: TABLE knowledge_index_pointer_t; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.knowledge_index_pointer_t IS 'Stores knowledge index pointer records used by the Light Knowledge ingestion, retrieval, indexing, and operations services.';


--
-- Name: COLUMN knowledge_index_pointer_t.knowledge_base_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_index_pointer_t.knowledge_base_id IS 'Identifier for the related knowledge base.';


--
-- Name: COLUMN knowledge_index_pointer_t.environment; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_index_pointer_t.environment IS 'Environment value for this knowledge index pointer record.';


--
-- Name: COLUMN knowledge_index_pointer_t.index_generation_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_index_pointer_t.index_generation_id IS 'Identifier for the related index generation.';


--
-- Name: COLUMN knowledge_index_pointer_t.pointer_version; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_index_pointer_t.pointer_version IS 'Version value for pointer.';


--
-- Name: COLUMN knowledge_index_pointer_t.update_ts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_index_pointer_t.update_ts IS 'Timestamp when this record was last updated.';


--
-- Name: COLUMN knowledge_index_pointer_t.update_user; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_index_pointer_t.update_user IS 'User or service principal that last updated this record.';


--
-- Name: knowledge_index_segment_t; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.knowledge_index_segment_t (
    index_segment_id uuid NOT NULL,
    knowledge_base_id uuid NOT NULL,
    index_generation_id uuid NOT NULL,
    segment_kind character varying(8) NOT NULL,
    state character varying(16) NOT NULL,
    snapshot_watermark bigint NOT NULL,
    parser_contract_digest character(64) NOT NULL,
    chunker_contract_digest character(64) NOT NULL,
    lexical_contract_digest character(64) NOT NULL,
    embedding_contract_digest character(64) NOT NULL,
    acl_contract_digest character(64) NOT NULL,
    physical_locator character varying(2048) NOT NULL,
    manifest_digest character(64) NOT NULL,
    document_count bigint NOT NULL,
    chunk_count bigint NOT NULL,
    vector_count bigint NOT NULL,
    acl_count bigint NOT NULL,
    created_ts timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    predecessor_segment_id uuid,
    operation_count bigint DEFAULT 0 NOT NULL,
    CONSTRAINT knowledge_index_segment_kind_ck CHECK (((segment_kind)::text = ANY (ARRAY[('BASE'::character varying)::text, ('DELTA'::character varying)::text]))),
    CONSTRAINT knowledge_index_segment_t_acl_count_check CHECK ((acl_count >= 0)),
    CONSTRAINT knowledge_index_segment_t_chunk_count_check CHECK ((chunk_count >= 0)),
    CONSTRAINT knowledge_index_segment_t_document_count_check CHECK ((document_count >= 0)),
    CONSTRAINT knowledge_index_segment_t_manifest_digest_check CHECK ((manifest_digest ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT knowledge_index_segment_t_operation_count_check CHECK ((operation_count >= 0)),
    CONSTRAINT knowledge_index_segment_t_snapshot_watermark_check CHECK ((snapshot_watermark >= 0)),
    CONSTRAINT knowledge_index_segment_t_state_check CHECK (((state)::text = ANY (ARRAY[('BUILDING'::character varying)::text, ('READY'::character varying)::text, ('FAILED'::character varying)::text, ('PURGED'::character varying)::text]))),
    CONSTRAINT knowledge_index_segment_t_vector_count_check CHECK ((vector_count >= 0))
);


--
-- Name: TABLE knowledge_index_segment_t; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.knowledge_index_segment_t IS 'Stores knowledge index segment records used by the Light Knowledge ingestion, retrieval, indexing, and operations services.';


--
-- Name: COLUMN knowledge_index_segment_t.index_segment_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_index_segment_t.index_segment_id IS 'Identifier for the related index segment.';


--
-- Name: COLUMN knowledge_index_segment_t.knowledge_base_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_index_segment_t.knowledge_base_id IS 'Identifier for the related knowledge base.';


--
-- Name: COLUMN knowledge_index_segment_t.index_generation_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_index_segment_t.index_generation_id IS 'Identifier for the related index generation.';


--
-- Name: COLUMN knowledge_index_segment_t.segment_kind; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_index_segment_t.segment_kind IS 'Segment Kind value for this knowledge index segment record.';


--
-- Name: COLUMN knowledge_index_segment_t.state; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_index_segment_t.state IS 'State value for this knowledge index segment record.';


--
-- Name: COLUMN knowledge_index_segment_t.snapshot_watermark; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_index_segment_t.snapshot_watermark IS 'Snapshot Watermark value for this knowledge index segment record.';


--
-- Name: COLUMN knowledge_index_segment_t.parser_contract_digest; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_index_segment_t.parser_contract_digest IS 'Integrity digest for parser contract.';


--
-- Name: COLUMN knowledge_index_segment_t.chunker_contract_digest; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_index_segment_t.chunker_contract_digest IS 'Integrity digest for chunker contract.';


--
-- Name: COLUMN knowledge_index_segment_t.lexical_contract_digest; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_index_segment_t.lexical_contract_digest IS 'Integrity digest for lexical contract.';


--
-- Name: COLUMN knowledge_index_segment_t.embedding_contract_digest; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_index_segment_t.embedding_contract_digest IS 'Integrity digest for embedding contract.';


--
-- Name: COLUMN knowledge_index_segment_t.acl_contract_digest; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_index_segment_t.acl_contract_digest IS 'Integrity digest for acl contract.';


--
-- Name: COLUMN knowledge_index_segment_t.physical_locator; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_index_segment_t.physical_locator IS 'Physical Locator value for this knowledge index segment record.';


--
-- Name: COLUMN knowledge_index_segment_t.manifest_digest; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_index_segment_t.manifest_digest IS 'Integrity digest for manifest.';


--
-- Name: COLUMN knowledge_index_segment_t.document_count; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_index_segment_t.document_count IS 'Count of document.';


--
-- Name: COLUMN knowledge_index_segment_t.chunk_count; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_index_segment_t.chunk_count IS 'Count of chunk.';


--
-- Name: COLUMN knowledge_index_segment_t.vector_count; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_index_segment_t.vector_count IS 'Count of vector.';


--
-- Name: COLUMN knowledge_index_segment_t.acl_count; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_index_segment_t.acl_count IS 'Count of acl.';


--
-- Name: COLUMN knowledge_index_segment_t.created_ts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_index_segment_t.created_ts IS 'Timestamp for the created event or state.';


--
-- Name: COLUMN knowledge_index_segment_t.predecessor_segment_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_index_segment_t.predecessor_segment_id IS 'Identifier for the related predecessor segment.';


--
-- Name: COLUMN knowledge_index_segment_t.operation_count; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_index_segment_t.operation_count IS 'Count of operation.';


--
-- Name: knowledge_ingestion_error_t; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.knowledge_ingestion_error_t (
    ingestion_error_id uuid NOT NULL,
    sync_run_id uuid NOT NULL,
    source_object_id character varying(1024),
    error_class character varying(96) NOT NULL,
    retryable boolean NOT NULL,
    redacted_detail jsonb NOT NULL,
    occurrence_count integer DEFAULT 1 NOT NULL,
    first_seen_ts timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    last_seen_ts timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT knowledge_ingestion_error_t_occurrence_count_check CHECK ((occurrence_count > 0)),
    CONSTRAINT knowledge_ingestion_error_t_redacted_detail_check CHECK ((jsonb_typeof(redacted_detail) = 'object'::text))
);


--
-- Name: TABLE knowledge_ingestion_error_t; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.knowledge_ingestion_error_t IS 'Stores knowledge ingestion error records used by the Light Knowledge ingestion, retrieval, indexing, and operations services.';


--
-- Name: COLUMN knowledge_ingestion_error_t.ingestion_error_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_ingestion_error_t.ingestion_error_id IS 'Identifier for the related ingestion error.';


--
-- Name: COLUMN knowledge_ingestion_error_t.sync_run_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_ingestion_error_t.sync_run_id IS 'Identifier for the related sync run.';


--
-- Name: COLUMN knowledge_ingestion_error_t.source_object_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_ingestion_error_t.source_object_id IS 'Identifier for the related source object.';


--
-- Name: COLUMN knowledge_ingestion_error_t.error_class; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_ingestion_error_t.error_class IS 'Error Class value for this knowledge ingestion error record.';


--
-- Name: COLUMN knowledge_ingestion_error_t.retryable; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_ingestion_error_t.retryable IS 'Retryable value for this knowledge ingestion error record.';


--
-- Name: COLUMN knowledge_ingestion_error_t.redacted_detail; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_ingestion_error_t.redacted_detail IS 'Redacted Detail value for this knowledge ingestion error record.';


--
-- Name: COLUMN knowledge_ingestion_error_t.occurrence_count; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_ingestion_error_t.occurrence_count IS 'Count of occurrence.';


--
-- Name: COLUMN knowledge_ingestion_error_t.first_seen_ts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_ingestion_error_t.first_seen_ts IS 'Timestamp for the first seen event or state.';


--
-- Name: COLUMN knowledge_ingestion_error_t.last_seen_ts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_ingestion_error_t.last_seen_ts IS 'Timestamp for the last seen event or state.';


--
-- Name: knowledge_ingestion_policy_t; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.knowledge_ingestion_policy_t (
    ingestion_policy_id uuid NOT NULL,
    host_id uuid,
    policy_name character varying(255) NOT NULL,
    max_documents bigint NOT NULL,
    max_chunks bigint NOT NULL,
    max_source_bytes bigint NOT NULL,
    max_stored_bytes bigint NOT NULL,
    max_embedding_tokens bigint NOT NULL,
    max_spend_micros bigint NOT NULL,
    max_wall_time_seconds bigint NOT NULL,
    max_concurrency integer NOT NULL,
    version bigint DEFAULT 1 NOT NULL,
    active boolean DEFAULT true NOT NULL,
    update_ts timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    update_user character varying(126) DEFAULT SESSION_USER NOT NULL,
    CONSTRAINT knowledge_ingestion_policy_t_max_chunks_check CHECK ((max_chunks > 0)),
    CONSTRAINT knowledge_ingestion_policy_t_max_concurrency_check CHECK ((max_concurrency > 0)),
    CONSTRAINT knowledge_ingestion_policy_t_max_documents_check CHECK ((max_documents > 0)),
    CONSTRAINT knowledge_ingestion_policy_t_max_embedding_tokens_check CHECK ((max_embedding_tokens > 0)),
    CONSTRAINT knowledge_ingestion_policy_t_max_source_bytes_check CHECK ((max_source_bytes > 0)),
    CONSTRAINT knowledge_ingestion_policy_t_max_spend_micros_check CHECK ((max_spend_micros >= 0)),
    CONSTRAINT knowledge_ingestion_policy_t_max_stored_bytes_check CHECK ((max_stored_bytes > 0)),
    CONSTRAINT knowledge_ingestion_policy_t_max_wall_time_seconds_check CHECK ((max_wall_time_seconds > 0)),
    CONSTRAINT knowledge_ingestion_policy_t_version_check CHECK ((version > 0))
);


--
-- Name: TABLE knowledge_ingestion_policy_t; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.knowledge_ingestion_policy_t IS 'Stores knowledge ingestion policy records used by the Light Knowledge ingestion, retrieval, indexing, and operations services.';


--
-- Name: COLUMN knowledge_ingestion_policy_t.ingestion_policy_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_ingestion_policy_t.ingestion_policy_id IS 'Identifier for the related ingestion policy.';


--
-- Name: COLUMN knowledge_ingestion_policy_t.host_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_ingestion_policy_t.host_id IS 'Tenant host identifier that scopes this record.';


--
-- Name: COLUMN knowledge_ingestion_policy_t.policy_name; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_ingestion_policy_t.policy_name IS 'Policy Name value for this knowledge ingestion policy record.';


--
-- Name: COLUMN knowledge_ingestion_policy_t.max_documents; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_ingestion_policy_t.max_documents IS 'Max Documents value for this knowledge ingestion policy record.';


--
-- Name: COLUMN knowledge_ingestion_policy_t.max_chunks; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_ingestion_policy_t.max_chunks IS 'Max Chunks value for this knowledge ingestion policy record.';


--
-- Name: COLUMN knowledge_ingestion_policy_t.max_source_bytes; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_ingestion_policy_t.max_source_bytes IS 'Max Source Bytes value for this knowledge ingestion policy record.';


--
-- Name: COLUMN knowledge_ingestion_policy_t.max_stored_bytes; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_ingestion_policy_t.max_stored_bytes IS 'Max Stored Bytes value for this knowledge ingestion policy record.';


--
-- Name: COLUMN knowledge_ingestion_policy_t.max_embedding_tokens; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_ingestion_policy_t.max_embedding_tokens IS 'Max Embedding Tokens value for this knowledge ingestion policy record.';


--
-- Name: COLUMN knowledge_ingestion_policy_t.max_spend_micros; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_ingestion_policy_t.max_spend_micros IS 'Max Spend Micros value for this knowledge ingestion policy record.';


--
-- Name: COLUMN knowledge_ingestion_policy_t.max_wall_time_seconds; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_ingestion_policy_t.max_wall_time_seconds IS 'Max Wall Time Seconds value for this knowledge ingestion policy record.';


--
-- Name: COLUMN knowledge_ingestion_policy_t.max_concurrency; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_ingestion_policy_t.max_concurrency IS 'Max Concurrency value for this knowledge ingestion policy record.';


--
-- Name: COLUMN knowledge_ingestion_policy_t.version; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_ingestion_policy_t.version IS 'Version value for version.';


--
-- Name: COLUMN knowledge_ingestion_policy_t.active; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_ingestion_policy_t.active IS 'Indicates whether this record is active.';


--
-- Name: COLUMN knowledge_ingestion_policy_t.update_ts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_ingestion_policy_t.update_ts IS 'Timestamp when this record was last updated.';


--
-- Name: COLUMN knowledge_ingestion_policy_t.update_user; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_ingestion_policy_t.update_user IS 'User or service principal that last updated this record.';


--
-- Name: knowledge_job_t; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.knowledge_job_t (
    job_id uuid NOT NULL,
    knowledge_base_id uuid NOT NULL,
    source_id uuid,
    job_type character varying(24) NOT NULL,
    state character varying(16) DEFAULT 'QUEUED'::character varying NOT NULL,
    idempotency_key character varying(255) NOT NULL,
    requested_by character varying(255) NOT NULL,
    claim_token uuid,
    lease_expires_ts timestamp with time zone,
    attempt_count integer DEFAULT 0 NOT NULL,
    next_attempt_ts timestamp with time zone,
    payload jsonb DEFAULT '{}'::jsonb NOT NULL,
    result jsonb,
    created_ts timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    update_ts timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT knowledge_job_t_attempt_count_check CHECK ((attempt_count >= 0)),
    CONSTRAINT knowledge_job_t_payload_check CHECK ((jsonb_typeof(payload) = 'object'::text)),
    CONSTRAINT knowledge_job_t_result_check CHECK (((result IS NULL) OR (jsonb_typeof(result) = 'object'::text))),
    CONSTRAINT knowledge_job_t_state_check CHECK (((state)::text = ANY (ARRAY[('QUEUED'::character varying)::text, ('RUNNING'::character varying)::text, ('SUCCEEDED'::character varying)::text, ('FAILED'::character varying)::text, ('CANCELLED'::character varying)::text]))),
    CONSTRAINT knowledge_job_type_phase3_ck CHECK (((job_type)::text = ANY (ARRAY[('SYNC'::character varying)::text, ('DELTA_SYNC'::character varying)::text, ('FULL_REINDEX'::character varying)::text, ('PROMOTE'::character varying)::text, ('PURGE'::character varying)::text, ('RETRIEVAL_TEST'::character varying)::text, ('CONNECTIVITY_TEST'::character varying)::text, ('UPLOAD'::character varying)::text, ('COMPACTION'::character varying)::text, ('ANTI_ENTROPY'::character varying)::text, ('CONNECTOR_SYNC'::character varying)::text, ('ACL_RECONCILE'::character varying)::text, ('PROVIDER_NOTIFICATION'::character varying)::text, ('MIGRATION_PREFLIGHT'::character varying)::text, ('MIGRATION_BACKFILL'::character varying)::text, ('MIGRATION_CATCHUP'::character varying)::text, ('MIGRATION_VALIDATE'::character varying)::text, ('MIGRATION_PAUSE'::character varying)::text, ('MIGRATION_CANCEL'::character varying)::text, ('MIGRATION_PROMOTE'::character varying)::text, ('MIGRATION_ROLLBACK'::character varying)::text, ('MIGRATION_RETIRE'::character varying)::text, ('BACKUP_CHECKPOINT'::character varying)::text, ('RESTORE_VERIFY'::character varying)::text, ('SEGMENT_PURGE'::character varying)::text])))
);


--
-- Name: TABLE knowledge_job_t; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.knowledge_job_t IS 'Stores knowledge job records used by the Light Knowledge ingestion, retrieval, indexing, and operations services.';


--
-- Name: COLUMN knowledge_job_t.job_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_job_t.job_id IS 'Identifier for the related job.';


--
-- Name: COLUMN knowledge_job_t.knowledge_base_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_job_t.knowledge_base_id IS 'Identifier for the related knowledge base.';


--
-- Name: COLUMN knowledge_job_t.source_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_job_t.source_id IS 'Identifier for the related source.';


--
-- Name: COLUMN knowledge_job_t.job_type; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_job_t.job_type IS 'Job Type value for this knowledge job record.';


--
-- Name: COLUMN knowledge_job_t.state; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_job_t.state IS 'State value for this knowledge job record.';


--
-- Name: COLUMN knowledge_job_t.idempotency_key; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_job_t.idempotency_key IS 'Idempotency Key value for this knowledge job record.';


--
-- Name: COLUMN knowledge_job_t.requested_by; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_job_t.requested_by IS 'Requested By value for this knowledge job record.';


--
-- Name: COLUMN knowledge_job_t.claim_token; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_job_t.claim_token IS 'Claim Token value for this knowledge job record.';


--
-- Name: COLUMN knowledge_job_t.lease_expires_ts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_job_t.lease_expires_ts IS 'Timestamp for the lease expires event or state.';


--
-- Name: COLUMN knowledge_job_t.attempt_count; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_job_t.attempt_count IS 'Count of attempt.';


--
-- Name: COLUMN knowledge_job_t.next_attempt_ts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_job_t.next_attempt_ts IS 'Timestamp for the next attempt event or state.';


--
-- Name: COLUMN knowledge_job_t.payload; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_job_t.payload IS 'Payload value for this knowledge job record.';


--
-- Name: COLUMN knowledge_job_t.result; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_job_t.result IS 'Result value for this knowledge job record.';


--
-- Name: COLUMN knowledge_job_t.created_ts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_job_t.created_ts IS 'Timestamp for the created event or state.';


--
-- Name: COLUMN knowledge_job_t.update_ts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_job_t.update_ts IS 'Timestamp when this record was last updated.';


--
-- Name: knowledge_migration_evaluation_t; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.knowledge_migration_evaluation_t (
    evaluation_evidence_id uuid NOT NULL,
    migration_id uuid NOT NULL,
    knowledge_base_id uuid NOT NULL,
    candidate_generation_id uuid NOT NULL,
    evaluation_contract_version character varying(64) NOT NULL,
    corpus_watermark bigint NOT NULL,
    metrics jsonb NOT NULL,
    evidence_digest character(64) NOT NULL,
    passed boolean NOT NULL,
    expires_ts timestamp with time zone NOT NULL,
    authorized_by character varying(255) NOT NULL,
    created_ts timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT knowledge_migration_evaluation_t_check CHECK ((expires_ts > created_ts)),
    CONSTRAINT knowledge_migration_evaluation_t_corpus_watermark_check CHECK ((corpus_watermark >= 0)),
    CONSTRAINT knowledge_migration_evaluation_t_evidence_digest_check CHECK ((evidence_digest ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT knowledge_migration_evaluation_t_metrics_check CHECK ((jsonb_typeof(metrics) = 'object'::text))
);


--
-- Name: TABLE knowledge_migration_evaluation_t; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.knowledge_migration_evaluation_t IS 'Stores knowledge migration evaluation records used by the Light Knowledge ingestion, retrieval, indexing, and operations services.';


--
-- Name: COLUMN knowledge_migration_evaluation_t.evaluation_evidence_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_migration_evaluation_t.evaluation_evidence_id IS 'Identifier for the related evaluation evidence.';


--
-- Name: COLUMN knowledge_migration_evaluation_t.migration_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_migration_evaluation_t.migration_id IS 'Identifier for the related migration.';


--
-- Name: COLUMN knowledge_migration_evaluation_t.knowledge_base_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_migration_evaluation_t.knowledge_base_id IS 'Identifier for the related knowledge base.';


--
-- Name: COLUMN knowledge_migration_evaluation_t.candidate_generation_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_migration_evaluation_t.candidate_generation_id IS 'Identifier for the related candidate generation.';


--
-- Name: COLUMN knowledge_migration_evaluation_t.evaluation_contract_version; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_migration_evaluation_t.evaluation_contract_version IS 'Version value for evaluation contract.';


--
-- Name: COLUMN knowledge_migration_evaluation_t.corpus_watermark; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_migration_evaluation_t.corpus_watermark IS 'Corpus Watermark value for this knowledge migration evaluation record.';


--
-- Name: COLUMN knowledge_migration_evaluation_t.metrics; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_migration_evaluation_t.metrics IS 'Metrics value for this knowledge migration evaluation record.';


--
-- Name: COLUMN knowledge_migration_evaluation_t.evidence_digest; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_migration_evaluation_t.evidence_digest IS 'Integrity digest for evidence.';


--
-- Name: COLUMN knowledge_migration_evaluation_t.passed; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_migration_evaluation_t.passed IS 'Passed value for this knowledge migration evaluation record.';


--
-- Name: COLUMN knowledge_migration_evaluation_t.expires_ts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_migration_evaluation_t.expires_ts IS 'Timestamp for the expires event or state.';


--
-- Name: COLUMN knowledge_migration_evaluation_t.authorized_by; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_migration_evaluation_t.authorized_by IS 'Authorized By value for this knowledge migration evaluation record.';


--
-- Name: COLUMN knowledge_migration_evaluation_t.created_ts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_migration_evaluation_t.created_ts IS 'Timestamp for the created event or state.';


--
-- Name: knowledge_operational_policy_t; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.knowledge_operational_policy_t (
    knowledge_base_id uuid NOT NULL,
    maximum_parallel_bulk_jobs integer DEFAULT 1 NOT NULL,
    maximum_migration_cost_micros bigint DEFAULT 100000000 NOT NULL,
    migration_cost_per_token_micros numeric(18,6) DEFAULT 0 NOT NULL,
    rollback_window_seconds bigint DEFAULT 86400 NOT NULL,
    anti_entropy_interval_seconds bigint DEFAULT 3600 NOT NULL,
    backup_interval_seconds bigint DEFAULT 86400 NOT NULL,
    version bigint DEFAULT 1 NOT NULL,
    update_ts timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT knowledge_operational_policy_anti_entropy_interval_second_check CHECK (((anti_entropy_interval_seconds >= 60) AND (anti_entropy_interval_seconds <= 604800))),
    CONSTRAINT knowledge_operational_policy_maximum_migration_cost_micro_check CHECK ((maximum_migration_cost_micros >= 0)),
    CONSTRAINT knowledge_operational_policy_migration_cost_per_token_mic_check CHECK ((migration_cost_per_token_micros >= (0)::numeric)),
    CONSTRAINT knowledge_operational_policy_t_backup_interval_seconds_check CHECK (((backup_interval_seconds >= 300) AND (backup_interval_seconds <= 2592000))),
    CONSTRAINT knowledge_operational_policy_t_maximum_parallel_bulk_jobs_check CHECK (((maximum_parallel_bulk_jobs >= 1) AND (maximum_parallel_bulk_jobs <= 32))),
    CONSTRAINT knowledge_operational_policy_t_rollback_window_seconds_check CHECK (((rollback_window_seconds >= 300) AND (rollback_window_seconds <= 2592000))),
    CONSTRAINT knowledge_operational_policy_t_version_check CHECK ((version > 0))
);


--
-- Name: TABLE knowledge_operational_policy_t; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.knowledge_operational_policy_t IS 'Stores knowledge operational policy records used by the Light Knowledge ingestion, retrieval, indexing, and operations services.';


--
-- Name: COLUMN knowledge_operational_policy_t.knowledge_base_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_operational_policy_t.knowledge_base_id IS 'Identifier for the related knowledge base.';


--
-- Name: COLUMN knowledge_operational_policy_t.maximum_parallel_bulk_jobs; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_operational_policy_t.maximum_parallel_bulk_jobs IS 'Maximum Parallel Bulk Jobs value for this knowledge operational policy record.';


--
-- Name: COLUMN knowledge_operational_policy_t.maximum_migration_cost_micros; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_operational_policy_t.maximum_migration_cost_micros IS 'Maximum Migration Cost Micros value for this knowledge operational policy record.';


--
-- Name: COLUMN knowledge_operational_policy_t.migration_cost_per_token_micros; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_operational_policy_t.migration_cost_per_token_micros IS 'Migration Cost Per Token Micros value for this knowledge operational policy record.';


--
-- Name: COLUMN knowledge_operational_policy_t.rollback_window_seconds; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_operational_policy_t.rollback_window_seconds IS 'Rollback Window Seconds value for this knowledge operational policy record.';


--
-- Name: COLUMN knowledge_operational_policy_t.anti_entropy_interval_seconds; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_operational_policy_t.anti_entropy_interval_seconds IS 'Anti Entropy Interval Seconds value for this knowledge operational policy record.';


--
-- Name: COLUMN knowledge_operational_policy_t.backup_interval_seconds; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_operational_policy_t.backup_interval_seconds IS 'Backup Interval Seconds value for this knowledge operational policy record.';


--
-- Name: COLUMN knowledge_operational_policy_t.version; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_operational_policy_t.version IS 'Version value for version.';


--
-- Name: COLUMN knowledge_operational_policy_t.update_ts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_operational_policy_t.update_ts IS 'Timestamp when this record was last updated.';


--
-- Name: knowledge_passage_anchor_t; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.knowledge_passage_anchor_t (
    passage_anchor_id uuid NOT NULL,
    knowledge_base_id uuid NOT NULL,
    document_id uuid NOT NULL,
    document_version_id uuid NOT NULL,
    chunk_id uuid NOT NULL,
    anchor_contract_digest character(64) NOT NULL,
    continuity_state character varying(16) NOT NULL,
    anchor_sequence bigint NOT NULL,
    created_ts timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT knowledge_passage_anchor_t_anchor_contract_digest_check CHECK ((anchor_contract_digest ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT knowledge_passage_anchor_t_anchor_sequence_check CHECK ((anchor_sequence > 0)),
    CONSTRAINT knowledge_passage_anchor_t_continuity_state_check CHECK (((continuity_state)::text = ANY (ARRAY[('STABLE'::character varying)::text, ('MOVED'::character varying)::text, ('AMBIGUOUS'::character varying)::text, ('RETIRED'::character varying)::text])))
);


--
-- Name: TABLE knowledge_passage_anchor_t; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.knowledge_passage_anchor_t IS 'Stores knowledge passage anchor records used by the Light Knowledge ingestion, retrieval, indexing, and operations services.';


--
-- Name: COLUMN knowledge_passage_anchor_t.passage_anchor_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_passage_anchor_t.passage_anchor_id IS 'Identifier for the related passage anchor.';


--
-- Name: COLUMN knowledge_passage_anchor_t.knowledge_base_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_passage_anchor_t.knowledge_base_id IS 'Identifier for the related knowledge base.';


--
-- Name: COLUMN knowledge_passage_anchor_t.document_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_passage_anchor_t.document_id IS 'Identifier for the related document.';


--
-- Name: COLUMN knowledge_passage_anchor_t.document_version_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_passage_anchor_t.document_version_id IS 'Identifier for the related document version.';


--
-- Name: COLUMN knowledge_passage_anchor_t.chunk_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_passage_anchor_t.chunk_id IS 'Identifier for the related chunk.';


--
-- Name: COLUMN knowledge_passage_anchor_t.anchor_contract_digest; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_passage_anchor_t.anchor_contract_digest IS 'Integrity digest for anchor contract.';


--
-- Name: COLUMN knowledge_passage_anchor_t.continuity_state; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_passage_anchor_t.continuity_state IS 'Continuity State value for this knowledge passage anchor record.';


--
-- Name: COLUMN knowledge_passage_anchor_t.anchor_sequence; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_passage_anchor_t.anchor_sequence IS 'Anchor Sequence value for this knowledge passage anchor record.';


--
-- Name: COLUMN knowledge_passage_anchor_t.created_ts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_passage_anchor_t.created_ts IS 'Timestamp for the created event or state.';


--
-- Name: knowledge_promotion_receipt_t; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.knowledge_promotion_receipt_t (
    promotion_id uuid NOT NULL,
    knowledge_base_id uuid NOT NULL,
    environment character varying(32) NOT NULL,
    index_generation_id uuid NOT NULL,
    pointer_version bigint NOT NULL,
    evidence_digest character(64) NOT NULL,
    authorized_by character varying(255) NOT NULL,
    committed_ts timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT knowledge_promotion_receipt_t_evidence_digest_check CHECK ((evidence_digest ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT knowledge_promotion_receipt_t_pointer_version_check CHECK ((pointer_version > 0))
);


--
-- Name: knowledge_purge_evidence_t; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.knowledge_purge_evidence_t (
    purge_evidence_id uuid NOT NULL,
    knowledge_base_id uuid NOT NULL,
    index_generation_id uuid,
    purge_scope character varying(24) NOT NULL,
    state character varying(20) NOT NULL,
    reference_counts jsonb NOT NULL,
    deletion_counts jsonb NOT NULL,
    evidence_digest character(64) NOT NULL,
    authorized_by character varying(255) NOT NULL,
    created_ts timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    finished_ts timestamp with time zone,
    CONSTRAINT knowledge_purge_evidence_t_deletion_counts_check CHECK ((jsonb_typeof(deletion_counts) = 'object'::text)),
    CONSTRAINT knowledge_purge_evidence_t_evidence_digest_check CHECK ((evidence_digest ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT knowledge_purge_evidence_t_purge_scope_check CHECK (((purge_scope)::text = ANY (ARRAY[('GENERATION'::character varying)::text, ('SEGMENT'::character varying)::text, ('EMBEDDING_ARTIFACT'::character varying)::text, ('KNOWLEDGE_BASE'::character varying)::text]))),
    CONSTRAINT knowledge_purge_evidence_t_reference_counts_check CHECK ((jsonb_typeof(reference_counts) = 'object'::text)),
    CONSTRAINT knowledge_purge_evidence_t_state_check CHECK (((state)::text = ANY (ARRAY[('REQUESTED'::character varying)::text, ('BLOCKED'::character varying)::text, ('VERIFIED'::character varying)::text, ('FAILED'::character varying)::text])))
);


--
-- Name: TABLE knowledge_purge_evidence_t; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.knowledge_purge_evidence_t IS 'Stores knowledge purge evidence records used by the Light Knowledge ingestion, retrieval, indexing, and operations services.';


--
-- Name: COLUMN knowledge_purge_evidence_t.purge_evidence_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_purge_evidence_t.purge_evidence_id IS 'Identifier for the related purge evidence.';


--
-- Name: COLUMN knowledge_purge_evidence_t.knowledge_base_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_purge_evidence_t.knowledge_base_id IS 'Identifier for the related knowledge base.';


--
-- Name: COLUMN knowledge_purge_evidence_t.index_generation_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_purge_evidence_t.index_generation_id IS 'Identifier for the related index generation.';


--
-- Name: COLUMN knowledge_purge_evidence_t.purge_scope; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_purge_evidence_t.purge_scope IS 'Purge Scope value for this knowledge purge evidence record.';


--
-- Name: COLUMN knowledge_purge_evidence_t.state; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_purge_evidence_t.state IS 'State value for this knowledge purge evidence record.';


--
-- Name: COLUMN knowledge_purge_evidence_t.reference_counts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_purge_evidence_t.reference_counts IS 'Reference Counts value for this knowledge purge evidence record.';


--
-- Name: COLUMN knowledge_purge_evidence_t.deletion_counts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_purge_evidence_t.deletion_counts IS 'Deletion Counts value for this knowledge purge evidence record.';


--
-- Name: COLUMN knowledge_purge_evidence_t.evidence_digest; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_purge_evidence_t.evidence_digest IS 'Integrity digest for evidence.';


--
-- Name: COLUMN knowledge_purge_evidence_t.authorized_by; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_purge_evidence_t.authorized_by IS 'Authorized By value for this knowledge purge evidence record.';


--
-- Name: COLUMN knowledge_purge_evidence_t.created_ts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_purge_evidence_t.created_ts IS 'Timestamp for the created event or state.';


--
-- Name: COLUMN knowledge_purge_evidence_t.finished_ts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_purge_evidence_t.finished_ts IS 'Timestamp for the finished event or state.';


--
-- Name: knowledge_query_admission_t; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.knowledge_query_admission_t (
    admission_id uuid NOT NULL,
    knowledge_base_id uuid NOT NULL,
    consumer_host_id uuid NOT NULL,
    request_id character varying(255) NOT NULL,
    admitted_ts timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    lease_expires_ts timestamp with time zone NOT NULL,
    reserved_cost_micros bigint NOT NULL,
    state character varying(16) DEFAULT 'ADMITTED'::character varying NOT NULL,
    CONSTRAINT knowledge_query_admission_t_check CHECK ((lease_expires_ts > admitted_ts)),
    CONSTRAINT knowledge_query_admission_t_reserved_cost_micros_check CHECK ((reserved_cost_micros >= 0)),
    CONSTRAINT knowledge_query_admission_t_state_check CHECK (((state)::text = ANY (ARRAY[('ADMITTED'::character varying)::text, ('COMPLETED'::character varying)::text, ('RELEASED'::character varying)::text])))
);


--
-- Name: TABLE knowledge_query_admission_t; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.knowledge_query_admission_t IS 'Stores knowledge query admission records used by the Light Knowledge ingestion, retrieval, indexing, and operations services.';


--
-- Name: COLUMN knowledge_query_admission_t.admission_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_query_admission_t.admission_id IS 'Identifier for the related admission.';


--
-- Name: COLUMN knowledge_query_admission_t.knowledge_base_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_query_admission_t.knowledge_base_id IS 'Identifier for the related knowledge base.';


--
-- Name: COLUMN knowledge_query_admission_t.consumer_host_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_query_admission_t.consumer_host_id IS 'Identifier for the related consumer host.';


--
-- Name: COLUMN knowledge_query_admission_t.request_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_query_admission_t.request_id IS 'Identifier for the related request.';


--
-- Name: COLUMN knowledge_query_admission_t.admitted_ts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_query_admission_t.admitted_ts IS 'Timestamp for the admitted event or state.';


--
-- Name: COLUMN knowledge_query_admission_t.lease_expires_ts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_query_admission_t.lease_expires_ts IS 'Timestamp for the lease expires event or state.';


--
-- Name: COLUMN knowledge_query_admission_t.reserved_cost_micros; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_query_admission_t.reserved_cost_micros IS 'Reserved Cost Micros value for this knowledge query admission record.';


--
-- Name: COLUMN knowledge_query_admission_t.state; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_query_admission_t.state IS 'State value for this knowledge query admission record.';


--
-- Name: knowledge_query_audit_t; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.knowledge_query_audit_t (
    query_audit_id uuid NOT NULL,
    request_id character varying(255) NOT NULL,
    knowledge_base_id uuid NOT NULL,
    consumer_host_id uuid NOT NULL,
    index_generation_id uuid NOT NULL,
    retrieval_profile_id uuid NOT NULL,
    strategy character varying(24) NOT NULL,
    segment_manifest_digest character(64) NOT NULL,
    query_digest character(64) NOT NULL,
    result_identities jsonb NOT NULL,
    fallback_reason character varying(64),
    latency_ms bigint NOT NULL,
    created_ts timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    graph_generation_id uuid,
    planner_diagnostics jsonb DEFAULT '{}'::jsonb NOT NULL,
    CONSTRAINT knowledge_query_audit_t_latency_ms_check CHECK ((latency_ms >= 0)),
    CONSTRAINT knowledge_query_audit_t_planner_diagnostics_check CHECK ((jsonb_typeof(planner_diagnostics) = 'object'::text)),
    CONSTRAINT knowledge_query_audit_t_query_digest_check CHECK ((query_digest ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT knowledge_query_audit_t_result_identities_check CHECK ((jsonb_typeof(result_identities) = 'array'::text)),
    CONSTRAINT knowledge_query_audit_t_segment_manifest_digest_check CHECK ((segment_manifest_digest ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT knowledge_query_audit_t_strategy_check CHECK (((strategy)::text = ANY (ARRAY[('LEXICAL'::character varying)::text, ('VECTOR'::character varying)::text, ('HYBRID'::character varying)::text, ('GRAPH_ASSISTED'::character varying)::text, ('HYBRID_FALLBACK'::character varying)::text])))
);


--
-- Name: TABLE knowledge_query_audit_t; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.knowledge_query_audit_t IS 'Stores knowledge query audit records used by the Light Knowledge ingestion, retrieval, indexing, and operations services.';


--
-- Name: COLUMN knowledge_query_audit_t.query_audit_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_query_audit_t.query_audit_id IS 'Identifier for the related query audit.';


--
-- Name: COLUMN knowledge_query_audit_t.request_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_query_audit_t.request_id IS 'Identifier for the related request.';


--
-- Name: COLUMN knowledge_query_audit_t.knowledge_base_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_query_audit_t.knowledge_base_id IS 'Identifier for the related knowledge base.';


--
-- Name: COLUMN knowledge_query_audit_t.consumer_host_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_query_audit_t.consumer_host_id IS 'Identifier for the related consumer host.';


--
-- Name: COLUMN knowledge_query_audit_t.index_generation_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_query_audit_t.index_generation_id IS 'Identifier for the related index generation.';


--
-- Name: COLUMN knowledge_query_audit_t.retrieval_profile_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_query_audit_t.retrieval_profile_id IS 'Identifier for the related retrieval profile.';


--
-- Name: COLUMN knowledge_query_audit_t.strategy; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_query_audit_t.strategy IS 'Strategy value for this knowledge query audit record.';


--
-- Name: COLUMN knowledge_query_audit_t.segment_manifest_digest; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_query_audit_t.segment_manifest_digest IS 'Integrity digest for segment manifest.';


--
-- Name: COLUMN knowledge_query_audit_t.query_digest; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_query_audit_t.query_digest IS 'Integrity digest for query.';


--
-- Name: COLUMN knowledge_query_audit_t.result_identities; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_query_audit_t.result_identities IS 'Result Identities value for this knowledge query audit record.';


--
-- Name: COLUMN knowledge_query_audit_t.fallback_reason; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_query_audit_t.fallback_reason IS 'Fallback Reason value for this knowledge query audit record.';


--
-- Name: COLUMN knowledge_query_audit_t.latency_ms; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_query_audit_t.latency_ms IS 'Latency Ms value for this knowledge query audit record.';


--
-- Name: COLUMN knowledge_query_audit_t.created_ts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_query_audit_t.created_ts IS 'Timestamp for the created event or state.';


--
-- Name: COLUMN knowledge_query_audit_t.graph_generation_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_query_audit_t.graph_generation_id IS 'Identifier for the related graph generation.';


--
-- Name: COLUMN knowledge_query_audit_t.planner_diagnostics; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_query_audit_t.planner_diagnostics IS 'Planner Diagnostics value for this knowledge query audit record.';


--
-- Name: knowledge_query_usage_t; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.knowledge_query_usage_t (
    usage_id uuid NOT NULL,
    knowledge_base_id uuid NOT NULL,
    consumer_host_id uuid NOT NULL,
    request_id character varying(255) NOT NULL,
    request_day date NOT NULL,
    charged_micros bigint NOT NULL,
    result_count integer DEFAULT 0 NOT NULL,
    status character varying(24) NOT NULL,
    created_ts timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT knowledge_query_usage_t_charged_micros_check CHECK ((charged_micros >= 0)),
    CONSTRAINT knowledge_query_usage_t_result_count_check CHECK ((result_count >= 0))
);


--
-- Name: TABLE knowledge_query_usage_t; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.knowledge_query_usage_t IS 'Stores knowledge query usage records used by the Light Knowledge ingestion, retrieval, indexing, and operations services.';


--
-- Name: COLUMN knowledge_query_usage_t.usage_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_query_usage_t.usage_id IS 'Identifier for the related usage.';


--
-- Name: COLUMN knowledge_query_usage_t.knowledge_base_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_query_usage_t.knowledge_base_id IS 'Identifier for the related knowledge base.';


--
-- Name: COLUMN knowledge_query_usage_t.consumer_host_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_query_usage_t.consumer_host_id IS 'Identifier for the related consumer host.';


--
-- Name: COLUMN knowledge_query_usage_t.request_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_query_usage_t.request_id IS 'Identifier for the related request.';


--
-- Name: COLUMN knowledge_query_usage_t.request_day; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_query_usage_t.request_day IS 'Request Day value for this knowledge query usage record.';


--
-- Name: COLUMN knowledge_query_usage_t.charged_micros; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_query_usage_t.charged_micros IS 'Charged Micros value for this knowledge query usage record.';


--
-- Name: COLUMN knowledge_query_usage_t.result_count; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_query_usage_t.result_count IS 'Count of result.';


--
-- Name: COLUMN knowledge_query_usage_t.status; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_query_usage_t.status IS 'Status value for this knowledge query usage record.';


--
-- Name: COLUMN knowledge_query_usage_t.created_ts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_query_usage_t.created_ts IS 'Timestamp for the created event or state.';


--
-- Name: knowledge_retrieval_profile_t; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.knowledge_retrieval_profile_t (
    profile_id uuid NOT NULL,
    host_id uuid,
    profile_name character varying(255) NOT NULL,
    strategy character varying(24) DEFAULT 'HYBRID'::character varying NOT NULL,
    lexical_candidates integer NOT NULL,
    vector_candidates integer NOT NULL,
    top_k integer NOT NULL,
    token_budget integer NOT NULL,
    fusion_method character varying(16) DEFAULT 'RRF'::character varying NOT NULL,
    operational_failure_policy character varying(24) DEFAULT 'FAIL_REQUEST'::character varying NOT NULL,
    graph_policy jsonb,
    version bigint DEFAULT 1 NOT NULL,
    active boolean DEFAULT true NOT NULL,
    update_ts timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    update_user character varying(126) DEFAULT SESSION_USER NOT NULL,
    maximum_knowledge_bases integer DEFAULT 1 NOT NULL,
    lexical_evidence_required boolean DEFAULT true NOT NULL,
    segment_candidate_multiplier integer DEFAULT 4 NOT NULL,
    context_expansion_before integer DEFAULT 0 NOT NULL,
    context_expansion_after integer DEFAULT 0 NOT NULL,
    CONSTRAINT knowledge_retrieval_profile__segment_candidate_multiplier_check CHECK (((segment_candidate_multiplier >= 1) AND (segment_candidate_multiplier <= 16))),
    CONSTRAINT knowledge_retrieval_profile_graph_failure_policy_ck CHECK (((graph_policy IS NULL) OR (NOT (graph_policy ? 'failurePolicy'::text)) OR ((graph_policy ->> 'failurePolicy'::text) = ANY (ARRAY['FALLBACK_HYBRID'::text, 'FAIL_CLOSED'::text])))),
    CONSTRAINT knowledge_retrieval_profile_name_ck CHECK ((length(btrim((profile_name)::text)) > 0)),
    CONSTRAINT knowledge_retrieval_profile_t_check CHECK (((top_k > 0) AND (top_k <= (lexical_candidates + vector_candidates)))),
    CONSTRAINT knowledge_retrieval_profile_t_context_expansion_after_check CHECK (((context_expansion_after >= 0) AND (context_expansion_after <= 4))),
    CONSTRAINT knowledge_retrieval_profile_t_context_expansion_before_check CHECK (((context_expansion_before >= 0) AND (context_expansion_before <= 4))),
    CONSTRAINT knowledge_retrieval_profile_t_fusion_method_check CHECK (((fusion_method)::text = 'RRF'::text)),
    CONSTRAINT knowledge_retrieval_profile_t_graph_policy_check CHECK (((graph_policy IS NULL) OR (jsonb_typeof(graph_policy) = 'object'::text))),
    CONSTRAINT knowledge_retrieval_profile_t_lexical_candidates_check CHECK ((lexical_candidates > 0)),
    CONSTRAINT knowledge_retrieval_profile_t_maximum_knowledge_bases_check CHECK (((maximum_knowledge_bases >= 1) AND (maximum_knowledge_bases <= 4))),
    CONSTRAINT knowledge_retrieval_profile_t_operational_failure_policy_check CHECK (((operational_failure_policy)::text = ANY (ARRAY[('FAIL_REQUEST'::character varying)::text, ('RETURN_PARTIAL'::character varying)::text]))),
    CONSTRAINT knowledge_retrieval_profile_t_strategy_check CHECK (((strategy)::text = ANY (ARRAY[('LEXICAL'::character varying)::text, ('VECTOR'::character varying)::text, ('HYBRID'::character varying)::text, ('GRAPH_ASSISTED'::character varying)::text]))),
    CONSTRAINT knowledge_retrieval_profile_t_token_budget_check CHECK ((token_budget > 0)),
    CONSTRAINT knowledge_retrieval_profile_t_vector_candidates_check CHECK ((vector_candidates > 0)),
    CONSTRAINT knowledge_retrieval_profile_t_version_check CHECK ((version > 0))
);


--
-- Name: TABLE knowledge_retrieval_profile_t; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.knowledge_retrieval_profile_t IS 'Stores knowledge retrieval profile records used by the Light Knowledge ingestion, retrieval, indexing, and operations services.';


--
-- Name: COLUMN knowledge_retrieval_profile_t.profile_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_retrieval_profile_t.profile_id IS 'Identifier for the related profile.';


--
-- Name: COLUMN knowledge_retrieval_profile_t.host_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_retrieval_profile_t.host_id IS 'Tenant host identifier that scopes this record.';


--
-- Name: COLUMN knowledge_retrieval_profile_t.profile_name; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_retrieval_profile_t.profile_name IS 'Profile Name value for this knowledge retrieval profile record.';


--
-- Name: COLUMN knowledge_retrieval_profile_t.strategy; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_retrieval_profile_t.strategy IS 'Strategy value for this knowledge retrieval profile record.';


--
-- Name: COLUMN knowledge_retrieval_profile_t.lexical_candidates; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_retrieval_profile_t.lexical_candidates IS 'Lexical Candidates value for this knowledge retrieval profile record.';


--
-- Name: COLUMN knowledge_retrieval_profile_t.vector_candidates; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_retrieval_profile_t.vector_candidates IS 'Vector Candidates value for this knowledge retrieval profile record.';


--
-- Name: COLUMN knowledge_retrieval_profile_t.top_k; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_retrieval_profile_t.top_k IS 'Top K value for this knowledge retrieval profile record.';


--
-- Name: COLUMN knowledge_retrieval_profile_t.token_budget; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_retrieval_profile_t.token_budget IS 'Token Budget value for this knowledge retrieval profile record.';


--
-- Name: COLUMN knowledge_retrieval_profile_t.fusion_method; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_retrieval_profile_t.fusion_method IS 'Fusion Method value for this knowledge retrieval profile record.';


--
-- Name: COLUMN knowledge_retrieval_profile_t.operational_failure_policy; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_retrieval_profile_t.operational_failure_policy IS 'Operational Failure Policy value for this knowledge retrieval profile record.';


--
-- Name: COLUMN knowledge_retrieval_profile_t.graph_policy; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_retrieval_profile_t.graph_policy IS 'Graph Policy value for this knowledge retrieval profile record.';


--
-- Name: COLUMN knowledge_retrieval_profile_t.version; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_retrieval_profile_t.version IS 'Version value for version.';


--
-- Name: COLUMN knowledge_retrieval_profile_t.active; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_retrieval_profile_t.active IS 'Indicates whether this record is active.';


--
-- Name: COLUMN knowledge_retrieval_profile_t.update_ts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_retrieval_profile_t.update_ts IS 'Timestamp when this record was last updated.';


--
-- Name: COLUMN knowledge_retrieval_profile_t.update_user; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_retrieval_profile_t.update_user IS 'User or service principal that last updated this record.';


--
-- Name: COLUMN knowledge_retrieval_profile_t.maximum_knowledge_bases; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_retrieval_profile_t.maximum_knowledge_bases IS 'Maximum Knowledge Bases value for this knowledge retrieval profile record.';


--
-- Name: COLUMN knowledge_retrieval_profile_t.lexical_evidence_required; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_retrieval_profile_t.lexical_evidence_required IS 'Lexical Evidence Required value for this knowledge retrieval profile record.';


--
-- Name: COLUMN knowledge_retrieval_profile_t.segment_candidate_multiplier; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_retrieval_profile_t.segment_candidate_multiplier IS 'Segment Candidate Multiplier value for this knowledge retrieval profile record.';


--
-- Name: COLUMN knowledge_retrieval_profile_t.context_expansion_before; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_retrieval_profile_t.context_expansion_before IS 'Context Expansion Before value for this knowledge retrieval profile record.';


--
-- Name: COLUMN knowledge_retrieval_profile_t.context_expansion_after; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_retrieval_profile_t.context_expansion_after IS 'Context Expansion After value for this knowledge retrieval profile record.';


--
-- Name: knowledge_runtime_authorization_t; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.knowledge_runtime_authorization_t (
    knowledge_base_id uuid NOT NULL,
    consumer_host_id uuid NOT NULL,
    environment character varying(32) NOT NULL,
    agent_id uuid NOT NULL,
    retrieval_profile_id uuid NOT NULL,
    qualified_strategies jsonb DEFAULT '["HYBRID"]'::jsonb NOT NULL,
    active boolean DEFAULT true NOT NULL,
    desired_event_sequence bigint NOT NULL,
    applied_event_sequence bigint NOT NULL,
    projector_id character varying(255) NOT NULL,
    lease_expires_ts timestamp with time zone NOT NULL,
    authorization_digest character(64) NOT NULL,
    update_ts timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT knowledge_runtime_authorization_t_applied_event_sequence_check CHECK ((applied_event_sequence >= 0)),
    CONSTRAINT knowledge_runtime_authorization_t_authorization_digest_check CHECK ((authorization_digest ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT knowledge_runtime_authorization_t_check CHECK ((applied_event_sequence <= desired_event_sequence)),
    CONSTRAINT knowledge_runtime_authorization_t_desired_event_sequence_check CHECK ((desired_event_sequence >= 0)),
    CONSTRAINT knowledge_runtime_authorization_t_environment_check CHECK ((length((environment)::text) > 0)),
    CONSTRAINT knowledge_runtime_authorization_t_qualified_strategies_check CHECK ((jsonb_typeof(qualified_strategies) = 'array'::text))
);


--
-- Name: TABLE knowledge_runtime_authorization_t; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.knowledge_runtime_authorization_t IS 'Stores knowledge runtime authorization records used by the Light Knowledge ingestion, retrieval, indexing, and operations services.';


--
-- Name: COLUMN knowledge_runtime_authorization_t.knowledge_base_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_runtime_authorization_t.knowledge_base_id IS 'Identifier for the related knowledge base.';


--
-- Name: COLUMN knowledge_runtime_authorization_t.consumer_host_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_runtime_authorization_t.consumer_host_id IS 'Identifier for the related consumer host.';


--
-- Name: COLUMN knowledge_runtime_authorization_t.environment; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_runtime_authorization_t.environment IS 'Environment value for this knowledge runtime authorization record.';


--
-- Name: COLUMN knowledge_runtime_authorization_t.agent_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_runtime_authorization_t.agent_id IS 'Identifier for the related agent.';


--
-- Name: COLUMN knowledge_runtime_authorization_t.retrieval_profile_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_runtime_authorization_t.retrieval_profile_id IS 'Identifier for the related retrieval profile.';


--
-- Name: COLUMN knowledge_runtime_authorization_t.qualified_strategies; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_runtime_authorization_t.qualified_strategies IS 'Qualified Strategies value for this knowledge runtime authorization record.';


--
-- Name: COLUMN knowledge_runtime_authorization_t.active; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_runtime_authorization_t.active IS 'Indicates whether this record is active.';


--
-- Name: COLUMN knowledge_runtime_authorization_t.desired_event_sequence; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_runtime_authorization_t.desired_event_sequence IS 'Desired Event Sequence value for this knowledge runtime authorization record.';


--
-- Name: COLUMN knowledge_runtime_authorization_t.applied_event_sequence; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_runtime_authorization_t.applied_event_sequence IS 'Applied Event Sequence value for this knowledge runtime authorization record.';


--
-- Name: COLUMN knowledge_runtime_authorization_t.projector_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_runtime_authorization_t.projector_id IS 'Identifier for the related projector.';


--
-- Name: COLUMN knowledge_runtime_authorization_t.lease_expires_ts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_runtime_authorization_t.lease_expires_ts IS 'Timestamp for the lease expires event or state.';


--
-- Name: COLUMN knowledge_runtime_authorization_t.authorization_digest; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_runtime_authorization_t.authorization_digest IS 'Integrity digest for authorization.';


--
-- Name: COLUMN knowledge_runtime_authorization_t.update_ts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_runtime_authorization_t.update_ts IS 'Timestamp when this record was last updated.';


--
-- Name: knowledge_segment_chunk_t; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.knowledge_segment_chunk_t (
    index_segment_id uuid NOT NULL,
    chunk_id uuid NOT NULL,
    knowledge_base_id uuid NOT NULL,
    acl_revision_id uuid NOT NULL
);


--
-- Name: TABLE knowledge_segment_chunk_t; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.knowledge_segment_chunk_t IS 'Stores knowledge segment chunk records used by the Light Knowledge ingestion, retrieval, indexing, and operations services.';


--
-- Name: COLUMN knowledge_segment_chunk_t.index_segment_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_segment_chunk_t.index_segment_id IS 'Identifier for the related index segment.';


--
-- Name: COLUMN knowledge_segment_chunk_t.chunk_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_segment_chunk_t.chunk_id IS 'Identifier for the related chunk.';


--
-- Name: COLUMN knowledge_segment_chunk_t.knowledge_base_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_segment_chunk_t.knowledge_base_id IS 'Identifier for the related knowledge base.';


--
-- Name: COLUMN knowledge_segment_chunk_t.acl_revision_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_segment_chunk_t.acl_revision_id IS 'Identifier for the related acl revision.';


--
-- Name: knowledge_segment_document_t; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.knowledge_segment_document_t (
    index_segment_id uuid NOT NULL,
    document_id uuid NOT NULL,
    knowledge_base_id uuid NOT NULL,
    document_version_id uuid NOT NULL,
    acl_revision_id uuid NOT NULL
);


--
-- Name: TABLE knowledge_segment_document_t; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.knowledge_segment_document_t IS 'Stores knowledge segment document records used by the Light Knowledge ingestion, retrieval, indexing, and operations services.';


--
-- Name: COLUMN knowledge_segment_document_t.index_segment_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_segment_document_t.index_segment_id IS 'Identifier for the related index segment.';


--
-- Name: COLUMN knowledge_segment_document_t.document_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_segment_document_t.document_id IS 'Identifier for the related document.';


--
-- Name: COLUMN knowledge_segment_document_t.knowledge_base_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_segment_document_t.knowledge_base_id IS 'Identifier for the related knowledge base.';


--
-- Name: COLUMN knowledge_segment_document_t.document_version_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_segment_document_t.document_version_id IS 'Identifier for the related document version.';


--
-- Name: COLUMN knowledge_segment_document_t.acl_revision_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_segment_document_t.acl_revision_id IS 'Identifier for the related acl revision.';


--
-- Name: knowledge_segment_operation_t; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.knowledge_segment_operation_t (
    index_segment_id uuid NOT NULL,
    operation_ordinal bigint NOT NULL,
    operation_id uuid NOT NULL,
    knowledge_base_id uuid NOT NULL,
    operation_kind character varying(24) NOT NULL,
    document_id uuid NOT NULL,
    document_version_id uuid,
    chunk_id uuid,
    passage_anchor_id uuid,
    acl_revision_id uuid,
    operation_digest character(64) NOT NULL,
    CONSTRAINT knowledge_segment_operation_t_check CHECK ((((operation_kind)::text <> 'ACTIVATE_CHUNK'::text) OR (chunk_id IS NOT NULL))),
    CONSTRAINT knowledge_segment_operation_t_check1 CHECK ((((operation_kind)::text <> 'SET_ACL_REVISION'::text) OR (acl_revision_id IS NOT NULL))),
    CONSTRAINT knowledge_segment_operation_t_operation_digest_check CHECK ((operation_digest ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT knowledge_segment_operation_t_operation_kind_check CHECK (((operation_kind)::text = ANY (ARRAY[('ACTIVATE_DOCUMENT'::character varying)::text, ('SUPERSEDE_DOCUMENT'::character varying)::text, ('TOMBSTONE_DOCUMENT'::character varying)::text, ('ACTIVATE_CHUNK'::character varying)::text, ('TOMBSTONE_CHUNK'::character varying)::text, ('SET_ACL_REVISION'::character varying)::text]))),
    CONSTRAINT knowledge_segment_operation_t_operation_ordinal_check CHECK ((operation_ordinal >= 0))
);


--
-- Name: TABLE knowledge_segment_operation_t; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.knowledge_segment_operation_t IS 'Stores knowledge segment operation records used by the Light Knowledge ingestion, retrieval, indexing, and operations services.';


--
-- Name: COLUMN knowledge_segment_operation_t.index_segment_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_segment_operation_t.index_segment_id IS 'Identifier for the related index segment.';


--
-- Name: COLUMN knowledge_segment_operation_t.operation_ordinal; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_segment_operation_t.operation_ordinal IS 'Operation Ordinal value for this knowledge segment operation record.';


--
-- Name: COLUMN knowledge_segment_operation_t.operation_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_segment_operation_t.operation_id IS 'Identifier for the related operation.';


--
-- Name: COLUMN knowledge_segment_operation_t.knowledge_base_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_segment_operation_t.knowledge_base_id IS 'Identifier for the related knowledge base.';


--
-- Name: COLUMN knowledge_segment_operation_t.operation_kind; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_segment_operation_t.operation_kind IS 'Operation Kind value for this knowledge segment operation record.';


--
-- Name: COLUMN knowledge_segment_operation_t.document_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_segment_operation_t.document_id IS 'Identifier for the related document.';


--
-- Name: COLUMN knowledge_segment_operation_t.document_version_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_segment_operation_t.document_version_id IS 'Identifier for the related document version.';


--
-- Name: COLUMN knowledge_segment_operation_t.chunk_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_segment_operation_t.chunk_id IS 'Identifier for the related chunk.';


--
-- Name: COLUMN knowledge_segment_operation_t.passage_anchor_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_segment_operation_t.passage_anchor_id IS 'Identifier for the related passage anchor.';


--
-- Name: COLUMN knowledge_segment_operation_t.acl_revision_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_segment_operation_t.acl_revision_id IS 'Identifier for the related acl revision.';


--
-- Name: COLUMN knowledge_segment_operation_t.operation_digest; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_segment_operation_t.operation_digest IS 'Integrity digest for operation.';


--
-- Name: knowledge_segment_vector_t; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.knowledge_segment_vector_t (
    index_segment_id uuid NOT NULL,
    chunk_id uuid NOT NULL,
    embedding_artifact_id uuid NOT NULL,
    knowledge_base_id uuid NOT NULL,
    projection public.vector NOT NULL,
    dimension integer NOT NULL,
    CONSTRAINT knowledge_segment_vector_t_check CHECK ((public.vector_dims(projection) = dimension)),
    CONSTRAINT knowledge_segment_vector_t_dimension_check CHECK ((dimension > 0))
);


--
-- Name: TABLE knowledge_segment_vector_t; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.knowledge_segment_vector_t IS 'Stores knowledge segment vector records used by the Light Knowledge ingestion, retrieval, indexing, and operations services.';


--
-- Name: COLUMN knowledge_segment_vector_t.index_segment_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_segment_vector_t.index_segment_id IS 'Identifier for the related index segment.';


--
-- Name: COLUMN knowledge_segment_vector_t.chunk_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_segment_vector_t.chunk_id IS 'Identifier for the related chunk.';


--
-- Name: COLUMN knowledge_segment_vector_t.embedding_artifact_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_segment_vector_t.embedding_artifact_id IS 'Identifier for the related embedding artifact.';


--
-- Name: COLUMN knowledge_segment_vector_t.knowledge_base_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_segment_vector_t.knowledge_base_id IS 'Identifier for the related knowledge base.';


--
-- Name: COLUMN knowledge_segment_vector_t.projection; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_segment_vector_t.projection IS 'Projection value for this knowledge segment vector record.';


--
-- Name: COLUMN knowledge_segment_vector_t.dimension; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_segment_vector_t.dimension IS 'Dimension value for this knowledge segment vector record.';


--
-- Name: knowledge_source_acl_state_t; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.knowledge_source_acl_state_t (
    source_id uuid NOT NULL,
    knowledge_base_id uuid NOT NULL,
    reconciliation_id uuid,
    state character varying(16) NOT NULL,
    discovered_object_count bigint DEFAULT 0 NOT NULL,
    covered_object_count bigint DEFAULT 0 NOT NULL,
    denied_object_count bigint DEFAULT 0 NOT NULL,
    unresolved_subject_count bigint DEFAULT 0 NOT NULL,
    observed_ts timestamp with time zone,
    fresh_until_ts timestamp with time zone,
    evidence_digest character(64),
    update_ts timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT knowledge_source_acl_state_t_check CHECK ((((state)::text <> 'COMPLETE'::text) OR ((reconciliation_id IS NOT NULL) AND (observed_ts IS NOT NULL) AND (fresh_until_ts IS NOT NULL) AND (fresh_until_ts > observed_ts) AND (fresh_until_ts <= (observed_ts + '00:15:00'::interval)) AND (covered_object_count = discovered_object_count) AND (unresolved_subject_count = 0)))),
    CONSTRAINT knowledge_source_acl_state_t_covered_object_count_check CHECK ((covered_object_count >= 0)),
    CONSTRAINT knowledge_source_acl_state_t_denied_object_count_check CHECK ((denied_object_count >= 0)),
    CONSTRAINT knowledge_source_acl_state_t_discovered_object_count_check CHECK ((discovered_object_count >= 0)),
    CONSTRAINT knowledge_source_acl_state_t_evidence_digest_check CHECK (((evidence_digest IS NULL) OR (evidence_digest ~ '^[a-f0-9]{64}$'::text))),
    CONSTRAINT knowledge_source_acl_state_t_state_check CHECK (((state)::text = ANY (ARRAY[('PENDING'::character varying)::text, ('RECONCILING'::character varying)::text, ('COMPLETE'::character varying)::text, ('STALE'::character varying)::text, ('INCOMPLETE'::character varying)::text]))),
    CONSTRAINT knowledge_source_acl_state_t_unresolved_subject_count_check CHECK ((unresolved_subject_count >= 0))
);


--
-- Name: TABLE knowledge_source_acl_state_t; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.knowledge_source_acl_state_t IS 'Stores knowledge source acl state records used by the Light Knowledge ingestion, retrieval, indexing, and operations services.';


--
-- Name: COLUMN knowledge_source_acl_state_t.source_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_source_acl_state_t.source_id IS 'Identifier for the related source.';


--
-- Name: COLUMN knowledge_source_acl_state_t.knowledge_base_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_source_acl_state_t.knowledge_base_id IS 'Identifier for the related knowledge base.';


--
-- Name: COLUMN knowledge_source_acl_state_t.reconciliation_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_source_acl_state_t.reconciliation_id IS 'Identifier for the related reconciliation.';


--
-- Name: COLUMN knowledge_source_acl_state_t.state; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_source_acl_state_t.state IS 'State value for this knowledge source acl state record.';


--
-- Name: COLUMN knowledge_source_acl_state_t.discovered_object_count; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_source_acl_state_t.discovered_object_count IS 'Count of discovered object.';


--
-- Name: COLUMN knowledge_source_acl_state_t.covered_object_count; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_source_acl_state_t.covered_object_count IS 'Count of covered object.';


--
-- Name: COLUMN knowledge_source_acl_state_t.denied_object_count; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_source_acl_state_t.denied_object_count IS 'Count of denied object.';


--
-- Name: COLUMN knowledge_source_acl_state_t.unresolved_subject_count; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_source_acl_state_t.unresolved_subject_count IS 'Count of unresolved subject.';


--
-- Name: COLUMN knowledge_source_acl_state_t.observed_ts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_source_acl_state_t.observed_ts IS 'Timestamp for the observed event or state.';


--
-- Name: COLUMN knowledge_source_acl_state_t.fresh_until_ts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_source_acl_state_t.fresh_until_ts IS 'Timestamp for the fresh until event or state.';


--
-- Name: COLUMN knowledge_source_acl_state_t.evidence_digest; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_source_acl_state_t.evidence_digest IS 'Integrity digest for evidence.';


--
-- Name: COLUMN knowledge_source_acl_state_t.update_ts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_source_acl_state_t.update_ts IS 'Timestamp when this record was last updated.';


--
-- Name: knowledge_source_change_t; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.knowledge_source_change_t (
    source_change_id uuid NOT NULL,
    sync_run_id uuid NOT NULL,
    knowledge_base_id uuid NOT NULL,
    source_id uuid NOT NULL,
    source_object_id character varying(1024) NOT NULL,
    change_sequence bigint NOT NULL,
    change_kind character varying(16) NOT NULL,
    previous_document_version_id uuid,
    selected_document_version_id uuid,
    selected_acl_revision_id uuid,
    input_contract_digest character(64) NOT NULL,
    change_digest character(64) NOT NULL,
    observed_ts timestamp with time zone NOT NULL,
    CONSTRAINT knowledge_source_change_t_change_digest_check CHECK ((change_digest ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT knowledge_source_change_t_change_kind_check CHECK (((change_kind)::text = ANY (ARRAY[('ADD'::character varying)::text, ('MODIFY'::character varying)::text, ('DELETE'::character varying)::text, ('ACL_ONLY'::character varying)::text, ('METADATA_ONLY'::character varying)::text]))),
    CONSTRAINT knowledge_source_change_t_change_sequence_check CHECK ((change_sequence > 0)),
    CONSTRAINT knowledge_source_change_t_input_contract_digest_check CHECK ((input_contract_digest ~ '^[a-f0-9]{64}$'::text))
);


--
-- Name: TABLE knowledge_source_change_t; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.knowledge_source_change_t IS 'Stores knowledge source change records used by the Light Knowledge ingestion, retrieval, indexing, and operations services.';


--
-- Name: COLUMN knowledge_source_change_t.source_change_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_source_change_t.source_change_id IS 'Identifier for the related source change.';


--
-- Name: COLUMN knowledge_source_change_t.sync_run_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_source_change_t.sync_run_id IS 'Identifier for the related sync run.';


--
-- Name: COLUMN knowledge_source_change_t.knowledge_base_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_source_change_t.knowledge_base_id IS 'Identifier for the related knowledge base.';


--
-- Name: COLUMN knowledge_source_change_t.source_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_source_change_t.source_id IS 'Identifier for the related source.';


--
-- Name: COLUMN knowledge_source_change_t.source_object_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_source_change_t.source_object_id IS 'Identifier for the related source object.';


--
-- Name: COLUMN knowledge_source_change_t.change_sequence; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_source_change_t.change_sequence IS 'Change Sequence value for this knowledge source change record.';


--
-- Name: COLUMN knowledge_source_change_t.change_kind; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_source_change_t.change_kind IS 'Change Kind value for this knowledge source change record.';


--
-- Name: COLUMN knowledge_source_change_t.previous_document_version_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_source_change_t.previous_document_version_id IS 'Identifier for the related previous document version.';


--
-- Name: COLUMN knowledge_source_change_t.selected_document_version_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_source_change_t.selected_document_version_id IS 'Identifier for the related selected document version.';


--
-- Name: COLUMN knowledge_source_change_t.selected_acl_revision_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_source_change_t.selected_acl_revision_id IS 'Identifier for the related selected acl revision.';


--
-- Name: COLUMN knowledge_source_change_t.input_contract_digest; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_source_change_t.input_contract_digest IS 'Integrity digest for input contract.';


--
-- Name: COLUMN knowledge_source_change_t.change_digest; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_source_change_t.change_digest IS 'Integrity digest for change.';


--
-- Name: COLUMN knowledge_source_change_t.observed_ts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_source_change_t.observed_ts IS 'Timestamp for the observed event or state.';


--
-- Name: knowledge_source_cursor_t; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.knowledge_source_cursor_t (
    source_id uuid NOT NULL,
    knowledge_base_id uuid NOT NULL,
    opaque_cursor text,
    source_watermark bigint DEFAULT 0 NOT NULL,
    last_full_reconciliation_ts timestamp with time zone,
    cursor_digest character(64),
    update_ts timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT knowledge_source_cursor_t_cursor_digest_check CHECK (((cursor_digest IS NULL) OR (cursor_digest ~ '^[a-f0-9]{64}$'::text))),
    CONSTRAINT knowledge_source_cursor_t_source_watermark_check CHECK ((source_watermark >= 0))
);


--
-- Name: TABLE knowledge_source_cursor_t; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.knowledge_source_cursor_t IS 'Stores knowledge source cursor records used by the Light Knowledge ingestion, retrieval, indexing, and operations services.';


--
-- Name: COLUMN knowledge_source_cursor_t.source_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_source_cursor_t.source_id IS 'Identifier for the related source.';


--
-- Name: COLUMN knowledge_source_cursor_t.knowledge_base_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_source_cursor_t.knowledge_base_id IS 'Identifier for the related knowledge base.';


--
-- Name: COLUMN knowledge_source_cursor_t.opaque_cursor; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_source_cursor_t.opaque_cursor IS 'Opaque Cursor value for this knowledge source cursor record.';


--
-- Name: COLUMN knowledge_source_cursor_t.source_watermark; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_source_cursor_t.source_watermark IS 'Source Watermark value for this knowledge source cursor record.';


--
-- Name: COLUMN knowledge_source_cursor_t.last_full_reconciliation_ts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_source_cursor_t.last_full_reconciliation_ts IS 'Timestamp for the last full reconciliation event or state.';


--
-- Name: COLUMN knowledge_source_cursor_t.cursor_digest; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_source_cursor_t.cursor_digest IS 'Integrity digest for cursor.';


--
-- Name: COLUMN knowledge_source_cursor_t.update_ts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_source_cursor_t.update_ts IS 'Timestamp when this record was last updated.';


--
-- Name: knowledge_source_t; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.knowledge_source_t (
    source_id uuid NOT NULL,
    knowledge_base_id uuid NOT NULL,
    source_type character varying(32) NOT NULL,
    display_name character varying(255) NOT NULL,
    config_json jsonb DEFAULT '{}'::jsonb NOT NULL,
    secret_reference character varying(1024),
    status character varying(24) DEFAULT 'DRAFT'::character varying NOT NULL,
    acl_mode character varying(24) DEFAULT 'UNIFORM_SCOPE'::character varying NOT NULL,
    source_trust_tier character varying(32) DEFAULT 'UNREVIEWED'::character varying NOT NULL,
    approval_policy jsonb DEFAULT '{}'::jsonb NOT NULL,
    schedule jsonb DEFAULT '{}'::jsonb NOT NULL,
    acl_reconciliation_policy jsonb DEFAULT '{}'::jsonb NOT NULL,
    ingestion_policy_id uuid NOT NULL,
    version bigint DEFAULT 1 NOT NULL,
    update_ts timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    update_user character varying(126) DEFAULT SESSION_USER NOT NULL,
    CONSTRAINT knowledge_source_t_acl_mode_check CHECK (((acl_mode)::text = ANY (ARRAY[('UNIFORM_SCOPE'::character varying)::text, ('MIRROR_SOURCE_ACL'::character varying)::text]))),
    CONSTRAINT knowledge_source_t_acl_reconciliation_policy_check CHECK ((jsonb_typeof(acl_reconciliation_policy) = 'object'::text)),
    CONSTRAINT knowledge_source_t_approval_policy_check CHECK ((jsonb_typeof(approval_policy) = 'object'::text)),
    CONSTRAINT knowledge_source_t_config_json_check CHECK ((jsonb_typeof(config_json) = 'object'::text)),
    CONSTRAINT knowledge_source_t_schedule_check CHECK ((jsonb_typeof(schedule) = 'object'::text)),
    CONSTRAINT knowledge_source_t_source_type_check CHECK (((source_type)::text = ANY (ARRAY[('GIT_MARKDOWN'::character varying)::text, ('UPLOAD'::character varying)::text, ('CONFLUENCE'::character varying)::text, ('SHAREPOINT'::character varying)::text]))),
    CONSTRAINT knowledge_source_t_status_check CHECK (((status)::text = ANY (ARRAY[('DRAFT'::character varying)::text, ('ACTIVE'::character varying)::text, ('INACTIVE'::character varying)::text, ('DELETING'::character varying)::text, ('DELETED'::character varying)::text]))),
    CONSTRAINT knowledge_source_t_version_check CHECK ((version > 0))
);


--
-- Name: TABLE knowledge_source_t; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.knowledge_source_t IS 'Stores knowledge source records used by the Light Knowledge ingestion, retrieval, indexing, and operations services.';


--
-- Name: COLUMN knowledge_source_t.source_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_source_t.source_id IS 'Identifier for the related source.';


--
-- Name: COLUMN knowledge_source_t.knowledge_base_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_source_t.knowledge_base_id IS 'Identifier for the related knowledge base.';


--
-- Name: COLUMN knowledge_source_t.source_type; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_source_t.source_type IS 'Source Type value for this knowledge source record.';


--
-- Name: COLUMN knowledge_source_t.display_name; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_source_t.display_name IS 'Display Name value for this knowledge source record.';


--
-- Name: COLUMN knowledge_source_t.config_json; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_source_t.config_json IS 'Config Json value for this knowledge source record.';


--
-- Name: COLUMN knowledge_source_t.secret_reference; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_source_t.secret_reference IS 'Secret Reference value for this knowledge source record.';


--
-- Name: COLUMN knowledge_source_t.status; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_source_t.status IS 'Status value for this knowledge source record.';


--
-- Name: COLUMN knowledge_source_t.acl_mode; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_source_t.acl_mode IS 'Acl Mode value for this knowledge source record.';


--
-- Name: COLUMN knowledge_source_t.source_trust_tier; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_source_t.source_trust_tier IS 'Source Trust Tier value for this knowledge source record.';


--
-- Name: COLUMN knowledge_source_t.approval_policy; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_source_t.approval_policy IS 'Approval Policy value for this knowledge source record.';


--
-- Name: COLUMN knowledge_source_t.schedule; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_source_t.schedule IS 'Schedule value for this knowledge source record.';


--
-- Name: COLUMN knowledge_source_t.acl_reconciliation_policy; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_source_t.acl_reconciliation_policy IS 'Acl Reconciliation Policy value for this knowledge source record.';


--
-- Name: COLUMN knowledge_source_t.ingestion_policy_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_source_t.ingestion_policy_id IS 'Identifier for the related ingestion policy.';


--
-- Name: COLUMN knowledge_source_t.version; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_source_t.version IS 'Version value for version.';


--
-- Name: COLUMN knowledge_source_t.update_ts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_source_t.update_ts IS 'Timestamp when this record was last updated.';


--
-- Name: COLUMN knowledge_source_t.update_user; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_source_t.update_user IS 'User or service principal that last updated this record.';


--
-- Name: knowledge_subject_mapping_t; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.knowledge_subject_mapping_t (
    subject_mapping_id uuid NOT NULL,
    host_id uuid,
    source_id uuid NOT NULL,
    provider_subject_type character varying(32) NOT NULL,
    provider_subject_id character varying(1024) NOT NULL,
    normalized_subject_type character varying(16) NOT NULL,
    normalized_subject_id character varying(1024),
    mapping_state character varying(16) NOT NULL,
    evidence_digest character(64) NOT NULL,
    valid_from_ts timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    valid_until_ts timestamp with time zone,
    update_user character varying(255) NOT NULL,
    CONSTRAINT knowledge_subject_mapping_t_check CHECK ((((mapping_state)::text = 'APPROVED'::text) = (normalized_subject_id IS NOT NULL))),
    CONSTRAINT knowledge_subject_mapping_t_evidence_digest_check CHECK ((evidence_digest ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT knowledge_subject_mapping_t_mapping_state_check CHECK (((mapping_state)::text = ANY (ARRAY[('APPROVED'::character varying)::text, ('REVOKED'::character varying)::text, ('AMBIGUOUS'::character varying)::text, ('UNRESOLVED'::character varying)::text]))),
    CONSTRAINT knowledge_subject_mapping_t_normalized_subject_type_check CHECK (((normalized_subject_type)::text = ANY (ARRAY[('USER'::character varying)::text, ('GROUP'::character varying)::text, ('ORGANIZATION'::character varying)::text, ('EVERYONE'::character varying)::text, ('UNRESOLVED'::character varying)::text])))
);


--
-- Name: TABLE knowledge_subject_mapping_t; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.knowledge_subject_mapping_t IS 'Stores knowledge subject mapping records used by the Light Knowledge ingestion, retrieval, indexing, and operations services.';


--
-- Name: COLUMN knowledge_subject_mapping_t.subject_mapping_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_subject_mapping_t.subject_mapping_id IS 'Identifier for the related subject mapping.';


--
-- Name: COLUMN knowledge_subject_mapping_t.host_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_subject_mapping_t.host_id IS 'Tenant host identifier that scopes this record.';


--
-- Name: COLUMN knowledge_subject_mapping_t.source_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_subject_mapping_t.source_id IS 'Identifier for the related source.';


--
-- Name: COLUMN knowledge_subject_mapping_t.provider_subject_type; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_subject_mapping_t.provider_subject_type IS 'Provider Subject Type value for this knowledge subject mapping record.';


--
-- Name: COLUMN knowledge_subject_mapping_t.provider_subject_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_subject_mapping_t.provider_subject_id IS 'Identifier for the related provider subject.';


--
-- Name: COLUMN knowledge_subject_mapping_t.normalized_subject_type; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_subject_mapping_t.normalized_subject_type IS 'Normalized Subject Type value for this knowledge subject mapping record.';


--
-- Name: COLUMN knowledge_subject_mapping_t.normalized_subject_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_subject_mapping_t.normalized_subject_id IS 'Identifier for the related normalized subject.';


--
-- Name: COLUMN knowledge_subject_mapping_t.mapping_state; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_subject_mapping_t.mapping_state IS 'Mapping State value for this knowledge subject mapping record.';


--
-- Name: COLUMN knowledge_subject_mapping_t.evidence_digest; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_subject_mapping_t.evidence_digest IS 'Integrity digest for evidence.';


--
-- Name: COLUMN knowledge_subject_mapping_t.valid_from_ts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_subject_mapping_t.valid_from_ts IS 'Timestamp for the valid from event or state.';


--
-- Name: COLUMN knowledge_subject_mapping_t.valid_until_ts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_subject_mapping_t.valid_until_ts IS 'Timestamp for the valid until event or state.';


--
-- Name: COLUMN knowledge_subject_mapping_t.update_user; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_subject_mapping_t.update_user IS 'User or service principal that last updated this record.';


--
-- Name: knowledge_sync_run_t; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.knowledge_sync_run_t (
    sync_run_id uuid NOT NULL,
    knowledge_base_id uuid NOT NULL,
    source_id uuid NOT NULL,
    requested_by character varying(255) NOT NULL,
    requested_ts timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    start_watermark bigint DEFAULT 0 NOT NULL,
    snapshot_watermark bigint,
    state character varying(20) DEFAULT 'ACCEPTED'::character varying NOT NULL,
    document_count bigint DEFAULT 0 NOT NULL,
    chunk_count bigint DEFAULT 0 NOT NULL,
    source_bytes bigint DEFAULT 0 NOT NULL,
    embedding_tokens bigint DEFAULT 0 NOT NULL,
    stored_bytes bigint DEFAULT 0 NOT NULL,
    finished_ts timestamp with time zone,
    error_summary jsonb,
    job_id uuid,
    request_event_id uuid,
    index_generation_id uuid,
    ingestion_policy_id uuid,
    ingestion_policy_version bigint,
    phase character varying(32) DEFAULT 'ACCEPTED'::character varying NOT NULL,
    progress jsonb DEFAULT '{}'::jsonb NOT NULL,
    attempt_count integer DEFAULT 0 NOT NULL,
    next_attempt_ts timestamp with time zone,
    update_ts timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT knowledge_sync_run_snapshot_watermark_v2_ck CHECK (((snapshot_watermark IS NULL) OR (snapshot_watermark >= 0))),
    CONSTRAINT knowledge_sync_run_state_v2_ck CHECK (((state)::text = ANY (ARRAY[('ACCEPTED'::character varying)::text, ('QUEUED'::character varying)::text, ('RUNNING'::character varying)::text, ('SUCCEEDED'::character varying)::text, ('FAILED'::character varying)::text, ('PAUSED_BUDGET'::character varying)::text, ('FAILED_BUDGET'::character varying)::text, ('CANCELLED'::character varying)::text]))),
    CONSTRAINT knowledge_sync_run_t_attempt_count_check CHECK ((attempt_count >= 0)),
    CONSTRAINT knowledge_sync_run_t_chunk_count_check CHECK ((chunk_count >= 0)),
    CONSTRAINT knowledge_sync_run_t_document_count_check CHECK ((document_count >= 0)),
    CONSTRAINT knowledge_sync_run_t_embedding_tokens_check CHECK ((embedding_tokens >= 0)),
    CONSTRAINT knowledge_sync_run_t_error_summary_check CHECK (((error_summary IS NULL) OR (jsonb_typeof(error_summary) = 'object'::text))),
    CONSTRAINT knowledge_sync_run_t_progress_check CHECK ((jsonb_typeof(progress) = 'object'::text)),
    CONSTRAINT knowledge_sync_run_t_source_bytes_check CHECK ((source_bytes >= 0)),
    CONSTRAINT knowledge_sync_run_t_start_watermark_check CHECK ((start_watermark >= 0)),
    CONSTRAINT knowledge_sync_run_t_stored_bytes_check CHECK ((stored_bytes >= 0))
);


--
-- Name: TABLE knowledge_sync_run_t; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.knowledge_sync_run_t IS 'Stores knowledge sync run records used by the Light Knowledge ingestion, retrieval, indexing, and operations services.';


--
-- Name: COLUMN knowledge_sync_run_t.sync_run_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_sync_run_t.sync_run_id IS 'Identifier for the related sync run.';


--
-- Name: COLUMN knowledge_sync_run_t.knowledge_base_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_sync_run_t.knowledge_base_id IS 'Identifier for the related knowledge base.';


--
-- Name: COLUMN knowledge_sync_run_t.source_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_sync_run_t.source_id IS 'Identifier for the related source.';


--
-- Name: COLUMN knowledge_sync_run_t.requested_by; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_sync_run_t.requested_by IS 'Requested By value for this knowledge sync run record.';


--
-- Name: COLUMN knowledge_sync_run_t.requested_ts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_sync_run_t.requested_ts IS 'Timestamp for the requested event or state.';


--
-- Name: COLUMN knowledge_sync_run_t.start_watermark; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_sync_run_t.start_watermark IS 'Start Watermark value for this knowledge sync run record.';


--
-- Name: COLUMN knowledge_sync_run_t.snapshot_watermark; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_sync_run_t.snapshot_watermark IS 'Snapshot Watermark value for this knowledge sync run record.';


--
-- Name: COLUMN knowledge_sync_run_t.state; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_sync_run_t.state IS 'State value for this knowledge sync run record.';


--
-- Name: COLUMN knowledge_sync_run_t.document_count; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_sync_run_t.document_count IS 'Count of document.';


--
-- Name: COLUMN knowledge_sync_run_t.chunk_count; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_sync_run_t.chunk_count IS 'Count of chunk.';


--
-- Name: COLUMN knowledge_sync_run_t.source_bytes; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_sync_run_t.source_bytes IS 'Source Bytes value for this knowledge sync run record.';


--
-- Name: COLUMN knowledge_sync_run_t.embedding_tokens; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_sync_run_t.embedding_tokens IS 'Embedding Tokens value for this knowledge sync run record.';


--
-- Name: COLUMN knowledge_sync_run_t.stored_bytes; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_sync_run_t.stored_bytes IS 'Stored Bytes value for this knowledge sync run record.';


--
-- Name: COLUMN knowledge_sync_run_t.finished_ts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_sync_run_t.finished_ts IS 'Timestamp for the finished event or state.';


--
-- Name: COLUMN knowledge_sync_run_t.error_summary; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_sync_run_t.error_summary IS 'Error Summary value for this knowledge sync run record.';


--
-- Name: COLUMN knowledge_sync_run_t.job_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_sync_run_t.job_id IS 'Identifier for the related job.';


--
-- Name: COLUMN knowledge_sync_run_t.request_event_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_sync_run_t.request_event_id IS 'Identifier for the related request event.';


--
-- Name: COLUMN knowledge_sync_run_t.index_generation_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_sync_run_t.index_generation_id IS 'Identifier for the related index generation.';


--
-- Name: COLUMN knowledge_sync_run_t.ingestion_policy_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_sync_run_t.ingestion_policy_id IS 'Identifier for the related ingestion policy.';


--
-- Name: COLUMN knowledge_sync_run_t.ingestion_policy_version; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_sync_run_t.ingestion_policy_version IS 'Version value for ingestion policy.';


--
-- Name: COLUMN knowledge_sync_run_t.phase; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_sync_run_t.phase IS 'Phase value for this knowledge sync run record.';


--
-- Name: COLUMN knowledge_sync_run_t.progress; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_sync_run_t.progress IS 'Progress value for this knowledge sync run record.';


--
-- Name: COLUMN knowledge_sync_run_t.attempt_count; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_sync_run_t.attempt_count IS 'Count of attempt.';


--
-- Name: COLUMN knowledge_sync_run_t.next_attempt_ts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_sync_run_t.next_attempt_ts IS 'Timestamp for the next attempt event or state.';


--
-- Name: COLUMN knowledge_sync_run_t.update_ts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_sync_run_t.update_ts IS 'Timestamp when this record was last updated.';


--
-- Name: knowledge_upload_t; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.knowledge_upload_t (
    upload_id uuid NOT NULL,
    knowledge_base_id uuid NOT NULL,
    source_id uuid NOT NULL,
    source_object_id character varying(1024) NOT NULL,
    original_filename character varying(512) NOT NULL,
    media_type character varying(128) NOT NULL,
    content_length bigint NOT NULL,
    staged_locator character varying(2048) NOT NULL,
    staged_digest character(64) NOT NULL,
    scan_state character varying(16) DEFAULT 'PENDING'::character varying NOT NULL,
    lifecycle_state character varying(16) DEFAULT 'STAGED'::character varying NOT NULL,
    rejection_code character varying(96),
    requested_by character varying(255) NOT NULL,
    staged_ts timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    verified_ts timestamp with time zone,
    promoted_ts timestamp with time zone,
    purge_after_ts timestamp with time zone NOT NULL,
    CONSTRAINT knowledge_upload_t_check CHECK ((purge_after_ts > staged_ts)),
    CONSTRAINT knowledge_upload_t_check1 CHECK (((((lifecycle_state)::text = ANY (ARRAY[('VERIFIED'::character varying)::text, ('PROMOTED'::character varying)::text])) = ((scan_state)::text = 'CLEAN'::text)) OR ((lifecycle_state)::text = ANY (ARRAY[('STAGED'::character varying)::text, ('REJECTED'::character varying)::text, ('ORPHANED'::character varying)::text, ('PURGED'::character varying)::text])))),
    CONSTRAINT knowledge_upload_t_content_length_check CHECK (((content_length >= 1) AND (content_length <= 104857600))),
    CONSTRAINT knowledge_upload_t_lifecycle_state_check CHECK (((lifecycle_state)::text = ANY (ARRAY[('STAGED'::character varying)::text, ('VERIFIED'::character varying)::text, ('PROMOTED'::character varying)::text, ('REJECTED'::character varying)::text, ('ORPHANED'::character varying)::text, ('PURGED'::character varying)::text]))),
    CONSTRAINT knowledge_upload_t_media_type_check CHECK (((media_type)::text = ANY (ARRAY[('text/plain'::character varying)::text, ('text/markdown'::character varying)::text, ('text/html'::character varying)::text, ('application/pdf'::character varying)::text]))),
    CONSTRAINT knowledge_upload_t_scan_state_check CHECK (((scan_state)::text = ANY (ARRAY[('PENDING'::character varying)::text, ('CLEAN'::character varying)::text, ('REJECTED'::character varying)::text, ('ERROR'::character varying)::text]))),
    CONSTRAINT knowledge_upload_t_staged_digest_check CHECK ((staged_digest ~ '^[a-f0-9]{64}$'::text))
);


--
-- Name: TABLE knowledge_upload_t; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.knowledge_upload_t IS 'Stores knowledge upload records used by the Light Knowledge ingestion, retrieval, indexing, and operations services.';


--
-- Name: COLUMN knowledge_upload_t.upload_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_upload_t.upload_id IS 'Identifier for the related upload.';


--
-- Name: COLUMN knowledge_upload_t.knowledge_base_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_upload_t.knowledge_base_id IS 'Identifier for the related knowledge base.';


--
-- Name: COLUMN knowledge_upload_t.source_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_upload_t.source_id IS 'Identifier for the related source.';


--
-- Name: COLUMN knowledge_upload_t.source_object_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_upload_t.source_object_id IS 'Identifier for the related source object.';


--
-- Name: COLUMN knowledge_upload_t.original_filename; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_upload_t.original_filename IS 'Original Filename value for this knowledge upload record.';


--
-- Name: COLUMN knowledge_upload_t.media_type; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_upload_t.media_type IS 'Media Type value for this knowledge upload record.';


--
-- Name: COLUMN knowledge_upload_t.content_length; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_upload_t.content_length IS 'Content Length value for this knowledge upload record.';


--
-- Name: COLUMN knowledge_upload_t.staged_locator; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_upload_t.staged_locator IS 'Staged Locator value for this knowledge upload record.';


--
-- Name: COLUMN knowledge_upload_t.staged_digest; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_upload_t.staged_digest IS 'Integrity digest for staged.';


--
-- Name: COLUMN knowledge_upload_t.scan_state; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_upload_t.scan_state IS 'Scan State value for this knowledge upload record.';


--
-- Name: COLUMN knowledge_upload_t.lifecycle_state; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_upload_t.lifecycle_state IS 'Lifecycle State value for this knowledge upload record.';


--
-- Name: COLUMN knowledge_upload_t.rejection_code; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_upload_t.rejection_code IS 'Rejection Code value for this knowledge upload record.';


--
-- Name: COLUMN knowledge_upload_t.requested_by; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_upload_t.requested_by IS 'Requested By value for this knowledge upload record.';


--
-- Name: COLUMN knowledge_upload_t.staged_ts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_upload_t.staged_ts IS 'Timestamp for the staged event or state.';


--
-- Name: COLUMN knowledge_upload_t.verified_ts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_upload_t.verified_ts IS 'Timestamp for the verified event or state.';


--
-- Name: COLUMN knowledge_upload_t.promoted_ts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_upload_t.promoted_ts IS 'Timestamp for the promoted event or state.';


--
-- Name: COLUMN knowledge_upload_t.purge_after_ts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.knowledge_upload_t.purge_after_ts IS 'Timestamp for the purge after event or state.';


--
-- Name: agent_knowledge_base_t agent_knowledge_base_t_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_knowledge_base_t
    ADD CONSTRAINT agent_knowledge_base_t_pkey PRIMARY KEY (host_id, agent_id, knowledge_base_id, environment);


--
-- Name: cascade_relationship_policy_t cascade_relationship_policy_t_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cascade_relationship_policy_t
    ADD CONSTRAINT cascade_relationship_policy_t_pkey PRIMARY KEY (parent_schema, parent_table, child_schema, child_table, constraint_name);


--
-- Name: knowledge_acl_reconciliation_t knowledge_acl_reconciliation__reconciliation_id_knowledge_b_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_acl_reconciliation_t
    ADD CONSTRAINT knowledge_acl_reconciliation__reconciliation_id_knowledge_b_key UNIQUE (reconciliation_id, knowledge_base_id);


--
-- Name: knowledge_acl_reconciliation_t knowledge_acl_reconciliation_t_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_acl_reconciliation_t
    ADD CONSTRAINT knowledge_acl_reconciliation_t_pkey PRIMARY KEY (reconciliation_id);


--
-- Name: knowledge_acl_subject_t knowledge_acl_subject_t_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_acl_subject_t
    ADD CONSTRAINT knowledge_acl_subject_t_pkey PRIMARY KEY (acl_revision_id, subject_ordinal);


--
-- Name: knowledge_acl_transition_t knowledge_acl_transition_t_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_acl_transition_t
    ADD CONSTRAINT knowledge_acl_transition_t_pkey PRIMARY KEY (acl_transition_id);


--
-- Name: knowledge_acl_transition_t knowledge_acl_transition_t_reconciliation_id_document_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_acl_transition_t
    ADD CONSTRAINT knowledge_acl_transition_t_reconciliation_id_document_id_key UNIQUE (reconciliation_id, document_id);


--
-- Name: knowledge_anti_entropy_run_t knowledge_anti_entropy_run_t_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_anti_entropy_run_t
    ADD CONSTRAINT knowledge_anti_entropy_run_t_pkey PRIMARY KEY (anti_entropy_run_id);


--
-- Name: knowledge_backup_checkpoint_t knowledge_backup_checkpoint_t_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_backup_checkpoint_t
    ADD CONSTRAINT knowledge_backup_checkpoint_t_pkey PRIMARY KEY (checkpoint_id);


--
-- Name: knowledge_base_strategy_qualification_t knowledge_base_strategy_qualification_t_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_base_strategy_qualification_t
    ADD CONSTRAINT knowledge_base_strategy_qualification_t_pkey PRIMARY KEY (knowledge_base_id, strategy);


--
-- Name: knowledge_base_t knowledge_base_t_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_base_t
    ADD CONSTRAINT knowledge_base_t_pkey PRIMARY KEY (knowledge_base_id);


--
-- Name: knowledge_chunk_embedding_t knowledge_chunk_embedding_t_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_chunk_embedding_t
    ADD CONSTRAINT knowledge_chunk_embedding_t_pkey PRIMARY KEY (chunk_id, embedding_artifact_id);


--
-- Name: knowledge_chunk_t knowledge_chunk_identity_version_uq; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_chunk_t
    ADD CONSTRAINT knowledge_chunk_identity_version_uq UNIQUE (chunk_id, document_version_id, knowledge_base_id);


--
-- Name: knowledge_chunk_t knowledge_chunk_t_chunk_id_knowledge_base_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_chunk_t
    ADD CONSTRAINT knowledge_chunk_t_chunk_id_knowledge_base_id_key UNIQUE (chunk_id, knowledge_base_id);


--
-- Name: knowledge_chunk_t knowledge_chunk_t_document_version_id_ordinal_chunker_contr_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_chunk_t
    ADD CONSTRAINT knowledge_chunk_t_document_version_id_ordinal_chunker_contr_key UNIQUE (document_version_id, ordinal, chunker_contract_digest);


--
-- Name: knowledge_chunk_t knowledge_chunk_t_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_chunk_t
    ADD CONSTRAINT knowledge_chunk_t_pkey PRIMARY KEY (chunk_id);


--
-- Name: knowledge_compaction_run_t knowledge_compaction_run_t_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_compaction_run_t
    ADD CONSTRAINT knowledge_compaction_run_t_pkey PRIMARY KEY (compaction_run_id);


--
-- Name: knowledge_connector_notification_t knowledge_connector_notificat_source_id_provider_notificati_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_connector_notification_t
    ADD CONSTRAINT knowledge_connector_notificat_source_id_provider_notificati_key UNIQUE (source_id, provider_notification_id);


--
-- Name: knowledge_connector_notification_t knowledge_connector_notification_t_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_connector_notification_t
    ADD CONSTRAINT knowledge_connector_notification_t_pkey PRIMARY KEY (connector_notification_id);


--
-- Name: knowledge_connector_object_t knowledge_connector_object_t_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_connector_object_t
    ADD CONSTRAINT knowledge_connector_object_t_pkey PRIMARY KEY (connector_object_id);


--
-- Name: knowledge_connector_object_t knowledge_connector_object_t_source_id_external_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_connector_object_t
    ADD CONSTRAINT knowledge_connector_object_t_source_id_external_id_key UNIQUE (source_id, external_id);


--
-- Name: knowledge_consumer_quota_t knowledge_consumer_quota_t_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_consumer_quota_t
    ADD CONSTRAINT knowledge_consumer_quota_t_pkey PRIMARY KEY (knowledge_base_id, consumer_host_id);


--
-- Name: knowledge_control_snapshot_t knowledge_control_snapshot_t_host_id_environment_publicatio_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_control_snapshot_t
    ADD CONSTRAINT knowledge_control_snapshot_t_host_id_environment_publicatio_key UNIQUE (host_id, environment, publication_sequence);


--
-- Name: knowledge_control_snapshot_t knowledge_control_snapshot_t_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_control_snapshot_t
    ADD CONSTRAINT knowledge_control_snapshot_t_pkey PRIMARY KEY (snapshot_id);


--
-- Name: knowledge_document_acl_t knowledge_document_acl_t_acl_revision_id_knowledge_base_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_document_acl_t
    ADD CONSTRAINT knowledge_document_acl_t_acl_revision_id_knowledge_base_id_key UNIQUE (acl_revision_id, knowledge_base_id);


--
-- Name: knowledge_document_acl_t knowledge_document_acl_t_document_id_acl_sequence_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_document_acl_t
    ADD CONSTRAINT knowledge_document_acl_t_document_id_acl_sequence_key UNIQUE (document_id, acl_sequence);


--
-- Name: knowledge_document_acl_t knowledge_document_acl_t_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_document_acl_t
    ADD CONSTRAINT knowledge_document_acl_t_pkey PRIMARY KEY (acl_revision_id);


--
-- Name: knowledge_document_t knowledge_document_t_document_id_knowledge_base_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_document_t
    ADD CONSTRAINT knowledge_document_t_document_id_knowledge_base_id_key UNIQUE (document_id, knowledge_base_id);


--
-- Name: knowledge_document_t knowledge_document_t_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_document_t
    ADD CONSTRAINT knowledge_document_t_pkey PRIMARY KEY (document_id);


--
-- Name: knowledge_document_t knowledge_document_t_source_id_source_object_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_document_t
    ADD CONSTRAINT knowledge_document_t_source_id_source_object_id_key UNIQUE (source_id, source_object_id);


--
-- Name: knowledge_document_version_t knowledge_document_version_t_document_id_source_version_par_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_document_version_t
    ADD CONSTRAINT knowledge_document_version_t_document_id_source_version_par_key UNIQUE (document_id, source_version, parser_contract_digest);


--
-- Name: knowledge_document_version_t knowledge_document_version_t_document_version_id_knowledge__key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_document_version_t
    ADD CONSTRAINT knowledge_document_version_t_document_version_id_knowledge__key UNIQUE (document_version_id, knowledge_base_id);


--
-- Name: knowledge_document_version_t knowledge_document_version_t_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_document_version_t
    ADD CONSTRAINT knowledge_document_version_t_pkey PRIMARY KEY (document_version_id);


--
-- Name: knowledge_embedding_artifact_t knowledge_embedding_artifact__embedding_artifact_id_dimensi_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_embedding_artifact_t
    ADD CONSTRAINT knowledge_embedding_artifact__embedding_artifact_id_dimensi_key UNIQUE (embedding_artifact_id, dimension);


--
-- Name: knowledge_embedding_artifact_t knowledge_embedding_artifact__knowledge_base_id_transformed_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_embedding_artifact_t
    ADD CONSTRAINT knowledge_embedding_artifact__knowledge_base_id_transformed_key UNIQUE (knowledge_base_id, transformed_input_digest, space_id, space_revision, document_input_transform_version);


--
-- Name: knowledge_embedding_artifact_t knowledge_embedding_artifact_t_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_embedding_artifact_t
    ADD CONSTRAINT knowledge_embedding_artifact_t_pkey PRIMARY KEY (embedding_artifact_id);


--
-- Name: knowledge_embedding_migration_chunk_t knowledge_embedding_migration_chunk_t_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_embedding_migration_chunk_t
    ADD CONSTRAINT knowledge_embedding_migration_chunk_t_pkey PRIMARY KEY (migration_id, chunk_id);


--
-- Name: knowledge_embedding_migration_t knowledge_embedding_migration_knowledge_base_id_migration_i_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_embedding_migration_t
    ADD CONSTRAINT knowledge_embedding_migration_knowledge_base_id_migration_i_key UNIQUE (knowledge_base_id, migration_id);


--
-- Name: knowledge_embedding_migration_t knowledge_embedding_migration_t_candidate_generation_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_embedding_migration_t
    ADD CONSTRAINT knowledge_embedding_migration_t_candidate_generation_id_key UNIQUE (candidate_generation_id);


--
-- Name: knowledge_embedding_migration_t knowledge_embedding_migration_t_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_embedding_migration_t
    ADD CONSTRAINT knowledge_embedding_migration_t_pkey PRIMARY KEY (migration_id);


--
-- Name: knowledge_embedding_profile_t knowledge_embedding_profile_t_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_embedding_profile_t
    ADD CONSTRAINT knowledge_embedding_profile_t_pkey PRIMARY KEY (profile_id, profile_revision);


--
-- Name: knowledge_embedding_reference_t knowledge_embedding_reference_t_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_embedding_reference_t
    ADD CONSTRAINT knowledge_embedding_reference_t_pkey PRIMARY KEY (embedding_artifact_id, knowledge_base_id, chunk_id);


--
-- Name: knowledge_generation_retention_t knowledge_generation_retention_t_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_generation_retention_t
    ADD CONSTRAINT knowledge_generation_retention_t_pkey PRIMARY KEY (index_generation_id);


--
-- Name: knowledge_generation_segment_t knowledge_generation_segment__index_generation_id_index_seg_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_generation_segment_t
    ADD CONSTRAINT knowledge_generation_segment__index_generation_id_index_seg_key UNIQUE (index_generation_id, index_segment_id);


--
-- Name: knowledge_generation_segment_t knowledge_generation_segment_t_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_generation_segment_t
    ADD CONSTRAINT knowledge_generation_segment_t_pkey PRIMARY KEY (index_generation_id, ordinal);


--
-- Name: knowledge_graph_entity_contribution_t knowledge_graph_entity_contribution_t_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_graph_entity_contribution_t
    ADD CONSTRAINT knowledge_graph_entity_contribution_t_pkey PRIMARY KEY (graph_entity_id, chunk_id);


--
-- Name: knowledge_graph_entity_t knowledge_graph_entity_t_graph_entity_id_graph_generation_i_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_graph_entity_t
    ADD CONSTRAINT knowledge_graph_entity_t_graph_entity_id_graph_generation_i_key UNIQUE (graph_entity_id, graph_generation_id, knowledge_base_id);


--
-- Name: knowledge_graph_entity_t knowledge_graph_entity_t_graph_generation_id_entity_type_no_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_graph_entity_t
    ADD CONSTRAINT knowledge_graph_entity_t_graph_generation_id_entity_type_no_key UNIQUE (graph_generation_id, entity_type, normalized_key);


--
-- Name: knowledge_graph_entity_t knowledge_graph_entity_t_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_graph_entity_t
    ADD CONSTRAINT knowledge_graph_entity_t_pkey PRIMARY KEY (graph_entity_id);


--
-- Name: knowledge_graph_generation_t knowledge_graph_generation_t_graph_generation_id_knowledge__key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_graph_generation_t
    ADD CONSTRAINT knowledge_graph_generation_t_graph_generation_id_knowledge__key UNIQUE (graph_generation_id, knowledge_base_id);


--
-- Name: knowledge_graph_generation_t knowledge_graph_generation_t_index_generation_id_contract_d_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_graph_generation_t
    ADD CONSTRAINT knowledge_graph_generation_t_index_generation_id_contract_d_key UNIQUE (index_generation_id, contract_digest);


--
-- Name: knowledge_graph_generation_t knowledge_graph_generation_t_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_graph_generation_t
    ADD CONSTRAINT knowledge_graph_generation_t_pkey PRIMARY KEY (graph_generation_id);


--
-- Name: knowledge_graph_relation_contribution_t knowledge_graph_relation_contribution_t_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_graph_relation_contribution_t
    ADD CONSTRAINT knowledge_graph_relation_contribution_t_pkey PRIMARY KEY (graph_relation_id, chunk_id);


--
-- Name: knowledge_graph_relation_t knowledge_graph_relation_t_graph_generation_id_subject_enti_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_graph_relation_t
    ADD CONSTRAINT knowledge_graph_relation_t_graph_generation_id_subject_enti_key UNIQUE (graph_generation_id, subject_entity_id, relation_type, object_entity_id);


--
-- Name: knowledge_graph_relation_t knowledge_graph_relation_t_graph_relation_id_graph_generati_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_graph_relation_t
    ADD CONSTRAINT knowledge_graph_relation_t_graph_relation_id_graph_generati_key UNIQUE (graph_relation_id, graph_generation_id, knowledge_base_id);


--
-- Name: knowledge_graph_relation_t knowledge_graph_relation_t_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_graph_relation_t
    ADD CONSTRAINT knowledge_graph_relation_t_pkey PRIMARY KEY (graph_relation_id);


--
-- Name: knowledge_index_generation_t knowledge_index_generation_identity_kb_uq; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_index_generation_t
    ADD CONSTRAINT knowledge_index_generation_identity_kb_uq UNIQUE (index_generation_id, knowledge_base_id);


--
-- Name: knowledge_index_generation_t knowledge_index_generation_t_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_index_generation_t
    ADD CONSTRAINT knowledge_index_generation_t_pkey PRIMARY KEY (index_generation_id);


--
-- Name: knowledge_index_pointer_history_t knowledge_index_pointer_histo_knowledge_base_id_environment_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_index_pointer_history_t
    ADD CONSTRAINT knowledge_index_pointer_histo_knowledge_base_id_environment_key UNIQUE (knowledge_base_id, environment, pointer_version);


--
-- Name: knowledge_index_pointer_history_t knowledge_index_pointer_history_t_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_index_pointer_history_t
    ADD CONSTRAINT knowledge_index_pointer_history_t_pkey PRIMARY KEY (pointer_history_id);


--
-- Name: knowledge_index_pointer_t knowledge_index_pointer_t_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_index_pointer_t
    ADD CONSTRAINT knowledge_index_pointer_t_pkey PRIMARY KEY (knowledge_base_id);


--
-- Name: knowledge_index_segment_t knowledge_index_segment_t_index_segment_id_knowledge_base_i_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_index_segment_t
    ADD CONSTRAINT knowledge_index_segment_t_index_segment_id_knowledge_base_i_key UNIQUE (index_segment_id, knowledge_base_id);


--
-- Name: knowledge_index_segment_t knowledge_index_segment_t_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_index_segment_t
    ADD CONSTRAINT knowledge_index_segment_t_pkey PRIMARY KEY (index_segment_id);


--
-- Name: knowledge_ingestion_error_t knowledge_ingestion_error_t_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_ingestion_error_t
    ADD CONSTRAINT knowledge_ingestion_error_t_pkey PRIMARY KEY (ingestion_error_id);


--
-- Name: knowledge_ingestion_policy_t knowledge_ingestion_policy_t_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_ingestion_policy_t
    ADD CONSTRAINT knowledge_ingestion_policy_t_pkey PRIMARY KEY (ingestion_policy_id);


--
-- Name: knowledge_job_t knowledge_job_t_knowledge_base_id_idempotency_key_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_job_t
    ADD CONSTRAINT knowledge_job_t_knowledge_base_id_idempotency_key_key UNIQUE (knowledge_base_id, idempotency_key);


--
-- Name: knowledge_job_t knowledge_job_t_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_job_t
    ADD CONSTRAINT knowledge_job_t_pkey PRIMARY KEY (job_id);


--
-- Name: knowledge_migration_evaluation_t knowledge_migration_evaluation_migration_id_evidence_digest_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_migration_evaluation_t
    ADD CONSTRAINT knowledge_migration_evaluation_migration_id_evidence_digest_key UNIQUE (migration_id, evidence_digest);


--
-- Name: knowledge_migration_evaluation_t knowledge_migration_evaluation_t_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_migration_evaluation_t
    ADD CONSTRAINT knowledge_migration_evaluation_t_pkey PRIMARY KEY (evaluation_evidence_id);


--
-- Name: knowledge_operational_policy_t knowledge_operational_policy_t_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_operational_policy_t
    ADD CONSTRAINT knowledge_operational_policy_t_pkey PRIMARY KEY (knowledge_base_id);


--
-- Name: knowledge_passage_anchor_t knowledge_passage_anchor_t_document_id_anchor_sequence_pass_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_passage_anchor_t
    ADD CONSTRAINT knowledge_passage_anchor_t_document_id_anchor_sequence_pass_key UNIQUE (document_id, anchor_sequence, passage_anchor_id);


--
-- Name: knowledge_passage_anchor_t knowledge_passage_anchor_t_document_version_id_chunk_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_passage_anchor_t
    ADD CONSTRAINT knowledge_passage_anchor_t_document_version_id_chunk_id_key UNIQUE (document_version_id, chunk_id);


--
-- Name: knowledge_passage_anchor_t knowledge_passage_anchor_t_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_passage_anchor_t
    ADD CONSTRAINT knowledge_passage_anchor_t_pkey PRIMARY KEY (passage_anchor_id, document_version_id);


--
-- Name: knowledge_promotion_receipt_t knowledge_promotion_receipt_t_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_promotion_receipt_t
    ADD CONSTRAINT knowledge_promotion_receipt_t_pkey PRIMARY KEY (promotion_id);


--
-- Name: knowledge_purge_evidence_t knowledge_purge_evidence_t_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_purge_evidence_t
    ADD CONSTRAINT knowledge_purge_evidence_t_pkey PRIMARY KEY (purge_evidence_id);


--
-- Name: knowledge_query_admission_t knowledge_query_admission_t_knowledge_base_id_consumer_host_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_query_admission_t
    ADD CONSTRAINT knowledge_query_admission_t_knowledge_base_id_consumer_host_key UNIQUE (knowledge_base_id, consumer_host_id, request_id);


--
-- Name: knowledge_query_admission_t knowledge_query_admission_t_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_query_admission_t
    ADD CONSTRAINT knowledge_query_admission_t_pkey PRIMARY KEY (admission_id);


--
-- Name: knowledge_query_audit_t knowledge_query_audit_t_knowledge_base_id_consumer_host_id__key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_query_audit_t
    ADD CONSTRAINT knowledge_query_audit_t_knowledge_base_id_consumer_host_id__key UNIQUE (knowledge_base_id, consumer_host_id, request_id);


--
-- Name: knowledge_query_audit_t knowledge_query_audit_t_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_query_audit_t
    ADD CONSTRAINT knowledge_query_audit_t_pkey PRIMARY KEY (query_audit_id);


--
-- Name: knowledge_query_usage_t knowledge_query_usage_t_knowledge_base_id_consumer_host_id__key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_query_usage_t
    ADD CONSTRAINT knowledge_query_usage_t_knowledge_base_id_consumer_host_id__key UNIQUE (knowledge_base_id, consumer_host_id, request_id);


--
-- Name: knowledge_query_usage_t knowledge_query_usage_t_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_query_usage_t
    ADD CONSTRAINT knowledge_query_usage_t_pkey PRIMARY KEY (usage_id);


--
-- Name: knowledge_retrieval_profile_t knowledge_retrieval_profile_t_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_retrieval_profile_t
    ADD CONSTRAINT knowledge_retrieval_profile_t_pkey PRIMARY KEY (profile_id);


--
-- Name: knowledge_runtime_authorization_t knowledge_runtime_authorization_t_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_runtime_authorization_t
    ADD CONSTRAINT knowledge_runtime_authorization_t_pkey PRIMARY KEY (knowledge_base_id, consumer_host_id, environment, agent_id);


--
-- Name: knowledge_segment_chunk_t knowledge_segment_chunk_t_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_segment_chunk_t
    ADD CONSTRAINT knowledge_segment_chunk_t_pkey PRIMARY KEY (index_segment_id, chunk_id);


--
-- Name: knowledge_segment_document_t knowledge_segment_document_t_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_segment_document_t
    ADD CONSTRAINT knowledge_segment_document_t_pkey PRIMARY KEY (index_segment_id, document_id);


--
-- Name: knowledge_segment_operation_t knowledge_segment_operation_t_index_segment_id_operation_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_segment_operation_t
    ADD CONSTRAINT knowledge_segment_operation_t_index_segment_id_operation_id_key UNIQUE (index_segment_id, operation_id);


--
-- Name: knowledge_segment_operation_t knowledge_segment_operation_t_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_segment_operation_t
    ADD CONSTRAINT knowledge_segment_operation_t_pkey PRIMARY KEY (index_segment_id, operation_ordinal);


--
-- Name: knowledge_segment_vector_t knowledge_segment_vector_t_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_segment_vector_t
    ADD CONSTRAINT knowledge_segment_vector_t_pkey PRIMARY KEY (index_segment_id, chunk_id);


--
-- Name: knowledge_source_acl_state_t knowledge_source_acl_state_t_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_source_acl_state_t
    ADD CONSTRAINT knowledge_source_acl_state_t_pkey PRIMARY KEY (source_id);


--
-- Name: knowledge_source_change_t knowledge_source_change_t_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_source_change_t
    ADD CONSTRAINT knowledge_source_change_t_pkey PRIMARY KEY (source_change_id);


--
-- Name: knowledge_source_change_t knowledge_source_change_t_source_id_change_sequence_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_source_change_t
    ADD CONSTRAINT knowledge_source_change_t_source_id_change_sequence_key UNIQUE (source_id, change_sequence);


--
-- Name: knowledge_source_change_t knowledge_source_change_t_sync_run_id_source_object_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_source_change_t
    ADD CONSTRAINT knowledge_source_change_t_sync_run_id_source_object_id_key UNIQUE (sync_run_id, source_object_id);


--
-- Name: knowledge_source_cursor_t knowledge_source_cursor_t_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_source_cursor_t
    ADD CONSTRAINT knowledge_source_cursor_t_pkey PRIMARY KEY (source_id);


--
-- Name: knowledge_source_t knowledge_source_t_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_source_t
    ADD CONSTRAINT knowledge_source_t_pkey PRIMARY KEY (source_id);


--
-- Name: knowledge_subject_mapping_t knowledge_subject_mapping_t_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_subject_mapping_t
    ADD CONSTRAINT knowledge_subject_mapping_t_pkey PRIMARY KEY (subject_mapping_id);


--
-- Name: knowledge_sync_run_t knowledge_sync_run_t_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_sync_run_t
    ADD CONSTRAINT knowledge_sync_run_t_pkey PRIMARY KEY (sync_run_id);


--
-- Name: knowledge_upload_t knowledge_upload_t_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_upload_t
    ADD CONSTRAINT knowledge_upload_t_pkey PRIMARY KEY (upload_id);


--
-- Name: knowledge_upload_t knowledge_upload_t_source_id_source_object_id_staged_digest_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_upload_t
    ADD CONSTRAINT knowledge_upload_t_source_id_source_object_id_staged_digest_key UNIQUE (source_id, source_object_id, staged_digest);


--
-- Name: knowledge_acl_reconciliation_source_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX knowledge_acl_reconciliation_source_idx ON public.knowledge_acl_reconciliation_t USING btree (source_id, started_ts DESC);


--
-- Name: knowledge_acl_subject_match_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX knowledge_acl_subject_match_idx ON public.knowledge_acl_subject_t USING btree (acl_revision_id, effect, normalized_subject_type, normalized_subject_id);


--
-- Name: knowledge_acl_transition_source_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX knowledge_acl_transition_source_idx ON public.knowledge_acl_transition_t USING btree (source_id, recorded_ts DESC);


--
-- Name: knowledge_base_global_name_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX knowledge_base_global_name_uq ON public.knowledge_base_t USING btree (environment, name) WHERE ((host_id IS NULL) AND ((status)::text <> 'DELETED'::text));


--
-- Name: knowledge_base_tenant_name_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX knowledge_base_tenant_name_uq ON public.knowledge_base_t USING btree (host_id, environment, name) WHERE ((host_id IS NOT NULL) AND ((status)::text <> 'DELETED'::text));


--
-- Name: knowledge_chunk_identifier_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX knowledge_chunk_identifier_idx ON public.knowledge_chunk_t USING gin (chunk_text public.gin_trgm_ops);


--
-- Name: knowledge_chunk_lexical_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX knowledge_chunk_lexical_idx ON public.knowledge_chunk_t USING gin (lexical_input);


--
-- Name: knowledge_embedding_migration_active_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX knowledge_embedding_migration_active_uq ON public.knowledge_embedding_migration_t USING btree (knowledge_base_id) WHERE ((state)::text = ANY (ARRAY[('REQUESTED'::character varying)::text, ('PREFLIGHTED'::character varying)::text, ('BACKFILLING'::character varying)::text, ('PAUSED'::character varying)::text, ('CATCHING_UP'::character varying)::text, ('VALIDATING'::character varying)::text, ('READY'::character varying)::text, ('PROMOTED'::character varying)::text, ('SOAKING'::character varying)::text]));


--
-- Name: knowledge_embedding_migration_chunk_work_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX knowledge_embedding_migration_chunk_work_idx ON public.knowledge_embedding_migration_chunk_t USING btree (migration_id, state, claim_expires_ts, chunk_id);


--
-- Name: knowledge_embedding_migration_work_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX knowledge_embedding_migration_work_idx ON public.knowledge_embedding_migration_t USING btree (state, update_ts);


--
-- Name: knowledge_embedding_profile_global_space_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX knowledge_embedding_profile_global_space_uq ON public.knowledge_embedding_profile_t USING btree (expected_space_id, expected_space_revision, query_input_transform_version) WHERE ((host_id IS NULL) AND (active IS TRUE));


--
-- Name: knowledge_embedding_profile_tenant_space_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX knowledge_embedding_profile_tenant_space_uq ON public.knowledge_embedding_profile_t USING btree (host_id, expected_space_id, expected_space_revision, query_input_transform_version) WHERE ((host_id IS NOT NULL) AND (active IS TRUE));


--
-- Name: knowledge_embedding_reference_last_ref_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX knowledge_embedding_reference_last_ref_idx ON public.knowledge_embedding_reference_t USING btree (embedding_artifact_id, reference_state);


--
-- Name: knowledge_graph_entity_lookup_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX knowledge_graph_entity_lookup_idx ON public.knowledge_graph_entity_t USING btree (graph_generation_id, normalized_key);


--
-- Name: knowledge_graph_relation_object_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX knowledge_graph_relation_object_idx ON public.knowledge_graph_relation_t USING btree (graph_generation_id, object_entity_id, relation_type);


--
-- Name: knowledge_graph_relation_subject_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX knowledge_graph_relation_subject_idx ON public.knowledge_graph_relation_t USING btree (graph_generation_id, subject_entity_id, relation_type);


--
-- Name: knowledge_ingestion_policy_global_name_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX knowledge_ingestion_policy_global_name_uq ON public.knowledge_ingestion_policy_t USING btree (policy_name) WHERE ((host_id IS NULL) AND (active IS TRUE));


--
-- Name: knowledge_ingestion_policy_tenant_name_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX knowledge_ingestion_policy_tenant_name_uq ON public.knowledge_ingestion_policy_t USING btree (host_id, policy_name) WHERE ((host_id IS NOT NULL) AND (active IS TRUE));


--
-- Name: knowledge_job_work_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX knowledge_job_work_idx ON public.knowledge_job_t USING btree (state, next_attempt_ts, created_ts);


--
-- Name: knowledge_passage_anchor_current_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX knowledge_passage_anchor_current_idx ON public.knowledge_passage_anchor_t USING btree (document_id, passage_anchor_id, anchor_sequence DESC);


--
-- Name: knowledge_query_admission_active_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX knowledge_query_admission_active_idx ON public.knowledge_query_admission_t USING btree (knowledge_base_id, consumer_host_id, lease_expires_ts) WHERE ((state)::text = 'ADMITTED'::text);


--
-- Name: knowledge_query_audit_fallback_created_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX knowledge_query_audit_fallback_created_idx ON public.knowledge_query_audit_t USING btree (created_ts DESC) WHERE (fallback_reason IS NOT NULL);


--
-- Name: knowledge_retrieval_profile_global_name_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX knowledge_retrieval_profile_global_name_uq ON public.knowledge_retrieval_profile_t USING btree (profile_name) WHERE ((host_id IS NULL) AND (active IS TRUE));


--
-- Name: knowledge_retrieval_profile_tenant_name_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX knowledge_retrieval_profile_tenant_name_uq ON public.knowledge_retrieval_profile_t USING btree (host_id, profile_name) WHERE ((host_id IS NOT NULL) AND (active IS TRUE));


--
-- Name: knowledge_runtime_authorization_effective_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX knowledge_runtime_authorization_effective_idx ON public.knowledge_runtime_authorization_t USING btree (consumer_host_id, agent_id, environment, knowledge_base_id, active);


--
-- Name: knowledge_segment_operation_document_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX knowledge_segment_operation_document_idx ON public.knowledge_segment_operation_t USING btree (knowledge_base_id, document_id, index_segment_id, operation_ordinal);


--
-- Name: knowledge_source_name_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX knowledge_source_name_uq ON public.knowledge_source_t USING btree (knowledge_base_id, display_name) WHERE ((status)::text <> 'DELETED'::text);


--
-- Name: knowledge_subject_mapping_global_uk; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX knowledge_subject_mapping_global_uk ON public.knowledge_subject_mapping_t USING btree (source_id, provider_subject_type, provider_subject_id) WHERE (host_id IS NULL);


--
-- Name: knowledge_subject_mapping_tenant_uk; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX knowledge_subject_mapping_tenant_uk ON public.knowledge_subject_mapping_t USING btree (host_id, source_id, provider_subject_type, provider_subject_id) WHERE (host_id IS NOT NULL);


--
-- Name: knowledge_sync_run_base_state_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX knowledge_sync_run_base_state_idx ON public.knowledge_sync_run_t USING btree (knowledge_base_id, state, requested_ts DESC);


--
-- Name: knowledge_sync_run_job_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX knowledge_sync_run_job_uq ON public.knowledge_sync_run_t USING btree (job_id) WHERE (job_id IS NOT NULL);


--
-- Name: knowledge_sync_run_source_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX knowledge_sync_run_source_idx ON public.knowledge_sync_run_t USING btree (source_id, requested_ts DESC);


--
-- Name: knowledge_upload_orphan_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX knowledge_upload_orphan_idx ON public.knowledge_upload_t USING btree (lifecycle_state, purge_after_ts) WHERE ((lifecycle_state)::text = ANY (ARRAY[('STAGED'::character varying)::text, ('ORPHANED'::character varying)::text, ('REJECTED'::character varying)::text]));


--
-- Name: knowledge_embedding_migration_t knowledge_embedding_migration_contract_trg; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER knowledge_embedding_migration_contract_trg BEFORE UPDATE ON public.knowledge_embedding_migration_t FOR EACH ROW EXECUTE FUNCTION public.enforce_knowledge_embedding_migration_contract();


--
-- Name: knowledge_embedding_profile_t knowledge_embedding_profile_immutable_trg; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER knowledge_embedding_profile_immutable_trg BEFORE UPDATE ON public.knowledge_embedding_profile_t FOR EACH ROW EXECUTE FUNCTION public.enforce_knowledge_embedding_profile_immutable();


--
-- Name: knowledge_generation_segment_t knowledge_generation_segment_phase1b_trg; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER knowledge_generation_segment_phase1b_trg BEFORE INSERT OR UPDATE ON public.knowledge_generation_segment_t FOR EACH ROW EXECUTE FUNCTION public.validate_knowledge_generation_segment_phase1b();


--
-- Name: knowledge_index_generation_t knowledge_index_generation_profile_trg; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER knowledge_index_generation_profile_trg BEFORE INSERT OR UPDATE ON public.knowledge_index_generation_t FOR EACH ROW EXECUTE FUNCTION public.validate_knowledge_index_generation_profile();


--
-- Name: knowledge_index_pointer_t knowledge_index_pointer_valid_trg; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER knowledge_index_pointer_valid_trg BEFORE INSERT OR UPDATE ON public.knowledge_index_pointer_t FOR EACH ROW EXECUTE FUNCTION public.validate_knowledge_index_pointer();


--
-- Name: knowledge_job_t knowledge_job_eligible_notify_trg; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER knowledge_job_eligible_notify_trg AFTER INSERT OR UPDATE OF state, next_attempt_ts ON public.knowledge_job_t FOR EACH ROW EXECUTE FUNCTION public.notify_knowledge_job_eligible();


--
-- Name: knowledge_segment_vector_t knowledge_segment_vector_dimension_trg; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER knowledge_segment_vector_dimension_trg BEFORE INSERT OR UPDATE ON public.knowledge_segment_vector_t FOR EACH ROW EXECUTE FUNCTION public.enforce_knowledge_segment_vector_dimension();


--
-- Name: knowledge_source_t knowledge_source_acl_mode_fence_trg; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER knowledge_source_acl_mode_fence_trg BEFORE UPDATE OF acl_mode ON public.knowledge_source_t FOR EACH ROW EXECUTE FUNCTION public.prevent_knowledge_acl_mode_downgrade();


--
-- Name: agent_knowledge_base_t agent_knowledge_base_t_knowledge_base_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_knowledge_base_t
    ADD CONSTRAINT agent_knowledge_base_t_knowledge_base_id_fkey FOREIGN KEY (knowledge_base_id) REFERENCES public.knowledge_base_t(knowledge_base_id) ON DELETE RESTRICT;


--
-- Name: agent_knowledge_base_t agent_knowledge_base_t_retrieval_profile_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_knowledge_base_t
    ADD CONSTRAINT agent_knowledge_base_t_retrieval_profile_id_fkey FOREIGN KEY (retrieval_profile_id) REFERENCES public.knowledge_retrieval_profile_t(profile_id) ON DELETE RESTRICT;


--
-- Name: knowledge_acl_reconciliation_t knowledge_acl_reconciliation_t_knowledge_base_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_acl_reconciliation_t
    ADD CONSTRAINT knowledge_acl_reconciliation_t_knowledge_base_id_fkey FOREIGN KEY (knowledge_base_id) REFERENCES public.knowledge_base_t(knowledge_base_id) ON DELETE RESTRICT;


--
-- Name: knowledge_acl_reconciliation_t knowledge_acl_reconciliation_t_source_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_acl_reconciliation_t
    ADD CONSTRAINT knowledge_acl_reconciliation_t_source_id_fkey FOREIGN KEY (source_id) REFERENCES public.knowledge_source_t(source_id) ON DELETE RESTRICT;


--
-- Name: knowledge_acl_subject_t knowledge_acl_subject_t_acl_revision_id_knowledge_base_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_acl_subject_t
    ADD CONSTRAINT knowledge_acl_subject_t_acl_revision_id_knowledge_base_id_fkey FOREIGN KEY (acl_revision_id, knowledge_base_id) REFERENCES public.knowledge_document_acl_t(acl_revision_id, knowledge_base_id) ON DELETE RESTRICT;


--
-- Name: knowledge_acl_subject_t knowledge_acl_subject_t_document_id_knowledge_base_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_acl_subject_t
    ADD CONSTRAINT knowledge_acl_subject_t_document_id_knowledge_base_id_fkey FOREIGN KEY (document_id, knowledge_base_id) REFERENCES public.knowledge_document_t(document_id, knowledge_base_id) ON DELETE RESTRICT;


--
-- Name: knowledge_acl_transition_t knowledge_acl_transition_t_document_id_knowledge_base_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_acl_transition_t
    ADD CONSTRAINT knowledge_acl_transition_t_document_id_knowledge_base_id_fkey FOREIGN KEY (document_id, knowledge_base_id) REFERENCES public.knowledge_document_t(document_id, knowledge_base_id) ON DELETE RESTRICT;


--
-- Name: knowledge_acl_transition_t knowledge_acl_transition_t_reconciliation_id_knowledge_bas_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_acl_transition_t
    ADD CONSTRAINT knowledge_acl_transition_t_reconciliation_id_knowledge_bas_fkey FOREIGN KEY (reconciliation_id, knowledge_base_id) REFERENCES public.knowledge_acl_reconciliation_t(reconciliation_id, knowledge_base_id) ON DELETE RESTRICT;


--
-- Name: knowledge_acl_transition_t knowledge_acl_transition_t_source_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_acl_transition_t
    ADD CONSTRAINT knowledge_acl_transition_t_source_id_fkey FOREIGN KEY (source_id) REFERENCES public.knowledge_source_t(source_id) ON DELETE RESTRICT;


--
-- Name: knowledge_anti_entropy_run_t knowledge_anti_entropy_run_t_index_generation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_anti_entropy_run_t
    ADD CONSTRAINT knowledge_anti_entropy_run_t_index_generation_id_fkey FOREIGN KEY (index_generation_id) REFERENCES public.knowledge_index_generation_t(index_generation_id) ON DELETE RESTRICT;


--
-- Name: knowledge_anti_entropy_run_t knowledge_anti_entropy_run_t_knowledge_base_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_anti_entropy_run_t
    ADD CONSTRAINT knowledge_anti_entropy_run_t_knowledge_base_id_fkey FOREIGN KEY (knowledge_base_id) REFERENCES public.knowledge_base_t(knowledge_base_id) ON DELETE RESTRICT;


--
-- Name: knowledge_backup_checkpoint_t knowledge_backup_checkpoint_t_index_generation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_backup_checkpoint_t
    ADD CONSTRAINT knowledge_backup_checkpoint_t_index_generation_id_fkey FOREIGN KEY (index_generation_id) REFERENCES public.knowledge_index_generation_t(index_generation_id) ON DELETE RESTRICT;


--
-- Name: knowledge_backup_checkpoint_t knowledge_backup_checkpoint_t_knowledge_base_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_backup_checkpoint_t
    ADD CONSTRAINT knowledge_backup_checkpoint_t_knowledge_base_id_fkey FOREIGN KEY (knowledge_base_id) REFERENCES public.knowledge_base_t(knowledge_base_id) ON DELETE RESTRICT;


--
-- Name: knowledge_base_t knowledge_base_replacement_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_base_t
    ADD CONSTRAINT knowledge_base_replacement_fk FOREIGN KEY (replacement_knowledge_base_id) REFERENCES public.knowledge_base_t(knowledge_base_id) ON DELETE RESTRICT;


--
-- Name: knowledge_base_strategy_qualification_t knowledge_base_strategy_qualification_t_knowledge_base_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_base_strategy_qualification_t
    ADD CONSTRAINT knowledge_base_strategy_qualification_t_knowledge_base_id_fkey FOREIGN KEY (knowledge_base_id) REFERENCES public.knowledge_base_t(knowledge_base_id) ON DELETE RESTRICT;


--
-- Name: knowledge_base_t knowledge_base_t_desired_embedding_profile_id_desired_embe_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_base_t
    ADD CONSTRAINT knowledge_base_t_desired_embedding_profile_id_desired_embe_fkey FOREIGN KEY (desired_embedding_profile_id, desired_embedding_profile_revision) REFERENCES public.knowledge_embedding_profile_t(profile_id, profile_revision) ON DELETE RESTRICT;


--
-- Name: knowledge_chunk_embedding_t knowledge_chunk_embedding_t_chunk_id_knowledge_base_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_chunk_embedding_t
    ADD CONSTRAINT knowledge_chunk_embedding_t_chunk_id_knowledge_base_id_fkey FOREIGN KEY (chunk_id, knowledge_base_id) REFERENCES public.knowledge_chunk_t(chunk_id, knowledge_base_id) ON DELETE RESTRICT;


--
-- Name: knowledge_chunk_embedding_t knowledge_chunk_embedding_t_embedding_artifact_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_chunk_embedding_t
    ADD CONSTRAINT knowledge_chunk_embedding_t_embedding_artifact_id_fkey FOREIGN KEY (embedding_artifact_id) REFERENCES public.knowledge_embedding_artifact_t(embedding_artifact_id) ON DELETE RESTRICT;


--
-- Name: knowledge_chunk_embedding_t knowledge_chunk_embedding_t_embedding_profile_id_embedding_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_chunk_embedding_t
    ADD CONSTRAINT knowledge_chunk_embedding_t_embedding_profile_id_embedding_fkey FOREIGN KEY (embedding_profile_id, embedding_profile_revision) REFERENCES public.knowledge_embedding_profile_t(profile_id, profile_revision) ON DELETE RESTRICT;


--
-- Name: knowledge_chunk_t knowledge_chunk_t_document_version_id_knowledge_base_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_chunk_t
    ADD CONSTRAINT knowledge_chunk_t_document_version_id_knowledge_base_id_fkey FOREIGN KEY (document_version_id, knowledge_base_id) REFERENCES public.knowledge_document_version_t(document_version_id, knowledge_base_id) ON DELETE RESTRICT;


--
-- Name: knowledge_compaction_run_t knowledge_compaction_run_t_candidate_generation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_compaction_run_t
    ADD CONSTRAINT knowledge_compaction_run_t_candidate_generation_id_fkey FOREIGN KEY (candidate_generation_id) REFERENCES public.knowledge_index_generation_t(index_generation_id) ON DELETE RESTRICT;


--
-- Name: knowledge_compaction_run_t knowledge_compaction_run_t_knowledge_base_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_compaction_run_t
    ADD CONSTRAINT knowledge_compaction_run_t_knowledge_base_id_fkey FOREIGN KEY (knowledge_base_id) REFERENCES public.knowledge_base_t(knowledge_base_id) ON DELETE RESTRICT;


--
-- Name: knowledge_compaction_run_t knowledge_compaction_run_t_source_generation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_compaction_run_t
    ADD CONSTRAINT knowledge_compaction_run_t_source_generation_id_fkey FOREIGN KEY (source_generation_id) REFERENCES public.knowledge_index_generation_t(index_generation_id) ON DELETE RESTRICT;


--
-- Name: knowledge_connector_notification_t knowledge_connector_notification_t_source_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_connector_notification_t
    ADD CONSTRAINT knowledge_connector_notification_t_source_id_fkey FOREIGN KEY (source_id) REFERENCES public.knowledge_source_t(source_id) ON DELETE RESTRICT;


--
-- Name: knowledge_connector_object_t knowledge_connector_object_t_document_id_knowledge_base_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_connector_object_t
    ADD CONSTRAINT knowledge_connector_object_t_document_id_knowledge_base_id_fkey FOREIGN KEY (document_id, knowledge_base_id) REFERENCES public.knowledge_document_t(document_id, knowledge_base_id) ON DELETE RESTRICT;


--
-- Name: knowledge_connector_object_t knowledge_connector_object_t_knowledge_base_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_connector_object_t
    ADD CONSTRAINT knowledge_connector_object_t_knowledge_base_id_fkey FOREIGN KEY (knowledge_base_id) REFERENCES public.knowledge_base_t(knowledge_base_id) ON DELETE RESTRICT;


--
-- Name: knowledge_connector_object_t knowledge_connector_object_t_last_reconciliation_id_knowle_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_connector_object_t
    ADD CONSTRAINT knowledge_connector_object_t_last_reconciliation_id_knowle_fkey FOREIGN KEY (last_reconciliation_id, knowledge_base_id) REFERENCES public.knowledge_acl_reconciliation_t(reconciliation_id, knowledge_base_id) ON DELETE RESTRICT;


--
-- Name: knowledge_connector_object_t knowledge_connector_object_t_source_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_connector_object_t
    ADD CONSTRAINT knowledge_connector_object_t_source_id_fkey FOREIGN KEY (source_id) REFERENCES public.knowledge_source_t(source_id) ON DELETE RESTRICT;


--
-- Name: knowledge_consumer_quota_t knowledge_consumer_quota_t_knowledge_base_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_consumer_quota_t
    ADD CONSTRAINT knowledge_consumer_quota_t_knowledge_base_id_fkey FOREIGN KEY (knowledge_base_id) REFERENCES public.knowledge_base_t(knowledge_base_id) ON DELETE CASCADE;


--
-- Name: knowledge_document_acl_t knowledge_document_acl_reconciliation_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_document_acl_t
    ADD CONSTRAINT knowledge_document_acl_reconciliation_fk FOREIGN KEY (reconciliation_id, knowledge_base_id) REFERENCES public.knowledge_acl_reconciliation_t(reconciliation_id, knowledge_base_id) ON DELETE RESTRICT;


--
-- Name: knowledge_document_acl_t knowledge_document_acl_t_document_id_knowledge_base_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_document_acl_t
    ADD CONSTRAINT knowledge_document_acl_t_document_id_knowledge_base_id_fkey FOREIGN KEY (document_id, knowledge_base_id) REFERENCES public.knowledge_document_t(document_id, knowledge_base_id) ON DELETE RESTRICT;


--
-- Name: knowledge_document_t knowledge_document_current_version_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_document_t
    ADD CONSTRAINT knowledge_document_current_version_fk FOREIGN KEY (current_document_version_id, knowledge_base_id) REFERENCES public.knowledge_document_version_t(document_version_id, knowledge_base_id) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED;


--
-- Name: knowledge_document_t knowledge_document_t_knowledge_base_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_document_t
    ADD CONSTRAINT knowledge_document_t_knowledge_base_id_fkey FOREIGN KEY (knowledge_base_id) REFERENCES public.knowledge_base_t(knowledge_base_id) ON DELETE RESTRICT;


--
-- Name: knowledge_document_t knowledge_document_t_source_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_document_t
    ADD CONSTRAINT knowledge_document_t_source_id_fkey FOREIGN KEY (source_id) REFERENCES public.knowledge_source_t(source_id) ON DELETE RESTRICT;


--
-- Name: knowledge_document_version_t knowledge_document_version_t_document_id_knowledge_base_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_document_version_t
    ADD CONSTRAINT knowledge_document_version_t_document_id_knowledge_base_id_fkey FOREIGN KEY (document_id, knowledge_base_id) REFERENCES public.knowledge_document_t(document_id, knowledge_base_id) ON DELETE RESTRICT;


--
-- Name: knowledge_embedding_artifact_t knowledge_embedding_artifact_t_knowledge_base_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_embedding_artifact_t
    ADD CONSTRAINT knowledge_embedding_artifact_t_knowledge_base_id_fkey FOREIGN KEY (knowledge_base_id) REFERENCES public.knowledge_base_t(knowledge_base_id) ON DELETE RESTRICT;


--
-- Name: knowledge_embedding_migration_chunk_t knowledge_embedding_migration_c_chunk_id_knowledge_base_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_embedding_migration_chunk_t
    ADD CONSTRAINT knowledge_embedding_migration_c_chunk_id_knowledge_base_id_fkey FOREIGN KEY (chunk_id, knowledge_base_id) REFERENCES public.knowledge_chunk_t(chunk_id, knowledge_base_id) ON DELETE RESTRICT;


--
-- Name: knowledge_embedding_migration_chunk_t knowledge_embedding_migration_chunk__embedding_artifact_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_embedding_migration_chunk_t
    ADD CONSTRAINT knowledge_embedding_migration_chunk__embedding_artifact_id_fkey FOREIGN KEY (embedding_artifact_id) REFERENCES public.knowledge_embedding_artifact_t(embedding_artifact_id) ON DELETE RESTRICT;


--
-- Name: knowledge_embedding_migration_chunk_t knowledge_embedding_migration_migration_id_knowledge_base__fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_embedding_migration_chunk_t
    ADD CONSTRAINT knowledge_embedding_migration_migration_id_knowledge_base__fkey FOREIGN KEY (migration_id, knowledge_base_id) REFERENCES public.knowledge_embedding_migration_t(migration_id, knowledge_base_id) ON DELETE RESTRICT;


--
-- Name: knowledge_embedding_migration_t knowledge_embedding_migration_t_knowledge_base_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_embedding_migration_t
    ADD CONSTRAINT knowledge_embedding_migration_t_knowledge_base_id_fkey FOREIGN KEY (knowledge_base_id) REFERENCES public.knowledge_base_t(knowledge_base_id) ON DELETE RESTRICT;


--
-- Name: knowledge_embedding_migration_t knowledge_embedding_migration_t_source_generation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_embedding_migration_t
    ADD CONSTRAINT knowledge_embedding_migration_t_source_generation_id_fkey FOREIGN KEY (source_generation_id) REFERENCES public.knowledge_index_generation_t(index_generation_id) ON DELETE RESTRICT;


--
-- Name: knowledge_embedding_migration_t knowledge_embedding_migration_target_profile_id_target_pro_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_embedding_migration_t
    ADD CONSTRAINT knowledge_embedding_migration_target_profile_id_target_pro_fkey FOREIGN KEY (target_profile_id, target_profile_revision) REFERENCES public.knowledge_embedding_profile_t(profile_id, profile_revision) ON DELETE RESTRICT;


--
-- Name: knowledge_embedding_reference_t knowledge_embedding_reference_t_chunk_id_knowledge_base_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_embedding_reference_t
    ADD CONSTRAINT knowledge_embedding_reference_t_chunk_id_knowledge_base_id_fkey FOREIGN KEY (chunk_id, knowledge_base_id) REFERENCES public.knowledge_chunk_t(chunk_id, knowledge_base_id) ON DELETE RESTRICT;


--
-- Name: knowledge_embedding_reference_t knowledge_embedding_reference_t_embedding_artifact_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_embedding_reference_t
    ADD CONSTRAINT knowledge_embedding_reference_t_embedding_artifact_id_fkey FOREIGN KEY (embedding_artifact_id) REFERENCES public.knowledge_embedding_artifact_t(embedding_artifact_id) ON DELETE RESTRICT;


--
-- Name: knowledge_generation_retention_t knowledge_generation_retention_t_index_generation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_generation_retention_t
    ADD CONSTRAINT knowledge_generation_retention_t_index_generation_id_fkey FOREIGN KEY (index_generation_id) REFERENCES public.knowledge_index_generation_t(index_generation_id) ON DELETE RESTRICT;


--
-- Name: knowledge_generation_retention_t knowledge_generation_retention_t_knowledge_base_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_generation_retention_t
    ADD CONSTRAINT knowledge_generation_retention_t_knowledge_base_id_fkey FOREIGN KEY (knowledge_base_id) REFERENCES public.knowledge_base_t(knowledge_base_id) ON DELETE RESTRICT;


--
-- Name: knowledge_generation_segment_t knowledge_generation_segment_t_index_generation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_generation_segment_t
    ADD CONSTRAINT knowledge_generation_segment_t_index_generation_id_fkey FOREIGN KEY (index_generation_id) REFERENCES public.knowledge_index_generation_t(index_generation_id) ON DELETE RESTRICT;


--
-- Name: knowledge_generation_segment_t knowledge_generation_segment_t_index_segment_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_generation_segment_t
    ADD CONSTRAINT knowledge_generation_segment_t_index_segment_id_fkey FOREIGN KEY (index_segment_id) REFERENCES public.knowledge_index_segment_t(index_segment_id) ON DELETE RESTRICT;


--
-- Name: knowledge_graph_entity_contribution_t knowledge_graph_entity_contri_chunk_id_document_version_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_graph_entity_contribution_t
    ADD CONSTRAINT knowledge_graph_entity_contri_chunk_id_document_version_id_fkey FOREIGN KEY (chunk_id, document_version_id, knowledge_base_id) REFERENCES public.knowledge_chunk_t(chunk_id, document_version_id, knowledge_base_id) ON DELETE RESTRICT;


--
-- Name: knowledge_graph_entity_contribution_t knowledge_graph_entity_contri_graph_entity_id_graph_genera_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_graph_entity_contribution_t
    ADD CONSTRAINT knowledge_graph_entity_contri_graph_entity_id_graph_genera_fkey FOREIGN KEY (graph_entity_id, graph_generation_id, knowledge_base_id) REFERENCES public.knowledge_graph_entity_t(graph_entity_id, graph_generation_id, knowledge_base_id) ON DELETE CASCADE;


--
-- Name: knowledge_graph_entity_t knowledge_graph_entity_t_graph_generation_id_knowledge_bas_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_graph_entity_t
    ADD CONSTRAINT knowledge_graph_entity_t_graph_generation_id_knowledge_bas_fkey FOREIGN KEY (graph_generation_id, knowledge_base_id) REFERENCES public.knowledge_graph_generation_t(graph_generation_id, knowledge_base_id) ON DELETE CASCADE;


--
-- Name: knowledge_graph_generation_t knowledge_graph_generation_t_index_generation_id_knowledge_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_graph_generation_t
    ADD CONSTRAINT knowledge_graph_generation_t_index_generation_id_knowledge_fkey FOREIGN KEY (index_generation_id, knowledge_base_id) REFERENCES public.knowledge_index_generation_t(index_generation_id, knowledge_base_id) ON DELETE RESTRICT;


--
-- Name: knowledge_graph_generation_t knowledge_graph_generation_t_knowledge_base_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_graph_generation_t
    ADD CONSTRAINT knowledge_graph_generation_t_knowledge_base_id_fkey FOREIGN KEY (knowledge_base_id) REFERENCES public.knowledge_base_t(knowledge_base_id) ON DELETE RESTRICT;


--
-- Name: knowledge_graph_relation_contribution_t knowledge_graph_relation_cont_chunk_id_document_version_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_graph_relation_contribution_t
    ADD CONSTRAINT knowledge_graph_relation_cont_chunk_id_document_version_id_fkey FOREIGN KEY (chunk_id, document_version_id, knowledge_base_id) REFERENCES public.knowledge_chunk_t(chunk_id, document_version_id, knowledge_base_id) ON DELETE RESTRICT;


--
-- Name: knowledge_graph_relation_contribution_t knowledge_graph_relation_cont_graph_relation_id_graph_gene_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_graph_relation_contribution_t
    ADD CONSTRAINT knowledge_graph_relation_cont_graph_relation_id_graph_gene_fkey FOREIGN KEY (graph_relation_id, graph_generation_id, knowledge_base_id) REFERENCES public.knowledge_graph_relation_t(graph_relation_id, graph_generation_id, knowledge_base_id) ON DELETE CASCADE;


--
-- Name: knowledge_graph_relation_t knowledge_graph_relation_t_graph_generation_id_knowledge_b_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_graph_relation_t
    ADD CONSTRAINT knowledge_graph_relation_t_graph_generation_id_knowledge_b_fkey FOREIGN KEY (graph_generation_id, knowledge_base_id) REFERENCES public.knowledge_graph_generation_t(graph_generation_id, knowledge_base_id) ON DELETE CASCADE;


--
-- Name: knowledge_graph_relation_t knowledge_graph_relation_t_object_entity_id_graph_generati_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_graph_relation_t
    ADD CONSTRAINT knowledge_graph_relation_t_object_entity_id_graph_generati_fkey FOREIGN KEY (object_entity_id, graph_generation_id, knowledge_base_id) REFERENCES public.knowledge_graph_entity_t(graph_entity_id, graph_generation_id, knowledge_base_id) ON DELETE CASCADE;


--
-- Name: knowledge_graph_relation_t knowledge_graph_relation_t_subject_entity_id_graph_generat_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_graph_relation_t
    ADD CONSTRAINT knowledge_graph_relation_t_subject_entity_id_graph_generat_fkey FOREIGN KEY (subject_entity_id, graph_generation_id, knowledge_base_id) REFERENCES public.knowledge_graph_entity_t(graph_entity_id, graph_generation_id, knowledge_base_id) ON DELETE CASCADE;


--
-- Name: knowledge_index_generation_t knowledge_index_generation_t_embedding_profile_id_embeddin_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_index_generation_t
    ADD CONSTRAINT knowledge_index_generation_t_embedding_profile_id_embeddin_fkey FOREIGN KEY (embedding_profile_id, embedding_profile_revision) REFERENCES public.knowledge_embedding_profile_t(profile_id, profile_revision) ON DELETE RESTRICT;


--
-- Name: knowledge_index_generation_t knowledge_index_generation_t_knowledge_base_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_index_generation_t
    ADD CONSTRAINT knowledge_index_generation_t_knowledge_base_id_fkey FOREIGN KEY (knowledge_base_id) REFERENCES public.knowledge_base_t(knowledge_base_id) ON DELETE RESTRICT;


--
-- Name: knowledge_index_pointer_history_t knowledge_index_pointer_history_t_knowledge_base_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_index_pointer_history_t
    ADD CONSTRAINT knowledge_index_pointer_history_t_knowledge_base_id_fkey FOREIGN KEY (knowledge_base_id) REFERENCES public.knowledge_base_t(knowledge_base_id) ON DELETE RESTRICT;


--
-- Name: knowledge_index_pointer_history_t knowledge_index_pointer_history_t_previous_generation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_index_pointer_history_t
    ADD CONSTRAINT knowledge_index_pointer_history_t_previous_generation_id_fkey FOREIGN KEY (previous_generation_id) REFERENCES public.knowledge_index_generation_t(index_generation_id) ON DELETE RESTRICT;


--
-- Name: knowledge_index_pointer_history_t knowledge_index_pointer_history_t_selected_generation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_index_pointer_history_t
    ADD CONSTRAINT knowledge_index_pointer_history_t_selected_generation_id_fkey FOREIGN KEY (selected_generation_id) REFERENCES public.knowledge_index_generation_t(index_generation_id) ON DELETE RESTRICT;


--
-- Name: knowledge_index_pointer_t knowledge_index_pointer_t_index_generation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_index_pointer_t
    ADD CONSTRAINT knowledge_index_pointer_t_index_generation_id_fkey FOREIGN KEY (index_generation_id) REFERENCES public.knowledge_index_generation_t(index_generation_id) ON DELETE RESTRICT;


--
-- Name: knowledge_index_pointer_t knowledge_index_pointer_t_knowledge_base_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_index_pointer_t
    ADD CONSTRAINT knowledge_index_pointer_t_knowledge_base_id_fkey FOREIGN KEY (knowledge_base_id) REFERENCES public.knowledge_base_t(knowledge_base_id) ON DELETE RESTRICT;


--
-- Name: knowledge_index_segment_t knowledge_index_segment_predecessor_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_index_segment_t
    ADD CONSTRAINT knowledge_index_segment_predecessor_fk FOREIGN KEY (predecessor_segment_id) REFERENCES public.knowledge_index_segment_t(index_segment_id) ON DELETE RESTRICT;


--
-- Name: knowledge_index_segment_t knowledge_index_segment_t_index_generation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_index_segment_t
    ADD CONSTRAINT knowledge_index_segment_t_index_generation_id_fkey FOREIGN KEY (index_generation_id) REFERENCES public.knowledge_index_generation_t(index_generation_id) ON DELETE RESTRICT;


--
-- Name: knowledge_index_segment_t knowledge_index_segment_t_knowledge_base_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_index_segment_t
    ADD CONSTRAINT knowledge_index_segment_t_knowledge_base_id_fkey FOREIGN KEY (knowledge_base_id) REFERENCES public.knowledge_base_t(knowledge_base_id) ON DELETE RESTRICT;


--
-- Name: knowledge_ingestion_error_t knowledge_ingestion_error_t_sync_run_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_ingestion_error_t
    ADD CONSTRAINT knowledge_ingestion_error_t_sync_run_id_fkey FOREIGN KEY (sync_run_id) REFERENCES public.knowledge_sync_run_t(sync_run_id) ON DELETE RESTRICT;


--
-- Name: knowledge_job_t knowledge_job_t_knowledge_base_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_job_t
    ADD CONSTRAINT knowledge_job_t_knowledge_base_id_fkey FOREIGN KEY (knowledge_base_id) REFERENCES public.knowledge_base_t(knowledge_base_id) ON DELETE RESTRICT;


--
-- Name: knowledge_job_t knowledge_job_t_source_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_job_t
    ADD CONSTRAINT knowledge_job_t_source_id_fkey FOREIGN KEY (source_id) REFERENCES public.knowledge_source_t(source_id) ON DELETE RESTRICT;


--
-- Name: knowledge_migration_evaluation_t knowledge_migration_evaluatio_migration_id_knowledge_base__fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_migration_evaluation_t
    ADD CONSTRAINT knowledge_migration_evaluatio_migration_id_knowledge_base__fkey FOREIGN KEY (migration_id, knowledge_base_id) REFERENCES public.knowledge_embedding_migration_t(migration_id, knowledge_base_id) ON DELETE RESTRICT;


--
-- Name: knowledge_migration_evaluation_t knowledge_migration_evaluation_t_candidate_generation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_migration_evaluation_t
    ADD CONSTRAINT knowledge_migration_evaluation_t_candidate_generation_id_fkey FOREIGN KEY (candidate_generation_id) REFERENCES public.knowledge_index_generation_t(index_generation_id) ON DELETE RESTRICT;


--
-- Name: knowledge_operational_policy_t knowledge_operational_policy_t_knowledge_base_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_operational_policy_t
    ADD CONSTRAINT knowledge_operational_policy_t_knowledge_base_id_fkey FOREIGN KEY (knowledge_base_id) REFERENCES public.knowledge_base_t(knowledge_base_id) ON DELETE RESTRICT;


--
-- Name: knowledge_passage_anchor_t knowledge_passage_anchor_t_chunk_id_knowledge_base_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_passage_anchor_t
    ADD CONSTRAINT knowledge_passage_anchor_t_chunk_id_knowledge_base_id_fkey FOREIGN KEY (chunk_id, knowledge_base_id) REFERENCES public.knowledge_chunk_t(chunk_id, knowledge_base_id) ON DELETE RESTRICT;


--
-- Name: knowledge_passage_anchor_t knowledge_passage_anchor_t_document_id_knowledge_base_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_passage_anchor_t
    ADD CONSTRAINT knowledge_passage_anchor_t_document_id_knowledge_base_id_fkey FOREIGN KEY (document_id, knowledge_base_id) REFERENCES public.knowledge_document_t(document_id, knowledge_base_id) ON DELETE RESTRICT;


--
-- Name: knowledge_passage_anchor_t knowledge_passage_anchor_t_document_version_id_knowledge_b_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_passage_anchor_t
    ADD CONSTRAINT knowledge_passage_anchor_t_document_version_id_knowledge_b_fkey FOREIGN KEY (document_version_id, knowledge_base_id) REFERENCES public.knowledge_document_version_t(document_version_id, knowledge_base_id) ON DELETE RESTRICT;


--
-- Name: knowledge_promotion_receipt_t knowledge_promotion_receipt_t_index_generation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_promotion_receipt_t
    ADD CONSTRAINT knowledge_promotion_receipt_t_index_generation_id_fkey FOREIGN KEY (index_generation_id) REFERENCES public.knowledge_index_generation_t(index_generation_id) ON DELETE RESTRICT;


--
-- Name: knowledge_promotion_receipt_t knowledge_promotion_receipt_t_knowledge_base_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_promotion_receipt_t
    ADD CONSTRAINT knowledge_promotion_receipt_t_knowledge_base_id_fkey FOREIGN KEY (knowledge_base_id) REFERENCES public.knowledge_base_t(knowledge_base_id) ON DELETE RESTRICT;


--
-- Name: knowledge_purge_evidence_t knowledge_purge_evidence_t_index_generation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_purge_evidence_t
    ADD CONSTRAINT knowledge_purge_evidence_t_index_generation_id_fkey FOREIGN KEY (index_generation_id) REFERENCES public.knowledge_index_generation_t(index_generation_id) ON DELETE RESTRICT;


--
-- Name: knowledge_purge_evidence_t knowledge_purge_evidence_t_knowledge_base_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_purge_evidence_t
    ADD CONSTRAINT knowledge_purge_evidence_t_knowledge_base_id_fkey FOREIGN KEY (knowledge_base_id) REFERENCES public.knowledge_base_t(knowledge_base_id) ON DELETE RESTRICT;


--
-- Name: knowledge_query_admission_t knowledge_query_admission_t_knowledge_base_id_consumer_hos_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_query_admission_t
    ADD CONSTRAINT knowledge_query_admission_t_knowledge_base_id_consumer_hos_fkey FOREIGN KEY (knowledge_base_id, consumer_host_id) REFERENCES public.knowledge_consumer_quota_t(knowledge_base_id, consumer_host_id) ON DELETE RESTRICT;


--
-- Name: knowledge_query_audit_t knowledge_query_audit_graph_generation_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_query_audit_t
    ADD CONSTRAINT knowledge_query_audit_graph_generation_fk FOREIGN KEY (graph_generation_id) REFERENCES public.knowledge_graph_generation_t(graph_generation_id) ON DELETE RESTRICT;


--
-- Name: knowledge_query_audit_t knowledge_query_audit_t_index_generation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_query_audit_t
    ADD CONSTRAINT knowledge_query_audit_t_index_generation_id_fkey FOREIGN KEY (index_generation_id) REFERENCES public.knowledge_index_generation_t(index_generation_id) ON DELETE RESTRICT;


--
-- Name: knowledge_query_audit_t knowledge_query_audit_t_knowledge_base_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_query_audit_t
    ADD CONSTRAINT knowledge_query_audit_t_knowledge_base_id_fkey FOREIGN KEY (knowledge_base_id) REFERENCES public.knowledge_base_t(knowledge_base_id) ON DELETE RESTRICT;


--
-- Name: knowledge_query_audit_t knowledge_query_audit_t_retrieval_profile_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_query_audit_t
    ADD CONSTRAINT knowledge_query_audit_t_retrieval_profile_id_fkey FOREIGN KEY (retrieval_profile_id) REFERENCES public.knowledge_retrieval_profile_t(profile_id) ON DELETE RESTRICT;


--
-- Name: knowledge_query_usage_t knowledge_query_usage_t_knowledge_base_id_consumer_host_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_query_usage_t
    ADD CONSTRAINT knowledge_query_usage_t_knowledge_base_id_consumer_host_id_fkey FOREIGN KEY (knowledge_base_id, consumer_host_id) REFERENCES public.knowledge_consumer_quota_t(knowledge_base_id, consumer_host_id) ON DELETE RESTRICT;


--
-- Name: knowledge_runtime_authorization_t knowledge_runtime_authorization_t_knowledge_base_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_runtime_authorization_t
    ADD CONSTRAINT knowledge_runtime_authorization_t_knowledge_base_id_fkey FOREIGN KEY (knowledge_base_id) REFERENCES public.knowledge_base_t(knowledge_base_id) ON DELETE RESTRICT;


--
-- Name: knowledge_runtime_authorization_t knowledge_runtime_authorization_t_retrieval_profile_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_runtime_authorization_t
    ADD CONSTRAINT knowledge_runtime_authorization_t_retrieval_profile_id_fkey FOREIGN KEY (retrieval_profile_id) REFERENCES public.knowledge_retrieval_profile_t(profile_id) ON DELETE RESTRICT;


--
-- Name: knowledge_segment_chunk_t knowledge_segment_chunk_t_acl_revision_id_knowledge_base_i_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_segment_chunk_t
    ADD CONSTRAINT knowledge_segment_chunk_t_acl_revision_id_knowledge_base_i_fkey FOREIGN KEY (acl_revision_id, knowledge_base_id) REFERENCES public.knowledge_document_acl_t(acl_revision_id, knowledge_base_id) ON DELETE RESTRICT;


--
-- Name: knowledge_segment_chunk_t knowledge_segment_chunk_t_chunk_id_knowledge_base_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_segment_chunk_t
    ADD CONSTRAINT knowledge_segment_chunk_t_chunk_id_knowledge_base_id_fkey FOREIGN KEY (chunk_id, knowledge_base_id) REFERENCES public.knowledge_chunk_t(chunk_id, knowledge_base_id) ON DELETE RESTRICT;


--
-- Name: knowledge_segment_chunk_t knowledge_segment_chunk_t_index_segment_id_knowledge_base__fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_segment_chunk_t
    ADD CONSTRAINT knowledge_segment_chunk_t_index_segment_id_knowledge_base__fkey FOREIGN KEY (index_segment_id, knowledge_base_id) REFERENCES public.knowledge_index_segment_t(index_segment_id, knowledge_base_id) ON DELETE RESTRICT;


--
-- Name: knowledge_segment_document_t knowledge_segment_document_t_acl_revision_id_knowledge_bas_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_segment_document_t
    ADD CONSTRAINT knowledge_segment_document_t_acl_revision_id_knowledge_bas_fkey FOREIGN KEY (acl_revision_id, knowledge_base_id) REFERENCES public.knowledge_document_acl_t(acl_revision_id, knowledge_base_id) ON DELETE RESTRICT;


--
-- Name: knowledge_segment_document_t knowledge_segment_document_t_document_version_id_knowledge_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_segment_document_t
    ADD CONSTRAINT knowledge_segment_document_t_document_version_id_knowledge_fkey FOREIGN KEY (document_version_id, knowledge_base_id) REFERENCES public.knowledge_document_version_t(document_version_id, knowledge_base_id) ON DELETE RESTRICT;


--
-- Name: knowledge_segment_document_t knowledge_segment_document_t_index_segment_id_knowledge_ba_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_segment_document_t
    ADD CONSTRAINT knowledge_segment_document_t_index_segment_id_knowledge_ba_fkey FOREIGN KEY (index_segment_id, knowledge_base_id) REFERENCES public.knowledge_index_segment_t(index_segment_id, knowledge_base_id) ON DELETE RESTRICT;


--
-- Name: knowledge_segment_operation_t knowledge_segment_operation_t_document_id_knowledge_base_i_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_segment_operation_t
    ADD CONSTRAINT knowledge_segment_operation_t_document_id_knowledge_base_i_fkey FOREIGN KEY (document_id, knowledge_base_id) REFERENCES public.knowledge_document_t(document_id, knowledge_base_id) ON DELETE RESTRICT;


--
-- Name: knowledge_segment_operation_t knowledge_segment_operation_t_index_segment_id_knowledge_b_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_segment_operation_t
    ADD CONSTRAINT knowledge_segment_operation_t_index_segment_id_knowledge_b_fkey FOREIGN KEY (index_segment_id, knowledge_base_id) REFERENCES public.knowledge_index_segment_t(index_segment_id, knowledge_base_id) ON DELETE RESTRICT;


--
-- Name: knowledge_segment_vector_t knowledge_segment_vector_t_embedding_artifact_id_dimension_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_segment_vector_t
    ADD CONSTRAINT knowledge_segment_vector_t_embedding_artifact_id_dimension_fkey FOREIGN KEY (embedding_artifact_id, dimension) REFERENCES public.knowledge_embedding_artifact_t(embedding_artifact_id, dimension) ON DELETE RESTRICT;


--
-- Name: knowledge_segment_vector_t knowledge_segment_vector_t_index_segment_id_chunk_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_segment_vector_t
    ADD CONSTRAINT knowledge_segment_vector_t_index_segment_id_chunk_id_fkey FOREIGN KEY (index_segment_id, chunk_id) REFERENCES public.knowledge_segment_chunk_t(index_segment_id, chunk_id) ON DELETE RESTRICT;


--
-- Name: knowledge_source_acl_state_t knowledge_source_acl_state_t_knowledge_base_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_source_acl_state_t
    ADD CONSTRAINT knowledge_source_acl_state_t_knowledge_base_id_fkey FOREIGN KEY (knowledge_base_id) REFERENCES public.knowledge_base_t(knowledge_base_id) ON DELETE RESTRICT;


--
-- Name: knowledge_source_acl_state_t knowledge_source_acl_state_t_reconciliation_id_knowledge_b_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_source_acl_state_t
    ADD CONSTRAINT knowledge_source_acl_state_t_reconciliation_id_knowledge_b_fkey FOREIGN KEY (reconciliation_id, knowledge_base_id) REFERENCES public.knowledge_acl_reconciliation_t(reconciliation_id, knowledge_base_id) ON DELETE RESTRICT;


--
-- Name: knowledge_source_acl_state_t knowledge_source_acl_state_t_source_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_source_acl_state_t
    ADD CONSTRAINT knowledge_source_acl_state_t_source_id_fkey FOREIGN KEY (source_id) REFERENCES public.knowledge_source_t(source_id) ON DELETE RESTRICT;


--
-- Name: knowledge_source_change_t knowledge_source_change_t_knowledge_base_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_source_change_t
    ADD CONSTRAINT knowledge_source_change_t_knowledge_base_id_fkey FOREIGN KEY (knowledge_base_id) REFERENCES public.knowledge_base_t(knowledge_base_id) ON DELETE RESTRICT;


--
-- Name: knowledge_source_change_t knowledge_source_change_t_source_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_source_change_t
    ADD CONSTRAINT knowledge_source_change_t_source_id_fkey FOREIGN KEY (source_id) REFERENCES public.knowledge_source_t(source_id) ON DELETE RESTRICT;


--
-- Name: knowledge_source_change_t knowledge_source_change_t_sync_run_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_source_change_t
    ADD CONSTRAINT knowledge_source_change_t_sync_run_id_fkey FOREIGN KEY (sync_run_id) REFERENCES public.knowledge_sync_run_t(sync_run_id) ON DELETE RESTRICT;


--
-- Name: knowledge_source_cursor_t knowledge_source_cursor_t_knowledge_base_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_source_cursor_t
    ADD CONSTRAINT knowledge_source_cursor_t_knowledge_base_id_fkey FOREIGN KEY (knowledge_base_id) REFERENCES public.knowledge_base_t(knowledge_base_id) ON DELETE RESTRICT;


--
-- Name: knowledge_source_cursor_t knowledge_source_cursor_t_source_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_source_cursor_t
    ADD CONSTRAINT knowledge_source_cursor_t_source_id_fkey FOREIGN KEY (source_id) REFERENCES public.knowledge_source_t(source_id) ON DELETE RESTRICT;


--
-- Name: knowledge_source_t knowledge_source_t_ingestion_policy_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_source_t
    ADD CONSTRAINT knowledge_source_t_ingestion_policy_id_fkey FOREIGN KEY (ingestion_policy_id) REFERENCES public.knowledge_ingestion_policy_t(ingestion_policy_id) ON DELETE RESTRICT;


--
-- Name: knowledge_source_t knowledge_source_t_knowledge_base_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_source_t
    ADD CONSTRAINT knowledge_source_t_knowledge_base_id_fkey FOREIGN KEY (knowledge_base_id) REFERENCES public.knowledge_base_t(knowledge_base_id) ON DELETE RESTRICT;


--
-- Name: knowledge_subject_mapping_t knowledge_subject_mapping_t_source_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_subject_mapping_t
    ADD CONSTRAINT knowledge_subject_mapping_t_source_id_fkey FOREIGN KEY (source_id) REFERENCES public.knowledge_source_t(source_id) ON DELETE RESTRICT;


--
-- Name: knowledge_sync_run_t knowledge_sync_run_generation_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_sync_run_t
    ADD CONSTRAINT knowledge_sync_run_generation_fk FOREIGN KEY (index_generation_id) REFERENCES public.knowledge_index_generation_t(index_generation_id) ON DELETE RESTRICT;


--
-- Name: knowledge_sync_run_t knowledge_sync_run_job_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_sync_run_t
    ADD CONSTRAINT knowledge_sync_run_job_fk FOREIGN KEY (job_id) REFERENCES public.knowledge_job_t(job_id) ON DELETE RESTRICT;


--
-- Name: knowledge_sync_run_t knowledge_sync_run_policy_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_sync_run_t
    ADD CONSTRAINT knowledge_sync_run_policy_fk FOREIGN KEY (ingestion_policy_id) REFERENCES public.knowledge_ingestion_policy_t(ingestion_policy_id) ON DELETE RESTRICT;


--
-- Name: knowledge_sync_run_t knowledge_sync_run_t_knowledge_base_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_sync_run_t
    ADD CONSTRAINT knowledge_sync_run_t_knowledge_base_id_fkey FOREIGN KEY (knowledge_base_id) REFERENCES public.knowledge_base_t(knowledge_base_id) ON DELETE RESTRICT;


--
-- Name: knowledge_sync_run_t knowledge_sync_run_t_source_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_sync_run_t
    ADD CONSTRAINT knowledge_sync_run_t_source_id_fkey FOREIGN KEY (source_id) REFERENCES public.knowledge_source_t(source_id) ON DELETE RESTRICT;


--
-- Name: knowledge_upload_t knowledge_upload_t_knowledge_base_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_upload_t
    ADD CONSTRAINT knowledge_upload_t_knowledge_base_id_fkey FOREIGN KEY (knowledge_base_id) REFERENCES public.knowledge_base_t(knowledge_base_id) ON DELETE RESTRICT;


--
-- Name: knowledge_upload_t knowledge_upload_t_source_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knowledge_upload_t
    ADD CONSTRAINT knowledge_upload_t_source_id_fkey FOREIGN KEY (source_id) REFERENCES public.knowledge_source_t(source_id) ON DELETE RESTRICT;


--
-- Name: SCHEMA public; Type: ACL; Schema: -; Owner: -
--

GRANT USAGE ON SCHEMA public TO light_knowledge_api_role;
GRANT USAGE ON SCHEMA public TO light_knowledge_worker_role;
GRANT USAGE ON SCHEMA public TO light_knowledge_ops_read_role;
GRANT ALL ON SCHEMA public TO light_knowledge_schema_migration_role;
GRANT USAGE ON SCHEMA public TO light_knowledge_admin_api_role;
GRANT USAGE ON SCHEMA public TO light_knowledge_snapshot_loader_role;


--
-- Name: FUNCTION knowledge_resolved_generation_chunk(p_index_generation_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.knowledge_resolved_generation_chunk(p_index_generation_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.knowledge_resolved_generation_chunk(p_index_generation_id uuid) TO light_knowledge_worker_role;


--
-- Name: FUNCTION promote_knowledge_base_generation(p_promotion_id uuid, p_history_id uuid, p_knowledge_base_id uuid, p_environment character varying, p_generation_id uuid, p_expected_pointer_version bigint, p_authorized_by character varying, p_reason text, p_evidence jsonb, p_evidence_digest character varying, p_rollback_deadline timestamp with time zone); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.promote_knowledge_base_generation(p_promotion_id uuid, p_history_id uuid, p_knowledge_base_id uuid, p_environment character varying, p_generation_id uuid, p_expected_pointer_version bigint, p_authorized_by character varying, p_reason text, p_evidence jsonb, p_evidence_digest character varying, p_rollback_deadline timestamp with time zone) FROM PUBLIC;
GRANT ALL ON FUNCTION public.promote_knowledge_base_generation(p_promotion_id uuid, p_history_id uuid, p_knowledge_base_id uuid, p_environment character varying, p_generation_id uuid, p_expected_pointer_version bigint, p_authorized_by character varying, p_reason text, p_evidence jsonb, p_evidence_digest character varying, p_rollback_deadline timestamp with time zone) TO light_knowledge_worker_role;


--
-- Name: TABLE agent_knowledge_base_t; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.agent_knowledge_base_t TO light_knowledge_api_role;
GRANT SELECT ON TABLE public.agent_knowledge_base_t TO light_knowledge_worker_role;
GRANT SELECT ON TABLE public.agent_knowledge_base_t TO light_knowledge_ops_read_role;
GRANT SELECT ON TABLE public.agent_knowledge_base_t TO light_knowledge_admin_api_role;
GRANT SELECT,INSERT,UPDATE ON TABLE public.agent_knowledge_base_t TO light_knowledge_snapshot_loader_role;


--
-- Name: TABLE knowledge_acl_reconciliation_t; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.knowledge_acl_reconciliation_t TO light_knowledge_worker_role;
GRANT SELECT ON TABLE public.knowledge_acl_reconciliation_t TO light_knowledge_ops_read_role;
GRANT SELECT ON TABLE public.knowledge_acl_reconciliation_t TO light_knowledge_admin_api_role;


--
-- Name: TABLE knowledge_acl_subject_t; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.knowledge_acl_subject_t TO light_knowledge_api_role;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.knowledge_acl_subject_t TO light_knowledge_worker_role;
GRANT SELECT ON TABLE public.knowledge_acl_subject_t TO light_knowledge_ops_read_role;
GRANT SELECT ON TABLE public.knowledge_acl_subject_t TO light_knowledge_admin_api_role;


--
-- Name: TABLE knowledge_acl_transition_t; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.knowledge_acl_transition_t TO light_knowledge_ops_read_role;
GRANT SELECT,INSERT ON TABLE public.knowledge_acl_transition_t TO light_knowledge_worker_role;
GRANT SELECT ON TABLE public.knowledge_acl_transition_t TO light_knowledge_admin_api_role;


--
-- Name: TABLE knowledge_anti_entropy_run_t; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.knowledge_anti_entropy_run_t TO light_knowledge_worker_role;
GRANT SELECT ON TABLE public.knowledge_anti_entropy_run_t TO light_knowledge_ops_read_role;
GRANT SELECT ON TABLE public.knowledge_anti_entropy_run_t TO light_knowledge_admin_api_role;


--
-- Name: TABLE knowledge_backup_checkpoint_t; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.knowledge_backup_checkpoint_t TO light_knowledge_worker_role;
GRANT SELECT ON TABLE public.knowledge_backup_checkpoint_t TO light_knowledge_ops_read_role;
GRANT SELECT ON TABLE public.knowledge_backup_checkpoint_t TO light_knowledge_admin_api_role;


--
-- Name: TABLE knowledge_base_strategy_qualification_t; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.knowledge_base_strategy_qualification_t TO light_knowledge_api_role;
GRANT SELECT ON TABLE public.knowledge_base_strategy_qualification_t TO light_knowledge_worker_role;
GRANT SELECT ON TABLE public.knowledge_base_strategy_qualification_t TO light_knowledge_ops_read_role;
GRANT SELECT ON TABLE public.knowledge_base_strategy_qualification_t TO light_knowledge_admin_api_role;
GRANT SELECT,INSERT,UPDATE ON TABLE public.knowledge_base_strategy_qualification_t TO light_knowledge_snapshot_loader_role;


--
-- Name: TABLE knowledge_base_t; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.knowledge_base_t TO light_knowledge_api_role;
GRANT SELECT ON TABLE public.knowledge_base_t TO light_knowledge_worker_role;
GRANT SELECT ON TABLE public.knowledge_base_t TO light_knowledge_ops_read_role;
GRANT SELECT ON TABLE public.knowledge_base_t TO light_knowledge_admin_api_role;
GRANT SELECT,INSERT,UPDATE ON TABLE public.knowledge_base_t TO light_knowledge_snapshot_loader_role;


--
-- Name: TABLE knowledge_chunk_embedding_t; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.knowledge_chunk_embedding_t TO light_knowledge_api_role;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.knowledge_chunk_embedding_t TO light_knowledge_worker_role;
GRANT SELECT ON TABLE public.knowledge_chunk_embedding_t TO light_knowledge_ops_read_role;


--
-- Name: TABLE knowledge_chunk_t; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.knowledge_chunk_t TO light_knowledge_api_role;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.knowledge_chunk_t TO light_knowledge_worker_role;
GRANT SELECT ON TABLE public.knowledge_chunk_t TO light_knowledge_ops_read_role;
GRANT SELECT ON TABLE public.knowledge_chunk_t TO light_knowledge_admin_api_role;


--
-- Name: TABLE knowledge_compaction_run_t; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.knowledge_compaction_run_t TO light_knowledge_worker_role;
GRANT SELECT ON TABLE public.knowledge_compaction_run_t TO light_knowledge_ops_read_role;
GRANT SELECT ON TABLE public.knowledge_compaction_run_t TO light_knowledge_admin_api_role;


--
-- Name: TABLE knowledge_connector_notification_t; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.knowledge_connector_notification_t TO light_knowledge_worker_role;
GRANT SELECT ON TABLE public.knowledge_connector_notification_t TO light_knowledge_ops_read_role;


--
-- Name: TABLE knowledge_connector_object_t; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.knowledge_connector_object_t TO light_knowledge_api_role;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.knowledge_connector_object_t TO light_knowledge_worker_role;
GRANT SELECT ON TABLE public.knowledge_connector_object_t TO light_knowledge_ops_read_role;
GRANT SELECT ON TABLE public.knowledge_connector_object_t TO light_knowledge_admin_api_role;


--
-- Name: TABLE knowledge_consumer_quota_t; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.knowledge_consumer_quota_t TO light_knowledge_api_role;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.knowledge_consumer_quota_t TO light_knowledge_worker_role;
GRANT SELECT ON TABLE public.knowledge_consumer_quota_t TO light_knowledge_ops_read_role;


--
-- Name: TABLE knowledge_control_snapshot_t; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,UPDATE,DELETE ON TABLE public.knowledge_control_snapshot_t TO light_knowledge_admin_api_role;
GRANT SELECT ON TABLE public.knowledge_control_snapshot_t TO light_knowledge_api_role;
GRANT SELECT ON TABLE public.knowledge_control_snapshot_t TO light_knowledge_worker_role;
GRANT SELECT,INSERT,UPDATE ON TABLE public.knowledge_control_snapshot_t TO light_knowledge_snapshot_loader_role;


--
-- Name: TABLE knowledge_document_acl_t; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.knowledge_document_acl_t TO light_knowledge_api_role;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.knowledge_document_acl_t TO light_knowledge_worker_role;
GRANT SELECT ON TABLE public.knowledge_document_acl_t TO light_knowledge_ops_read_role;
GRANT SELECT ON TABLE public.knowledge_document_acl_t TO light_knowledge_admin_api_role;


--
-- Name: COLUMN knowledge_document_acl_t.reconciliation_id; Type: ACL; Schema: public; Owner: -
--

GRANT UPDATE(reconciliation_id) ON TABLE public.knowledge_document_acl_t TO light_knowledge_worker_role;


--
-- Name: COLUMN knowledge_document_acl_t.provider_effective_decision; Type: ACL; Schema: public; Owner: -
--

GRANT UPDATE(provider_effective_decision) ON TABLE public.knowledge_document_acl_t TO light_knowledge_worker_role;


--
-- Name: TABLE knowledge_document_t; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.knowledge_document_t TO light_knowledge_api_role;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.knowledge_document_t TO light_knowledge_worker_role;
GRANT SELECT ON TABLE public.knowledge_document_t TO light_knowledge_ops_read_role;
GRANT SELECT ON TABLE public.knowledge_document_t TO light_knowledge_admin_api_role;


--
-- Name: TABLE knowledge_document_version_t; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.knowledge_document_version_t TO light_knowledge_api_role;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.knowledge_document_version_t TO light_knowledge_worker_role;
GRANT SELECT ON TABLE public.knowledge_document_version_t TO light_knowledge_ops_read_role;


--
-- Name: TABLE knowledge_embedding_artifact_t; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.knowledge_embedding_artifact_t TO light_knowledge_api_role;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.knowledge_embedding_artifact_t TO light_knowledge_worker_role;
GRANT SELECT ON TABLE public.knowledge_embedding_artifact_t TO light_knowledge_ops_read_role;


--
-- Name: TABLE knowledge_embedding_migration_chunk_t; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.knowledge_embedding_migration_chunk_t TO light_knowledge_worker_role;
GRANT SELECT ON TABLE public.knowledge_embedding_migration_chunk_t TO light_knowledge_ops_read_role;


--
-- Name: TABLE knowledge_embedding_migration_t; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.knowledge_embedding_migration_t TO light_knowledge_worker_role;
GRANT SELECT ON TABLE public.knowledge_embedding_migration_t TO light_knowledge_ops_read_role;
GRANT SELECT ON TABLE public.knowledge_embedding_migration_t TO light_knowledge_admin_api_role;


--
-- Name: TABLE knowledge_embedding_profile_t; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.knowledge_embedding_profile_t TO light_knowledge_api_role;
GRANT SELECT ON TABLE public.knowledge_embedding_profile_t TO light_knowledge_worker_role;
GRANT SELECT ON TABLE public.knowledge_embedding_profile_t TO light_knowledge_ops_read_role;
GRANT SELECT,INSERT,UPDATE ON TABLE public.knowledge_embedding_profile_t TO light_knowledge_snapshot_loader_role;


--
-- Name: TABLE knowledge_embedding_profile_runtime_v; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.knowledge_embedding_profile_runtime_v TO light_knowledge_api_role;
GRANT SELECT ON TABLE public.knowledge_embedding_profile_runtime_v TO light_knowledge_worker_role;
GRANT SELECT ON TABLE public.knowledge_embedding_profile_runtime_v TO light_knowledge_admin_api_role;


--
-- Name: TABLE knowledge_embedding_reference_t; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.knowledge_embedding_reference_t TO light_knowledge_worker_role;
GRANT SELECT ON TABLE public.knowledge_embedding_reference_t TO light_knowledge_ops_read_role;


--
-- Name: TABLE knowledge_generation_retention_t; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.knowledge_generation_retention_t TO light_knowledge_worker_role;
GRANT SELECT ON TABLE public.knowledge_generation_retention_t TO light_knowledge_ops_read_role;
GRANT SELECT ON TABLE public.knowledge_generation_retention_t TO light_knowledge_admin_api_role;


--
-- Name: TABLE knowledge_generation_segment_t; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.knowledge_generation_segment_t TO light_knowledge_api_role;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.knowledge_generation_segment_t TO light_knowledge_worker_role;
GRANT SELECT ON TABLE public.knowledge_generation_segment_t TO light_knowledge_ops_read_role;


--
-- Name: TABLE knowledge_graph_entity_contribution_t; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.knowledge_graph_entity_contribution_t TO light_knowledge_worker_role;
GRANT SELECT ON TABLE public.knowledge_graph_entity_contribution_t TO light_knowledge_api_role;
GRANT SELECT ON TABLE public.knowledge_graph_entity_contribution_t TO light_knowledge_ops_read_role;


--
-- Name: TABLE knowledge_graph_entity_t; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.knowledge_graph_entity_t TO light_knowledge_worker_role;
GRANT SELECT ON TABLE public.knowledge_graph_entity_t TO light_knowledge_api_role;
GRANT SELECT ON TABLE public.knowledge_graph_entity_t TO light_knowledge_ops_read_role;


--
-- Name: TABLE knowledge_graph_generation_t; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.knowledge_graph_generation_t TO light_knowledge_worker_role;
GRANT SELECT ON TABLE public.knowledge_graph_generation_t TO light_knowledge_api_role;
GRANT SELECT ON TABLE public.knowledge_graph_generation_t TO light_knowledge_ops_read_role;


--
-- Name: TABLE knowledge_graph_relation_contribution_t; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.knowledge_graph_relation_contribution_t TO light_knowledge_worker_role;
GRANT SELECT ON TABLE public.knowledge_graph_relation_contribution_t TO light_knowledge_api_role;
GRANT SELECT ON TABLE public.knowledge_graph_relation_contribution_t TO light_knowledge_ops_read_role;


--
-- Name: TABLE knowledge_graph_relation_t; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.knowledge_graph_relation_t TO light_knowledge_worker_role;
GRANT SELECT ON TABLE public.knowledge_graph_relation_t TO light_knowledge_api_role;
GRANT SELECT ON TABLE public.knowledge_graph_relation_t TO light_knowledge_ops_read_role;


--
-- Name: TABLE knowledge_index_generation_t; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.knowledge_index_generation_t TO light_knowledge_api_role;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.knowledge_index_generation_t TO light_knowledge_worker_role;
GRANT SELECT ON TABLE public.knowledge_index_generation_t TO light_knowledge_ops_read_role;
GRANT SELECT ON TABLE public.knowledge_index_generation_t TO light_knowledge_admin_api_role;


--
-- Name: TABLE knowledge_index_pointer_history_t; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.knowledge_index_pointer_history_t TO light_knowledge_api_role;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.knowledge_index_pointer_history_t TO light_knowledge_worker_role;
GRANT SELECT ON TABLE public.knowledge_index_pointer_history_t TO light_knowledge_ops_read_role;


--
-- Name: TABLE knowledge_index_pointer_t; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.knowledge_index_pointer_t TO light_knowledge_api_role;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.knowledge_index_pointer_t TO light_knowledge_worker_role;
GRANT SELECT ON TABLE public.knowledge_index_pointer_t TO light_knowledge_ops_read_role;
GRANT SELECT ON TABLE public.knowledge_index_pointer_t TO light_knowledge_admin_api_role;


--
-- Name: TABLE knowledge_index_segment_t; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.knowledge_index_segment_t TO light_knowledge_api_role;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.knowledge_index_segment_t TO light_knowledge_worker_role;
GRANT SELECT ON TABLE public.knowledge_index_segment_t TO light_knowledge_ops_read_role;
GRANT SELECT ON TABLE public.knowledge_index_segment_t TO light_knowledge_admin_api_role;


--
-- Name: TABLE knowledge_ingestion_error_t; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.knowledge_ingestion_error_t TO light_knowledge_worker_role;
GRANT SELECT ON TABLE public.knowledge_ingestion_error_t TO light_knowledge_ops_read_role;


--
-- Name: TABLE knowledge_ingestion_policy_t; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.knowledge_ingestion_policy_t TO light_knowledge_api_role;
GRANT SELECT ON TABLE public.knowledge_ingestion_policy_t TO light_knowledge_worker_role;
GRANT SELECT ON TABLE public.knowledge_ingestion_policy_t TO light_knowledge_ops_read_role;
GRANT SELECT ON TABLE public.knowledge_ingestion_policy_t TO light_knowledge_admin_api_role;
GRANT SELECT,INSERT,UPDATE ON TABLE public.knowledge_ingestion_policy_t TO light_knowledge_snapshot_loader_role;


--
-- Name: TABLE knowledge_job_t; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.knowledge_job_t TO light_knowledge_worker_role;
GRANT SELECT ON TABLE public.knowledge_job_t TO light_knowledge_ops_read_role;
GRANT INSERT ON TABLE public.knowledge_job_t TO light_knowledge_api_role;
GRANT SELECT,INSERT,UPDATE ON TABLE public.knowledge_job_t TO light_knowledge_admin_api_role;


--
-- Name: TABLE knowledge_migration_evaluation_t; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.knowledge_migration_evaluation_t TO light_knowledge_worker_role;
GRANT SELECT ON TABLE public.knowledge_migration_evaluation_t TO light_knowledge_ops_read_role;
GRANT SELECT ON TABLE public.knowledge_migration_evaluation_t TO light_knowledge_admin_api_role;


--
-- Name: TABLE knowledge_operational_policy_t; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.knowledge_operational_policy_t TO light_knowledge_worker_role;
GRANT SELECT ON TABLE public.knowledge_operational_policy_t TO light_knowledge_ops_read_role;
GRANT SELECT ON TABLE public.knowledge_operational_policy_t TO light_knowledge_admin_api_role;


--
-- Name: TABLE knowledge_passage_anchor_t; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.knowledge_passage_anchor_t TO light_knowledge_api_role;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.knowledge_passage_anchor_t TO light_knowledge_worker_role;
GRANT SELECT ON TABLE public.knowledge_passage_anchor_t TO light_knowledge_ops_read_role;
GRANT SELECT ON TABLE public.knowledge_passage_anchor_t TO light_knowledge_admin_api_role;


--
-- Name: TABLE knowledge_promotion_receipt_t; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.knowledge_promotion_receipt_t TO light_knowledge_admin_api_role;
GRANT SELECT ON TABLE public.knowledge_promotion_receipt_t TO light_knowledge_ops_read_role;
GRANT SELECT,INSERT ON TABLE public.knowledge_promotion_receipt_t TO light_knowledge_worker_role;


--
-- Name: TABLE knowledge_purge_evidence_t; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.knowledge_purge_evidence_t TO light_knowledge_worker_role;
GRANT SELECT ON TABLE public.knowledge_purge_evidence_t TO light_knowledge_ops_read_role;
GRANT SELECT ON TABLE public.knowledge_purge_evidence_t TO light_knowledge_admin_api_role;


--
-- Name: TABLE knowledge_query_admission_t; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,UPDATE ON TABLE public.knowledge_query_admission_t TO light_knowledge_api_role;
GRANT SELECT ON TABLE public.knowledge_query_admission_t TO light_knowledge_ops_read_role;


--
-- Name: TABLE knowledge_query_audit_t; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,UPDATE ON TABLE public.knowledge_query_audit_t TO light_knowledge_api_role;
GRANT SELECT ON TABLE public.knowledge_query_audit_t TO light_knowledge_ops_read_role;


--
-- Name: TABLE knowledge_query_usage_t; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,UPDATE ON TABLE public.knowledge_query_usage_t TO light_knowledge_api_role;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.knowledge_query_usage_t TO light_knowledge_worker_role;
GRANT SELECT ON TABLE public.knowledge_query_usage_t TO light_knowledge_ops_read_role;


--
-- Name: TABLE knowledge_retrieval_profile_t; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.knowledge_retrieval_profile_t TO light_knowledge_api_role;
GRANT SELECT ON TABLE public.knowledge_retrieval_profile_t TO light_knowledge_worker_role;
GRANT SELECT ON TABLE public.knowledge_retrieval_profile_t TO light_knowledge_ops_read_role;
GRANT SELECT ON TABLE public.knowledge_retrieval_profile_t TO light_knowledge_admin_api_role;
GRANT SELECT,INSERT,UPDATE ON TABLE public.knowledge_retrieval_profile_t TO light_knowledge_snapshot_loader_role;


--
-- Name: TABLE knowledge_runtime_authorization_t; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.knowledge_runtime_authorization_t TO light_knowledge_api_role;
GRANT SELECT ON TABLE public.knowledge_runtime_authorization_t TO light_knowledge_ops_read_role;
GRANT SELECT,INSERT,UPDATE ON TABLE public.knowledge_runtime_authorization_t TO light_knowledge_snapshot_loader_role;


--
-- Name: TABLE knowledge_segment_chunk_t; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.knowledge_segment_chunk_t TO light_knowledge_api_role;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.knowledge_segment_chunk_t TO light_knowledge_worker_role;
GRANT SELECT ON TABLE public.knowledge_segment_chunk_t TO light_knowledge_ops_read_role;


--
-- Name: TABLE knowledge_segment_document_t; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.knowledge_segment_document_t TO light_knowledge_api_role;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.knowledge_segment_document_t TO light_knowledge_worker_role;
GRANT SELECT ON TABLE public.knowledge_segment_document_t TO light_knowledge_ops_read_role;


--
-- Name: TABLE knowledge_segment_operation_t; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.knowledge_segment_operation_t TO light_knowledge_api_role;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.knowledge_segment_operation_t TO light_knowledge_worker_role;
GRANT SELECT ON TABLE public.knowledge_segment_operation_t TO light_knowledge_ops_read_role;


--
-- Name: TABLE knowledge_segment_vector_t; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.knowledge_segment_vector_t TO light_knowledge_api_role;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.knowledge_segment_vector_t TO light_knowledge_worker_role;
GRANT SELECT ON TABLE public.knowledge_segment_vector_t TO light_knowledge_ops_read_role;


--
-- Name: TABLE knowledge_source_acl_state_t; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.knowledge_source_acl_state_t TO light_knowledge_api_role;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.knowledge_source_acl_state_t TO light_knowledge_worker_role;
GRANT SELECT ON TABLE public.knowledge_source_acl_state_t TO light_knowledge_ops_read_role;
GRANT SELECT ON TABLE public.knowledge_source_acl_state_t TO light_knowledge_admin_api_role;


--
-- Name: TABLE knowledge_source_change_t; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.knowledge_source_change_t TO light_knowledge_worker_role;
GRANT SELECT ON TABLE public.knowledge_source_change_t TO light_knowledge_ops_read_role;
GRANT SELECT ON TABLE public.knowledge_source_change_t TO light_knowledge_admin_api_role;


--
-- Name: TABLE knowledge_source_cursor_t; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.knowledge_source_cursor_t TO light_knowledge_worker_role;
GRANT SELECT ON TABLE public.knowledge_source_cursor_t TO light_knowledge_ops_read_role;


--
-- Name: TABLE knowledge_source_t; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.knowledge_source_t TO light_knowledge_api_role;
GRANT SELECT ON TABLE public.knowledge_source_t TO light_knowledge_worker_role;
GRANT SELECT ON TABLE public.knowledge_source_t TO light_knowledge_ops_read_role;
GRANT SELECT ON TABLE public.knowledge_source_t TO light_knowledge_admin_api_role;
GRANT SELECT,INSERT,UPDATE ON TABLE public.knowledge_source_t TO light_knowledge_snapshot_loader_role;


--
-- Name: TABLE knowledge_subject_mapping_t; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.knowledge_subject_mapping_t TO light_knowledge_worker_role;
GRANT SELECT ON TABLE public.knowledge_subject_mapping_t TO light_knowledge_ops_read_role;


--
-- Name: TABLE knowledge_sync_run_t; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.knowledge_sync_run_t TO light_knowledge_worker_role;
GRANT SELECT ON TABLE public.knowledge_sync_run_t TO light_knowledge_ops_read_role;
GRANT SELECT ON TABLE public.knowledge_sync_run_t TO light_knowledge_admin_api_role;


--
-- Name: TABLE knowledge_upload_t; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT ON TABLE public.knowledge_upload_t TO light_knowledge_api_role;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.knowledge_upload_t TO light_knowledge_worker_role;
GRANT SELECT ON TABLE public.knowledge_upload_t TO light_knowledge_ops_read_role;
GRANT SELECT ON TABLE public.knowledge_upload_t TO light_knowledge_admin_api_role;


--
-- Name: COLUMN knowledge_upload_t.scan_state; Type: ACL; Schema: public; Owner: -
--

GRANT UPDATE(scan_state) ON TABLE public.knowledge_upload_t TO light_knowledge_api_role;


--
-- Name: COLUMN knowledge_upload_t.lifecycle_state; Type: ACL; Schema: public; Owner: -
--

GRANT UPDATE(lifecycle_state) ON TABLE public.knowledge_upload_t TO light_knowledge_api_role;


--
-- Name: COLUMN knowledge_upload_t.rejection_code; Type: ACL; Schema: public; Owner: -
--

GRANT UPDATE(rejection_code) ON TABLE public.knowledge_upload_t TO light_knowledge_api_role;


--
-- Name: COLUMN knowledge_upload_t.verified_ts; Type: ACL; Schema: public; Owner: -
--

GRANT UPDATE(verified_ts) ON TABLE public.knowledge_upload_t TO light_knowledge_api_role;


--
-- Phase 3 bounded administration API audit and access paths
--

CREATE TABLE public.knowledge_admin_audit_t (
    admin_audit_id uuid NOT NULL,
    request_id character varying(128) NOT NULL,
    knowledge_base_id uuid REFERENCES public.knowledge_base_t(knowledge_base_id) ON DELETE CASCADE,
    consumer_host_id uuid NOT NULL,
    environment character varying(16) NOT NULL,
    operation character varying(64) NOT NULL,
    input_digest character(64) NOT NULL,
    subject_ref character varying(128),
    result_count bigint NOT NULL,
    latency_ms bigint NOT NULL,
    created_ts timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT knowledge_admin_audit_t_pkey PRIMARY KEY (admin_audit_id),
    CONSTRAINT knowledge_admin_audit_operation_check CHECK ((operation)::text = ANY (ARRAY[
        'EMBEDDING_MIGRATION_ESTIMATE'::text, 'AUTHORIZATION_SIMULATION'::text,
        'CONTROL_SNAPSHOT_APPLY'::text, 'OPERATIONAL_COMMAND_SUBMIT'::text])),
    CONSTRAINT knowledge_admin_audit_input_digest_check CHECK (input_digest ~ '^[a-f0-9]{64}$'::text),
    CONSTRAINT knowledge_admin_audit_result_count_check CHECK (result_count >= 0),
    CONSTRAINT knowledge_admin_audit_latency_check CHECK (latency_ms >= 0 AND latency_ms <= 120000)
);

COMMENT ON TABLE public.knowledge_admin_audit_t IS
    'Content-safe audit evidence for Light Knowledge administration reads, commands, and control snapshots.';

CREATE INDEX knowledge_admin_audit_page_idx ON public.knowledge_admin_audit_t
    (knowledge_base_id, created_ts DESC, admin_audit_id DESC);
CREATE INDEX knowledge_admin_sync_runs_page_idx ON public.knowledge_sync_run_t
    (knowledge_base_id, requested_ts DESC, sync_run_id DESC);
CREATE INDEX knowledge_admin_documents_page_idx ON public.knowledge_document_t
    (knowledge_base_id, update_ts DESC, document_id DESC);
CREATE INDEX knowledge_admin_generations_page_idx ON public.knowledge_index_generation_t
    (knowledge_base_id, created_ts DESC, index_generation_id DESC);
CREATE INDEX knowledge_admin_segments_page_idx ON public.knowledge_index_segment_t
    (knowledge_base_id, created_ts DESC, index_segment_id DESC);
CREATE INDEX knowledge_admin_uploads_page_idx ON public.knowledge_upload_t
    (knowledge_base_id, staged_ts DESC, upload_id DESC);
CREATE INDEX knowledge_admin_changes_page_idx ON public.knowledge_source_change_t
    (knowledge_base_id, observed_ts DESC, source_change_id DESC);
CREATE INDEX knowledge_admin_anchors_page_idx ON public.knowledge_passage_anchor_t
    (knowledge_base_id, created_ts DESC, passage_anchor_id DESC, document_version_id DESC);
CREATE INDEX knowledge_admin_compactions_page_idx ON public.knowledge_compaction_run_t
    (knowledge_base_id, created_ts DESC, compaction_run_id DESC);
CREATE INDEX knowledge_admin_anti_entropy_page_idx ON public.knowledge_anti_entropy_run_t
    (knowledge_base_id, started_ts DESC, anti_entropy_run_id DESC);
CREATE INDEX knowledge_admin_acl_freshness_page_idx ON public.knowledge_source_acl_state_t
    (knowledge_base_id, update_ts DESC, source_id DESC);
CREATE INDEX knowledge_admin_acl_reconciliation_page_idx ON public.knowledge_acl_reconciliation_t
    (knowledge_base_id, started_ts DESC, reconciliation_id DESC);
CREATE INDEX knowledge_admin_acl_transition_page_idx ON public.knowledge_acl_transition_t
    (knowledge_base_id, recorded_ts DESC, acl_transition_id DESC);
CREATE INDEX knowledge_admin_connector_objects_page_idx ON public.knowledge_connector_object_t
    (knowledge_base_id, observed_ts DESC, connector_object_id DESC);
CREATE INDEX knowledge_admin_migrations_page_idx ON public.knowledge_embedding_migration_t
    (knowledge_base_id, created_ts DESC, migration_id DESC);
CREATE INDEX knowledge_admin_evaluations_page_idx ON public.knowledge_migration_evaluation_t
    (knowledge_base_id, created_ts DESC, evaluation_evidence_id DESC);
CREATE INDEX knowledge_admin_retention_page_idx ON public.knowledge_generation_retention_t
    (knowledge_base_id, update_ts DESC, index_generation_id DESC);
CREATE INDEX knowledge_admin_checkpoints_page_idx ON public.knowledge_backup_checkpoint_t
    (knowledge_base_id, created_ts DESC, checkpoint_id DESC);
CREATE INDEX knowledge_admin_purge_page_idx ON public.knowledge_purge_evidence_t
    (knowledge_base_id, created_ts DESC, purge_evidence_id DESC);
CREATE INDEX knowledge_admin_promotion_receipts_page_idx ON public.knowledge_promotion_receipt_t
    (knowledge_base_id, committed_ts DESC, promotion_id DESC);
CREATE INDEX knowledge_admin_estimate_documents_idx ON public.knowledge_document_t
    (knowledge_base_id, lifecycle_state, current_document_version_id);
CREATE INDEX knowledge_admin_estimate_chunks_idx ON public.knowledge_chunk_t
    (document_version_id) INCLUDE (token_count);
CREATE INDEX knowledge_admin_simulation_acl_idx ON public.knowledge_document_acl_t
    (document_id, acl_sequence DESC);

REVOKE ALL ON TABLE public.knowledge_admin_audit_t FROM PUBLIC;
GRANT INSERT ON TABLE public.knowledge_admin_audit_t TO light_knowledge_admin_api_role;
GRANT SELECT ON TABLE public.knowledge_admin_audit_t TO light_knowledge_ops_read_role;


--
-- PostgreSQL database dump complete
--

\unrestrict cAc57KIIf2l6uz2LledZrfAk6Bp8LAVD3YQy7cVo8QyIqLI5Ew8gMjW7e7GsWPI

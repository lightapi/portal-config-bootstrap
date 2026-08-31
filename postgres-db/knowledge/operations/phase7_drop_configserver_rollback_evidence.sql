\if :{?phase7_evidence_sha256}
\else
\echo 'phase7_evidence_sha256 is required; use the guarded Phase 7 cleanup command'
\quit 3
\endif

BEGIN;

CREATE TEMP TABLE phase7_cleanup_authorization_t (
    evidence_sha256 text NOT NULL
) ON COMMIT DROP;
INSERT INTO phase7_cleanup_authorization_t VALUES (:'phase7_evidence_sha256');

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
          FROM phase7_cleanup_authorization_t
         WHERE evidence_sha256 ~ '^[0-9a-f]{64}$'
    ) THEN
        RAISE EXCEPTION 'invalid Phase 7 qualification evidence digest';
    END IF;
    IF to_regnamespace('knowledge_rollback_evidence') IS NULL THEN
        RAISE EXCEPTION 'knowledge_rollback_evidence does not exist in this database';
    END IF;
END
$$;

SELECT relation_name, row_count, captured_at
  FROM knowledge_rollback_evidence.capture_manifest_t
 ORDER BY relation_name;

DROP SCHEMA knowledge_rollback_evidence CASCADE;

COMMIT;

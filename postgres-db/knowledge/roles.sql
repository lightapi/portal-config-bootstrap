-- Roles are cluster objects and must exist before postgres/knowledge/ddl.sql.
-- The block is idempotent so local bootstrap and in-place upgrades share it.
DO $$
DECLARE role_name text;
BEGIN
    FOREACH role_name IN ARRAY ARRAY[
        'light_knowledge_schema_migration_role',
        'light_knowledge_snapshot_loader_role',
        'light_knowledge_api_role',
        'light_knowledge_worker_role',
        'light_knowledge_ops_read_role',
        'light_knowledge_admin_api_role'
    ]
    LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = role_name) THEN
            EXECUTE format('CREATE ROLE %I NOLOGIN', role_name);
        END IF;
    END LOOP;
END
$$;

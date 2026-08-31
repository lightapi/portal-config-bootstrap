-- Required by the administration snapshot transaction when it derives
-- fail-closed runtime-authorization digests from applied bindings.
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA public;

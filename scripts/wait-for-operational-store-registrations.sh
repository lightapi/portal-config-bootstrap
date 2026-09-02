#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
manifest="${OPERATIONAL_DATABASE_MANIFEST:-$repo_root/postgres-db/operations/operational-databases.tsv}"
container_cmd="${CONTAINER_CMD:-docker}"
postgres_container="${POSTGRES_CONTAINER:-postgres}"
attempts="${OPERATIONAL_REGISTRATION_ATTEMPTS:-120}"
interval="${OPERATIONAL_REGISTRATION_INTERVAL:-1}"

fail() { printf '[operational-store-readiness] error: %s\n' "$*" >&2; exit 1; }

[[ -f "$manifest" ]] || fail "database manifest is missing: $manifest"
[[ "$attempts" =~ ^[1-9][0-9]*$ ]] || fail "attempt count must be a positive integer"
expected_state="$(awk -F '\t' '$1 !~ /^#/ && NF { print $3 "|" $1 "|" $4 "|" $5 }' "$manifest" | LC_ALL=C sort)"
[[ "$(printf '%s\n' "$expected_state" | sed '/^$/d' | wc -l)" == 3 ]] || fail "manifest must define exactly three Host registrations"

query_state() {
  "$container_cmd" exec "$postgres_container" psql -h localhost -p 5432 -U postgres -d configserver -X -qAt -F '|' -c "
    SELECT b.host_id::text, b.expected_database, b.binding_id::text, b.binding_digest
      FROM operational_store_binding_t b
      JOIN operational_store_publication_t p ON p.binding_id=b.binding_id AND p.binding_version=b.aggregate_version
     WHERE b.contract_version=2 AND b.scope_kind='HOST' AND b.environment IS NULL
       AND b.lifecycle_state='REGISTERED' AND b.active AND b.published
       AND p.publication_state='ACTIVE' AND p.content_digest=b.binding_digest
       AND p.host_id=b.host_id AND p.environment IS NULL
       AND p.projection->>'contractVersion'='2'
       AND p.projection->>'bindingId'=b.binding_id::text
       AND p.projection->>'bindingDigest'=b.binding_digest
       AND p.projection->>'hostId'=b.host_id::text
       AND p.projection->>'expectedDatabase'=b.expected_database
       AND NOT EXISTS (SELECT 1 FROM operational_store_provisioning_job_t j WHERE j.binding_id=b.binding_id)
     ORDER BY b.host_id::text;
  " 2>/dev/null
}

last_state=""
for ((attempt=1; attempt<=attempts; attempt++)); do
  last_state="$(query_state || true)"
  [[ "$last_state" == "$expected_state" ]] && {
    printf '[operational-store-readiness] three Host registrations and publications are ready\n'
    exit 0
  }
  sleep "$interval"
done
printf '[operational-store-readiness] expected:\n%s\n' "$expected_state" >&2
printf '[operational-store-readiness] observed:\n%s\n' "${last_state:-<none>}" >&2
fail "three Host registrations did not become ready after $attempts attempts"

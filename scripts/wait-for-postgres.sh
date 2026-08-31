#!/usr/bin/env bash
set -euo pipefail

attempts="${POSTGRES_READY_ATTEMPTS:-180}"
interval="${POSTGRES_READY_INTERVAL:-2}"
log_lines="${POSTGRES_READY_LOG_LINES:-120}"
attempt=1

while [[ "$attempt" -le "$attempts" ]]; do
  if docker exec postgres psql -h localhost -p 5432 -U postgres -d configserver -tAc "select 1;" >/dev/null 2>&1; then
    exit 0
  fi

  if ! docker inspect -f '{{.State.Running}}' postgres 2>/dev/null | grep -qx true; then
    printf '[wait-for-postgres] postgres exited before becoming ready\n' >&2
    docker logs --tail "$log_lines" postgres >&2 || true
    exit 1
  fi

  sleep "$interval"
  attempt=$((attempt + 1))
done

printf '[wait-for-postgres] postgres did not become ready after %s attempts\n' "$attempts" >&2
docker logs --tail "$log_lines" postgres >&2 || true
exit 1

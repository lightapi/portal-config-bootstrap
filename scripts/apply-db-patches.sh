#!/usr/bin/env bash
set -euo pipefail

log() {
  printf '[apply-db-patches] %s\n' "$*"
}

die() {
  printf '[apply-db-patches] error: %s\n' "$*" >&2
  exit 1
}

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd -- "$script_dir/.." && pwd)"
patch_dir="${DB_PATCH_DIR:-$repo_dir/db/patches}"
schema_renderer="$repo_dir/postgres-db/lib/render-schema.sh"
psql=(docker exec -i postgres psql -h localhost -p 5432 -U postgres -d configserver -v ON_ERROR_STOP=1)

"$script_dir/wait-for-postgres.sh"

"${psql[@]}" <<'SQL'
CREATE TABLE IF NOT EXISTS portal_schema_patch_t (
  patch_id VARCHAR(128) PRIMARY KEY,
  checksum VARCHAR(128) NOT NULL,
  applied_ts TIMESTAMPTZ NOT NULL DEFAULT now()
);
SQL

shopt -s nullglob
patches=("$patch_dir"/*.sql)
shopt -u nullglob

if ((${#patches[@]} == 0)); then
  log "no database patches found in $patch_dir"
  exit 0
fi

IFS=$'\n' patches=($(printf '%s\n' "${patches[@]}" | sort))
unset IFS

for patch in "${patches[@]}"; do
  patch_id="$(basename -- "$patch" .sql)"
  checksum="$(sha256sum "$patch" | awk '{print $1}')"
  existing_checksum="$(docker exec postgres psql -h localhost -p 5432 -U postgres -d configserver -tAc "select checksum from portal_schema_patch_t where patch_id = '$patch_id';" | tr -d '[:space:]' || true)"

  if [[ -n "$existing_checksum" ]]; then
    [[ "$existing_checksum" == "$checksum" ]] ||
      die "checksum drift for applied patch $patch_id: database=$existing_checksum file=$checksum"
    log "already applied $patch_id"
    continue
  fi

  log "applying $patch_id"
  source_sql="$(mktemp "${TMPDIR:-/tmp}/portal-db-patch-source.XXXXXX.sql")"
  rendered_sql="$(mktemp "${TMPDIR:-/tmp}/portal-db-patch-rendered.XXXXXX.sql")"
  {
    printf 'BEGIN;\n'
    cat "$patch"
    printf '\n'
    printf "INSERT INTO portal_schema_patch_t (patch_id, checksum) VALUES ('%s', '%s');\n" "$patch_id" "$checksum"
    printf 'COMMIT;\n'
  } > "$source_sql"

  PORTAL_DB_CONFIGSERVER_SOURCE="$source_sql" \
    "$schema_renderer" configserver configserver "$rendered_sql"

  if ! "${psql[@]}" < "$rendered_sql"; then
    rm -f "$source_sql" "$rendered_sql"
    die "failed to apply $patch_id"
  fi
  rm -f "$source_sql" "$rendered_sql"
done

log "database patches completed"

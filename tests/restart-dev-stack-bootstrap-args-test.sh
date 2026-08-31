#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

mkdir -p "$test_dir/bin" "$test_dir/data"
printf '[]\n' > "$test_dir/data/events.json"

cat > "$test_dir/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == "exec" ]]; then
  if [[ "$*" == *'consumer_offsets'* ]]; then
    printf 'ready\n'
  else
    printf '0\n'
  fi
  exit 0
fi
if [[ "$1" == "inspect" ]]; then
  if [[ "$*" == *'.State.Running'* ]]; then
    printf 'true\n'
  else
    printf 'bootstrap-test-network\n'
  fi
  exit 0
fi
if [[ "$1" == "run" ]]; then
  printf '%s\n' "$*" >> "$BOOTSTRAP_TEST_CAPTURE"
  cat >/dev/null
fi
EOF

cat > "$test_dir/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
while (($#)); do
  if [[ "$1" == "-o" ]]; then
    printf 'test archive\n' > "$2"
    exit 0
  fi
  shift
done
exit 1
EOF

cat > "$test_dir/bin/unzip" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '[]\n'
EOF

chmod +x "$test_dir/bin/docker" "$test_dir/bin/curl" "$test_dir/bin/unzip"

run_restart() {
  PATH="$test_dir/bin:$PATH" \
  BOOTSTRAP_TEST_CAPTURE="$1" \
  DEV_EVENTS_FILE="$test_dir/data/events.json" \
  IMPORT_EVENTS=force \
  DEV_DEPLOY_SKIP_DB_PATCHES=true \
  DEV_DEPLOY_SKIP_EVENT_DELTAS=true \
  DEV_DEPLOY_SKIP_CONFIG_SNAPSHOT_REFRESH=true \
  DEV_DEPLOY_SKIP_PULL=true \
  DEV_DEPLOY_SKIP_HEALTHCHECK=true \
  EVENT_IMPORTER_IMAGE=networknt/event-importer:bootstrap-test \
    "$repo_dir/scripts/restart-dev-stack.sh" >/dev/null
}

default_capture="$test_dir/default.args"
run_restart "$default_capture"
grep -Fq -- '--physical-chunk-events 500' "$default_capture"
grep -Fq -- '--physical-chunk-bytes 16777216' "$default_capture"
grep -Fq -- '--max-event-bytes 67108864' "$default_capture"
if grep -Eq -- '--legacy-write-fenced|--bootstrap-operator-id|--bootstrap-(graph-wait|total-barrier)-timeout-seconds' "$default_capture"; then
  printf 'obsolete processing arguments unexpectedly passed to bootstrap importer\n' >&2
  exit 1
fi
if grep -Fq -- '--bootstrap-synchronous-commit-off' "$default_capture"; then
  printf 'synchronous_commit override unexpectedly enabled by default\n' >&2
  exit 1
fi

configured_capture="$test_dir/configured.args"
EVENT_IMPORT_PHYSICAL_CHUNK_EVENTS=100 \
EVENT_IMPORT_PHYSICAL_CHUNK_BYTES=8388608 \
EVENT_IMPORT_MAX_EVENT_BYTES=33554432 \
EVENT_IMPORT_SYNCHRONOUS_COMMIT_OFF=true \
EVENT_IMPORT_DIAGNOSE_FAILED_CHUNK=true \
EVENT_IMPORT_PHYSICAL_CHUNKING_DISABLED=true \
  run_restart "$configured_capture"
grep -Fq -- '--physical-chunk-events 100' "$configured_capture"
grep -Fq -- '--physical-chunk-bytes 8388608' "$configured_capture"
grep -Fq -- '--max-event-bytes 33554432' "$configured_capture"
grep -Fq -- '--bootstrap-synchronous-commit-off' "$configured_capture"
grep -Fq -- '--diagnose-failed-chunk' "$configured_capture"
grep -Fq -- '--physical-chunking-disabled' "$configured_capture"

recreate_capture="$test_dir/recreate.args"
recreate_log="$test_dir/recreate.log"
PATH="$test_dir/bin:$PATH" \
BOOTSTRAP_TEST_CAPTURE="$recreate_capture" \
DEV_EVENTS_FILE="$test_dir/data/events.json" \
DEV_EVENTS_ARCHIVE_URL=https://example.test/events.zip \
DEV_POSTGRES_DATA_DIR="$test_dir/postgres-data" \
DEV_DEPLOY_SKIP_EVENT_DELTAS=true \
DEV_DEPLOY_SKIP_CONFIG_SNAPSHOT_REFRESH=true \
DEV_DEPLOY_SKIP_PULL=true \
DEV_DEPLOY_SKIP_HEALTHCHECK=true \
EVENT_IMPORTER_IMAGE=networknt/event-importer:bootstrap-test \
  "$repo_dir/scripts/restart-dev-stack.sh" --recreate-database >"$recreate_log"
grep -Fq -- '[restart-dev-stack] skipping database patches' "$recreate_log"

printf 'restart-dev-stack bootstrap argument tests passed\n'

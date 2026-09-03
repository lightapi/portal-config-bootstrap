#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

[[ -s "$repo_dir/release-keys/portal-release-2026-01.pem" ]]
grep -Fq -- '-----BEGIN PUBLIC KEY-----' "$repo_dir/release-keys/portal-release-2026-01.pem"
if grep -Fq -- 'PRIVATE KEY' "$repo_dir/release-keys/portal-release-2026-01.pem"; then
  printf 'release trust directory contains private key material\n' >&2
  exit 1
fi

mkdir -p "$test_dir/bin" "$test_dir/data" "$test_dir/release-keys"
mkdir -p "$test_dir/private-event-deltas"
printf '[]\n' > "$test_dir/private-event-deltas/unmanifested.json"
printf '[]\n' > "$test_dir/data/events.json"
printf 'test public key\n' > "$test_dir/release-keys/release-test.pem"
mkdir -p "$test_dir/sso/tls" "$test_dir/sso/lightapi/dist" "$test_dir/operational-secrets"
printf 'test\n' > "$test_dir/sso/tls/ca.pem"
printf 'test\n' > "$test_dir/sso/tls/cert.pem"
printf 'test\n' > "$test_dir/sso/tls/key.pem"
printf '<html></html>\n' > "$test_dir/sso/lightapi/dist/index.html"
cat > "$test_dir/bootstrap.env" <<'EOF'
COMPOSE_PROJECT_NAME=bootstrap-contract-test
MSAL_TENANT_ID=test-tenant
MSAL_CLIENT_ID=test-client
MSAL_REDIRECT_URI=https://example.test/authorization
MSAL_EXCHANGE_CLIENT_ID=test-exchange-client
MSAL_EXCHANGE_CLIENT_SECRET=test-exchange-secret
PORTAL_BFF_SSO_LIGHT_PORTAL_AUTHORIZATION=Bearer test-token
EOF

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
  if [[ "$*" == *'--verify-bundle'* && "${BOOTSTRAP_TEST_VERIFY_FAIL:-false}" == "true" ]]; then
    exit 9
  fi
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
  BOOTSTRAP_ENV_FILE="$test_dir/bootstrap.env" \
  BOOTSTRAP_SSO_ASSET_ROOT="$test_dir/sso" \
  BOOTSTRAP_OPERATIONAL_SECRET_DIR="$test_dir/operational-secrets" \
  BOOTSTRAP_EVENTS_FILE="$test_dir/data/events.json" \
  PORTAL_INSTANCE_EVENT_DELTA_DIR="$test_dir/private-event-deltas" \
  IMPORT_EVENTS=force \
  BOOTSTRAP_DEPLOY_SKIP_DB_PATCHES=true \
  BOOTSTRAP_DEPLOY_SKIP_EVENT_DELTAS=true \
  BOOTSTRAP_DEPLOY_SKIP_CONFIG_SNAPSHOT_REFRESH=true \
  BOOTSTRAP_DEPLOY_SKIP_PULL=true \
  BOOTSTRAP_DEPLOY_SKIP_HEALTHCHECK=true \
  EVENT_IMPORTER_IMAGE=networknt/event-importer:bootstrap-test \
    "$repo_dir/scripts/restart-bootstrap-stack.sh" >/dev/null
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
BOOTSTRAP_ENV_FILE="$test_dir/bootstrap.env" \
BOOTSTRAP_SSO_ASSET_ROOT="$test_dir/sso" \
BOOTSTRAP_OPERATIONAL_SECRET_DIR="$test_dir/operational-secrets" \
  BOOTSTRAP_EVENTS_FILE="$test_dir/data/events.json" \
  BOOTSTRAP_EVENTS_ARCHIVE_URL=https://example.test/events.zip \
  BOOTSTRAP_POSTGRES_DATA_DIR="$test_dir/postgres-data" \
  EVENT_BUNDLE_KEY_DIR="$test_dir/release-keys" \
  BOOTSTRAP_EVENTS_REQUIRE_BUNDLE_MATCH=true \
  BOOTSTRAP_DEPLOY_SKIP_EVENT_DELTAS=true \
  BOOTSTRAP_DEPLOY_SKIP_CONFIG_SNAPSHOT_REFRESH=true \
  BOOTSTRAP_DEPLOY_SKIP_PULL=true \
  BOOTSTRAP_DEPLOY_SKIP_HEALTHCHECK=true \
  EVENT_IMPORTER_IMAGE=networknt/event-importer:bootstrap-test \
  "$repo_dir/scripts/restart-bootstrap-stack.sh" --recreate-database >"$recreate_log"
grep -Fq -- '[restart-bootstrap-stack] skipping database patches' "$recreate_log"
grep -Fq -- '--verify-bundle --bundle /bundle/events.zip.tmp --bundle-key-dir /bundle-keys' "$recreate_capture"
[[ -s "$test_dir/data/events.json.source-bundle.sha256" ]]

failing_data_dir="$test_dir/postgres-data-preserved"
mkdir -p "$failing_data_dir"
printf 'preserve me\n' > "$failing_data_dir/sentinel"
set +e
PATH="$test_dir/bin:$PATH" \
BOOTSTRAP_TEST_CAPTURE="$test_dir/recreate-failure.args" \
BOOTSTRAP_TEST_VERIFY_FAIL=true \
BOOTSTRAP_ENV_FILE="$test_dir/bootstrap.env" \
BOOTSTRAP_SSO_ASSET_ROOT="$test_dir/sso" \
BOOTSTRAP_OPERATIONAL_SECRET_DIR="$test_dir/operational-secrets" \
BOOTSTRAP_EVENTS_FILE="$test_dir/data/events-failure.json" \
BOOTSTRAP_EVENTS_ARCHIVE_URL=https://example.test/events.zip \
BOOTSTRAP_POSTGRES_DATA_DIR="$failing_data_dir" \
EVENT_BUNDLE_KEY_DIR="$test_dir/release-keys" \
BOOTSTRAP_DEPLOY_SKIP_EVENT_DELTAS=true \
BOOTSTRAP_DEPLOY_SKIP_CONFIG_SNAPSHOT_REFRESH=true \
BOOTSTRAP_DEPLOY_SKIP_PULL=true \
BOOTSTRAP_DEPLOY_SKIP_HEALTHCHECK=true \
EVENT_IMPORTER_IMAGE=networknt/event-importer:bootstrap-test \
  "$repo_dir/scripts/restart-bootstrap-stack.sh" --recreate-database >/dev/null 2>&1
failure_status=$?
set -e
[[ "$failure_status" -ne 0 ]]
[[ -f "$failing_data_dir/sentinel" ]]
[[ ! -e "$failing_data_dir.before-reset-"* ]]

printf 'restart-dev-stack bootstrap argument tests passed\n'

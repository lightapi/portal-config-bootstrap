#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
manifest="$repo_root/postgres-db/operations/operational-databases.tsv"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
mock="$test_dir/container"
cat >"$mock" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
awk -F '\t' -v mode="${MOCK_REGISTRATION_MODE:-ready}" '$1 !~ /^#/ && NF { database=$1; if (mode=="swapped" && database=="operations") database="operations_networknt"; print $3 "|" database "|" $4 "|" $5 }' "$MOCK_REGISTRATION_MANIFEST" | LC_ALL=C sort
MOCK
chmod +x "$mock"
CONTAINER_CMD="$mock" MOCK_REGISTRATION_MANIFEST="$manifest" OPERATIONAL_REGISTRATION_ATTEMPTS=1 OPERATIONAL_REGISTRATION_INTERVAL=0 "$repo_root/scripts/wait-for-operational-store-registrations.sh" >/dev/null
set +e
CONTAINER_CMD="$mock" MOCK_REGISTRATION_MANIFEST="$manifest" MOCK_REGISTRATION_MODE=swapped OPERATIONAL_REGISTRATION_ATTEMPTS=1 OPERATIONAL_REGISTRATION_INTERVAL=0 "$repo_root/scripts/wait-for-operational-store-registrations.sh" >/dev/null 2>&1
swapped_status=$?
set -e
[[ "$swapped_status" -ne 0 ]] || { echo "publication readiness accepted a swapped Host/database mapping" >&2; exit 1; }
echo "Operational-store publication readiness contract passed"

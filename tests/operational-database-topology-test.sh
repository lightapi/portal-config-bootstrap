#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -d "$repo_root/all-in-lt" ]]; then
  stack_root="$repo_root/all-in-lt"
else
  stack_root="$repo_root"
fi
compose_file="$stack_root/docker-compose.yml"
operations_root="$stack_root/postgres-db/operations"
manifest="$operations_root/operational-databases.tsv"
readiness_script="$repo_root/scripts/wait-for-operational-store-registrations.sh"

fail() {
  echo "operational-database-topology-test: $*" >&2
  exit 1
}

[[ -f "$manifest" ]] || fail "manifest is missing"
[[ -x "$readiness_script" ]] || fail "registration/publication readiness gate is missing"
grep -q 'wait-for-operational-store-registrations.sh' "$repo_root/scripts/restart-bootstrap-stack.sh" ||
  fail "bootstrap restart does not wait for operational-store publications"
actual_mapping="$(awk -F '\t' '$1 !~ /^#/ { print $1 "|" $2 "|" $3 }' "$manifest")"
expected_mapping="$(printf '%s\n' \
  'operations|dev.lightapi.net|01964b05-552a-7c4b-9184-6857e7f3dc5f' \
  'operations_networknt|dev.networknt.com|01a04864-b507-74dd-962a-d1e26769a3b4' \
  'operations_taiji|dev.taiji.io|01a06288-ceec-7de6-85b1-ed12d4dd4732')"
[[ "$actual_mapping" == "$expected_mapping" ]] || fail "database/Host mapping drifted"

prerequisite_delta="$repo_root/events/deltas/20260902-000-taiji-org-host-prerequisite.json"
registration_delta="$repo_root/events/deltas/20260902-001-operational-store-default-registrations.json"
delta_verifier="$repo_root/events/deltas/verify-event-delta.sql"
[[ -f "$prerequisite_delta" ]] || fail "Taiji Host prerequisite delta is missing"
[[ "$prerequisite_delta" < "$registration_delta" ]] || fail "Taiji Host prerequisite must sort before registrations"
jq -e '
  length == 2 and
  .[0].type == "OrgCreatedEvent" and
  .[0].subject == "taiji.io" and
  .[0].host == "01964b05-552a-7c4b-9184-6857e7f3dc5f" and
  .[1].type == "HostCreatedEvent" and
  .[1].subject == "01a06288-ceec-7de6-85b1-ed12d4dd4732" and
  .[1].data.hostId == "01a06288-ceec-7de6-85b1-ed12d4dd4732" and
  .[1].host == "01964b05-552a-7c4b-9184-6857e7f3dc5f"
' "$prerequisite_delta" >/dev/null || fail "Taiji Host prerequisite event authority drifted"
[[ -f "$delta_verifier" ]] || fail "event delta verifier is missing"
grep -Fq "expected.event_type = 'HostCreatedEvent'" "$delta_verifier" ||
  fail "event delta verifier does not recognize corrected Host-birth authority"
grep -Fq "equivalent.payload -> 'data' ->> 'hostId' = expected.data ->> 'hostId'" "$delta_verifier" ||
  fail "event delta verifier does not pin corrected Host births by data.hostId"
grep -Fq -- "- 'updateUser'" "$delta_verifier" ||
  fail "event delta verifier treats regenerated audit ownership as entity identity"
grep -Fq "expected.event_type = 'OperationalStoreBindingRegisteredEvent'" "$delta_verifier" ||
  fail "event delta verifier does not recognize normalized operational registrations"
grep -Fq "ARRAY['targetHostId', 'scopeKind', 'active', 'published']::TEXT[]" "$delta_verifier" ||
  fail "event delta verifier does not exclude derived operational registration fields"

grep -q 'PORTAL_DB_OPERATIONAL_NAMES: operations,operations_networknt,operations_taiji' "$compose_file" ||
  fail "PostgreSQL does not declare the three-database manifest"
grep -q 'bootstrap-operational-databases.sh' "$compose_file" ||
  fail "multi-database bootstrap is not wired"
grep -q 'validate-operational-databases.sh' "$compose_file" ||
  fail "multi-database validation is not wired"
grep -q 'operational-hosts/\$${OPERATIONAL_RUNTIME_HOST:-dev.lightapi.net}' "$compose_file" ||
  fail "runtime credentials are not selected by Host FQDN"
grep -q '/run/secrets/operational-database-url' "$compose_file" ||
  fail "runtime credentials do not use the standard protected path"
grep -q 'chown -R ${LIGHT_RUNTIME_UID:-999}:${LIGHT_RUNTIME_GID:-999}' "$compose_file" ||
  fail "runtime credential volumes are not readable by the runtime UID"
if grep -Eq 'operational-store-provisioner|/var/run/docker.sock|operational-store-provisioning' "$compose_file"; then
  fail "obsolete provisioning privilege remains in Compose"
fi
[[ ! -e "$operations_root/bin/operational-store-provisioner.sh" ]] ||
  fail "obsolete provisioner worker remains"
[[ ! -e "$operations_root/bin/provision-dev-dedicated.sh" ]] ||
  fail "obsolete dedicated-container provider remains"

bash -n "$stack_root/postgres-db/init-environment.sh"
bash -n "$operations_root/bin/bootstrap-operational-databases.sh"
bash -n "$operations_root/bin/validate-operational-databases.sh"

if command -v docker >/dev/null 2>&1; then
  [[ "$(cd "$stack_root" && docker compose config --services | grep -c '^postgres$')" == 1 ]] ||
    fail "Compose must contain exactly one PostgreSQL service"
  (cd "$stack_root" && docker compose config --quiet)
fi

echo "Operational database topology contract passed for $stack_root"

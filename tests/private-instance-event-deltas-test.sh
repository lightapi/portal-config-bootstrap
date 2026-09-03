#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
importer="$repo_root/scripts/import-instance-event-deltas.sh"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/portal-private-delta-test.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

fail() {
  printf 'private-instance-event-deltas-test: %s\n' "$*" >&2
  exit 1
}

[[ -x "$importer" ]] || fail "private instance delta importer is missing"
bash -n "$importer"

PORTAL_INSTANCE_EVENT_DELTA_DIR="$tmp_dir/absent" "$importer" >/dev/null

mkdir -p "$tmp_dir/empty"
printf '%s\n' \
  '{' \
  '  "format": "lightapi.portal-instance-event-deltas",' \
  '  "formatVersion": 1,' \
  '  "instanceId": "test-installation",' \
  '  "eventDeltas": []' \
  '}' > "$tmp_dir/empty/manifest.json"
PORTAL_INSTANCE_EVENT_DELTA_DIR="$tmp_dir/empty" "$importer" >/dev/null

printf '[]\n' > "$tmp_dir/empty/not-authorized.json"
if PORTAL_INSTANCE_EVENT_DELTA_DIR="$tmp_dir/empty" "$importer" >"$tmp_dir/stdout" 2>"$tmp_dir/stderr"; then
  fail "an unmanifested private JSON file was accepted"
fi
grep -Fq 'not authorized by the manifest' "$tmp_dir/stderr" ||
  fail "unmanifested-file rejection was not explicit"
if "$repo_root/scripts/build-instance-event-delta-manifest.sh" test-installation "$tmp_dir/empty" \
    >"$tmp_dir/stdout" 2>"$tmp_dir/stderr"; then
  fail "manifest builder accepted an empty event array"
fi
grep -Fq 'must be a non-empty JSON array' "$tmp_dir/stderr" ||
  fail "empty-array rejection was not explicit"
printf '[{}]\n' > "$tmp_dir/empty/not-authorized.json"
printf '[{}]\n' > "$tmp_dir/empty/second.json"
"$repo_root/scripts/build-instance-event-delta-manifest.sh" test-installation "$tmp_dir/empty" >/dev/null
jq -e '.instanceId == "test-installation" and
  ([.eventDeltas[].id] == ["not-authorized", "second"]) and
  ([.eventDeltas[].file] == ["not-authorized.json", "second.json"]) and
  all(.eventDeltas[]; .sha256 | test("^[0-9a-f]{64}$"))' "$tmp_dir/empty/manifest.json" >/dev/null ||
  fail "manifest builder did not checksum the private event array"

mkdir -p "$tmp_dir/bin" "$tmp_dir/all-in-lt"
cat > "$tmp_dir/bin/container" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$PRIVATE_DELTA_CONTAINER_CAPTURE"
case "${1:-}" in
  exec)
    [[ "$*" != *"select checksum from portal_instance_event_delta_t"* ]] || exit 0
    [[ " $* " != *" -i "* ]] || cat >/dev/null
    ;;
  inspect)
    # Deliberately return no network so the PORTAL_STACK_DIR fallback is tested.
    ;;
  run)
    cat >/dev/null
    ;;
esac
EOF
chmod +x "$tmp_dir/bin/container"
PRIVATE_DELTA_CONTAINER_CAPTURE="$tmp_dir/container.args" \
CONTAINER_CMD="$tmp_dir/bin/container" \
PORTAL_STACK_DIR="$tmp_dir/all-in-lt" \
PORTAL_INSTANCE_EVENT_DELTA_DIR="$tmp_dir/empty" \
EVENT_IMPORTER_IMAGE=networknt/event-importer:test \
  "$importer" </dev/null >/dev/null
grep -Fq 'run --rm -i --network all-in-lt_default' "$tmp_dir/container.args" ||
  fail "private importer did not use the stack directory network fallback"
[[ "$(grep -c '^run --rm -i ' "$tmp_dir/container.args")" == "2" ]] ||
  fail "private importer did not run once for each manifest delta"
[[ "$(grep -c 'INSERT INTO portal_instance_event_delta_t' "$tmp_dir/container.args")" == "2" ]] ||
  fail "private importer did not ledger each manifest delta"
if grep 'INSERT INTO portal_instance_event_delta_t' "$tmp_dir/container.args" | grep -Fq 'exec -i '; then
  fail "private delta ledger INSERT still attaches caller stdin"
fi

orchestrator=""
for candidate in \
  "$repo_root/scripts/restart-dev-stack.sh" \
  "$repo_root/scripts/restart-bootstrap-stack.sh" \
  "$repo_root/scripts/deploy-local.sh" \
  "$repo_root/install.sh"; do
  [[ -f "$candidate" ]] && orchestrator="$candidate" && break
done
[[ -n "$orchestrator" ]] || fail "startup orchestrator was not found"
if grep -Fiq 'fresh signed baseline is authoritative; skipping release event deltas' "$orchestrator"; then
  fail "startup still bypasses all release deltas for a fresh baseline"
fi
grep -Fq 'import-instance-event-deltas.sh' "$orchestrator" ||
  fail "startup does not invoke the private instance delta importer"
grep -Fq 'PORTAL_SKIP_INSTANCE_EVENT_DELTAS' "$orchestrator" ||
  fail "startup has no independent private-delta skip contract"

echo "Private instance event delta contract passed for $repo_root"

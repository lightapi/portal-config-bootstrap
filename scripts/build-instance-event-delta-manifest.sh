#!/usr/bin/env bash
set -euo pipefail

die() {
  printf '[build-instance-event-delta-manifest] error: %s\n' "$*" >&2
  exit 1
}

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd -- "$script_dir/.." && pwd)"
instance_id="${1:-}"
delta_dir="${2:-${PORTAL_INSTANCE_EVENT_DELTA_DIR:-$repo_dir/data/private-event-deltas}}"
manifest="${PORTAL_INSTANCE_EVENT_DELTA_MANIFEST:-$delta_dir/manifest.json}"

[[ "$instance_id" =~ ^[A-Za-z0-9._-]{1,128}$ ]] ||
  die "usage: $0 INSTANCE_ID [PRIVATE_DELTA_DIRECTORY]"
command -v jq >/dev/null 2>&1 || die "jq is required"
mkdir -p "$delta_dir"

shopt -s nullglob
files=("$delta_dir"/*.json)
shopt -u nullglob
entries="$(mktemp "${TMPDIR:-/tmp}/portal-instance-delta-entries.XXXXXX")"
manifest_tmp="$(mktemp "${TMPDIR:-/tmp}/portal-instance-delta-manifest.XXXXXX")"
trap 'rm -f "$entries" "$manifest_tmp"' EXIT

for path in "${files[@]}"; do
  [[ "$path" == "$manifest" ]] && continue
  jq -e 'type == "array" and length > 0' "$path" >/dev/null ||
    die "private event delta must be a non-empty JSON array: $path"
  file="$(basename -- "$path")"
  id="${file%.json}"
  [[ "$id" =~ ^[A-Za-z0-9._-]{1,128}$ ]] ||
    die "private event delta filename is not a safe delta id: $file"
  checksum="$(sha256sum "$path" | awk '{print $1}')"
  jq -cn --arg id "$id" --arg file "$file" --arg sha256 "$checksum" \
    '{id:$id,file:$file,sha256:$sha256}' >> "$entries"
done

jq -s --arg instanceId "$instance_id" '{
  format: "lightapi.portal-instance-event-deltas",
  formatVersion: 1,
  instanceId: $instanceId,
  eventDeltas: .
}' "$entries" > "$manifest_tmp"
mv "$manifest_tmp" "$manifest"
printf '[build-instance-event-delta-manifest] wrote %s\n' "$manifest"

#!/usr/bin/env bash
# Expected release is pinned independently of the mounted bundle.
set -euo pipefail
root="${OPERATIONAL_BUNDLE_ROOT:-/opt/operational-store/bundle}"
read -r expected count version < "$(dirname -- "${BASH_SOURCE[0]}")/expected-bundle.tsv"
[[ "$expected" =~ ^[0-9a-f]{64}$ && "$count" =~ ^[1-9][0-9]*$ ]] || exit 1
[[ "${OPERATIONAL_BUNDLE_VERSION:-$version}" == "$version" ]] || exit 1
[[ "$(sha256sum "$root/manifest.json" | awk '{print $1}')" == "$expected" ]] || {
  echo 'operational-bundle: stale or unqualified release manifest; synchronize canonical assets' >&2
  exit 1
}
(cd "$root" && sha256sum -c bundle.sha256 >/dev/null)
[[ "$(awk -F '\t' 'NF && $1 !~ /^#/ {n++} END {print n+0}' "$root/migration-order.tsv")" == "$count" ]] || exit 1

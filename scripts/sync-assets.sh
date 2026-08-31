#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/sync-assets.sh [--dry-run]

Download the current runtime asset archives from the CDN and sync them into
the Bootstrap baseline services.

Synced assets:
  hybrid-command.zip -> hybrid-command/service/
  hybrid-query.zip   -> hybrid-query/service/
  lightapi.zip       -> light-gateway-rust/lightapi/
  signin.zip         -> light-gateway-rust/signin/

Options:
  -n, --dry-run  Show what would be downloaded and replaced.
  -h, --help     Show this help.

Environment overrides:
  LIGHT_PORTAL_ASSET_BASE_URL  Default: https://cdn.networknt.com
  ASSET_CACHE_DIR              Optional archive cache. By default a temporary
                               directory is used and removed after the sync.
USAGE
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

dry_run=false
while (($#)); do
  case "$1" in
    -n|--dry-run)
      dry_run=true
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
  shift
done

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd -- "$script_dir/.." && pwd)"
asset_base_url="${LIGHT_PORTAL_ASSET_BASE_URL:-https://cdn.networknt.com}"
asset_base_url="${asset_base_url%/}"

temporary_cache=false
active_staged_dir=""
if [[ -n "${ASSET_CACHE_DIR:-}" ]]; then
  cache_dir="$ASSET_CACHE_DIR"
else
  cache_dir="$(mktemp -d "${TMPDIR:-/tmp}/portal-config-bootstrap-assets.XXXXXX")"
  temporary_cache=true
fi

cleanup() {
  [[ -z "$active_staged_dir" ]] || rm -rf "$active_staged_dir"
  if [[ "$temporary_cache" == true ]]; then
    rm -rf "$cache_dir"
  fi
}
trap cleanup EXIT

fetch_archive() {
  local archive_name="$1"
  local archive_path="$cache_dir/$archive_name"
  local url="$asset_base_url/$archive_name"

  if [[ "$dry_run" == true ]]; then
    printf 'would download %s\n' "$url"
    return
  fi

  mkdir -p "$cache_dir"
  printf 'downloading %s\n' "$url"
  curl -fsSL "$url" -o "$archive_path.tmp"
  mv "$archive_path.tmp" "$archive_path"
  unzip -tq "$archive_path" >/dev/null || die "invalid archive: $archive_path"
}

extract_archive() {
  local archive_name="$1"
  local target_dir="$2"
  local archive_path="$cache_dir/$archive_name"
  local staged_dir="${target_dir}.sync.$$"

  if [[ "$dry_run" == true ]]; then
    printf 'would replace %s from %s\n' "$target_dir" "$archive_name"
    return
  fi

  rm -rf "$staged_dir"
  active_staged_dir="$staged_dir"
  mkdir -p "$staged_dir"
  unzip -q "$archive_path" -d "$staged_dir"
  if [[ -f "$target_dir/.gitkeep" ]]; then
    cp -p "$target_dir/.gitkeep" "$staged_dir/.gitkeep"
  fi
  rm -rf "$target_dir"
  mv "$staged_dir" "$target_dir"
  active_staged_dir=""
  printf 'synced %s to %s\n' "$archive_name" "$target_dir"
}

if [[ "$dry_run" == false ]]; then
  command -v curl >/dev/null 2>&1 || die "curl is required"
  command -v unzip >/dev/null 2>&1 || die "unzip is required"
fi

printf 'using release assets from %s\n' "$asset_base_url"
for archive_name in hybrid-command.zip hybrid-query.zip lightapi.zip signin.zip; do
  fetch_archive "$archive_name"
done

extract_archive hybrid-command.zip "$repo_dir/hybrid-command/service"
extract_archive hybrid-query.zip "$repo_dir/hybrid-query/service"
extract_archive lightapi.zip "$repo_dir/light-gateway-rust/lightapi"
extract_archive signin.zip "$repo_dir/light-gateway-rust/signin"

if [[ "$dry_run" == true ]]; then
  printf 'dry run complete; no files changed\n'
else
  printf 'asset sync complete\n'
fi

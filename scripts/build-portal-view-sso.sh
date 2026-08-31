#!/usr/bin/env bash
set -euo pipefail

die() {
  printf '[build-portal-view-sso] error: %s\n' "$*" >&2
  exit 1
}

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd -- "$script_dir/.." && pwd)"
portal_view_dir="${PORTAL_VIEW_DIR:-$repo_dir/../portal-view}"
bootstrap_env_file="${BOOTSTRAP_ENV_FILE:-$repo_dir/.env.bootstrap}"
target_dir="$repo_dir/portal-bff-sso/lightapi/dist"
staged_dir="${target_dir}.build.$$"

[[ -f "$bootstrap_env_file" ]] || die "missing $bootstrap_env_file; copy .env.bootstrap.example first"
[[ -f "$portal_view_dir/package.json" ]] || die "portal-view checkout not found at $portal_view_dir"
command -v npm >/dev/null 2>&1 || die "npm is required"

env_value() {
  local name="$1"

  awk -F= -v key="$name" '
    $1 == key {
      sub(/^[^=]*=/, "")
      gsub(/^"|"$/, "")
      print
      exit
    }
  ' "$bootstrap_env_file"
}

tenant_id="$(env_value MSAL_TENANT_ID)"
client_id="$(env_value MSAL_CLIENT_ID)"
redirect_uri="$(env_value MSAL_REDIRECT_URI)"

[[ -n "$tenant_id" && "$tenant_id" != replace-* ]] || die "MSAL_TENANT_ID is not configured"
[[ -n "$client_id" && "$client_id" != replace-* ]] || die "MSAL_CLIENT_ID is not configured"
[[ "$redirect_uri" == https://* ]] || die "MSAL_REDIRECT_URI must be an HTTPS URL"

printf '[build-portal-view-sso] building Portal View with MSAL enabled\n'
(
  cd "$portal_view_dir"
  npm ci
  VITE_SSO_ENABLED=true \
  VITE_TENANT_ID="$tenant_id" \
  VITE_CLIENT_ID="$client_id" \
  VITE_REDIRECT_URI="$redirect_uri" \
    npm run build
)

[[ -f "$portal_view_dir/dist/index.html" ]] || die "portal-view build did not create dist/index.html"
rm -rf "$staged_dir"
mkdir -p "$staged_dir"
cp -a "$portal_view_dir/dist/." "$staged_dir/"
rm -rf "$target_dir"
mv "$staged_dir" "$target_dir"
printf '[build-portal-view-sso] installed SSO SPA in %s\n' "$target_dir"

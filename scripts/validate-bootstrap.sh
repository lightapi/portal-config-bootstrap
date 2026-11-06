#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd -- "$script_dir/.." && pwd)"
env_file="${BOOTSTRAP_ENV_FILE:-$repo_dir/.env.bootstrap.example}"
light_portal_env_file="${LIGHT_PORTAL_ENV_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/lightapi/light-portal.env}"
[[ -f "$env_file" ]] || { printf 'bootstrap environment file is missing: %s\n' "$env_file" >&2; exit 1; }
python3 -B "$script_dir/portal-view-release.py" image-env
env_args=(--env-file "$repo_dir/docker-images.env")
if [[ -f "$light_portal_env_file" ]]; then
  env_args+=(--env-file "$light_portal_env_file")
fi
env_args+=(--env-file "$env_file")

docker compose \
  -f "$repo_dir/docker-compose.yml" \
  -f "$repo_dir/docker-compose.bootstrap.yml" \
  "${env_args[@]}" \
  config --quiet

for shell_file in "$repo_dir"/scripts/*.sh; do
  bash -n "$shell_file"
done

printf '[validate-bootstrap] Compose and shell validation passed\n'

#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd -- "$script_dir/.." && pwd)"
env_file="${BOOTSTRAP_ENV_FILE:-$repo_dir/.env.bootstrap.example}"

docker compose \
  -f "$repo_dir/docker-compose.yml" \
  -f "$repo_dir/docker-compose.bootstrap.yml" \
  --env-file "$env_file" \
  config --quiet

for shell_file in "$repo_dir"/scripts/*.sh; do
  bash -n "$shell_file"
done

printf '[validate-bootstrap] Compose and shell validation passed\n'

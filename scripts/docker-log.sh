#!/usr/bin/env bash
set -u

usage() {
  cat <<'USAGE'
Usage: scripts/docker-log.sh [OUTPUT_DIR]

Write portal-config-dev container logs to text files for debugging.

OUTPUT_DIR defaults to the current directory.
USAGE
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac

if (($# > 1)); then
  usage >&2
  exit 1
fi

output_dir="${1:-.}"
mkdir -p "$output_dir"

collect_log() {
  local container="$1"
  local file="$2"
  local path="$output_dir/$file"

  rm -f "$path"
  if ! docker logs "$container" > "$path" 2>&1; then
    printf 'failed to collect logs for %s; see %s\n' "$container" "$path" >&2
  fi
}

collect_log hybrid-query query.txt
collect_log hybrid-command command.txt
collect_log light-oauth oauth.txt
collect_log postgres postgres.txt
collect_log portal-service reference.txt
collect_log light-gateway gateway.txt
collect_log llm-gateway llm-gateway.txt
collect_log config-server config.txt
collect_log controller controller.txt
collect_log light-workflow workflow.txt
collect_log demo-customer-profile-api customer-profile.txt
collect_log demo-offer-decision-api offer-decision.txt

printf 'docker logs written to %s\n' "$output_dir"

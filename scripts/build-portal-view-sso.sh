#!/usr/bin/env bash
set -euo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
printf '%s\n' '[build-portal-view-sso] Preparing packaged Portal View; no source build is performed.'
exec python3 -B "$script_dir/portal-view-release.py" --service portal-bff-sso prepare "$@"

#!/usr/bin/env bash
set -euo pipefail

die() {
  printf '[generate-bootstrap-tls] error: %s\n' "$*" >&2
  exit 1
}

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd -- "$script_dir/.." && pwd)"
bootstrap_env_file="${BOOTSTRAP_ENV_FILE:-$repo_dir/.env.bootstrap}"
tls_dir="$repo_dir/portal-bff-sso/tls"

[[ -f "$bootstrap_env_file" ]] || die "missing $bootstrap_env_file; copy .env.bootstrap.example first"
command -v openssl >/dev/null 2>&1 || die "openssl is required"

customer_host="$(awk -F= '$1 == "CUSTOMER_PORTAL_HOST" { sub(/^[^=]*=/, ""); gsub(/^"|"$/, ""); print; exit }' "$bootstrap_env_file")"
customer_host="${customer_host:-dev.yourcompany.com}"
[[ "$customer_host" =~ ^[A-Za-z0-9.-]+$ ]] || die "invalid CUSTOMER_PORTAL_HOST: $customer_host"

mkdir -p "$tls_dir"
for output_file in ca.pem cert.pem key.pem; do
  [[ ! -e "$tls_dir/$output_file" ]] || die "$tls_dir/$output_file already exists; refusing to overwrite it"
done

temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/portal-bootstrap-tls.XXXXXX")"
trap 'rm -rf "$temporary_dir"' EXIT

openssl req -x509 -newkey rsa:3072 -nodes -days 825 \
  -subj "/CN=$customer_host" \
  -addext "subjectAltName=DNS:$customer_host,DNS:localhost,IP:127.0.0.1" \
  -keyout "$temporary_dir/key.pem" \
  -out "$temporary_dir/cert.pem"

cp "$temporary_dir/cert.pem" "$tls_dir/ca.pem"
cp "$temporary_dir/cert.pem" "$tls_dir/cert.pem"
cp "$temporary_dir/key.pem" "$tls_dir/key.pem"
chmod 600 "$tls_dir/key.pem"
printf '[generate-bootstrap-tls] generated development certificate for %s\n' "$customer_host"
printf '[generate-bootstrap-tls] replace it with an enterprise-issued certificate before shared use\n'

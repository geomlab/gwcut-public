#!/usr/bin/env bash
set -euo pipefail
set +x
umask 077

readonly PUBLIC_STAGE0_SHA='c95f0bf398732232d1de886d540cdeb586dcbabb'
readonly PUBLIC_BOOTSTRAP_URL="https://raw.githubusercontent.com/geomlab/gwcut-public/${PUBLIC_STAGE0_SHA}/bootstrap.sh"

fatal() {
  printf 'gwcut stable bootstrap failed: %s\n' "$*" >&2
  exit 2
}

[[ ${EUID:-$(id -u)} -eq 0 ]] || fatal "must run as root"
[[ "$PUBLIC_STAGE0_SHA" =~ ^[0-9a-f]{40}$ ]] || fatal "invalid pinned public Stage-0 SHA"
command -v curl >/dev/null 2>&1 || fatal "curl is required"

tmp_dir="$(mktemp -d /root/gwcut-stable-bootstrap.XXXXXX)"
loader="${tmp_dir}/bootstrap.sh"
cleanup() {
  rm -rf -- "$tmp_dir"
}
trap cleanup EXIT

curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
  "$PUBLIC_BOOTSTRAP_URL" \
  --output "$loader"
chmod 0700 "$loader"

# Preserve stdin unchanged: the canonical seven-field credential bundle flows
# directly into the immutable Stage-0 selected by this stable release channel.
/bin/bash "$loader"

#!/usr/bin/env bash
set -euo pipefail
set +x
umask 077

readonly PUBLIC_STAGE0_SHA='acdc19676200931cc9b61cfaa5292b4a0ccab846'
readonly INFRA_SHA='ecbeb3a6413d4a073361f5ff8aa9404ecda843d7'
readonly PUBLIC_BOOTSTRAP_URL="https://raw.githubusercontent.com/geomlab/gwcut-public/${PUBLIC_STAGE0_SHA}/bootstrap.sh"

fatal() {
  printf 'gwcut stable bootstrap failed: %s\n' "$*" >&2
  exit 2
}

[[ ${EUID:-$(id -u)} -eq 0 ]] || fatal "must run as root"
[[ "$PUBLIC_STAGE0_SHA" =~ ^[0-9a-f]{40}$ ]] || fatal "invalid pinned public Stage-0 SHA"
[[ "$INFRA_SHA" =~ ^[0-9a-f]{40}$ ]] || fatal "invalid pinned infra SHA"
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

# Preserve stdin unchanged: the canonical retained credential bundle flows directly into the
# immutable Stage-0 selected by this stable release channel.
GWCUT_INFRA_GIT_SHA="$INFRA_SHA" /bin/bash "$loader"

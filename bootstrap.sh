#!/usr/bin/env bash
set -euo pipefail
set +x
umask 077

readonly INFRA_SHA='929b40d9ec957287ea31a811018ac3385831518b'
readonly INFRA_REPO='geomlab/gwcut-infra'
readonly BOOTSTRAP_PATH='deploy/compose/bootstrap-compose-v1.sh'

fatal() {
  printf 'gwcut stage-0 bootstrap failed: %s\n' "$*" >&2
  exit 2
}

[[ ${EUID:-$(id -u)} -eq 0 ]] || fatal "must run as root"
[[ "$INFRA_SHA" =~ ^[0-9a-f]{40}$ ]] || fatal "invalid pinned infra SHA"

command -v curl >/dev/null 2>&1 || fatal "curl is required"

# Read the canonical retained seven-field credential bundle.
# Do not source this file.
GITHUB_TOKEN=""
GHCR_READ_TOKEN=""
DASHBOARD_PASSWORD=""
S3_ACCESS_KEY=""
S3_SECRET_KEY=""
S3_BUCKET=""
S3_REGION=""

declare -A seen=()

while IFS= read -r line || [[ -n "$line" ]]; do
  [[ -z "$line" || "$line" == \#* ]] && continue
  [[ "$line" == *=* ]] \
    || fatal "bootstrap input must contain NAME=value assignments only"

  name=${line%%=*}
  value=${line#*=}

  case "$name" in
    GITHUB_TOKEN|GHCR_READ_TOKEN|DASHBOARD_PASSWORD|S3_ACCESS_KEY|S3_SECRET_KEY|S3_BUCKET|S3_REGION)
      ;;
    *)
      fatal "unknown bootstrap input field: $name"
      ;;
  esac

  [[ -z ${seen[$name]+x} ]] \
    || fatal "duplicate bootstrap input field: $name"
  [[ -n "$value" ]] \
    || fatal "bootstrap input field is empty: $name"
  [[ ${#value} -le 4096 ]] \
    || fatal "bootstrap input field is too long: $name"
  [[ "$value" != *$'\r'* ]] \
    || fatal "bootstrap input contains carriage return: $name"

  seen[$name]=1
  printf -v "$name" '%s' "$value"
done

required=(
  GITHUB_TOKEN
  GHCR_READ_TOKEN
  DASHBOARD_PASSWORD
  S3_ACCESS_KEY
  S3_SECRET_KEY
  S3_BUCKET
  S3_REGION
)

for name in "${required[@]}"; do
  [[ -n ${!name} ]] || fatal "missing bootstrap input field: $name"
done

[[ "$S3_REGION" =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]] \
  || fatal "S3_REGION has invalid syntax"

[[ "$S3_BUCKET" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]] \
  || fatal "S3_BUCKET has invalid syntax"

[[ "$S3_BUCKET" != *..* ]] \
  || fatal "S3_BUCKET must not contain adjacent dots"

tmp_dir="$(mktemp -d /root/gwcut-compose-stage0.XXXXXX)"
bootstrap="${tmp_dir}/bootstrap-compose-v1.sh"

cleanup() {
  rm -rf -- "$tmp_dir"
}

trap cleanup EXIT

# Fetch exactly one reviewed bootstrap file from the pinned private
# infrastructure commit. No production Git checkout is retained.
api_url="https://api.github.com/repos/${INFRA_REPO}/contents/${BOOTSTRAP_PATH}?ref=${INFRA_SHA}"

curl \
  --fail \
  --silent \
  --show-error \
  --location \
  --proto '=https' \
  --tlsv1.2 \
  -H "Authorization: Bearer ${GITHUB_TOKEN}" \
  -H "Accept: application/vnd.github.raw+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "$api_url" \
  --output "$bootstrap"

chmod 0700 "$bootstrap"

# The GitHub token is needed only to retrieve the exact private bootstrap.
# GHCR images are public. Neither credential is persisted on the host.
unset GITHUB_TOKEN

printf 'gwcut stage-0 selected exact infra release %s\n' "$INFRA_SHA"

# Forward the same canonical seven-field contract to the private bootstrap.
# GITHUB_TOKEN is no longer needed there, but the field remains part of the
# stable operator contract. Supply a non-secret compatibility marker.
{
  printf 'GITHUB_TOKEN=not-persisted-stage0-token\n'
  printf 'GHCR_READ_TOKEN=%s\n' "$GHCR_READ_TOKEN"
  printf 'DASHBOARD_PASSWORD=%s\n' "$DASHBOARD_PASSWORD"
  printf 'S3_ACCESS_KEY=%s\n' "$S3_ACCESS_KEY"
  printf 'S3_SECRET_KEY=%s\n' "$S3_SECRET_KEY"
  printf 'S3_BUCKET=%s\n' "$S3_BUCKET"
  printf 'S3_REGION=%s\n' "$S3_REGION"
} | /bin/bash "$bootstrap"

unset \
  GHCR_READ_TOKEN \
  DASHBOARD_PASSWORD \
  S3_ACCESS_KEY \
  S3_SECRET_KEY \
  S3_BUCKET \
  S3_REGION

printf 'gwcut stage-0 Compose bootstrap complete for %s\n' "$INFRA_SHA"

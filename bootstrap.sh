#!/usr/bin/env bash
set -euo pipefail
set +x
umask 077

fatal() {
  printf 'gwcut bootstrap failed: %s\n' "$*" >&2
  exit 2
}

log() {
  printf '\n==> %s\n' "$*"
}

[[ ${EUID:-$(id -u)} -eq 0 ]] || fatal "must run as root"

[[ -r /etc/os-release ]] || fatal "cannot identify operating system"
grep -Eq '^ID="?ubuntu"?$' /etc/os-release || fatal "requires Ubuntu 24.04"
grep -Eq '^VERSION_ID="?24\.04"?$' /etc/os-release || fatal "requires Ubuntu 24.04"

command -v curl >/dev/null 2>&1 || fatal "curl is required"

readonly INFRA_IMAGE='ghcr.io/geomlab/gwcut-infra:main'
readonly SCIENCE_DIGEST='sha256:8a1912c584e2d187e2d944a6d830f5b8af1715fd33a96ede85bc1cbb58086106'
readonly SCIENCE_IMAGE='ghcr.io/geomlab/gwcut@sha256:8a1912c584e2d187e2d944a6d830f5b8af1715fd33a96ede85bc1cbb58086106'

DASHBOARD_PASSWORD=""
S3_ACCESS_KEY=""
S3_SECRET_KEY=""
S3_BUCKET=""
S3_REGION=""

# Compatibility only:
# old retained files may still contain these two values.
# They are accepted but ignored.
GITHUB_TOKEN=""
GHCR_READ_TOKEN=""

declare -A seen=()

while IFS= read -r line || [[ -n "$line" ]]; do
  [[ -z "$line" || "$line" == \#* ]] && continue
  [[ "$line" == *=* ]] || fatal "input must contain NAME=value assignments only"

  name=${line%%=*}
  value=${line#*=}

  case "$name" in
    DASHBOARD_PASSWORD|S3_ACCESS_KEY|S3_SECRET_KEY|S3_BUCKET|S3_REGION|GITHUB_TOKEN|GHCR_READ_TOKEN)
      ;;
    *)
      fatal "unknown input field: $name"
      ;;
  esac

  [[ -z ${seen[$name]+x} ]] || fatal "duplicate input field: $name"
  [[ ${#value} -le 4096 ]] || fatal "input field is too long: $name"
  [[ "$value" != *$'\r'* ]] || fatal "input contains carriage return: $name"

  seen[$name]=1
  printf -v "$name" '%s' "$value"
done

required=(
  DASHBOARD_PASSWORD
  S3_ACCESS_KEY
  S3_SECRET_KEY
  S3_BUCKET
  S3_REGION
)

for name in "${required[@]}"; do
  [[ -n ${!name} ]] || fatal "missing input field: $name"
done

[[ "$S3_REGION" =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]] \
  || fatal "S3_REGION has invalid syntax"

[[ "$S3_BUCKET" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]] \
  || fatal "S3_BUCKET has invalid syntax"

[[ "$S3_BUCKET" != *..* ]] \
  || fatal "S3_BUCKET must not contain adjacent dots"

unset GITHUB_TOKEN GHCR_READ_TOKEN

log "Installing Docker Engine and Compose"

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates \
  curl \
  docker.io \
  docker-compose-v2 \
  python3

command -v docker >/dev/null 2>&1 \
  || fatal "docker is unavailable after installation"

docker compose version >/dev/null 2>&1 \
  || fatal "docker compose plugin is unavailable after installation"

systemctl enable --now docker.service
systemctl is-active --quiet docker.service \
  || fatal "docker.service is not active"

PUBLIC_HOST="$(
  ip -4 route get 1.1.1.1 2>/dev/null \
    | awk '
        {
          for (i = 1; i <= NF; i++) {
            if ($i == "src" && (i + 1) <= NF) {
              print $(i + 1)
              exit
            }
          }
        }
      '
)"

[[ -n "$PUBLIC_HOST" ]] || fatal "could not determine public IPv4 address"

[[ "$PUBLIC_HOST" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] \
  || fatal "detected public host is not an IPv4 address: $PUBLIC_HOST"

log "Detected public host: ${PUBLIC_HOST}"

install -d -o root -g root -m 0755 \
  /opt/gwcut \
  /opt/gwcut/deploy \
  /opt/gwcut/deploy/compose \
  /var/lib/gwcut \
  /var/lib/gwcut/work \
  /var/lib/gwcut/planner

log "Downloading current public Compose configuration"

curl \
  --fail \
  --silent \
  --show-error \
  --location \
  --proto '=https' \
  --tlsv1.2 \
  https://raw.githubusercontent.com/geomlab/gwcut-public/main/compose.production.yml \
  -o /opt/gwcut/compose.production.yml

curl \
  --fail \
  --silent \
  --show-error \
  --location \
  --proto '=https' \
  --tlsv1.2 \
  https://raw.githubusercontent.com/geomlab/gwcut-public/main/Caddyfile \
  -o /opt/gwcut/deploy/compose/Caddyfile

chmod 0644 \
  /opt/gwcut/compose.production.yml \
  /opt/gwcut/deploy/compose/Caddyfile

generate_secret() {
  python3 - <<'PY'
import secrets
print(secrets.token_hex(32))
PY
}

POSTGRES_PASSWORD="$(generate_secret)"
INTERNAL_TOKEN="$(generate_secret)"
S3_ENDPOINT="https://${S3_REGION}.your-objectstorage.com"

IMAGE_SPECS_JSON='{"'"${SCIENCE_DIGEST}"'":{"reference":"'"${SCIENCE_IMAGE}"'","entrypoint":"gwcut-worker"}}'

dotenv_literal() {
  local value=$1
  value=${value//\'/\\\'}
  printf "'%s'" "$value"
}

log "Writing Compose environment"

{
  printf 'COMPOSE_PROJECT_NAME=gwcut\n'

  printf 'POSTGRES_PASSWORD='
  dotenv_literal "$POSTGRES_PASSWORD"
  printf '\n'

  printf 'GWCUT_CONTROL_TOKEN='
  dotenv_literal "$DASHBOARD_PASSWORD"
  printf '\n'

  printf 'GWCUT_INTERNAL_TOKEN='
  dotenv_literal "$INTERNAL_TOKEN"
  printf '\n'

  printf 'GWCUT_INFRA_IMAGE=%s\n' "$INFRA_IMAGE"
  printf 'GWCUT_SCIENCE_IMAGE_DIGEST=%s\n' "$SCIENCE_DIGEST"
  printf 'GWCUT_SCIENCE_IMAGE_REFERENCE=%s\n' "$SCIENCE_IMAGE"

  printf 'GWCUT_IMAGE_SPECS_JSON='
  dotenv_literal "$IMAGE_SPECS_JSON"
  printf '\n'

  printf 'GWCUT_PUBLIC_HOST=%s\n' "$PUBLIC_HOST"

  printf 'GWCUT_MAX_WORKERS=4\n'
  printf 'GWCUT_MEMORY_BUDGET_MIB=12288\n'
  printf 'GWCUT_CPU_BUDGET=6\n'
  printf 'GWCUT_DISK_BUDGET_MIB=102400\n'

  printf 'S3_ENDPOINT=%s\n' "$S3_ENDPOINT"

  printf 'S3_BUCKET='
  dotenv_literal "$S3_BUCKET"
  printf '\n'

  printf 'S3_ACCESS_KEY='
  dotenv_literal "$S3_ACCESS_KEY"
  printf '\n'

  printf 'S3_SECRET_KEY='
  dotenv_literal "$S3_SECRET_KEY"
  printf '\n'

  printf 'GWCUT_ARTIFACT_S3_REGION=%s\n' "$S3_REGION"
} >/opt/gwcut/.env

chown root:root /opt/gwcut/.env
chmod 0600 /opt/gwcut/.env

unset \
  POSTGRES_PASSWORD \
  INTERNAL_TOKEN \
  DASHBOARD_PASSWORD \
  S3_ACCESS_KEY \
  S3_SECRET_KEY

cd /opt/gwcut

log "Validating Compose configuration"

docker compose \
  --env-file /opt/gwcut/.env \
  -f /opt/gwcut/compose.production.yml \
  config >/dev/null

mapfile -t services < <(
  docker compose \
    --env-file /opt/gwcut/.env \
    -f /opt/gwcut/compose.production.yml \
    config --services \
    | sort
)

expected_services=(api caddy postgres scheduler)

[[ "${services[*]}" == "${expected_services[*]}" ]] \
  || fatal "Compose contract must contain exactly: api caddy postgres scheduler"

log "Pulling GWCut images"

docker pull "$INFRA_IMAGE"
docker pull "$SCIENCE_IMAGE"

log "Starting GWCut"

docker compose \
  --env-file /opt/gwcut/.env \
  -f /opt/gwcut/compose.production.yml \
  pull

docker compose \
  --env-file /opt/gwcut/.env \
  -f /opt/gwcut/compose.production.yml \
  up -d

log "Waiting for services"

ready=0

for _ in $(seq 1 60); do
  running="$(
    docker compose \
      --env-file /opt/gwcut/.env \
      -f /opt/gwcut/compose.production.yml \
      ps --services --status running \
      | sort \
      | tr '\n' ' ' \
      | sed 's/[[:space:]]*$//'
  )"

  if [[ "$running" == "api caddy postgres scheduler" ]]; then
    api_id="$(
      docker compose \
        --env-file /opt/gwcut/.env \
        -f /opt/gwcut/compose.production.yml \
        ps -q api
    )"

    postgres_id="$(
      docker compose \
        --env-file /opt/gwcut/.env \
        -f /opt/gwcut/compose.production.yml \
        ps -q postgres
    )"

    api_health="$(
      docker inspect \
        --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
        "$api_id" 2>/dev/null || true
    )"

    postgres_health="$(
      docker inspect \
        --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
        "$postgres_id" 2>/dev/null || true
    )"

    if [[ "$api_health" == "healthy" && "$postgres_health" == "healthy" ]]; then
      ready=1
      break
    fi
  fi

  sleep 2
done

[[ "$ready" -eq 1 ]] || {
  docker compose \
    --env-file /opt/gwcut/.env \
    -f /opt/gwcut/compose.production.yml \
    ps || true

  docker compose \
    --env-file /opt/gwcut/.env \
    -f /opt/gwcut/compose.production.yml \
    logs --tail=120 || true

  fatal "Compose services did not become healthy"
}

log "Waiting for public HTTPS"

https_ready=0

for _ in $(seq 1 90); do
  body="$(
    curl \
      --fail \
      --silent \
      --show-error \
      --max-time 5 \
      "https://${PUBLIC_HOST}/health" \
      2>/dev/null || true
  )"

  if [[ "$body" == '{"status":"ok"}' ]]; then
    https_ready=1
    break
  fi

  sleep 2
done

[[ "$https_ready" -eq 1 ]] \
  || fatal "public HTTPS /health did not become ready"

app_status="$(
  curl \
    --silent \
    --output /dev/null \
    --write-out '%{http_code}' \
    --max-time 5

#!/usr/bin/env bash
set -euo pipefail
set +x
umask 077

readonly REPO_URL="https://github.com/geomlab/gwcut-infra.git"
readonly TOKEN_FILE="/opt/gwcut/updater-github-token"
readonly GHCR_TOKEN_FILE="/opt/gwcut/ghcr-read-token"
readonly RELEASE_ROOT="/opt/gwcut-infra/releases"
readonly AUTH_DIR="/opt/gwcut/auth"
readonly BOOTSTRAP_MODE="${GWCUT_BOOTSTRAP_MODE:-first-install}"

fatal() {
  printf 'gwcut stage-0 bootstrap failed: %s\n' "$*" >&2
  exit 2
}

[[ ${EUID:-$(id -u)} -eq 0 ]] || fatal "must run as root"
[[ -n ${GWCUT_INFRA_GIT_SHA:-} ]] || fatal "GWCUT_INFRA_GIT_SHA is required"
[[ ${GWCUT_INFRA_GIT_SHA} =~ ^[0-9a-f]{40}$ ]] || fatal "GWCUT_INFRA_GIT_SHA must be a full lowercase commit SHA"
target_sha="$GWCUT_INFRA_GIT_SHA"

case "$BOOTSTRAP_MODE" in
  first-install|host) ;;
  pitr-restore-drill)
    [[ -n ${GWCUT_PITR_SOURCE_GENERATION:-} ]] || fatal "restore drill mode requires GWCUT_PITR_SOURCE_GENERATION"
    [[ ${GWCUT_PITR_SOURCE_GENERATION} =~ ^[0-9]+$ ]] || fatal "GWCUT_PITR_SOURCE_GENERATION must be numeric"
    [[ -n ${GWCUT_DRILL_SOURCE_URL:-} ]] || fatal "restore drill mode requires GWCUT_DRILL_SOURCE_URL"
    ;;
  *) fatal "unsupported GWCUT_BOOTSTRAP_MODE: $BOOTSTRAP_MODE" ;;
esac

[[ -r /etc/os-release ]] || fatal "cannot identify operating system"
grep -Eq '^ID="?ubuntu"?$' /etc/os-release || fatal "fresh bootstrap requires Ubuntu 24.04"
grep -Eq '^VERSION_ID="?24\.04"?$' /etc/os-release || fatal "fresh bootstrap requires Ubuntu 24.04"

GITHUB_TOKEN=""
GHCR_READ_TOKEN=""
DASHBOARD_PASSWORD=""
S3_WORKER_ACCESS_KEY=""
S3_WORKER_SECRET_KEY=""
S3_READER_ACCESS_KEY=""
S3_READER_SECRET_KEY=""
S3_BACKUP_ACCESS_KEY=""
S3_BACKUP_SECRET_KEY=""
S3_PITR_ACCESS_KEY=""
S3_PITR_SECRET_KEY=""
S3_BUCKET=""
S3_REGION=""
declare -A seen=()
while IFS= read -r line || [[ -n "$line" ]]; do
  [[ -z "$line" || "$line" == \#* ]] && continue
  [[ "$line" == *=* ]] || fatal "bootstrap input must contain NAME=value assignments only"
  name=${line%%=*}
  value=${line#*=}
  case "$name" in
    GITHUB_TOKEN|GHCR_READ_TOKEN|DASHBOARD_PASSWORD|S3_WORKER_ACCESS_KEY|S3_WORKER_SECRET_KEY|S3_READER_ACCESS_KEY|S3_READER_SECRET_KEY|S3_BACKUP_ACCESS_KEY|S3_BACKUP_SECRET_KEY|S3_PITR_ACCESS_KEY|S3_PITR_SECRET_KEY|S3_BUCKET|S3_REGION) ;;
    *) fatal "unknown bootstrap input field: $name" ;;
  esac
  [[ -z ${seen[$name]+x} ]] || fatal "duplicate bootstrap input field: $name"
  [[ -n "$value" ]] || fatal "bootstrap input field is empty: $name"
  [[ ${#value} -le 4096 ]] || fatal "bootstrap input field is too long: $name"
  [[ "$value" != *$'\r'* ]] || fatal "bootstrap input field contains carriage return: $name"
  seen[$name]=1
  printf -v "$name" '%s' "$value"
done

case "$BOOTSTRAP_MODE" in
  first-install|host)
    required=(
      GITHUB_TOKEN GHCR_READ_TOKEN DASHBOARD_PASSWORD
      S3_WORKER_ACCESS_KEY S3_WORKER_SECRET_KEY
      S3_READER_ACCESS_KEY S3_READER_SECRET_KEY
      S3_BACKUP_ACCESS_KEY S3_BACKUP_SECRET_KEY
      S3_PITR_ACCESS_KEY S3_PITR_SECRET_KEY
      S3_BUCKET S3_REGION
    )
    ;;
  pitr-restore-drill)
    required=(GITHUB_TOKEN S3_PITR_ACCESS_KEY S3_PITR_SECRET_KEY S3_BUCKET S3_REGION)
    ;;
esac
for name in "${required[@]}"; do
  [[ -n ${!name} ]] || fatal "missing bootstrap input field for ${BOOTSTRAP_MODE}: $name"
done
[[ "$S3_REGION" =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]] || fatal "S3_REGION has invalid syntax"
[[ "$S3_BUCKET" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]] || fatal "S3_BUCKET has invalid syntax"
[[ "$S3_BUCKET" != *..* ]] || fatal "S3_BUCKET must not contain adjacent dots"

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl git
command -v git >/dev/null 2>&1 || fatal "git is unavailable after package preparation"
command -v curl >/dev/null 2>&1 || fatal "curl is unavailable after package preparation"

install -d -o root -g root -m 0755 /opt/gwcut "$RELEASE_ROOT"
install -d -o root -g root -m 0700 "$AUTH_DIR"
printf '%s\n' "$GITHUB_TOKEN" >"$TOKEN_FILE"
chown root:root "$TOKEN_FILE"
chmod 0600 "$TOKEN_FILE"
if [[ "$BOOTSTRAP_MODE" != "pitr-restore-drill" ]]; then
  printf '%s\n' "$GHCR_READ_TOKEN" >"$GHCR_TOKEN_FILE"
  chown root:root "$GHCR_TOKEN_FILE"
  chmod 0600 "$GHCR_TOKEN_FILE"
fi
unset GITHUB_TOKEN GHCR_READ_TOKEN

# The executable askpass helper contains only the root-only token pathname. The token itself is
# never placed in a Git URL, helper source or process argument.
askpass="${AUTH_DIR}/stage0-askpass.$$"
partial=""
cat >"$askpass" <<'EOF'
#!/bin/sh
set -eu
case "${1:-}" in
  *Username*) printf '%s\n' 'x-access-token' ;;
  *Password*) cat /opt/gwcut/updater-github-token ;;
  *) exit 2 ;;
esac
EOF
chmod 0700 "$askpass"
export GIT_ASKPASS="$askpass"
export GIT_TERMINAL_PROMPT=0
cleanup() {
  rm -f "$askpass"
  if [[ -n "$partial" && -e "$partial" ]]; then
    rm -rf -- "$partial"
  fi
}
trap cleanup EXIT

# Stage 0 never resolves mutable main. The operator block pins one reviewed exact infra commit.
target_release="${RELEASE_ROOT}/${target_sha}"
if [[ ! -d "$target_release/.git" ]]; then
  partial="${target_release}.partial.$$"
  [[ ! -e "$partial" ]] || fatal "bootstrap staging path already exists"
  install -d -o root -g root -m 0755 "$partial"
  git -C "$partial" init -q
  git -C "$partial" remote add origin "$REPO_URL"
  git -C "$partial" fetch --depth=1 origin "$target_sha"
  git -C "$partial" checkout --detach -q FETCH_HEAD
  [[ $(git -C "$partial" rev-parse HEAD) == "$target_sha" ]] || fatal "fetched gwcut-infra release SHA mismatch"
  mv "$partial" "$target_release"
  partial=""
fi
[[ $(git -C "$target_release" rev-parse HEAD) == "$target_sha" ]] || fatal "existing release path has a different Git SHA"

if [[ -e /opt/gwcut-infra/current ]]; then
  [[ -d /opt/gwcut-infra/current/.git ]] || fatal "existing GWCut current release is not an immutable Git checkout"
  current_sha="$(git -C /opt/gwcut-infra/current rev-parse HEAD)"
  [[ "$current_sha" == "$target_sha" ]] || fatal "existing GWCut installation is a different SHA; use the authenticated updater"
fi

case "$BOOTSTRAP_MODE" in
  first-install|host)
    [[ -f "$target_release/deploy/fresh-bootstrap.sh" ]] || fatal "pinned gwcut-infra release lacks fresh bootstrap contract"
    ;;
  pitr-restore-drill)
    [[ -f "$target_release/deploy/pitr-restore-drill.sh" ]] || fatal "pinned gwcut-infra release lacks restore drill contract"
    ;;
esac

cleanup
trap - EXIT
unset GIT_ASKPASS GIT_TERMINAL_PROMPT

printf 'gwcut stage-0 pinned private infra release %s for mode %s\n' "$target_sha" "$BOOTSTRAP_MODE"

case "$BOOTSTRAP_MODE" in
  first-install|host)
    marker=/var/lib/gwcut-bootstrap/host-complete.sha
    smoke_flag=0
    if [[ "$BOOTSTRAP_MODE" == "first-install" ]]; then
      marker=/var/lib/gwcut-bootstrap/first-install-complete.sha
      smoke_flag=1
    fi

    if [[ -e /opt/gwcut-infra/current && -f "$marker" ]]; then
      [[ $(cat "$marker") == "$target_sha" ]] || fatal "bootstrap completion marker belongs to a different infra SHA"
      if [[ "$BOOTSTRAP_MODE" == "first-install" ]]; then
        python3 - /var/lib/gwcut-science-smoke/last.json <<'PY'
import json
from pathlib import Path
import sys
path = Path(sys.argv[1])
payload = json.loads(path.read_text(encoding="utf-8"))
if payload.get("status") != "passed" or payload.get("fresh_submission") is not True:
    raise SystemExit("persisted first-install science receipt is not fresh and passing")
PY
      fi
      printf 'gwcut stage-0 already complete for exact release %s\n' "$target_sha"
      exit 0
    fi

    {
      printf 'DASHBOARD_PASSWORD=%s\n' "$DASHBOARD_PASSWORD"
      printf 'S3_WORKER_ACCESS_KEY=%s\n' "$S3_WORKER_ACCESS_KEY"
      printf 'S3_WORKER_SECRET_KEY=%s\n' "$S3_WORKER_SECRET_KEY"
      printf 'S3_READER_ACCESS_KEY=%s\n' "$S3_READER_ACCESS_KEY"
      printf 'S3_READER_SECRET_KEY=%s\n' "$S3_READER_SECRET_KEY"
      printf 'S3_BACKUP_ACCESS_KEY=%s\n' "$S3_BACKUP_ACCESS_KEY"
      printf 'S3_BACKUP_SECRET_KEY=%s\n' "$S3_BACKUP_SECRET_KEY"
      printf 'S3_PITR_ACCESS_KEY=%s\n' "$S3_PITR_ACCESS_KEY"
      printf 'S3_PITR_SECRET_KEY=%s\n' "$S3_PITR_SECRET_KEY"
      printf 'S3_BUCKET=%s\n' "$S3_BUCKET"
      printf 'S3_REGION=%s\n' "$S3_REGION"
    } | GWCUT_INFRA_GIT_SHA="$target_sha" \
        GWCUT_REQUIRE_FRESH_SCIENCE_SMOKE="$smoke_flag" \
        /bin/bash "$target_release/deploy/fresh-bootstrap.sh"

    [[ -f "$marker" && $(cat "$marker") == "$target_sha" ]] || fatal "private bootstrap did not publish the exact completion marker"
    if [[ "$BOOTSTRAP_MODE" == "first-install" ]]; then
      python3 - /var/lib/gwcut-science-smoke/last.json <<'PY'
import json
from pathlib import Path
import sys
path = Path(sys.argv[1])
payload = json.loads(path.read_text(encoding="utf-8"))
if payload.get("status") != "passed":
    raise SystemExit("science smoke receipt status is not passed")
if payload.get("fresh_submission") is not True:
    raise SystemExit("science smoke receipt is not a fresh submission")
PY
    fi
    ;;
  pitr-restore-drill)
    GWCUT_INFRA_GIT_SHA="$target_sha" \
    GWCUT_PITR_SOURCE_GENERATION="$GWCUT_PITR_SOURCE_GENERATION" \
    GWCUT_DRILL_SOURCE_URL="$GWCUT_DRILL_SOURCE_URL" \
    S3_ACCESS_KEY="$S3_PITR_ACCESS_KEY" \
    S3_SECRET_KEY="$S3_PITR_SECRET_KEY" \
    S3_BUCKET="$S3_BUCKET" \
    S3_REGION="$S3_REGION" \
      /bin/bash "$target_release/deploy/pitr-restore-drill.sh"
    ;;
esac

unset \
  DASHBOARD_PASSWORD \
  S3_WORKER_ACCESS_KEY S3_WORKER_SECRET_KEY \
  S3_READER_ACCESS_KEY S3_READER_SECRET_KEY \
  S3_BACKUP_ACCESS_KEY S3_BACKUP_SECRET_KEY \
  S3_PITR_ACCESS_KEY S3_PITR_SECRET_KEY \
  S3_BUCKET S3_REGION

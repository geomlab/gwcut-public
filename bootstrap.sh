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

printf 'gwcut stage-0 Compose bootstrap complete for %s\n' "$INFRA_SHA"GITHUB_TOKEN=""
GHCR_READ_TOKEN=""
DASHBOARD_PASSWORD=""
S3_ACCESS_KEY=""
S3_SECRET_KEY=""
S3_BUCKET=""
S3_REGION=""
declare -A seen=()
while IFS= read -r line || [[ -n "$line" ]]; do
  [[ -z "$line" || "$line" == \#* ]] && continue
  [[ "$line" == *=* ]] || fatal "bootstrap input must contain NAME=value assignments only"
  name=${line%%=*}
  value=${line#*=}
  case "$name" in
    GITHUB_TOKEN|GHCR_READ_TOKEN|DASHBOARD_PASSWORD|S3_ACCESS_KEY|S3_SECRET_KEY|S3_BUCKET|S3_REGION) ;;
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
  auto|first-install|host)
    required=(GITHUB_TOKEN GHCR_READ_TOKEN DASHBOARD_PASSWORD S3_ACCESS_KEY S3_SECRET_KEY S3_BUCKET S3_REGION)
    ;;
  pitr-restore-drill)
    required=(GITHUB_TOKEN S3_ACCESS_KEY S3_SECRET_KEY S3_BUCKET S3_REGION)
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

# Stage 0 never resolves mutable main. The operator pins one reviewed exact infra commit.
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
  auto|first-install|host)
    [[ -f "$target_release/deploy/fresh-bootstrap.sh" ]] || fatal "pinned gwcut-infra release lacks automatic host bootstrap contract"
    ;;
  pitr-restore-drill)
    [[ -f "$target_release/deploy/pitr-restore-drill.sh" ]] || fatal "pinned gwcut-infra release lacks restore drill contract"
    ;;
esac

cleanup
trap - EXIT
unset GIT_ASKPASS GIT_TERMINAL_PROMPT

printf 'gwcut stage-0 pinned private infra release %s for mode %s\n' "$target_sha" "$BOOTSTRAP_MODE"

verify_automatic_completion() {
  local decision=/var/lib/gwcut-bootstrap/database-decision.json
  local science=/var/lib/gwcut-science-smoke/last.json
  python3 - "$decision" "$science" <<'PY'
import json
from pathlib import Path
import sys

decision_path = Path(sys.argv[1])
science_path = Path(sys.argv[2])
try:
    payload = json.loads(decision_path.read_text(encoding="utf-8"))
except (OSError, json.JSONDecodeError) as exc:
    raise SystemExit(f"database decision receipt is unreadable: {exc}")
if payload.get("schema_version") != 1:
    raise SystemExit("database decision receipt has unsupported schema")
state = payload.get("database_state")
if state not in {"fresh-empty", "restored", "existing"}:
    raise SystemExit(f"database decision receipt is incomplete or invalid: {state!r}")
if state == "fresh-empty":
    try:
        science = json.loads(science_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise SystemExit(f"fresh-install science receipt is unreadable: {exc}")
    if science.get("status") != "passed":
        raise SystemExit("fresh-install science receipt status is not passed")
    if science.get("fresh_submission") is not True:
        raise SystemExit("fresh-install science receipt is not a fresh submission")
print(state)
PY
}

case "$BOOTSTRAP_MODE" in
  auto|first-install|host)
    marker=/var/lib/gwcut-bootstrap/host-complete.sha
    if [[ -e /opt/gwcut-infra/current && -f "$marker" ]]; then
      [[ $(cat "$marker") == "$target_sha" ]] || fatal "bootstrap completion marker belongs to a different infra SHA"
      state="$(verify_automatic_completion)" || fatal "persisted automatic bootstrap receipts do not verify"
      printf 'gwcut stage-0 already complete for exact release %s (%s)\n' "$target_sha" "$state"
      exit 0
    fi

    {
      printf 'DASHBOARD_PASSWORD=%s\n' "$DASHBOARD_PASSWORD"
      printf 'S3_ACCESS_KEY=%s\n' "$S3_ACCESS_KEY"
      printf 'S3_SECRET_KEY=%s\n' "$S3_SECRET_KEY"
      printf 'S3_BUCKET=%s\n' "$S3_BUCKET"
      printf 'S3_REGION=%s\n' "$S3_REGION"
    } | GWCUT_INFRA_GIT_SHA="$target_sha" \
        /bin/bash "$target_release/deploy/fresh-bootstrap.sh"

    [[ -f "$marker" && $(cat "$marker") == "$target_sha" ]] || fatal "private bootstrap did not publish the exact completion marker"
    state="$(verify_automatic_completion)" || fatal "automatic bootstrap receipts do not verify"
    printf 'gwcut stage-0 automatic host bootstrap complete (%s)\n' "$state"
    ;;
  pitr-restore-drill)
    GWCUT_INFRA_GIT_SHA="$target_sha" \
    GWCUT_PITR_SOURCE_GENERATION="$GWCUT_PITR_SOURCE_GENERATION" \
    GWCUT_DRILL_SOURCE_URL="$GWCUT_DRILL_SOURCE_URL" \
    S3_ACCESS_KEY="$S3_ACCESS_KEY" \
    S3_SECRET_KEY="$S3_SECRET_KEY" \
    S3_BUCKET="$S3_BUCKET" \
    S3_REGION="$S3_REGION" \
      /bin/bash "$target_release/deploy/pitr-restore-drill.sh"
    ;;
esac

unset DASHBOARD_PASSWORD S3_ACCESS_KEY S3_SECRET_KEY S3_BUCKET S3_REGION

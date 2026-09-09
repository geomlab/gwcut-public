#!/usr/bin/env bash
set -euo pipefail
set +x
umask 077

readonly REPO_URL="https://github.com/geomlab/gwcut-infra.git"
readonly TOKEN_FILE="/opt/gwcut/updater-github-token"
readonly RELEASE_ROOT="/opt/gwcut-infra/releases"

fatal() {
  printf 'gwcut stage-0 bootstrap failed: %s\n' "$*" >&2
  exit 2
}

[[ ${EUID:-$(id -u)} -eq 0 ]] || fatal "must run as root"
[[ ! -e /opt/gwcut-infra/current ]] || fatal "existing GWCut installation detected; use the authenticated updater instead"

[[ -r /etc/os-release ]] || fatal "cannot identify operating system"
# shellcheck disable=SC1091
. /etc/os-release
[[ ${ID:-} == "ubuntu" && ${VERSION_ID:-} == "24.04" ]] || fatal "fresh bootstrap requires Ubuntu 24.04"

GITHUB_TOKEN=""
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
    GITHUB_TOKEN|S3_ACCESS_KEY|S3_SECRET_KEY|S3_BUCKET|S3_REGION) ;;
    *) fatal "unknown bootstrap input field: $name" ;;
  esac
  [[ -z ${seen[$name]+x} ]] || fatal "duplicate bootstrap input field: $name"
  [[ -n "$value" ]] || fatal "bootstrap input field is empty: $name"
  [[ ${#value} -le 4096 ]] || fatal "bootstrap input field is too long: $name"
  seen[$name]=1
  printf -v "$name" '%s' "$value"
done

for name in GITHUB_TOKEN S3_ACCESS_KEY S3_SECRET_KEY S3_BUCKET S3_REGION; do
  [[ -n ${!name} ]] || fatal "missing bootstrap input field: $name"
done

export DEBIAN_FRONTEND=noninteractive
if ! command -v git >/dev/null 2>&1; then
  apt-get update
  apt-get install -y --no-install-recommends ca-certificates git
fi
command -v git >/dev/null 2>&1 || fatal "git is unavailable after package preparation"

install -d -o root -g root -m 0755 /opt/gwcut "$RELEASE_ROOT"
printf '%s\n' "$GITHUB_TOKEN" >"$TOKEN_FILE"
chown root:root "$TOKEN_FILE"
chmod 0600 "$TOKEN_FILE"
unset GITHUB_TOKEN

askpass="/run/gwcut-stage0-askpass.$$"
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
}
trap cleanup EXIT

remote_line="$(git ls-remote "$REPO_URL" refs/heads/main)" || fatal "cannot resolve private gwcut-infra main"
[[ "$remote_line" =~ ^([0-9a-f]{40})[[:space:]]+refs/heads/main$ ]] || fatal "private gwcut-infra main did not resolve to exactly one commit"
target_sha="${BASH_REMATCH[1]}"
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
fi
[[ $(git -C "$target_release" rev-parse HEAD) == "$target_sha" ]] || fatal "existing release path has a different Git SHA"
[[ -f "$target_release/deploy/fresh-bootstrap.sh" ]] || fatal "resolved gwcut-infra release lacks fresh bootstrap contract"

cleanup
trap - EXIT
unset GIT_ASKPASS GIT_TERMINAL_PROMPT remote_line

printf 'gwcut stage-0 resolved private infra main to %s\n' "$target_sha"
{
  printf 'S3_ACCESS_KEY=%s\n' "$S3_ACCESS_KEY"
  printf 'S3_SECRET_KEY=%s\n' "$S3_SECRET_KEY"
  printf 'S3_BUCKET=%s\n' "$S3_BUCKET"
  printf 'S3_REGION=%s\n' "$S3_REGION"
} | env GWCUT_INFRA_GIT_SHA="$target_sha" \
  /bin/bash "$target_release/deploy/fresh-bootstrap.sh"

# GWCut public Stage-0

This public repository contains only the non-secret Stage-0 entry point for bootstrapping pristine Ubuntu 24.04 Hetzner Cloud hosts. The privileged control plane, worker image allowlist, database/recovery logic and science orchestration remain in private `geomlab/gwcut-infra`; credentials and private deployment configuration must never be committed here.

## Trust model

Production-style operator blocks must pin **both** layers:

1. fetch `bootstrap.sh` from a reviewed immutable `geomlab/gwcut-public` commit, not mutable `main`;
2. set `GWCUT_INFRA_GIT_SHA` to one reviewed 40-character `geomlab/gwcut-infra` commit.

Stage 0 does not resolve `refs/heads/main`. It authenticates private Git with a temporary root-only `GIT_ASKPASS` helper whose source contains only the token-file pathname, fetches only the requested infra commit, verifies the checkout SHA, and delegates to that immutable release.

## SSH-safe and history-safe operator boundary

The outer paste must never enable `set -e`, call `exit`, or `exec` the bootstrap in the interactive SSH login shell. A bootstrap failure must terminate only a child shell so the operator remains connected and can read the failure diagnostics.

Because a one-paste body may contain secrets, the interactive Bash history must also be disabled **before** Bash reads the secret-bearing heredoc. The previous history state is restored after the child returns. The history state is queried directly with `shopt -qo history`; the `$-` `H` flag is intentionally not used because it represents `histexpand`, not the independent command-history option. Root sessions enter `/bin/bash` directly; non-root sessions enter a root child through `sudo`. The caller shell does not change its error mode, tracing mode, umask, or process identity.

<!-- ssh-safe-one-paste:start -->
```bash
if shopt -qo history; then
  GWCUT_HISTORY_WAS_ON=1
  set +o history
else
  GWCUT_HISTORY_WAS_ON=0
fi

(
  if [ "$(id -u)" -eq 0 ]; then
    exec /bin/bash
  fi
  exec sudo -H /bin/bash
) <<'GWCUT_OPERATOR'
set -euo pipefail
set +x
umask 077

# The complete reviewed, immutable-pin automatic-host operator body belongs here.
# Any fatal `exit` in this heredoc terminates only this child shell.

GWCUT_OPERATOR
GWCUT_CHILD_RC=$?

if [ "$GWCUT_HISTORY_WAS_ON" = 1 ]; then
  set -o history
fi
unset GWCUT_HISTORY_WAS_ON

if [ "$GWCUT_CHILD_RC" -eq 0 ]; then
  printf 'GWCut bootstrap child completed successfully.\n'
else
  printf 'GWCut bootstrap child failed with status %s; SSH session remains open.\n' "$GWCUT_CHILD_RC" >&2
fi
unset GWCUT_CHILD_RC
```
<!-- ssh-safe-one-paste:end -->

A nonzero child exit status is intentionally reported without closing the SSH session. The final one-paste production block must preserve this process/history boundary before performing package installation, temporary-file creation, secret handling, loader download, or bootstrap invocation.

The block is intended for the default Bash login shell on a fresh Ubuntu 24.04 host. Do not paste the secret-bearing operator block into a different interactive shell without an equivalent, reviewed history-suppression contract.

## Canonical six-field bootstrap bundle

The normal bootstrap has one durable external credential/configuration file. Its stdin contains exactly:

```text
GITHUB_TOKEN=...
GHCR_READ_TOKEN=...
S3_ACCESS_KEY=...
S3_SECRET_KEY=...
S3_BUCKET=...
S3_REGION=fsn1
```

The same file is used for a completely empty Object Storage bucket and for replacement/recovery from an existing committed GWCut backup. The operator does not select fresh install versus recovery. The private host bootstrap makes that decision fail-closed from the remote backup state and persists a root-only database-decision receipt before starting the control plane.

The single retained Object Storage credential is expanded into separate root-owned local worker, artifact-reader, logical-backup and PITR secret files. Those files preserve process-level separation, but this canonical bootstrap does not currently require provider-side per-role S3 identities. More granular provider credentials may be added later as optional hardening without changing the recoverability contract.

The repository and GHCR credentials are persisted in separate root-only files. Database credentials and internal API tokens are generated locally and may change on rebuild because they do not cross the recovery boundary.

The dashboard password is **not** an additional retained secret. The private bootstrap deterministically derives a 64-hex-character control password from the stable Object Storage credential plus bucket and region under the fixed domain `gwcut-dashboard-password-v1`. The S3 secret is fed to the local hash process over stdin/pipes rather than argv or logs. Therefore the same S3 identity, bucket and region reproduce the same dashboard password after a rebuild; intentional rotation of that storage identity also rotates the dashboard password.

## Automatic fresh-or-recovery completion contract

The default mode is `auto`; the operator normally does not set `GWCUT_BOOTSTRAP_MODE` at all. Historical `first-install` and `host` values are accepted as compatibility aliases for the same automatic host path. `GWCUT_BOOTSTRAP_MODE=pitr-restore-drill` remains the explicit disposable physical restore/WAL-replay path.

The private bootstrap obtains the public IPv4 from Hetzner metadata, derives the Object Storage endpoint and explicit host budgets, installs the exact release, preloads only approved digest-pinned images, and asks the host bootstrap to decide the database state:

- `fresh-empty`: no committed remote logical backup exists; initialize a new GWCut database;
- `restored`: a committed remote logical backup was found, verified and restored;
- `existing`: a retry or already-populated local host is being resumed.

Credential, transport, manifest, hash or restore failures are never reclassified as an empty installation. An interrupted database decision that may already have mutated PostgreSQL is fail-closed rather than guessed on retry.

After the database decision, the bootstrap creates a generation-scoped pgBackRest repository, requires stanza/check/full-backup recovery gates, normalizes only a shutdown-owned queue pause, and re-establishes the public HTTPS control plane.

Only `fresh-empty` requires the deterministic science smoke without `--allow-existing`; completion then requires `status: "passed"` and `fresh_submission: true`. A restored host does not need to fabricate a second first-install science proof. Stage 0 verifies the durable database-decision receipt and, when applicable, the fresh science receipt before returning success.

The canonical completion marker for both paths is `/var/lib/gwcut-bootstrap/host-complete.sha`. A partial bootstrap may be repeated only for the **same pinned infra SHA**. If `/opt/gwcut-infra/current` points at another release, Stage 0 fails closed and the authenticated updater is the supported transition.

Do not treat successful automatic bootstrap alone as complete production-lifecycle proof. The private lifecycle still requires the separate off-host restore, safe-shutdown, `safe_to_destroy`, provider deletion/rebuild and replacement-recovery evidence.

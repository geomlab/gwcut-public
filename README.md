# GWCut public Stage-0

This public repository contains only the non-secret Stage-0 entry point for bootstrapping pristine Ubuntu 24.04 Hetzner Cloud hosts. The privileged control plane, worker image allowlist, database/recovery logic and science orchestration remain in private `geomlab/gwcut-infra`; credentials and private deployment configuration must never be committed here.

## Canonical operator runbook

The permanent human/operator procedure and behavioral contract for agents and maintainers is [`BOOTSTRAP_RUNBOOK.md`](BOOTSTRAP_RUNBOOK.md). For the normal host path, that document is canonical: one durable credential file, one stable public launcher command, automatic fresh-vs-recovery detection, and no manual release SHA or restore mode.

## Trust model

Production-style operator blocks must pin **both** layers:

1. fetch `bootstrap.sh` from a reviewed immutable `geomlab/gwcut-public` commit, not mutable `main`;
2. set `GWCUT_INFRA_GIT_SHA` to one reviewed 40-character `geomlab/gwcut-infra` commit.

Stage 0 does not resolve `refs/heads/main`. It authenticates private Git with a temporary root-only `GIT_ASKPASS` helper whose source contains only the token-file pathname, fetches only the requested infra commit, verifies the checkout SHA, and delegates to that immutable release.

The normal operator does not provide these pins manually. `stable-bootstrap.sh` is the stable public release-channel entry point and carries reviewed immutable public/private pins internally; see the canonical runbook above.

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

## Canonical bootstrap bundle

The normal bootstrap has one durable external credential/configuration file. It contains exactly these names:

```text
GITHUB_TOKEN
GHCR_READ_TOKEN
DASHBOARD_PASSWORD

S3_WORKER_ACCESS_KEY
S3_WORKER_SECRET_KEY
S3_READER_ACCESS_KEY
S3_READER_SECRET_KEY
S3_BACKUP_ACCESS_KEY
S3_BACKUP_SECRET_KEY
S3_PITR_ACCESS_KEY
S3_PITR_SECRET_KEY

S3_BUCKET
S3_REGION
```

The four Object Storage access-key identities are mandatory and pairwise distinct. Worker, artifact reader, logical backup and PITR each receive only their own root-owned local secret file. The bootstrap never derives new provider credentials and never silently collapses the roles onto one shared Object Storage identity.

The same complete file is used for a fresh GWCut database and for replacement/recovery from an existing committed backup. The operator does not select fresh install versus recovery. The private host bootstrap makes that decision fail-closed from the remote backup state and persists a root-only database-decision receipt before starting the control plane.

The configured Object Storage bucket and these four role credentials are treated as long-lived production state. A compute-host rebuild is routine and reuses the retained bundle unchanged. Recreating Object Storage itself from nothing is a separate, rare provisioning task: create the bucket and role credentials first, then use the same normal bootstrap. That provider-side bootstrap is deliberately outside the compute-host recovery lifecycle.

The repository and GHCR credentials are persisted in separate root-only files. Database credentials and internal API tokens are generated locally and may change on rebuild because they do not cross the recovery boundary.

The dashboard password is retained explicitly in the same bootstrap file and used verbatim as the dashboard control password. A rebuild with the same bundle therefore preserves the exact operator-selected login.

## Automatic fresh-or-recovery completion contract

The default mode is `auto`; the operator normally does not set `GWCUT_BOOTSTRAP_MODE` at all. Historical `first-install` and `host` values are accepted as compatibility aliases for the same automatic host path. `GWCUT_BOOTSTRAP_MODE=pitr-restore-drill` remains the explicit disposable physical restore/WAL-replay path and uses the retained PITR Object Storage identity.

The private bootstrap obtains the public IPv4 from Hetzner metadata, derives the Object Storage endpoint and explicit host budgets, installs the exact release, preloads only approved digest-pinned images, and asks the host bootstrap to decide the database state:

- `fresh-empty`: no committed remote logical backup exists; initialize a new GWCut database;
- `restored`: a committed remote logical backup was found, verified and restored;
- `existing`: a retry or already-populated local host is being resumed.

Credential, transport, manifest, hash or restore failures are never reclassified as an empty installation. An interrupted database decision that may already have mutated PostgreSQL is fail-closed rather than guessed on retry.

After the database decision, the bootstrap creates a generation-scoped pgBackRest repository, requires stanza/check/full-backup recovery gates, normalizes only a shutdown-owned queue pause, and re-establishes the public HTTPS control plane.

Only `fresh-empty` requires the deterministic science smoke without `--allow-existing`; completion then requires `status: "passed"` and `fresh_submission: true`. A restored host does not need to fabricate a second first-install science proof. Stage 0 verifies the durable database-decision receipt and, when applicable, the fresh science receipt before returning success.

The canonical completion marker for both paths is `/var/lib/gwcut-bootstrap/host-complete.sha`. A partial bootstrap may be repeated only for the **same pinned infra SHA**. If `/opt/gwcut-infra/current` points at another release, Stage 0 fails closed and the authenticated updater is the supported transition.

Do not treat successful automatic bootstrap alone as complete production-lifecycle proof. The private lifecycle still requires the separate off-host restore, safe-shutdown, `safe_to_destroy`, provider deletion/rebuild and replacement-recovery evidence.

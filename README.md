# GWCut public Stage-0

This public repository contains only the non-secret Stage-0 entry point for bootstrapping pristine Ubuntu 24.04 Hetzner Cloud hosts. The privileged control plane, worker image allowlist, database/recovery logic and science orchestration remain in private `geomlab/gwcut-infra`; credentials and private deployment configuration must never be committed here.

## Trust model

Production-style operator blocks must pin **both** layers:

1. fetch `bootstrap.sh` from a reviewed immutable `geomlab/gwcut-public` commit, not mutable `main`;
2. set `GWCUT_INFRA_GIT_SHA` to one reviewed 40-character `geomlab/gwcut-infra` commit.

Stage 0 does not resolve `refs/heads/main`. It authenticates private Git with a temporary root-only `GIT_ASKPASS` helper whose source contains only the token-file pathname, fetches only the requested infra commit, verifies the checkout SHA, and delegates to that immutable release.

## SSH-safe and history-safe operator boundary

The outer paste must never enable `set -e`, call `exit`, or `exec` the bootstrap in the interactive SSH login shell. A bootstrap failure must terminate only a child shell so the operator remains connected and can read the failure diagnostics.

Because the one-paste body contains secrets, the interactive Bash history must also be disabled **before** Bash reads the secret-bearing heredoc. The previous history state is restored after the child returns. Root sessions enter `/bin/bash` directly; non-root sessions enter a root child through `sudo`. The caller shell does not change its error mode, tracing mode, umask, or process identity.

<!-- ssh-safe-one-paste:start -->
```bash
case $- in
  *H*) GWCUT_HISTORY_WAS_ON=1; set +o history ;;
  *)   GWCUT_HISTORY_WAS_ON=0 ;;
esac

(
  if [ "$(id -u)" -eq 0 ]; then
    exec /bin/bash
  fi
  exec sudo -H /bin/bash
) <<'GWCUT_OPERATOR'
set -euo pipefail
set +x
umask 077

# The complete reviewed, immutable-pin first-install operator body belongs here.
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

## First-install secret bundle

The default mode is `first-install`. Its stdin contains exactly the external secrets/configuration needed by the convenience path:

```text
GITHUB_TOKEN=...
GHCR_READ_TOKEN=...
DASHBOARD_PASSWORD=...
S3_WORKER_ACCESS_KEY=...
S3_WORKER_SECRET_KEY=...
S3_READER_ACCESS_KEY=...
S3_READER_SECRET_KEY=...
S3_BACKUP_ACCESS_KEY=...
S3_BACKUP_SECRET_KEY=...
S3_PITR_ACCESS_KEY=...
S3_PITR_SECRET_KEY=...
S3_BUCKET=...
S3_REGION=fsn1
```

The four Object Storage identities are intentionally distinct. Do not replace them with one broad convenience key. Configure bucket policy/permissions so the artifact reader is read-only and worker, logical-backup and physical-PITR authority are independently bounded to their required operations/prefixes.

The repository and GHCR credentials are persisted in separate root-only files. The remaining secrets are passed to the private bootstrap over stdin rather than Git URLs or command arguments. Database and internal API tokens are generated locally. The supplied dashboard password becomes the Basic-Auth control password so no second SSH session is required merely to discover it.

## First-install completion contract

The private bootstrap obtains the public IPv4 from Hetzner metadata, derives the location Object Storage endpoint and explicit host budgets, installs the exact release, preloads only approved digest-pinned images, performs the logical first-install/restore decision, creates a generation-scoped pgBackRest repository, and requires stanza/check/full-backup recovery gates.

In `first-install` mode Stage 0 additionally requires the existing `gwcut-science-smoke.service` without `--allow-existing`. Completion requires the durable receipt to contain `status: "passed"` and `fresh_submission: true`. The public loader verifies the private root-only completion marker and the receipt before returning success.

A partial bootstrap may be re-pasted only for the **same pinned infra SHA**. If `/opt/gwcut-infra/current` points at another release, Stage 0 fails closed and the authenticated updater is the only supported transition. A failed or ambiguous science execution is never reclassified as fresh evidence.

`GWCUT_BOOTSTRAP_MODE=host` retains replacement/recovery behavior without demanding a fresh deterministic science fixture from restored state. `GWCUT_BOOTSTRAP_MODE=pitr-restore-drill` remains the disposable physical restore/WAL-replay path and uses the dedicated PITR Object Storage identity.

Do not treat successful first-install alone as complete production-lifecycle proof. The private lifecycle still requires the separate off-host restore, safe-shutdown, `safe_to_destroy`, provider deletion and replacement-recovery evidence.

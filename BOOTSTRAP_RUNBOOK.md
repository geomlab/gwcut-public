# GWCut host bootstrap runbook and operator contract

This document is the canonical human/operator runbook for bootstrapping a fresh Ubuntu 24.04 Hetzner Cloud host into GWCut. It is also a behavioral contract for agents and maintainers: the normal host-bootstrap UX must remain this small and invariant unless this document is deliberately revised.

## Scope

This runbook covers the normal compute-host path only:

- first GWCut installation onto a fresh host when the configured Object Storage bucket contains no committed GWCut backup;
- replacement or rebuild of a compute host when Object Storage already contains committed GWCut recovery state;
- later migration to another fresh Ubuntu 24.04 compute host.

The operator does **not** choose between fresh install and recovery. `stable-bootstrap.sh` and the private bootstrap determine that automatically and fail closed.

Recreating Object Storage itself from nothing is deliberately outside this runbook. The configured bucket and its one retained S3 credential pair are long-lived production state. If Object Storage must ever be recreated, provision the bucket and one S3 credential pair first; after that, this exact host runbook applies again unchanged.

## Durable bootstrap credential file

The operator keeps one durable credential file outside Git and transfers/copies that same file to each replacement host as `/root/gwcut-bootstrap.env`.

The file contains exactly these seven assignments, with real values supplied by the operator:

```text
GITHUB_TOKEN=
GHCR_READ_TOKEN=
DASHBOARD_PASSWORD=
S3_ACCESS_KEY=
S3_SECRET_KEY=
S3_BUCKET=
S3_REGION=
```

There is exactly one retained provider-side S3 identity in the canonical host-bootstrap contract. Worker, artifact reader, logical backup and PITR receive separate root-owned local secret files, but those local files intentionally contain the same retained S3 access/secret pair. Provider-side role-key separation is not part of the normal contract.

`DASHBOARD_PASSWORD` is explicit and retained verbatim so the operator-selected login survives rebuilds unchanged. The credential file must never be committed to Git.

Values are line-oriented. Current deployment serialization requires single-line values and rejects literal single quotes in the dashboard/S3 secrets. The parser accepts the final assignment whether or not the file ends in a trailing newline.

## Step 1 — create or place the credential file

On a fresh host, the preferred manual entry/edit command is:

```bash
umask 077 && nano /root/gwcut-bootstrap.env && chmod 600 /root/gwcut-bootstrap.env
```

Paste or enter the durable credential bundle, save the file, and exit `nano`.

If the already-retained file is copied to the server by another secure mechanism instead of edited manually, it must still end up at `/root/gwcut-bootstrap.env` with mode `0600` before the bootstrap is started.

Do not `source` this file. Do not paste the secret values into shell command arguments. Do not enable shell tracing.

## Step 2 — download and run the stable bootstrap

Run exactly:

```bash
curl -fsSL \
  https://raw.githubusercontent.com/geomlab/gwcut-public/main/stable-bootstrap.sh \
  -o /root/bootstrap.sh \
&& bash /root/bootstrap.sh </root/gwcut-bootstrap.env
```

This is the permanent normal operator command. It is intentionally the same for an empty GWCut backup state and for recovery from an existing committed backup.

Do not add `GWCUT_BOOTSTRAP_MODE=first-install` or `GWCUT_BOOTSTRAP_MODE=host` for the normal path. Do not supply release SHAs manually. The stable public launcher carries reviewed immutable internal pins and may be updated through the repository release process without changing this operator command.

The launcher is downloaded to a file before execution instead of using `curl | bash` because the bootstrap consumes the credential file on standard input. The `&&` is intentional: a failed download must never fall through to executing a stale or incomplete new download attempt.

## Required automatic behavior

The bootstrap must determine the host state itself:

- If no committed GWCut logical backup exists remotely, classify the new host as `fresh-empty`, initialize GWCut, run the required fresh science smoke, and require a receipt with `status == "passed"` and `fresh_submission == true` before success.
- If a valid committed logical backup exists, classify the host as `restored`, verify and restore it, establish the new local PostgreSQL/PITR generation, pass the recovery gates, then start the control plane.
- If a retry encounters an already-populated local database from the same exact release, classify/resume as `existing` only under the persisted fail-closed decision/receipt rules.
- Authentication, Object Storage transport, manifest, integrity, restore, PITR, HTTPS, or receipt failures are fatal. They must never be silently reinterpreted as an empty/fresh installation.

The same complete seven-field credential file is required in all normal states. Fresh install and recovery must not have different credential contracts.

## Stable-launcher contract

`https://raw.githubusercontent.com/geomlab/gwcut-public/main/stable-bootstrap.sh` is the stable operator entry point.

The human-facing command above must remain invariant across ordinary GWCut software releases. Internally, the launcher pins reviewed immutable `gwcut-public` and `gwcut-infra` commits. Promoting a new release means changing those internal pins through review and CI, not changing the operator's recovery procedure.

Agents and maintainers must therefore preserve these properties:

- no manual release SHA is required from the operator;
- no manual fresh-vs-recovery mode is required from the operator;
- no private-repository Git operation is required from the operator;
- no separate restore command is required from the operator;
- exactly one retained S3 access/secret pair is required for the normal host path;
- the one retained credential file remains the input contract;
- the bootstrap remains fail closed;
- credentials remain outside Git and out of normal shell command arguments;
- Object Storage recreation remains an explicit rare provisioning task outside normal compute-host recovery.

## Operational minimalism

The intended normal human procedure on a pristine host is therefore exactly two actions:

1. place/edit `/root/gwcut-bootstrap.env` using the protected `umask 077`/`nano` command above;
2. run the stable download-and-bootstrap command above.

Additional manual recovery steps or additional provider-side role credentials are a sign that the normal bootstrap contract has drifted and should not be incorporated casually into the canonical runbook.

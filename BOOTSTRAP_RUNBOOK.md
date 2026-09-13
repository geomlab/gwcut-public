# GWCut Compose host bootstrap runbook and operator contract

This document is the canonical human/operator runbook for rebuilding a fresh Ubuntu 24.04 GWCut host. The operator-facing UX deliberately stays tiny and phone-friendly: place one retained credential file, then run one stable public bootstrap command.

## Target runtime

The rebuilt host is intentionally simple:

```text
Ubuntu 24.04
└── Docker Engine + Compose
    ├── postgres
    ├── api
    ├── scheduler
    └── caddy
```

Science jobs are short-lived worker containers started by the scheduler. There are no GWCut host Python virtualenvs, GWCut systemd service graph, custom Caddy binary, runtime/planner/artifact brokers, updater daemon, or production source checkout.

PostgreSQL starts empty for the first clean Compose rebuild. Current experimental database/object-storage contents are not migrated. Object Storage may be emptied/reinitialized before the rebuild when that clean-slate procedure is deliberately chosen.

## Durable credential file

The operator keeps the same seven-field credential bundle outside Git and places it on each replacement host as `/root/gwcut-bootstrap.env`:

```text
GITHUB_TOKEN=
GHCR_READ_TOKEN=
DASHBOARD_PASSWORD=
S3_ACCESS_KEY=
S3_SECRET_KEY=
S3_BUCKET=
S3_REGION=
```

This seven-field shape remains the compatibility contract so a retained mobile-friendly bootstrap note does not need to change. Secrets never belong in Git, URLs, or shell arguments.

`GITHUB_TOKEN` is used only to retrieve the exact reviewed private deployment artifacts selected by the public stable launcher. It is not passed to GWCut containers. `GHCR_READ_TOKEN` remains accepted for compatibility; current promoted GWCut container packages are publicly readable, so the Compose runtime does not require it. The bootstrap must not persist an unnecessary GHCR token when anonymous pulls succeed.

`DASHBOARD_PASSWORD` becomes the GWCut control/dashboard credential. PostgreSQL and internal worker/API credentials are generated locally by the bootstrap with cryptographically secure randomness; the operator does not have to type them.

The Hetzner Object Storage origin is derived from `S3_REGION` as `https://<region>.your-objectstorage.com`; the bucket and retained S3 access/secret pair come from this file.

## Step 1 — place the credential file

On the fresh host run:

```bash
umask 077 && nano /root/gwcut-bootstrap.env && chmod 600 /root/gwcut-bootstrap.env
```

Paste the seven assignments, save, and exit. Do not `source` the file and do not paste secret values into command arguments.

## Step 2 — run the stable public bootstrap

Run exactly:

```bash
curl -fsSL \
  https://raw.githubusercontent.com/geomlab/gwcut-public/main/stable-bootstrap.sh \
  -o /root/bootstrap.sh \
&& bash /root/bootstrap.sh </root/gwcut-bootstrap.env
```

This command is the permanent normal operator entry point. The operator does not provide release SHAs, image tags, Compose paths, fresh-vs-recovery modes, or individual installation commands.

The stable launcher pins reviewed immutable public/infra revisions. The selected private infra revision supplies the canonical `compose.production.yml` and `deploy/compose/Caddyfile`; the bootstrap does not clone a production source tree merely to run the application.

## Required automatic behavior

The bootstrap must, without additional operator decisions:

1. verify Ubuntu 24.04 and root execution;
2. parse exactly the retained seven-field input and reject unknown/duplicate/missing values;
3. install Docker Engine and the Docker Compose plugin;
4. create `/opt/gwcut`, `/var/lib/gwcut/work`, and `/var/lib/gwcut/planner` with appropriate ownership/modes;
5. retrieve the exact pinned Compose manifest and Caddyfile selected by the stable release;
6. generate a root-only `/opt/gwcut/.env`, including fresh PostgreSQL/internal tokens, the retained dashboard/S3 values, the public host address, and immutable infra/science image digests;
7. pull the selected images and run `docker compose up -d`;
8. require exactly the four long-lived services `postgres`, `api`, `scheduler`, and `caddy`, with PostgreSQL/API healthy;
9. require public HTTPS `/health` to return the GWCut healthy response and `/app/` to require Basic authentication;
10. prepare Remote Desktop Commander maintenance access as a separate maintenance facility, never as a dependency of GWCut runtime success.

All four long-lived containers use the Compose restart policy. PostgreSQL remains the source of truth for Campaigns, Jobs, and Attempts; scheduler restart/reconciliation handles interrupted science workers.

## Maintenance access

Remote Desktop Commander is maintenance tooling, not a fifth GWCut service. The bootstrap installs the required Node/npm tooling and the reviewed Desktop Commander package/launcher needed for remote pairing.

Remote Desktop Commander currently authenticates a fresh device through an interactive OAuth device-code flow. Therefore the bootstrap may display the pairing URL/code and wait for the operator to approve it on the phone, but no Desktop Commander credential is added to `gwcut-bootstrap.env` and no undocumented static token is invented.

GWCut readiness must not depend on the hosted maintenance relay. If Remote Desktop Commander pairing or later connectivity fails, the four-container GWCut runtime remains valid and SSH/provider console remains the recovery path. The runbook must state clearly whether a current upstream Desktop Commander release can survive a service/host restart without re-pairing before claiming unattended maintenance persistence.

## Clean-host acceptance

A rebuild is accepted only after all of the following are demonstrated on the rebuilt host:

- `docker compose ps` shows exactly four long-lived GWCut services;
- HTTPS `/health` succeeds and `/app/` is authentication-protected;
- a small fresh Campaign completes end-to-end through a temporary immutable science-worker container;
- deliberately interrupting a running worker records the interrupted Attempt and creates a fresh Attempt automatically;
- a full host reboot returns the four Compose services without operator intervention;
- the post-reboot smoke path still works;
- Remote Desktop Commander has been paired/tested separately, with any upstream restart limitation recorded rather than hidden.

Only after these acceptance gates should the real fresh S3/GW 10k Campaign be submitted.

## Operator minimalism

The intended normal human procedure on a pristine host remains exactly two visible actions:

1. place/edit `/root/gwcut-bootstrap.env`;
2. run the stable public bootstrap command.

Interactive approval of the maintenance-device pairing may occur inside the bootstrap flow, but it must not turn into a list of additional Linux administration commands. If normal rebuilds again require copying many commands between ChatGPT and the shell, the bootstrap contract has regressed.

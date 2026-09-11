# GWCut public bootstrap

This public repository contains only the non-secret Stage-0 entry point for bootstrapping a pristine Ubuntu 24.04 Hetzner Cloud host.

The privileged control plane, deployment policy, worker image allowlist, database logic, recovery gates, and science orchestration remain in the private `geomlab/gwcut-infra` repository. No credentials or private deployment configuration belong here.

## Fresh-host flow

Run this first on the fresh server:

```bash
curl -fsSL https://raw.githubusercontent.com/geomlab/gwcut-public/main/bootstrap.sh \
  -o /root/gwcut-bootstrap &&
chmod 700 /root/gwcut-bootstrap
```

Then paste the one secret block:

```bash
sudo /root/gwcut-bootstrap <<'GWCUT'
GITHUB_TOKEN=REPLACE_WITH_PRIVATE_REPO_READ_TOKEN
GHCR_READ_TOKEN=REPLACE_WITH_CLASSIC_PAT_WITH_READ_PACKAGES
S3_ACCESS_KEY=REPLACE_WITH_HETZNER_OBJECT_STORAGE_ACCESS_KEY
S3_SECRET_KEY=REPLACE_WITH_HETZNER_OBJECT_STORAGE_SECRET_KEY
S3_BUCKET=REPLACE_WITH_BUCKET
S3_REGION=fsn1
GWCUT
```

Stage 0 accepts exactly those six fields. It stores the private-repository token and the separate private-GHCR read token in distinct root-only files, resolves `geomlab/gwcut-infra/main` through authenticated Git to one exact commit SHA, fetches only that immutable commit, and delegates all deployment decisions to its private `deploy/fresh-bootstrap.sh` contract. The GHCR token is not forwarded on stdin to the private bootstrap or exposed to runtime services; the private installer uses its root-only file only to preload deployment-approved digest-pinned images.

The private bootstrap obtains the Hetzner public IPv4 from instance metadata, derives conservative explicit host resource budgets, generates the database password and API tokens locally, configures the supplied Object Storage keypair, and runs the normal fail-closed infrastructure installer. No domain or DNS record is required. On a successful installation the dashboard is intended to be available at `https://<server-public-ipv4>/` with a publicly trusted short-lived IP certificate.

This convenience path deliberately reuses one operator-supplied Object Storage credential across the internal worker, artifact-reader, and backup secret-file contracts. Deployments that need storage least privilege can still use the private manual deployment path with split credentials.

Do not put real credentials in this public repository. A failed bootstrap is not evidence that the host is safe to use or destroy; follow the private infrastructure recovery/lifecycle gates.

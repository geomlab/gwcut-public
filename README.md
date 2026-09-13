# GWCut Public Deployment

This repository is the small public deployment kit for GWCut.

A fresh host needs only Ubuntu 24.04, Docker Engine and Docker Compose. Production consists of four long-lived containers:

- postgres
- api
- scheduler
- caddy

Science workers are temporary containers launched by the scheduler.

Infrastructure intentionally follows the current `ghcr.io/geomlab/gwcut-infra:main` image. Infrastructure versioning is operational, not part of scientific reproducibility.

Science jobs remain reproducible because each Job records the exact immutable science-worker digest. The current worker reference is:

`ghcr.io/geomlab/gwcut@sha256:8a1912c584e2d187e2d944a6d830f5b8af1715fd33a96ede85bc1cbb58086106`

The active deployment files are:

- `bootstrap.sh`
- `compose.production.yml`
- `Caddyfile`

There is no stable/pinned bootstrap layer and no private infrastructure checkout on the production host. If a clean bootstrap fails, fix `main` and rebuild the host from scratch rather than repairing a partially mutated installation.

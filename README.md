# GWCut public bootstrap

This public repository contains only the non-secret Stage-0 entry point for bootstrapping a fresh GWCut host.

The privileged control plane, deployment policy, worker image allowlist, database logic, recovery gates, and science orchestration remain in the private `geomlab/gwcut-infra` repository. No credentials or private deployment configuration belong here.

The supported operator flow and `bootstrap.sh` will be published only together with the matching fail-closed private bootstrap contract.

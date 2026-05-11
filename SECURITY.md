# Security policy

## Supported versions

This repository is a **reference implementation**. Only the `master` branch is supported. Tagged releases (if any) are best-effort.

## Reporting a vulnerability

**Please do NOT open a public GitHub issue for security problems.**

If you believe you have found a security issue in this repository (including in the deployment scripts, sample agents, or Bicep modules):

1. Email the maintainer privately by opening a [GitHub security advisory](../../security/advisories/new) on this repository, OR
2. If that is not possible, contact the repository owner via the email on their GitHub profile.

Please include:

- A description of the issue and the impact you believe it could have.
- Steps to reproduce or a proof-of-concept (if available).
- The commit SHA or release tag where you observed the issue.
- Any relevant logs, screenshots, or HTTP traces (please redact secrets).

We aim to acknowledge reports within **5 business days** and to provide a remediation plan within **30 days** for confirmed issues.

## Scope

In scope:

- Source code under `src/`, `tools/`, `tests/`.
- Bicep modules under `infra/modules/`.
- Deployment scripts under `infra/scripts/`.
- Anything that ships as part of the deployed system (Orchestrator image, Web.Ui app).

Out of scope:

- Vulnerabilities in third-party Azure services themselves (report those directly to Microsoft via [MSRC](https://msrc.microsoft.com/)).
- Issues that require the attacker to already have `Owner` rights on the target subscription.
- Cost / quota issues that are not security-relevant.
- Issues that only apply to local-only configurations (e.g., a developer's machine with debugger attached).

## Disclosure policy

We follow **coordinated disclosure**:

- We will work with you privately on a fix and a CVSS estimate.
- Once a fix is available, we will publish a GitHub security advisory naming the reporter (with their consent) and crediting them.
- We will not name a reporter without explicit permission.

## Hardening status

This reference implementation **intentionally** ships with some production hardening disabled to keep the demo cheap and approachable. Specifically:

- Public ingress on APIM (Consumption SKU)
- No private endpoints on Storage / Search / Foundry / Key Vault
- No VNet integration on App Service / Container Apps
- No WAF / Front Door
- No CMK

See the *Hardening checklist* in [`docs/DEPLOYMENT.md`](docs/DEPLOYMENT.md) for the recommended upgrades before any production use.

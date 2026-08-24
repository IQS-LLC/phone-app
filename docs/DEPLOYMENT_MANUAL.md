# Lugh by IQS — Deployment Manual (redirect)

This document was split on 2026-08-24 into focused topic files — a 1445-line
monolith was harder to navigate and easier to let drift out of date than
several shorter, purpose-specific docs. The content is the same (updated
where it had gone stale — see `docs/AUDIT_FINDINGS.md`), just reorganized.

| Topic | Now lives at |
|---|---|
| Architecture, network topology, communication flow, ports | `docs/architecture.md` |
| Prerequisites, server setup, networking/tunnels, backend deploy, CI/CD, mobile install | `docs/deployment.md` |
| Beckhoff CX / ADS integration, GVL layout, device compatibility | `docs/plc-integration.md` |
| Local dev without hardware | `docs/dev-environment.md` |
| Admin/CI/dev access, all in one place | `docs/admin-access.md` |
| The 9-step commissioning wizard | `docs/commissioning.md` |
| Day-2 operations: backups, rollback, replacing hardware, rotating secrets | `docs/operations.md` |
| Troubleshooting | `docs/troubleshooting.md` |
| Testing | `docs/testing.md` |

Start at the repo root `README.md` if you're not sure where to begin.

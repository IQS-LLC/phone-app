# Legacy scripts

These three launchers (`start_lan.bat`, `start_local.bat`, `start_backend_only.ps1`)
are superseded by `start_project.ps1` in the repo root, which now correctly:

- binds Django to `0.0.0.0` (works for emulator, LAN, and custom-IP modes from one process)
- never rewrites `lib/main.dart` (these scripts did, destructively, on every launch)
- bootstraps a working dev login automatically (`manage.py bootstrap_dev_user`)
- doesn't require a `.venv` that may not exist

Kept here for reference rather than deleted outright, in case anything still
shells out to them. If nothing has referenced them after a few months, they
can be deleted for good.

## Also archived here (2026-08-24 audit): `deploy.sh`, `auto_deploy.sh`, `Dockerfile.single`, `run.sh`

These three are part of the repo's original scaffold commit (`d6ea612
"initial demo push"`, a different author than the project's actual
development history) — never touched again, never referenced by
`.github/workflows/deploy.yml`, and describing a single-container deployment
topology (`PLC_Project` as repo root, one Docker image running
Postgres+Django+Nginx together) that was never actually adopted. The real
deployment path is `docker-compose.prod.yml` + the NAS/Cloudflare-Tunnel
setup documented in `CLAUDE.md` and `docs/DEPLOYMENT_MANUAL.md`. Kept for
historical reference only — see `docs/AUDIT_FINDINGS.md` for the full audit
that found this.

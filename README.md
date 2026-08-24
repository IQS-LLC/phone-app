# Lugh by IQS — Smart Building Control

Lugh is a smart-building control platform: a Django backend talks to
Beckhoff TwinCAT PLCs over ADS/AMS, and residents/tech-team staff control
lights, relays, curtains, climate, and security through a Flutter app on
Android and iOS.

**Start here, then go deeper:**

| I want to... | Read |
|---|---|
| Understand the architecture | [`docs/DEPLOYMENT_MANUAL.md`](docs/DEPLOYMENT_MANUAL.md) §1 (being split into `docs/architecture.md`) |
| Deploy to production | [`docs/DEPLOYMENT_MANUAL.md`](docs/DEPLOYMENT_MANUAL.md) |
| Set up a local dev environment (no PLC hardware needed) | [`docs/dev-environment.md`](docs/dev-environment.md) |
| Understand PLC/GVL integration and device compatibility | [`docs/AUDIT_FINDINGS.md`](docs/AUDIT_FINDINGS.md) §1, `docs/plc-integration.md` (in progress) |
| Get an AI coding assistant up to speed fast | [`CLAUDE.md`](CLAUDE.md) |
| Find a past architectural decision or known issue | [`docs/AUDIT_FINDINGS.md`](docs/AUDIT_FINDINGS.md) |

## What's actually running in production

- **Backend**: Django 5.2 + Gunicorn (1 worker — deliberate, see `CLAUDE.md`'s
  "Critical Architecture Constraints"), PostgreSQL, Redis + Celery, all as
  separate containers (`lugh_django`, `lugh_db`, `lugh_redis`,
  `lugh_celery_worker`, `lugh_celery_beat`) via `docker-compose.prod.yml`,
  fronted by `lugh_nginx`.
- **PLC link**: `pyADS` talking ADS/AMS to a Beckhoff CX PLC, with a Modbus
  TCP fallback for a subset of devices when ADS is unavailable.
- **Internet exposure**: Cloudflare Tunnel(s) — no port forwarding. The
  phone app currently talks to a small pool of tunnel URLs with automatic
  failover between them (`flutter_application_plc/lib/config/runtime_config.dart`);
  this is a deliberately temporary bridge until the server has its own real
  WAN connectivity.
- **Mobile app**: Flutter, Android + iOS, built by GitHub Actions CI/CD on
  every push to `main`.

## Repo layout

- `PLC_Project/` — Django project settings/URLs.
- `find_device/` — the main Django app: models, views, PLC integration
  (`find_device/plc/`), device discovery/classification
  (`find_device/discovery/`), tests.
- `flutter_application_plc/` — the mobile app.
- `docs/` — the real documentation. `docs/legacy/` holds superseded material
  kept for historical reference, not current guidance.
- `scripts/legacy/`, `infra_legacy_k3s/` — abandoned scaffolding/prototypes,
  clearly labeled, not part of the current system.

## Local development, no hardware required

```bash
python manage.py migrate
python manage.py seed_demo --ip 127.0.0.1
PLC_MOCK=True python manage.py runserver 127.0.0.1:8000
```

See [`docs/dev-environment.md`](docs/dev-environment.md) for the full
walkthrough, including running the Flutter app against it and connecting to
real PLC hardware when you have it.

---

*A note on this file's history: an earlier version of this README described
a different, single-container deployment (`Dockerfile.single`,
`auto_deploy.sh`) that was part of the repo's very first scaffold commit and
was never actually built out — see `docs/AUDIT_FINDINGS.md` for the full
audit. That material is preserved in `docs/legacy/` and `scripts/legacy/` for
history, but does not describe the real system.*

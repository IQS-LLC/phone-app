# Admin / Developer Access

This is the single canonical reference for "how does someone get privileged
access to this system" — every kind of access this project has, in one
place, instead of scattered across memory or separate docs. If you're
looking for privileged access this document doesn't mention, it probably
doesn't exist yet — see the closing note.

## Application-level admin: Tech Team (`is_staff=True`)

The app-level admin role. Set on a Django `User` via `is_staff=True`
(`python manage.py createsuperuser` for the first one, or Django admin /
`python manage.py shell` for subsequent ones — see `docs/deployment.md`).
Unlocks, inside the app itself:
- The Commissioning FAB (9-step wizard — see `docs/commissioning.md`)
- The Map Editor FAB
- User Management, Apartment Management (Settings screen)
- The System Status panel, including the multi-endpoint failover status
  line (`flutter_application_plc/lib/screens/settings_screen.dart`)

All of this is enforced **server-side** — the Flutter app only shows/hides
UI based on what the backend's own response says about the logged-in user.
Never trust a client-side role check; see `CLAUDE.md`'s Security Rules.

Building Owner / Resident/Family roles sit below this — see `CLAUDE.md`'s
Role System table for the full hierarchy and what each role can see.

## Server-level admin: SSH + `.env`

Documented per-deployment in `CLAUDE.md`'s "NAS Server (Production)" section
(SSH host/port/user, DSM web UI, stack path). The single source of truth for
all runtime secrets and per-deployment config is `/volume1/docker/lugh/.env`
(or wherever the compose stack is deployed) — **unversioned, never
committed** (`.gitignore` excludes `.env`/`.env.*`), edited directly on the
server via SSH, with the affected containers restarted afterward. See
`docs/deployment.md` §5.1 for the full variable reference and what breaks if
each one is wrong.

## CI/CD-level admin: GitHub Actions secrets

Set at: repo → Settings → Secrets and variables → Actions.

| Secret | Purpose |
|---|---|
| `DOCKERHUB_USERNAME` / `DOCKERHUB_TOKEN` | Push the Django image |
| `DJANGO_SECRET_KEY` | Written to the server's `.env` on deploy |
| `DB_PASSWORD` | Written to the server's `.env` on deploy |
| `ANDROID_KEYSTORE_B64` / `ANDROID_STORE_PASSWORD` / `ANDROID_KEY_ALIAS` / `ANDROID_KEY_PASSWORD` | Sign the Android release APK |
| `LUGH_SERVER_URL` | Baked into the APK/IPA at build time — one or more comma-separated tunnel URLs (see `docs/deployment.md`'s networking section for why more than one) |
| `SERVER_HOST` | Health check target after an auto-deploy |
| `SERVER_SSH_KEY` / `SERVER_SSH_USER` / `SERVER_SSH_PORT` | The self-hosted deploy runner's SSH access to the server |

Auto-deploy is gated by a separate repo variable, `DEPLOY_ENABLED`
(Settings → Variables, not Secrets) — `true`/`false`. Setting it `false`
skips the deploy job without touching the running stack, useful for pausing
automatic rollout without touching any secret.

## Zero-hardware local dev/test environment

The fastest way to get a full-featured, every-role test environment with no
real PLC and no separate server:

```bash
python manage.py migrate
python manage.py seed_demo --ip 127.0.0.1
PLC_MOCK=True python manage.py runserver 127.0.0.1:8000
```

`seed_demo` (`find_device/management/commands/seed_demo.py`) creates one
account per role across a demo apartment, all sharing the password
`Demo12345!` — it prints the exact current list when it runs, and that
output is the authoritative source, not any doc (including this one) if
they ever disagree. `PLC_MOCK=True` is an **explicit opt-in** — the backend
does not silently fall back to mock data if a real PLC becomes unreachable
in production (`find_device/plc/registry.py`'s "No mock fallback" comment);
this is a deliberate dev/test-only switch, not a resilience feature.

See `docs/dev-environment.md` for the full walkthrough including running the
Flutter app against this.

## What does *not* exist, on purpose

There is no separate secrets vault, no additional admin backdoor, and no
privileged access path beyond the three layers above (app-level `is_staff`,
server-level SSH+`.env`, CI-level GitHub secrets). If a task seems to need
something beyond these three, that's a sign either the task is genuinely new
infrastructure work (discuss before building it — see the project's general
principle against complexity without a documented purpose), or that the
right layer already exists and just needs to be used correctly rather than
worked around.

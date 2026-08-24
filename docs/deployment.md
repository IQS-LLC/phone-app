# Deployment

**Target hardware:** Synology RS822+ (DSM 7.2+) in the reference deployment,
but nothing here is Synology-specific beyond the exact paths — any
Debian-based Docker host works.

> Follow the phases in order on a brand-new server. Every command is shown
> exactly as it must be typed, with `<PLACEHOLDER>` values you fill in for
> your environment.

## ★ Fill this in before you start

| Placeholder | Your Value | What It Is |
|---|---|---|
| `<SERVER_IP>` | __________ | LAN IP of the deployment host |
| `<SERVER_AMS_NET_ID>` | __________ | Always `<SERVER_IP>.1.1` |
| `<PLC_IP>` | __________ | LAN IP of the Beckhoff CX |
| `<PLC_AMS_NET_ID>` | __________ | Always `<PLC_IP>.1.1` |
| `<LAN_SUBNET>` | __________ | Building LAN in CIDR notation |
| `<TUNNEL_URLS>` | __________ | One or more comma-separated public HTTPS tunnel URLs (see "Network & Internet Access" below) |
| `<DOCKERHUB_USERNAME>` | __________ | Your Docker Hub username |
| `<GITHUB_REPO>` | __________ | Your GitHub repo, e.g. `IQS-LLC/phone-app` |
| `<DB_PASSWORD>` | __________ | Strong password for PostgreSQL |
| `<ADMIN_USERNAME>` / `<ADMIN_EMAIL>` / `<ADMIN_PASSWORD>` | __________ | First Django superuser |

**Where each value is used** (file + line, and exactly how to change it) —
see `docs/AUDIT_FINDINGS.md` if any of these have drifted since this was
last verified against the code:

- **`<SERVER_IP>`**: server's own `.env` (`EXTRA_ALLOWED_HOSTS=`), then
  restart `django`; `docker-compose.prod.yml`'s `EXTRA_ALLOWED_HOSTS`
  default; `PLC_Project/settings.py`'s hardcoded `ALLOWED_HOSTS` entries
  (the env var can't override these — must edit and redeploy); GitHub
  secret `SERVER_HOST`; the ADS route registered on the Beckhoff CX.
- **`<PLC_IP>`** / **`<PLC_AMS_NET_ID>`**: server's `.env` (`PLC_IP=`,
  `PLC_NETID=`), then restart `django celery-worker`;
  `docker-compose.prod.yml`'s defaults; the `PLCDevice` record in the app
  (Settings → Controllers → edit → Test Connection).
- **`<LAN_SUBNET>`**: server's `.env` (`PLC_DISCOVERY_SUBNETS=`), then
  restart `django`; `docker-compose.prod.yml`'s default.
- **`<TUNNEL_URLS>`**: the `LUGH_SERVER_URL` GitHub secret (comma-separated
  if more than one — see below), and a rebuild+redistribute of both apps
  afterward. **Old installed apps cannot be redirected without a
  reinstall** — there's no in-app server-URL setting reachable from the
  normal login flow (only the low-prominence "Advanced (Tech Team)" recovery
  sheet, for emergency single-URL overrides).
- **`<DOCKERHUB_USERNAME>`**: server's `.env`, `docker-compose.prod.yml`
  (reads it via `${DOCKERHUB_USERNAME}`, no direct edit needed once `.env`
  is set), GitHub secret `DOCKERHUB_USERNAME` (+ regenerate
  `DOCKERHUB_TOKEN` if the account changed).

---

## Phase 0 — Prerequisites & Hardware

- A Debian-based Docker host reachable from the building LAN, with a public
  internet connection (outbound only — no port forwarding required).
- Accounts to create before starting: Docker Hub, a GitHub repo with Actions
  enabled, a Cloudflare account (free tier is fine).
- Network info to confirm: the server's LAN IP, the CX's LAN IP, the
  building's LAN subnet in CIDR notation.

## Phase 1 — Server first-time setup

On a Synology NAS specifically:

1. **Enable SSH**: DSM → Control Panel → Terminal & SNMP → Enable SSH.
2. **SSH in** and run everything below as root.
3. **Verify DSM 7+**, install Docker via Package Center ("Container
   Manager").
4. **Fix Docker socket permissions** — Synology resets `/var/run/docker.sock`
   ownership on every reboot; install a boot-time fix script (`chown
   root:docker` + `chmod 660`) via Task Scheduler, triggered at boot.
5. **Create the directory layout** under `/volume1/docker/lugh/` — `django`
   inside the container runs as a non-root user pinned to uid/gid 1000; the
   bind-mounted `static/`/`media/`/`backups/` dirs need matching ownership
   here or `collectstatic`/`backup_db` fail with `PermissionError` the
   moment the container starts.
6. **Install the GitHub Actions self-hosted runner** (for CI to auto-deploy
   here) — download from the repo's Settings → Actions → Runners page,
   configure, install as a system service, verify it shows "Idle" in the
   GitHub UI.
7. **Configure auto-start on boot** — a boot script that brings the compose
   stack up automatically after a NAS reboot.

On any other Debian host, the equivalent is: install Docker, create the same
directory layout, and set up whatever service-manager auto-start mechanism
that OS uses (systemd unit, etc.) instead of Synology's Task Scheduler.

## Phase 2 — Network & Internet Access

### Install `cloudflared`

```bash
curl -L \
  https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 \
  -o /usr/local/bin/cloudflared
chmod +x /usr/local/bin/cloudflared
cloudflared --version
```

### Option A — one quick tunnel (fastest, least durable)

```bash
cloudflared tunnel --url http://localhost:9080 --no-autoupdate
```

Gets you a working URL immediately, printed in the output. **The URL
changes every time this process restarts**, and a bare quick tunnel has no
uptime guarantee — fine for initial testing, not for anything you depend on.

### Option B — a permanent named tunnel (one stable URL)

Requires a domain in a Cloudflare account (free plan works).

```bash
cloudflared tunnel login                              # once, opens a browser URL
cloudflared tunnel create lugh                         # once, ever — note the Tunnel ID
cloudflared tunnel route dns lugh <TUNNEL_DOMAIN>       # DNS CNAME → the tunnel

mkdir -p /etc/cloudflared
cat > /etc/cloudflared/config.yml << EOF
tunnel: <TUNNEL_ID>
credentials-file: /root/.cloudflared/<TUNNEL_ID>.json
ingress:
  - hostname: <TUNNEL_DOMAIN>
    service: http://localhost:9080
  - service: http_status:404
EOF

cloudflared service install
systemctl enable cloudflared
systemctl start cloudflared
```

Verify: `curl -s https://<TUNNEL_DOMAIN>/health/` → `healthy`.

### Option C — multiple tunnels for redundancy (recommended for production)

The app's `LUGH_SERVER_URL` accepts a **comma-separated list** of URLs — the
Flutter side (`RuntimeConfig`, see `docs/architecture.md`) treats it as a
priority-ordered pool and automatically fails over between entries based on
real traffic health. This removes the single-tunnel single-point-of-failure
without any backend code changes.

To set this up properly: run 2-3 independent `cloudflared` processes (each
Option A or B, your choice per-tunnel) all pointed at the same
`http://localhost:9080`, each getting its own URL/hostname. **Run every one
of them as a managed system service** (`systemctl enable`d, or your
platform's equivalent) — not as an ad-hoc terminal process on someone's
personal machine. A tunnel that only survives while a specific person's
laptop is open and a specific terminal window stays open defeats the entire
purpose of building redundancy; it just moves the single point of failure
from "the tunnel" to "that person's laptop." This was a real, live outage
found and fixed during this project's development — see
`docs/AUDIT_FINDINGS.md`.

Then set the GitHub secret to all of them joined by commas:

```bash
gh secret set LUGH_SERVER_URL \
  --body "https://<url-1>,https://<url-2>,https://<url-3>" \
  --repo <GITHUB_REPO>
```

Also add every hostname to the server's `.env` (`EXTRA_ALLOWED_HOSTS=`,
comma-separated) and restart `django`, or Django will reject requests
through any tunnel not already on the list with a 400 (`DisallowedHost`).

### Firewall rules

| Rule | Action | Port | Source |
|---|---|---|---|
| SSH | Allow | 22 | Admin workstation IP only |
| DSM/admin web UI | Allow | 5000, 5001 | Admin workstation IP only |
| Lugh API (LAN) | Allow | 9080 | `<LAN_SUBNET>` |
| Everything else | Deny | All | All |

Port 9080 does **not** need to be open on the internet-facing router —
Cloudflare Tunnel handles that via an outbound connection from the server.

## Phase 3 — Deploy the backend stack

### Write the `.env` file

```bash
SECRET_KEY=$(python3 -c "import secrets, string; \
  chars = string.ascii_letters + string.digits + '!@#%^&*(-_=+)'; \
  print(''.join(secrets.choice(chars) for _ in range(60)))")

cat > /volume1/docker/lugh/.env << EOF
DOCKERHUB_USERNAME=<DOCKERHUB_USERNAME>
SECRET_KEY=${SECRET_KEY}
POSTGRES_PASSWORD=<DB_PASSWORD>
DB_PASSWORD=<DB_PASSWORD>
EXTRA_ALLOWED_HOSTS=<SERVER_IP>,<TUNNEL_URLS as bare hostnames, comma-separated>
PLC_MOCK=false
PLC_IP=<PLC_IP>
PLC_NETID=<PLC_AMS_NET_ID>
PLC_PORT=851
PLC_DISCOVERY_SUBNETS=<LAN_SUBNET>
PLC_ROUTE_USERNAME=<CX_OS_USERNAME>
PLC_ROUTE_PASSWORD=<CX_OS_PASSWORD>
PLC_MODBUS_ENABLED=false
PLC_OUTAGE_WEBHOOK_URL=
HTTPS_ENABLED=false
BACKUP_RETENTION_DAYS=14
EOF

chmod 600 /volume1/docker/lugh/.env
```

`POSTGRES_PASSWORD` and `DB_PASSWORD` **must be identical** — Postgres uses
the former to initialize the DB, Django uses the latter to connect; if they
differ, Django fails with an authentication error.

See `docs/admin-access.md` for what each variable controls and what breaks
if it's wrong or missing — that table is the canonical reference, not
duplicated here.

**To change any `.env` value after deployment:**
```bash
nano /volume1/docker/lugh/.env
docker compose -f /volume1/docker/lugh/docker-compose.prod.yml \
  restart django celery-worker celery-beat
```

### Copy the compose and nginx files

```bash
# Clone the repo
git clone https://github.com/<GITHUB_REPO>.git /tmp/lugh-repo
cp /tmp/lugh-repo/docker-compose.prod.yml /volume1/docker/lugh/
cp /tmp/lugh-repo/nginx/nginx.conf        /volume1/docker/lugh/
rm -rf /tmp/lugh-repo

# Or the automated installer:
curl -fsSL \
  https://raw.githubusercontent.com/<GITHUB_REPO>/main/scripts/nas-install.sh \
  | bash
```

Every environment-specific value is read from `.env` via
`${VARIABLE:-default}` substitution in `docker-compose.prod.yml` — you
should not need to edit that file directly for a normal deployment. Only
open it for something structural (a port mapping, a volume path, adding a
service).

### Pull images and start the stack

```bash
docker compose -f /volume1/docker/lugh/docker-compose.prod.yml --env-file /volume1/docker/lugh/.env pull
docker compose -f /volume1/docker/lugh/docker-compose.prod.yml --env-file /volume1/docker/lugh/.env up -d
```

Startup order (enforced by `depends_on` + healthchecks): `lugh_db` →
`lugh_redis` → `lugh_django` (runs migrate + collectstatic, then starts
Gunicorn) → `lugh_celery_worker`/`lugh_celery_beat` → `lugh_nginx`.

**Verify:**
```bash
docker compose -f /volume1/docker/lugh/docker-compose.prod.yml ps
```
All containers should show `running (healthy)` or `running`.

### Create the admin superuser

```bash
docker exec -it lugh_django python manage.py createsuperuser
```

This is the first Tech Team (staff) account — see `docs/admin-access.md`.

### Verify health endpoints

```bash
curl http://<SERVER_IP>:9080/health/                # LAN
curl https://<one of your tunnel URLs>/health/       # internet, once tunnel(s) are running
```

Expected: `{"status": "ok", "database": "ok", "redis": "ok", "plc_mode": "live"}`

### Database backups

A Celery Beat task (`backup_database`) runs `pg_dump` nightly at 03:00 UTC
and prunes backups older than `BACKUP_RETENTION_DAYS` (default 14). Files
land in `/volume1/docker/lugh/backups/` as `lugh_db_<timestamp>.dump`
(`pg_dump`'s custom format — compressed, selectively restorable with
`pg_restore`). See `docs/operations.md` for manual backup/restore commands.
**Copy backups off the server** — a backup on the same disk as the database
it protects doesn't protect against disk failure.

## Phase 4 — CI/CD pipeline (GitHub Actions)

```
git push to main
    ↓
Django Tests (against real PostgreSQL)
    ↓ (pass)
    ├── Build Django Image → Docker Hub
    ├── Build Android APK (signed, LUGH_SERVER_URL baked in)
    └── Build iOS IPA (unsigned, LUGH_SERVER_URL baked in)
         ↓ (if DEPLOY_ENABLED=true)
    Deploy job on the self-hosted runner: docker pull → compose up -d → health check
```

Required GitHub secrets and the `DEPLOY_ENABLED` toggle: see
`docs/admin-access.md`.

**Build apps locally instead of waiting on CI:**
```bash
cd flutter_application_plc
flutter build apk --release \
  "--dart-define=LUGH_SERVER_URL=<comma-separated tunnel URLs>" \
  --build-name="1.0.0" --build-number="1"

flutter build ios --release --no-codesign \
  "--dart-define=LUGH_SERVER_URL=<comma-separated tunnel URLs>"
```

There is no in-app setting to change the server pool — it's set at build
time (the emergency single-URL "Advanced (Tech Team)" recovery sheet is the
one exception, for reaching a different single URL without a rebuild).

## Phase 6 — Mobile application installation

**Android:** Settings → Security → allow installs from your file manager →
transfer the APK → install → open. If the login screen shows a network
error immediately on load, the baked-in URL pool is wrong or every tunnel in
it is down.

**iOS via AltStore** (no paid developer account needed): install AltStore +
AltServer, add the IPA through AltStore. A free Apple ID's install expires
after 7 days and needs reinstalling; a paid Apple Developer account ($99/yr)
allows TestFlight distribution with no expiry.

**Login:** residents cannot self-register — all accounts are created by
staff through the Commissioning Wizard or Django admin.

---

## Reference

### Container reference

| Container | Image | Listens On | Restart When |
|---|---|---|---|
| `lugh_nginx` | `nginx:1.27-alpine` | `<SERVER_IP>:9080` | IP/config changes |
| `lugh_django` | `<DOCKERHUB_USERNAME>/lugh-django:latest` | Docker internal :8000 | `.env` changes, updates |
| `lugh_db` | `postgres:15-alpine` | Docker internal :5432 | Password changes |
| `lugh_redis` | `redis:7-alpine` | Docker internal :6379 | Rarely needed |
| `lugh_celery_worker` | same image as django | — | `.env` changes, updates |
| `lugh_celery_beat` | same image as django | — | Schedule changes |

### File locations

| File | Path | Edit When |
|---|---|---|
| Secrets & config | `/volume1/docker/lugh/.env` | IP changes, password rotation, PLC changes |
| Docker Compose | `/volume1/docker/lugh/docker-compose.prod.yml` | Stack structure changes |
| Nginx config | `/volume1/docker/lugh/nginx.conf` | Proxy/cache rules |
| Boot script | `/volume1/docker/lugh/start.sh` | Path changes |
| Backup script | `/volume1/docker/lugh/backup.sh` | Retention policy changes |
| DB backups | `/volume1/docker/lugh/backups/` | |
| Media (floor plans) | `/volume1/docker/lugh/media/` | |
| CI runner | `/volume1/docker/lugh/runner/` | Runner re-registration |

### Useful commands

```bash
# Stack
docker compose -f /volume1/docker/lugh/docker-compose.prod.yml up -d
docker compose -f /volume1/docker/lugh/docker-compose.prod.yml down
docker compose -f /volume1/docker/lugh/docker-compose.prod.yml restart django
docker compose -f /volume1/docker/lugh/docker-compose.prod.yml ps

# Django management
docker exec lugh_django python manage.py migrate
docker exec lugh_django python manage.py createsuperuser
docker exec -it lugh_django python manage.py shell

# Health
curl http://<SERVER_IP>:9080/health/

# Logs
docker logs lugh_django --tail=100 -f

# Database shell
docker exec -it lugh_db psql -U lugh_user -d lugh_db
```

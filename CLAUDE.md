# Lugh by IQS — Project Context for Claude

## What This Project Is

Lugh is a smart-building control platform. A Django backend runs on a Synology NAS at the client site,
communicates with a Beckhoff CX PLC over ADS/AMS, and is controlled by a Flutter app on Android and iOS.
Residents control lights, relays, curtains, and climate. Tech team staff commission and manage the system.

**GitHub repo:** `IQS-LLC/phone-app` (private)  
**Docker Hub image:** `shara-a/lugh-django:latest`  
**Docs entry point:** `README.md` → `docs/architecture.md`, `docs/deployment.md`, `docs/plc-integration.md`, `docs/admin-access.md`

---

## Behavioral Rules (follow these exactly)

- **Do not tell me what you are going to do. Actually do the work.**
- When you reach a point where you cannot test something because it requires the physical environment
  (Synology NAS, Beckhoff CX PLCs, Android emulator, iOS simulator, or local network), stop and
  explicitly state: **"Requires execution on the target environment."**
- Do not summarize what you just did at the end of a response. The user can read the diff.

---

## Security Rules (non-negotiable, never relax these)

- **Users must never see networking and must never be able to create or delete accounts — that is the
  tech team's job.**
- **Never trust the Flutter application. All authorization decisions belong in Django.**
- **All permissions must be enforced by the Django backend. Flutter is responsible only for presenting
  the correct interface.**

---

## Stack

| Layer | Technology | Notes |
|---|---|---|
| Backend | Django 5.2, Python 3.11, Gunicorn | `PLC_Project/` is the Django project folder |
| Database | PostgreSQL 15 | Container: `lugh_db` |
| Task queue | Redis 7 + Celery | Containers: `lugh_celery_worker`, `lugh_celery_beat` |
| Proxy | Nginx 1.27 | Container: `lugh_nginx`, port 9080:80 |
| PLC comms | pyADS 3.5.2 | ADS/AMS over TCP:48898 + TCP:851 |
| Internet | Cloudflare Tunnel (`cloudflared`) | No port forwarding needed |
| Mobile | Flutter (Android + iOS) | `flutter_application_plc/` |
| CI/CD | GitHub Actions | `.github/workflows/deploy.yml` |
| Registry | Docker Hub (`shara-a/lugh-django`) | Pushed on every main push |

---

## Critical Architecture Constraints

**Gunicorn must run with 1 worker.** `WEB_CONCURRENCY=1` is set in `Dockerfile` and `docker-compose.prod.yml`.
`DeviceRegistry` holds in-memory ADS connections per apartment. Multiple workers each get their own
registry — connections break. Do not add workers without a Redis-backed shared registry.

**`LUGH_SERVER_URL` is baked into the APK and IPA at build time** via `--dart-define`. Changing the
tunnel URL requires: update `LUGH_SERVER_URL` GitHub secret → trigger CI build → redistribute both apps.
There is no in-app setting to change the server URL.

**JWT tokens:** access = 30 min, refresh = 7 days. `is_staff=True` = Tech Team (Commission + Map Editor FABs,
TECH TEAM badge). All role checks are on the backend; never rely on what the Flutter app sends.

**AMS Net ID formula:** always `<IP_ADDRESS>.1.1`. PLC at `10.0.0.100` → AMS Net ID `10.0.0.100.1.1`.

---

## IP Addresses and Where to Change Them

All network values are placeholders in this repo. Every hardcoded example IP must be replaced.
See `docs/deployment.md` → "Fill this in before you start" for the complete per-file,
per-line reference. Summary:

| Value | Files that contain it | How to change |
|---|---|---|
| NAS IP | `docker-compose.prod.yml:36`, `PLC_Project/settings.py:33`, `/volume1/docker/lugh/.env`, GitHub secret `SERVER_HOST` | Edit `.env` + restart `django`; also update ADS route on CX |
| PLC IP | `docker-compose.prod.yml:38`, `PLC_Project/settings.py:34`, `/volume1/docker/lugh/.env`, PLCDevice DB record | Edit `.env` + restart `django celery-worker`; update in app Settings |
| PLC AMS Net ID | `docker-compose.prod.yml:39`, `/volume1/docker/lugh/.env`, PLCDevice DB record | Same as PLC IP |
| LAN subnet | `docker-compose.prod.yml:43`, `/volume1/docker/lugh/.env` | Edit `.env` + restart `django` |
| Tunnel URL | GitHub secret `LUGH_SERVER_URL` only (baked into apps) | Update secret → rebuild → redistribute apps |

---

## Key Files

| File | Purpose |
|---|---|
| `docker-compose.prod.yml` | Production Docker Compose — all env vars for PLC, DB, allowed hosts |
| `docker-compose.dev.yml` | Local Windows dev stack |
| `PLC_Project/settings.py` | Django settings — `ALLOWED_HOSTS` has hardcoded IPs at lines 33–34 |
| `PLC_Project/urls.py` | URL routing |
| `find_device/models.py` | `PLCDevice`, `Apartment`, `ApartmentMembership`, `DeviceState` |
| `find_device/views.py` | Main API views |
| `find_device/auth_views.py` | JWT login, token refresh, user info |
| `find_device/commissioning_views.py` | 3 commissioning endpoints (staff only) |
| `find_device/plc/ads_client.py` | `ADSClient` — thread-safe pyADS wrapper with exponential backoff reconnect |
| `find_device/plc/registry.py` | `DeviceRegistry` — in-memory ADS connection registry per apartment |
| `find_device/middleware.py` | `JWTAuthMiddleware`, `RateLimitMiddleware`, `RequestLoggingMiddleware` |
| `nginx/nginx.conf` | Nginx config — SSE proxy, security headers, static files |
| `gunicorn.conf.py` | Gunicorn config — 1 worker, 1000 max_requests |
| `Dockerfile` | Multi-stage build, non-root `django` user, healthcheck on `/health/` |
| `requirements.txt` | Python dependencies |
| `flutter_application_plc/lib/` | Flutter app source |
| `flutter_application_plc/lib/screens/main_shell.dart` | Staff FABs (Commission + Map Editor) |
| `flutter_application_plc/lib/screens/commissioning_wizard_screen.dart` | 9-step wizard |
| `scripts/nas-install.sh` | Interactive one-shot NAS installer |
| `lugh-startup.ps1` | Windows dev PC auto-start script |
| `setup-permanent-tunnel.ps1` | Cloudflare permanent tunnel setup |
| `.github/workflows/deploy.yml` | CI/CD — test → build → android → ios → deploy |
| `docs/deployment.md`, `docs/architecture.md`, `docs/plc-integration.md`, `docs/commissioning.md`, `docs/operations.md`, `docs/troubleshooting.md` | Installation, architecture, PLC integration, commissioning, day-2 ops, troubleshooting (was one `DEPLOYMENT_MANUAL.md`, split 2026-08-24 — see `docs/DEPLOYMENT_MANUAL.md` for the redirect map) |

---

## NAS Server (Production)

- **SSH:** `<NAS_IP>:22`, user `Administrator-NAS`
- **DSM Web:** `http://<NAS_IP>:5000`
- **App port:** `<NAS_IP>:9080` (Nginx)
- **Stack path:** `/volume1/docker/lugh/`
- **Env file:** `/volume1/docker/lugh/.env` (not committed — contains secrets)
- **Runner path:** `/volume1/docker/lugh/runner/`
- **Boot script:** `/volume1/docker/lugh/start.sh` (registered in DSM Task Scheduler)
- **Docker socket fix:** `/usr/local/etc/rc.d/fix-docker-sock.sh` — sets `chown root:docker` + `chmod 660` on `/var/run/docker.sock` at boot (Synology resets it each reboot)

### Container names
`lugh_django`, `lugh_nginx`, `lugh_db`, `lugh_redis`, `lugh_celery_worker`, `lugh_celery_beat`

### Common commands on NAS
```bash
# Stack status
docker compose -f /volume1/docker/lugh/docker-compose.prod.yml ps

# Restart single service
docker compose -f /volume1/docker/lugh/docker-compose.prod.yml restart django

# Logs
docker logs lugh_django --tail=100 -f

# Health check
curl http://localhost:9080/health/

# Django shell
docker exec -it lugh_django python manage.py shell

# Create superuser
docker exec -it lugh_django python manage.py createsuperuser
```

---

## Windows Dev PC (Local Stack)

When the NAS is not on-site, the full stack runs on the Windows PC.

```powershell
# Start dev stack
docker context use desktop-linux
cd "c:\Users\Automation\Desktop\phoneapp+apartment-16\phone-app"
docker compose -f docker-compose.dev.yml up -d

# If nginx returns 502 after restart (container IPs shifted):
docker exec lugh_nginx nginx -s reload
```

**Cloudflare quick tunnel (URL changes each restart):**
```powershell
C:\Users\Automation\Desktop\cloudflared.exe tunnel --url http://localhost:8090 --no-autoupdate
```
After getting a new URL:
1. `gh secret set LUGH_SERVER_URL --body "https://xxx.trycloudflare.com" --repo IQS-LLC/phone-app`
2. Push any commit to main to trigger a CI rebuild
3. Download new APK/IPA from GitHub Actions → Artifacts

**Dev ports:** nginx=8090, django=8000 (direct), postgres=5432, redis=6379

---

## CI/CD (GitHub Actions)

**Workflow:** `.github/workflows/deploy.yml`

Pipeline on push to `main`:
1. `test` — Django tests against real PostgreSQL service container
2. `build-backend` — Docker image pushed to `docker.io/shara-a/lugh-django:latest`
3. `build-android` — Signed release APK (keystore from `ANDROID_KEYSTORE_B64` secret)
4. `build-ios` — Unsigned IPA (`--no-codesign`, `macos-latest` runner)
5. `deploy` — Runs on self-hosted `[self-hosted, synology]` runner; skipped unless `vars.DEPLOY_ENABLED == 'true'`

**Auto-deploy toggle:** GitHub repo → Settings → Variables → `DEPLOY_ENABLED` = `true` / `false`

**Required secrets:** `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN`, `DJANGO_SECRET_KEY`, `DB_PASSWORD`,
`ANDROID_KEYSTORE_B64`, `ANDROID_STORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`,
`LUGH_SERVER_URL`, `SERVER_HOST`

**Android keystore:** `lugh-release.jks` — alias `lugh`, CN=Lugh O=HzorTech C=IE, valid 10000 days.
Keep this backed up — APK updates signed with a different key cannot replace an installed APK.

**Known CI quirks:**
- Always use `--body VALUE` with `gh secret set` — never pipe from PowerShell (adds UTF-8 BOM)
- SCP is disabled on Synology SSH; use stdin pipe: `ssh host "cat > path" < localfile`
- `psycopg[binary]` required (bundles libpq; no system dependency on the NAS)

---

## PLC Integration

**Protocol:** ADS/AMS via pyADS 3.5.2  
**Ports:** TCP 48898 (ADS router) + TCP 851 (TwinCAT 3 runtime)  
**AMS Net ID format:** always `<IP>.1.1`  
**Entry point:** `find_device/plc/ads_client.py` — `ADSClient(netid, ip, mock=False)`

`DeviceRegistry.for_apartment(apt_id)` returns the per-apartment registry and auto-reconnects
with exponential backoff (1 s → 2 s → ... → 60 s max).

**PLC variable naming:** there is no single fixed naming convention — see
`docs/plc-integration.md` for the real, current GVL layout used by the
control path (`find_device/plc/devices.py`), the separate dynamic
classification vocabulary used by SuperScan discovery
(`find_device/discovery/classifier.py`), and why the two currently disagree.
Do not hand-restate a naming table here again — it drifted out of sync with
the code once already (audited 2026-08-24, see `docs/AUDIT_FINDINGS.md` §1).

**For a new PLC connection to work:**
1. NAS must have a route on the CX: `<NAS_IP>` / `<NAS_AMS_NET_ID>` via TwinCAT System Manager
2. `PLC_IP` and `PLC_NETID` must be set in `/volume1/docker/lugh/.env`
3. TCP 48898 and 851 must be reachable from the NAS to the CX
4. TwinCAT must be in RUN state (ADS state 5)

**Modbus TCP fallback (optional, off by default):** `find_device/plc/modbus_client.py`
+ `PLC_MODBUS_ENABLED=true` gives DALI 1-16 / relay 1-4 a second path via
TF6250 (port 502) that survives AMS route/Secure-ADS failures ADS doesn't.
See `docs/plc_proposals/modbus_bridge.md` — requires TF6250 installed and
licensed on the CX8190 first; nothing connects until that env var is set.

**Outage heartbeat/alerting:** `find_device.tasks.check_plc_heartbeat` (Celery
Beat, every minute) tracks every apartment's reachability (ADS or Modbus) via
`PLCDevice.down_since`/`last_seen_at` and fires `send_notification` once on
outage-start (>2 min down) and once on recovery — deliberately ignores
`PLCDevice.is_active` (that flag only gates the background SSE poll, not
whether an apartment gets outage-monitored). `PLC_OUTAGE_WEBHOOK_URL` (unset
by default) posts the same alert to ntfy.sh/Slack/Discord for an actual phone
notification today — `send_notification` itself only logs until FCM/APNs
credentials are wired up.

---

## Role System

| Role | `is_staff` | Apartment | What they see |
|---|---|---|---|
| Tech Team | `True` | any/none | Full app + Commission FAB + Map Editor FAB + TECH TEAM badge |
| Owner | `False` | assigned, role=`owner` | Full control, user management, device settings |
| Family Member / Resident | `False` | assigned, role=`resident` | Device control, read-only settings |
| Guest (no apartment) | `False` | none | Bounced to login screen immediately |

All role checks enforced in Django. Flutter only shows/hides UI elements based on the API response.

---

## Commissioning Wizard (9 steps)

Launched from the amber Commission FAB (staff only):
1. Network Discovery — scans `PLC_DISCOVERY_SUBNETS` for Beckhoff ADS targets
2. PLC Connectivity — confirm IP + AMS Net ID + port, verify RUN state
3. Apartment Setup — create apartment + rooms in DB
4. Symbol Discovery — enumerate TwinCAT GVL variables
5. Floor Plan Upload — PNG/JPEG up to 20 MB
6. Map Editor — place device icons on floor plan
7. I/O Commissioning — pulse test each physical output
8. Resident Accounts — create owner + resident users
9. Handover — commissioning summary

API endpoints: `GET /commissioning/checklist/`, `POST /commissioning/test-io/`, `GET /commissioning/summary/`
All require `IsAdminUser` (`is_staff=True`).

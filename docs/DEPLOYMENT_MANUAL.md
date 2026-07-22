# Lugh by IQS
## Complete Installation, Deployment, Commissioning & Maintenance Manual

**Document version:** 1.0  
**Platform version:** As of commit `7677689`  
**Target hardware:** Synology RS822+ (DSM 7.2+)  
**Audience:** System installers, DevOps engineers, system administrators  

---

> **How to use this document**  
> Follow the phases in order on a brand-new server. Every command is shown exactly as it must be typed.  
> Sections marked ⚠️ **WARNING** must not be skipped. Sections marked 💡 **NOTE** provide context.  
> A reader with Linux knowledge but no prior exposure to this project should be able to complete a full deployment using only this document.

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Phase 0 — Prerequisites & Hardware](#2-phase-0--prerequisites--hardware)
3. [Phase 1 — Synology NAS First-Time Setup](#3-phase-1--synology-nas-first-time-setup)
4. [Phase 2 — Network & Internet Access](#4-phase-2--network--internet-access)
5. [Phase 3 — Deploy the Backend Stack](#5-phase-3--deploy-the-backend-stack)
6. [Phase 4 — CI/CD Pipeline (GitHub Actions)](#6-phase-4--cicd-pipeline-github-actions)
7. [Phase 5 — Beckhoff CX PLC Integration](#7-phase-5--beckhoff-cx-plc-integration)
8. [Phase 6 — Mobile Application Installation](#8-phase-6--mobile-application-installation)
9. [Phase 7 — Commissioning](#9-phase-7--commissioning)
10. [Phase 8 — Maintenance & Operations](#10-phase-8--maintenance--operations)
11. [Troubleshooting](#11-troubleshooting)
12. [Reference](#12-reference)

---

## 1. Architecture Overview

### 1.1 System Components

| Component | Technology | Purpose |
|---|---|---|
| Backend API | Django 5.2 / Python 3.11 / Gunicorn | REST API, JWT auth, PLC control |
| Database | PostgreSQL 15 | Persistent storage for all data |
| Task Queue | Redis 7 + Celery | Background tasks, alarms, notifications |
| Reverse Proxy | Nginx 1.27 | TLS termination, static files, SSE |
| Internet Tunnel | Cloudflare Tunnel (cloudflared) | Secure internet access, no port forwarding |
| PLC Communication | pyADS 3.5.2 | ADS/AMS protocol to Beckhoff CX |
| Mobile App | Flutter (Android + iOS) | Resident and tech team interface |
| CI/CD | GitHub Actions | Automated testing, image builds, deployment |
| Registry | Docker Hub (`shara-a/lugh-django`) | Docker image distribution |

### 1.2 Network Topology

```
                    ┌─────────────────────────────────────────┐
                    │              INTERNET                   │
                    └──────────────────┬──────────────────────┘
                                       │ HTTPS / WSS
                                       │ (Cloudflare Edge)
                    ┌──────────────────▼──────────────────────┐
                    │         CLOUDFLARE TUNNEL               │
                    │   (cloudflared running on NAS)          │
                    └──────────────────┬──────────────────────┘
                                       │ HTTP → localhost:9080
                    ┌──────────────────▼──────────────────────┐
                    │         SYNOLOGY RS822+                 │
                    │         192.168.0.192                   │
                    │                                         │
                    │  ┌─────────────────────────────────┐   │
                    │  │  Docker Stack (lugh_net bridge) │   │
                    │  │                                 │   │
                    │  │  ┌──────────┐  :80  ┌────────┐ │   │
                    │  │  │  Nginx   │◄──────│ Static │ │   │
                    │  │  │ :9080→80 │       │ Files  │ │   │
                    │  │  └────┬─────┘       └────────┘ │   │
                    │  │       │ proxy_pass :8000        │   │
                    │  │  ┌────▼─────┐                   │   │
                    │  │  │  Django  │                   │   │
                    │  │  │ Gunicorn │◄──── JWT Auth     │   │
                    │  │  │  :8000   │                   │   │
                    │  │  └────┬──┬──┘                   │   │
                    │  │       │  └──────────────────┐   │   │
                    │  │  ┌────▼─────┐  ┌────────────▼┐ │   │
                    │  │  │Postgres  │  │   Redis 7   │ │   │
                    │  │  │   :5432  │  │    :6379    │ │   │
                    │  │  └──────────┘  └──────┬──────┘ │   │
                    │  │                        │        │   │
                    │  │  ┌─────────────────────▼──────┐ │   │
                    │  │  │  Celery Worker + Beat      │ │   │
                    │  │  │  (plc, alarms, housekeep.) │ │   │
                    │  │  └────────────────────────────┘ │   │
                    │  └─────────────────────────────────┘   │
                    └──────────────────┬──────────────────────┘
                                       │ ADS/AMS  TCP:48898
                    ┌──────────────────▼──────────────────────┐
                    │      BUILDING LAN  192.168.0.0/24       │
                    │                                         │
                    │  ┌──────────────────────────────────┐   │
                    │  │  Beckhoff CX  192.168.0.161      │   │
                    │  │  AMS Net ID: 192.168.0.161.1.1   │   │
                    │  │  TwinCAT 3 Runtime               │   │
                    │  │  PLC Program running             │   │
                    │  └──────────────────────────────────┘   │
                    └──────────────────┬──────────────────────┘
                                       │ Physical I/O
                    ┌──────────────────▼──────────────────────┐
                    │          APARTMENT DEVICES              │
                    │  DALI lights, wall relays, curtains,    │
                    │  door/window sensors, wall switches     │
                    └─────────────────────────────────────────┘

         ┌────────────────────────────────────────────┐
         │              MOBILE APPS                   │
         │  Resident phones (Android + iOS)           │
         │  Tech Team phones (admin access)           │
         │  → HTTPS to Cloudflare tunnel URL          │
         └────────────────────────────────────────────┘
```

### 1.3 Communication Flow (Resident controls a light)

```
Resident taps "Dim to 50%" in app
    ↓  HTTPS POST /plc/{apt_id}/control/
Cloudflare Tunnel (encrypted)
    ↓  HTTP
Nginx → Django (JWT verified, apartment membership checked)
    ↓  Python function call
DeviceRegistry.for_apartment(apt_id)
    ↓  pyADS write_by_name()
ADS over TCP:48898
    ↓
TwinCAT 3 PLC Runtime (Beckhoff CX)
    ↓  DALI bus
Physical DALI ballast dims the light
    ↑
Django reads new state via ADS
    ↑  SSE push /realtime/{apt_id}/stream/
Resident's app updates the UI instantly
```

### 1.4 Port Reference

| Port | Protocol | Service | Exposed To |
|---|---|---|---|
| 9080 | TCP | Nginx (HTTP) | LAN + Cloudflare Tunnel |
| 8000 | TCP | Django/Gunicorn | Internal Docker network only |
| 5432 | TCP | PostgreSQL | Internal Docker network only |
| 6379 | TCP | Redis | Internal Docker network only |
| 48898 | TCP | ADS Router (Beckhoff) | Building LAN only |
| 851 | TCP | TwinCAT 3 PLC Runtime | Building LAN only |
| 22 | TCP | NAS SSH (DSM uses 22; Lugh NAS uses 8000 by convention) | Admin only |

---

## 2. Phase 0 — Prerequisites & Hardware

### 2.1 Hardware Required

| Item | Specification | Notes |
|---|---|---|
| NAS Server | Synology RS822+ | DSM 7.2 or later required |
| RAM | ≥ 4 GB | 8 GB recommended |
| Storage | ≥ 10 GB free on `/volume1` | For Docker images, DB, logs |
| Network | 100 Mbps LAN | NAS and PLC on same subnet |
| Beckhoff CX | Any CX series | TwinCAT 3 runtime required |
| Android device | Android 7.0+ | For APK sideloading |
| iOS device | iOS 14.0+ | For IPA sideloading via AltStore |

### 2.2 Accounts & Credentials Required (Collect Before Starting)

| Credential | Where to Get It | Used For |
|---|---|---|
| Docker Hub account | hub.docker.com | Pulling the `lugh-django` image |
| GitHub access token | github.com → Settings → Developer Settings | CI/CD automation |
| Cloudflare account | cloudflare.com | Internet tunnel (free tier works) |
| Strong PostgreSQL password | Generate: `openssl rand -base64 32` | Database security |

### 2.3 Network Information to Know in Advance

Before starting, note down:
- NAS IP address on the LAN (e.g. `192.168.0.192`)
- PLC IP address (e.g. `192.168.0.161`)
- PLC AMS Net ID (always `<PLC_IP>.1.1`, e.g. `192.168.0.161.1.1`)
- Building LAN subnet (e.g. `192.168.0.0/24`)

---

## 3. Phase 1 — Synology NAS First-Time Setup

### 3.1 Enable SSH on the NAS

1. Log into DSM web interface at `http://<NAS_IP>:5000`
2. Go to **Control Panel → Terminal & SNMP**
3. Enable SSH service, set port to `22` (default) or custom port
4. Click **Apply**

### 3.2 Connect via SSH

```bash
ssh Administrator@192.168.0.192
# Enter password when prompted
# Elevate to root:
sudo -i
```

All subsequent commands in Phase 1 must be run as `root`.

### 3.3 Verify DSM Version

```bash
synoinfo get_section_key_value /etc/synoinfo.conf majorversion
# Must return 7 or higher
```

### 3.4 Install Docker via Package Center

Docker on Synology comes from the **Container Manager** package.

1. Open DSM → Package Center
2. Search for **Container Manager**
3. Click **Install**
4. Wait for installation to complete

Verify:

```bash
docker --version
# Expected: Docker version 24.x.x or later

docker compose version
# Expected: Docker Compose version v2.x.x
```

> 💡 **NOTE:** Synology ships Docker Compose v2 as a plugin to Docker (`docker compose`), not as the legacy standalone `docker-compose` binary. Always use `docker compose` (with a space), never `docker-compose` (with a hyphen).

### 3.5 Fix Docker Socket Permissions (Synology-Specific)

Synology resets `/var/run/docker.sock` to `root:root 660` on every reboot. The GitHub Actions self-hosted runner needs group access to run Docker commands.

**Add the runner user to the docker group:**

```bash
# Create the docker group if it does not exist
synogroup --add docker 2>/dev/null || true

# Add the Administrator user to the docker group
synogroup --member docker Administrator

# Verify
id Administrator | grep docker
```

**Install a startup script to fix socket permissions on boot:**

```bash
cat > /usr/local/etc/rc.d/fix-docker-sock.sh << 'EOF'
#!/bin/bash
# Fix Docker socket group permissions after NAS reboot.
# Synology resets docker.sock to root:root on each boot.
sleep 10
chown root:docker /var/run/docker.sock
chmod 660 /var/run/docker.sock
EOF

chmod +x /usr/local/etc/rc.d/fix-docker-sock.sh
```

> ⚠️ **WARNING:** Do NOT use `chmod 777` or `chmod 666` on `/var/run/docker.sock`. That grants every process on the machine full Docker daemon control, which is equivalent to root access. The script above uses `660` with group ownership — only members of the `docker` group can use the socket.

### 3.6 Install Git

```bash
# Check if already available
git --version 2>/dev/null && echo "git OK" || echo "git missing"
```

If missing, install via Synology's Entware or ipkg:

```bash
# Check for Entware
/opt/bin/opkg list-installed | grep git

# Install if needed
/opt/bin/opkg install git
```

Alternatively, Git is available inside any Docker container — for this deployment, Git is not needed on the NAS host itself, only inside the CI runner (which runs on GitHub's infrastructure).

### 3.7 Create the Directory Layout

```bash
mkdir -p /volume1/docker/lugh/{postgres_data,redis_data,static,media}
chmod 750 /volume1/docker/lugh
ls -la /volume1/docker/lugh/
```

Expected output:
```
drwxr-x--- ... postgres_data
drwxr-x--- ... redis_data
drwxr-x--- ... static
drwxr-x--- ... media
```

### 3.8 Install the GitHub Actions Self-Hosted Runner

The self-hosted runner is what allows GitHub Actions to deploy directly to the NAS when code is pushed to `main`.

**On GitHub.com:**
1. Go to the repository → **Settings → Actions → Runners**
2. Click **New self-hosted runner**
3. Select **Linux** / **x64**
4. Follow the displayed commands exactly

**On the NAS (as root):**

```bash
mkdir -p /volume1/docker/lugh/runner && cd /volume1/docker/lugh/runner

# Download the runner (replace URL with the one GitHub provides)
curl -o actions-runner-linux-x64.tar.gz -L \
  https://github.com/actions/runner/releases/download/v2.317.0/actions-runner-linux-x64-2.317.0.tar.gz

tar xzf actions-runner-linux-x64.tar.gz

# Configure (replace TOKEN and REPO with values from GitHub UI)
./config.sh \
  --url https://github.com/IQS-LLC/phone-app \
  --token <REGISTRATION_TOKEN> \
  --labels synology \
  --name SynologyNAS-IQS \
  --unattended

# Install as a service
./svc.sh install
./svc.sh start
./svc.sh status
```

**Verify the runner is online:**
Go to GitHub → Settings → Actions → Runners → confirm `SynologyNAS-IQS` shows **Idle** (green dot).

### 3.9 Configure Auto-Start on Boot

**Method 1 — Task Scheduler (recommended for Synology):**

1. DSM → Control Panel → Task Scheduler
2. Click **Create → Triggered Task → User-defined script**
3. Settings:
   - **Task name:** `Lugh Stack Start`
   - **User:** `root`
   - **Event:** `Boot-up`
   - **Enabled:** checked
4. Task Settings tab → User-defined script:
   ```bash
   bash /volume1/docker/lugh/start.sh
   ```
5. Save

**Create the start script:**

```bash
cat > /volume1/docker/lugh/start.sh << 'EOF'
#!/bin/bash
# Lugh auto-start on NAS boot
sleep 30  # wait for Docker daemon to fully initialise
docker compose \
  -f /volume1/docker/lugh/docker-compose.prod.yml \
  --env-file /volume1/docker/lugh/.env \
  up -d --remove-orphans
EOF

chmod +x /volume1/docker/lugh/start.sh
```

---

## 4. Phase 2 — Network & Internet Access

### 4.1 Overview

The Lugh app communicates with the backend over HTTPS from anywhere in the world. This is achieved using **Cloudflare Tunnel** (`cloudflared`), which establishes an outbound-only encrypted connection from the NAS to Cloudflare's edge network. No port forwarding on the router is needed.

### 4.2 Install cloudflared on the NAS

```bash
# Download the latest cloudflared binary for Linux AMD64
curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 \
  -o /usr/local/bin/cloudflared

chmod +x /usr/local/bin/cloudflared
cloudflared --version
```

### 4.3 Option A — Quick Tunnel (Testing Only)

A quick tunnel gives you an immediate public HTTPS URL without any Cloudflare account configuration. The URL changes every time cloudflared restarts.

```bash
cloudflared tunnel --url http://localhost:9080 --no-autoupdate
```

The URL is printed to stdout:
```
+--------------------------------------------------------------------------------------------+
|  Your quick Tunnel has been created! Visit it at (it may take some time to be reachable): |
|  https://harder-independently-estimates-review.trycloudflare.com                          |
+--------------------------------------------------------------------------------------------+
```

> ⚠️ **WARNING:** Quick tunnel URLs are temporary and change on every restart. Every time the URL changes, you must update the `LUGH_SERVER_URL` GitHub secret and rebuild the mobile apps. Use Option B for production.

### 4.4 Option B — Permanent Named Tunnel (Production)

A permanent tunnel gives a stable subdomain (e.g. `https://lugh.hzortech.com`) that never changes.

**Prerequisites:** A domain managed in Cloudflare (free plan works).

```bash
# Authenticate with Cloudflare (opens browser — do on a machine with a browser,
# or copy the URL and open it elsewhere)
cloudflared tunnel login

# Create the tunnel (do this once, ever)
cloudflared tunnel create lugh

# Note the Tunnel ID from the output — you will need it.
# It looks like: a1b2c3d4-e5f6-7890-abcd-ef1234567890

# Create the DNS record pointing your subdomain to the tunnel
cloudflared tunnel route dns lugh lugh.hzortech.com

# Write the tunnel config
mkdir -p /etc/cloudflared
cat > /etc/cloudflared/config.yml << EOF
tunnel: <TUNNEL_ID>
credentials-file: /root/.cloudflared/<TUNNEL_ID>.json

ingress:
  - hostname: lugh.hzortech.com
    service: http://localhost:9080
  - service: http_status:404
EOF

# Run as a service
cloudflared service install
systemctl enable cloudflared
systemctl start cloudflared

# Verify
curl -s https://lugh.hzortech.com/health/
# Expected: {"status": "ok", ...}
```

### 4.5 Update the Server URL in GitHub Secrets

After getting the tunnel URL (permanent or quick), update the GitHub secret so the mobile apps know where to connect.

```bash
# On the development PC or any machine with gh CLI installed
gh secret set LUGH_SERVER_URL \
  --body "https://lugh.hzortech.com" \
  --repo IQS-LLC/phone-app
```

> 💡 **NOTE:** This secret is baked into the Android APK and iOS IPA at build time via `--dart-define=LUGH_SERVER_URL=...`. Any time the URL changes, both apps must be rebuilt and redistributed.

### 4.6 Firewall Configuration

The Synology firewall should allow inbound connections only from trusted sources. Cloudflare Tunnel removes the need to open any inbound ports for the app.

**DSM → Control Panel → Security → Firewall:**

| Rule | Action | Port | Source |
|---|---|---|---|
| Allow SSH | Allow | 22 | Admin IP only |
| Allow DSM Web | Allow | 5000, 5001 | Admin IP only |
| Allow Lugh API (LAN) | Allow | 9080 | LAN subnet |
| Deny all else | Deny | All | All |

> 💡 **NOTE:** Port 9080 does NOT need to be open on the internet-facing router. Cloudflare Tunnel handles internet access via an outbound connection from the NAS.

---

## 5. Phase 3 — Deploy the Backend Stack

### 5.1 Write the .env File

All secrets go into `/volume1/docker/lugh/.env`. This file is never committed to Git.

```bash
# Generate a strong Django SECRET_KEY
SECRET_KEY=$(python3 -c "import secrets, string; \
  chars = string.ascii_letters + string.digits + '!@#%^&*(-_=+)'; \
  print(''.join(secrets.choice(chars) for _ in range(60)))")

echo "Generated SECRET_KEY: $SECRET_KEY"

# Write the .env file
cat > /volume1/docker/lugh/.env << EOF
DOCKERHUB_USERNAME=shara-a
SECRET_KEY=${SECRET_KEY}
POSTGRES_PASSWORD=<YOUR_STRONG_PASSWORD>
DB_PASSWORD=<SAME_STRONG_PASSWORD>
EXTRA_ALLOWED_HOSTS=192.168.0.192,lugh.hzortech.com
PLC_IP=192.168.0.161
PLC_NETID=192.168.0.161.1.1
PLC_MOCK=false
PLC_DISCOVERY_SUBNETS=192.168.0.0/24
EOF

chmod 600 /volume1/docker/lugh/.env
```

> ⚠️ **WARNING:** `POSTGRES_PASSWORD` and `DB_PASSWORD` must be identical. They refer to the same database password — one is used by the Postgres container to initialise the DB, the other is used by Django to connect to it.

### 5.2 Copy the Compose and Nginx Files

The compose file and nginx config come from the repository. Copy them to the NAS deployment directory.

**Option A — If you have Git on the NAS:**
```bash
cd /tmp
git clone https://github.com/IQS-LLC/phone-app.git lugh-repo
cp lugh-repo/docker-compose.prod.yml /volume1/docker/lugh/
cp lugh-repo/nginx/nginx.conf        /volume1/docker/lugh/
rm -rf /tmp/lugh-repo
```

**Option B — Download directly:**
```bash
curl -fsSL \
  https://raw.githubusercontent.com/IQS-LLC/phone-app/main/docker-compose.prod.yml \
  -o /volume1/docker/lugh/docker-compose.prod.yml

curl -fsSL \
  https://raw.githubusercontent.com/IQS-LLC/phone-app/main/nginx/nginx.conf \
  -o /volume1/docker/lugh/nginx.conf
```

**Option C — Use the automated installer script:**
```bash
curl -fsSL \
  https://raw.githubusercontent.com/IQS-LLC/phone-app/main/scripts/nas-install.sh \
  | bash
```

> 💡 **NOTE:** The installer script (Option C) automates steps 5.1 through 5.6 interactively. It prompts for secrets, writes all config files, pulls images, starts the stack, and creates the Django superuser. Use it for first-time installations.

### 5.3 Pull Docker Images

```bash
docker compose \
  -f /volume1/docker/lugh/docker-compose.prod.yml \
  --env-file /volume1/docker/lugh/.env \
  pull
```

This pulls from Docker Hub:
- `shara-a/lugh-django:latest` — the backend application
- `postgres:15-alpine` — database
- `redis:7-alpine` — task queue
- `nginx:1.27-alpine` — reverse proxy

### 5.4 Start the Stack

```bash
docker compose \
  -f /volume1/docker/lugh/docker-compose.prod.yml \
  --env-file /volume1/docker/lugh/.env \
  up -d
```

The startup sequence is:
1. PostgreSQL starts first (healthcheck: `pg_isready`)
2. Redis starts (healthcheck: `redis-cli ping`)
3. Django starts only after both are healthy — it runs `migrate` and `collectstatic` on startup
4. Celery Worker and Celery Beat start after DB and Redis are healthy
5. Nginx starts after Django is healthy

### 5.5 Wait for Django to Become Healthy

```bash
# Watch Django health status (Ctrl+C when healthy)
watch -n 3 "docker inspect lugh_django --format '{{.State.Health.Status}}'"

# Or use this one-liner to wait up to 90 seconds
for i in $(seq 1 18); do
  STATUS=$(docker inspect lugh_django --format '{{.State.Health.Status}}' 2>/dev/null || echo "starting")
  echo "[${i}/18] Django: $STATUS"
  [ "$STATUS" = "healthy" ] && break
  sleep 5
done
```

### 5.6 Verify All Containers Are Healthy

```bash
docker compose \
  -f /volume1/docker/lugh/docker-compose.prod.yml \
  ps
```

Expected output (all containers `running (healthy)` or `running`):

```
NAME                 SERVICE          STATUS              PORTS
lugh_db              db               running (healthy)   5432/tcp
lugh_redis           redis            running (healthy)   6379/tcp
lugh_django          django           running (healthy)   8000/tcp
lugh_celery_worker   celery-worker    running             
lugh_celery_beat     celery-beat      running             
lugh_nginx           nginx            running (healthy)   0.0.0.0:9080->80/tcp
```

### 5.7 Create the Admin Superuser

```bash
docker compose \
  -f /volume1/docker/lugh/docker-compose.prod.yml \
  exec django \
  python manage.py createsuperuser
```

Follow the prompts. This creates the first `is_staff = True` (Tech Team) account.

> ⚠️ **WARNING:** Only staff accounts (`is_staff = True`) can access the Commissioning Wizard. Resident accounts are created later through the wizard, not through this command.

### 5.8 Verify the Health Endpoint

```bash
curl -s http://192.168.0.192:9080/health/
```

Expected response:
```json
{"status": "ok", "database": "ok", "redis": "ok", "plc_mode": "live"}
```

Also verify over the internet via the Cloudflare tunnel:

```bash
curl -s https://lugh.hzortech.com/health/
```

### 5.9 Verify the Django Admin Panel

Open a browser and navigate to:
```
http://192.168.0.192:9080/admin/
```

Log in with the superuser credentials created in step 5.7.

---

## 6. Phase 4 — CI/CD Pipeline (GitHub Actions)

### 6.1 What the Pipeline Does

Every push to the `main` branch triggers the following jobs in order:

```
push to main
    │
    ▼
┌─────────────────┐
│  Django Tests   │  Runs all 86 tests against PostgreSQL
└────────┬────────┘
         │ (all 4 jobs run in parallel after tests pass)
    ┌────┴──────────────────────┐
    │                           │
┌───▼───────────────┐  ┌───────▼──────────────┐
│ Build Django Image│  │  Build Android APK   │
│ → Docker Hub push │  │  (signed release)    │
└───────────────────┘  └──────────────────────┘
┌───────────────────┐
│  Build iOS IPA    │
│  (--no-codesign)  │
└───────────────────┘
         │
         ▼ (only if DEPLOY_ENABLED=true AND on main)
┌─────────────────────────────────────────────────────┐
│  Deploy to Production (self-hosted runner on NAS)   │
│  1. Write .env with secrets                         │
│  2. Copy compose + nginx files                      │
│  3. docker pull lugh-django:latest                  │
│  4. docker compose up -d --remove-orphans           │
│  5. Wait for healthy                                │
│  6. Health check                                    │
└─────────────────────────────────────────────────────┘
```

### 6.2 Required GitHub Secrets

Configure all secrets at: **GitHub repo → Settings → Secrets and variables → Actions**

| Secret Name | Value | Notes |
|---|---|---|
| `DOCKERHUB_USERNAME` | `shara-a` | Your Docker Hub handle |
| `DOCKERHUB_TOKEN` | `<token>` | Docker Hub → Security → New Token |
| `DJANGO_SECRET_KEY` | 60-char random string | Generate: `python3 -c "import secrets; print(secrets.token_urlsafe(50))"` |
| `DB_PASSWORD` | Strong password | Must match `.env` on NAS |
| `ANDROID_KEYSTORE_B64` | Base64 of `lugh-release.jks` | `base64 -w 0 lugh-release.jks` |
| `ANDROID_STORE_PASSWORD` | Keystore password | `Lugh@HzorTech2026!` |
| `ANDROID_KEY_ALIAS` | `lugh` | |
| `ANDROID_KEY_PASSWORD` | Key password | `Lugh@HzorTech2026!` |
| `LUGH_SERVER_URL` | `https://lugh.hzortech.com` | Baked into both APK and IPA at build time |
| `SERVER_HOST` | `192.168.0.192` | NAS LAN IP for deploy health check |

### 6.3 Enable Auto-Deploy

Auto-deploy to the NAS is controlled by a repository **variable** (not secret):

1. GitHub repo → Settings → **Variables** → **Actions**
2. Create variable: `DEPLOY_ENABLED` = `true`

To pause deployment without changing code, set it to `false`.

### 6.4 Downloading Build Artifacts

After each CI run, the signed APK and IPA are available as downloadable artifacts:

1. GitHub → **Actions** tab
2. Click the latest successful **CI/CD** run
3. Scroll to **Artifacts**
4. Download `lugh-android-apk` and `lugh-ios-ipa`

### 6.5 Creating a Release

To create a GitHub Release with the APK and IPA attached:

```bash
git tag v1.0.0
git push origin v1.0.0
```

This triggers the `release` job, which creates a release at:
```
https://github.com/IQS-LLC/phone-app/releases
```

### 6.6 Building Apps Locally (Without CI)

**Android (requires Flutter and Java 17 on Windows/macOS/Linux):**

```bash
cd flutter_application_plc
flutter build apk --release \
  "--dart-define=LUGH_SERVER_URL=https://lugh.hzortech.com" \
  --build-name="1.0.0" \
  --build-number="1"
# Output: build/app/outputs/flutter-apk/app-release.apk
```

**iOS (requires macOS with Xcode):**

```bash
cd flutter_application_plc
flutter build ios --release --no-codesign \
  "--dart-define=LUGH_SERVER_URL=https://lugh.hzortech.com"
# Package: zip -r lugh.ipa Payload/ (after copying Runner.app to Payload/)
```

---

## 7. Phase 5 — Beckhoff CX PLC Integration

### 7.1 Prerequisites

- Beckhoff CX device powered on and connected to the LAN
- TwinCAT 3 runtime installed on the CX
- PLC program deployed and set to **RUN** state
- NAS and CX on the **same subnet** (e.g. both on `192.168.0.x`)

### 7.2 Network Requirements

The NAS (Django backend) communicates with the PLC using the **ADS (Automation Device Specification)** protocol over TCP.

| Port | Direction | Purpose |
|---|---|---|
| 48898 | NAS → CX | ADS router port (always required) |
| 851 | NAS → CX | TwinCAT 3 PLC runtime port (default) |

Both ports must be reachable from the NAS to the CX. Test:

```bash
# Test from NAS to PLC
docker exec lugh_django nc -zv 192.168.0.161 48898
docker exec lugh_django nc -zv 192.168.0.161 851
```

Expected: `Connection to 192.168.0.161 48898 port [tcp/*] succeeded!`

### 7.3 Add ADS Route on the Beckhoff CX

The CX must know the NAS exists before ADS communication can work. Add a static route in TwinCAT System Manager.

**On a Windows engineering PC with TwinCAT installed:**

1. Open **TwinCAT System Manager** (or TwinCAT XAE)
2. Connect to the CX via the network (enter CX IP)
3. Go to **Routes** tab
4. Click **Add Route**
5. Fill in:
   - **Route Name:** `Lugh-NAS`
   - **AMS Net ID:** `192.168.0.192.1.1` ← NAS IP + `.1.1`
   - **Address:** `192.168.0.192` ← NAS LAN IP
   - **Transport type:** TCP/IP
6. Click **Add Route**

Alternatively, the backend can add the route programmatically (called automatically during commissioning):

```bash
# Test route addition via Django shell
docker exec lugh_django python manage.py shell -c "
from find_device.plc.ads_client import ADSClient
client = ADSClient('192.168.0.161.1.1', '192.168.0.161')
result = client.add_route('192.168.0.192.1.1', 'Lugh-NAS')
print('Route added:', result)
"
```

### 7.4 Verify the ADS Connection

```bash
docker exec lugh_django python manage.py shell -c "
from find_device.plc.ads_client import ADSClient
client = ADSClient('192.168.0.161.1.1', '192.168.0.161')
ok = client.connect()
print('Connected:', ok)
if ok:
    info = client.get_device_info()
    state = client.read_ads_state()
    print('Device:', info)
    print('ADS state:', state)
    client.disconnect()
"
```

Expected output when PLC is running:
```
Connected: True
Device: {'name': 'CX-12345', 'version': '3.1.4.68', 'major': 3, 'minor': 1}
ADS state: {'ads_state': 5, 'ads_state_name': 'RUN', 'device_state': 0}
```

ADS state `5 = RUN` means the PLC program is executing normally.

### 7.5 Configure PLC Connection in Docker Compose

The PLC IP and AMS Net ID are set in `/volume1/docker/lugh/.env` (already done in Phase 3) and referenced in `docker-compose.prod.yml`:

```yaml
PLC_MOCK:  "false"          # Use real PLC (not mock)
PLC_IP:    "192.168.0.161"  # PLC LAN IP address
PLC_NETID: "192.168.0.161.1.1"  # AMS Net ID
PLC_PORT:  "851"            # TwinCAT 3 runtime port
PLC_DISCOVERY_SUBNETS: "192.168.0.0/24"  # Subnet scanned by commissioning wizard
```

After changing these values, restart the stack:

```bash
docker compose -f /volume1/docker/lugh/docker-compose.prod.yml restart django celery-worker
```

### 7.6 PLC Variable Naming Convention

The Django backend accesses PLC variables by name using `read_by_name` / `write_by_name`. Your TwinCAT GVL (Global Variable List) structure must match the expected naming:

| GVL Name | Variable Type | Purpose |
|---|---|---|
| `gvlDALI` | `BYTE` array | DALI light channels (0–100 = brightness %) |
| `gvlRelays` | `BOOL` array | Wall relays (on/off) |
| `gvlHVAC` | `REAL` / `BOOL` | HVAC setpoints and states |
| `gvlAlarms` | `BOOL` array | Alarm trigger inputs |
| `gvlSensor` | `BOOL` / `REAL` | Door, window, motion sensors |
| `gvlMotor` | `INT` | Curtain motor commands (0=stop, 1=up, 2=down) |

Example variable names as they appear in ADS:
- `gvlDALI.channel_01` — DALI channel 1 brightness
- `gvlRelays.relay_03` — Wall relay 3
- `gvlSensor.door_living_room` — Living room door sensor

### 7.7 Discover PLC Symbols (via Commissioning Wizard)

The backend can enumerate all symbols from the PLC automatically. This is done through the Commissioning Wizard (Phase 7), but can also be tested directly:

```bash
docker exec lugh_django python manage.py shell -c "
from find_device.plc.ads_client import ADSClient
client = ADSClient('192.168.0.161.1.1', '192.168.0.161')
client.connect()
symbols = client.get_all_symbols()
print(f'Found {len(symbols)} symbols')
for s in symbols[:10]:
    print(f'  {s[\"full_name\"]}  ({s[\"type_name\"]})')
client.disconnect()
"
```

### 7.8 ADS Auto-Reconnect Behaviour

The `ADSClient` automatically handles connection loss:

- On any read/write failure: marks connection as lost, launches background reconnect thread
- Reconnect uses **exponential backoff**: 1s → 2s → 4s → 8s → ... → 60s (max)
- Successful reconnect resets the backoff counter
- Health status is available via `GET /health/` and the settings screen in the app

---

## 8. Phase 6 — Mobile Application Installation

### 8.1 Android — Install the APK

**Step 1: Enable Unknown Sources**
- Settings → Security → Install unknown apps → enable for your file manager or browser

**Step 2: Transfer the APK**
- Connect phone via USB and copy `Lugh-v1.0.0-android.apk` to the phone
- Or send via email/Telegram/WhatsApp and tap to download

**Step 3: Install**
- Open the file manager, navigate to the APK
- Tap it → Install
- Accept permissions → Open

**Step 4: Verify**
- Open the Lugh app
- The login screen should appear with "Lugh by IQS" branding
- If the app shows a network error immediately, the server URL baked into the APK does not match the running server — rebuild the APK with the correct `LUGH_SERVER_URL`

### 8.2 iOS — Install the IPA via AltStore

**Prerequisites on the iPhone:**
1. Install **AltStore** on the iPhone: [altstore.io](https://altstore.io)
   - Requires AltServer on a Windows or Mac connected to the same WiFi
2. Trust the AltStore developer certificate: Settings → General → VPN & Device Management → Trust

**Install the IPA:**
1. Open AltStore on the iPhone
2. Tap the **+** button (top-left)
3. Navigate to `Lugh-v1.0.0-ios.ipa`
4. Tap **Open** — AltStore installs the app
5. Trust the developer certificate: Settings → General → VPN & Device Management → IQS → Trust

> ⚠️ **WARNING:** IPA files installed via AltStore expire after 7 days (free Apple ID limit). To avoid this, use a paid Apple Developer account and distribute via TestFlight or enterprise distribution.

### 8.3 Connecting to the Backend

The server URL is baked in at build time. After installing the app:

1. Open Lugh
2. The app automatically connects to `https://lugh.hzortech.com` (or whatever URL was set at build)
3. Log in with credentials provided by the building administrator
4. If connection fails, the Settings screen (gear icon) shows the current server URL and connection status

### 8.4 App Login Flow

1. Open the app → Login screen appears
2. Enter username and password (provided by admin)
3. App receives a JWT access token (30-minute lifetime) and refresh token (7-day lifetime)
4. Tokens are stored securely — the app auto-refreshes the access token in the background
5. After login, the app navigates to the **Home** screen showing the resident's apartment

> 💡 **NOTE:** Residents cannot register themselves. All accounts are created by admin/staff users through the Commissioning Wizard or the Django admin panel. This is by design — the building administrator controls who has access.

---

## 9. Phase 7 — Commissioning

Commissioning is performed by a Tech Team member (staff user) using the Lugh app's **Commissioning Wizard**. It is run once per apartment when a new building or unit is set up.

### 9.1 Access the Commissioning Wizard

1. Log in to the app as a **staff user** (one with `is_staff = True` in Django)
2. On the Home screen, tap the amber **Commission** FAB (floating action button, bottom-right)
3. The 9-step wizard opens

> 💡 **NOTE:** The Commission FAB is only visible to staff users. Residents do not see it. The FAB is rendered based on `isStaff` from the JWT token — the backend enforces this on every API call regardless of what the app shows.

### 9.2 Commissioning Wizard — Step by Step

#### Step 1: Network Discovery

**Purpose:** Find Beckhoff CX devices on the building LAN.

- The backend scans the subnet configured in `PLC_DISCOVERY_SUBNETS` (e.g. `192.168.0.0/24`)
- Discovered PLCs appear in a list with their IP, hostname, and connection quality
- Already-registered PLCs are marked as such

**Checklist:**
- [ ] CX device appears in the scan results
- [ ] Connection quality shows **Excellent** or **Good** (latency < 50ms)
- [ ] Status shows **Unregistered** (for a new install)

**If PLC is not found:**
- Verify CX is powered on and connected to the LAN
- Verify `PLC_DISCOVERY_SUBNETS` matches your building LAN
- Test manually: `docker exec lugh_django nc -zv 192.168.0.161 48898`

#### Step 2: PLC Connectivity

**Purpose:** Register the CX and verify ADS communication.

- Enter (or confirm auto-filled): CX IP address, AMS Net ID, ADS port (851)
- The backend opens an ADS connection and reads device info
- ADS state must show **RUN**

**Checklist:**
- [ ] IP and AMS Net ID are correct
- [ ] ADS state = RUN (not STOP, CONFIG, or ERROR)
- [ ] Device name/version displayed (confirms real connection, not mock)

**If connectivity fails:**
- Verify the ADS route is configured on the CX (Section 7.3)
- Check firewall on both NAS and CX
- Ensure TwinCAT 3 runtime is in RUN mode (not CONFIG mode)

#### Step 3: Apartment Setup

**Purpose:** Create the apartment record and its rooms in the database.

- Enter apartment name (e.g. `Apartment 16`), building, and floor
- Add rooms (e.g. Living Room, Kitchen, Master Bedroom, Bathroom)
- Rooms can be added, renamed, or reordered

**Checklist:**
- [ ] Apartment created with correct name and floor
- [ ] All rooms added
- [ ] Room names match the physical space

#### Step 4: Symbol Discovery

**Purpose:** Read all PLC variables from the TwinCAT runtime and classify them.

- The backend calls `get_all_symbols()` via ADS
- Symbols are filtered (internal TwinCAT vars removed) and classified by type:
  - `gvlDALI.*` → DALI lighting channels
  - `gvlRelays.*` → Wall relays
  - `gvlSensor.*` → Door/window/motion sensors
  - `gvlAlarms.*` → Alarm inputs
  - `gvlMotor.*` → Curtain motors

**Checklist:**
- [ ] Symbol count is non-zero
- [ ] Expected GVL sections appear (DALI, Relays, Sensors)
- [ ] Symbol names match the PLC program's GVL structure

#### Step 5: Floor Plan

**Purpose:** Upload the apartment floor plan as a background image.

- Upload a PNG or JPEG of the floor plan (max 20 MB)
- The image is stored in `/volume1/docker/lugh/media/`
- It becomes the background for the Map Editor

**Checklist:**
- [ ] Floor plan image uploaded and displayed
- [ ] Image is correctly oriented (north = up or as marked on drawing)
- [ ] All rooms are visible on the plan

#### Step 6: Map Editor

**Purpose:** Place each discovered device on the floor plan.

- The floor plan is shown as a canvas
- Drag discovered PLC symbols onto the canvas as device icons
- Each placed device is linked to a symbol name, device type, and channel

**Checklist:**
- [ ] All DALI channels placed on the map (one icon per light/group)
- [ ] All relays placed (one icon per switch/appliance)
- [ ] All sensors placed (door, window, motion)
- [ ] All curtain motors placed
- [ ] Device labels are meaningful (e.g. "Living Room Ceiling Light", not "gvlDALI.ch01")

#### Step 7: I/O Commissioning — Physical Verification

**Purpose:** Verify every device by pulsing it and confirming physical response.

For each placed device, tap **Test**. The backend sends a brief pulse:

| Device Type | Test Action | Duration | Expected Physical Result |
|---|---|---|---|
| DALI light | Flash to 80% (or 20% if bright) | 1.5 seconds | Light flashes |
| Wall relay | Pulse ON | 0.8 seconds | Relay clicks, connected load activates |
| Curtain motor | Drive UP | 0.8 seconds | Curtain moves slightly upward |
| Door/Window sensor | Read current value | Instant | Shows OPEN or CLOSED |
| Motion sensor | Read current value | Instant | Shows ACTIVE or INACTIVE |

**Checklist (per room):**
- [ ] Living Room light — flashed ✓
- [ ] Living Room curtain — moved ✓
- [ ] Living Room door sensor — reads correctly ✓
- [ ] Kitchen light — flashed ✓
- [ ] Kitchen appliance relay — pulsed ✓
- [ ] Master Bedroom light — flashed ✓
- [ ] Bathroom light — flashed ✓
- [ ] *(add rows for each device in the apartment)*

> ⚠️ **WARNING:** During curtain motor testing, ensure no one is standing in the path of the curtain. The motor runs for 0.8 seconds and stops automatically.

#### Step 8: Resident Accounts

**Purpose:** Create Django user accounts for the apartment residents.

- For each resident, enter: username, email, password, role (owner/resident)
- Accounts are created with the apartment membership automatically set
- Residents **cannot** create their own accounts — only staff can do this

**Checklist:**
- [ ] Owner account created (role: `owner`)
- [ ] Additional residents created (role: `resident`) if applicable
- [ ] Temporary access accounts created with expiry dates if needed
- [ ] Test login for each resident (try logging in via the app)

#### Step 9: Handover

**Purpose:** Final review and commissioning certificate.

- The backend generates a summary of everything configured:
  - PLC details (IP, AMS Net ID, port, connection status)
  - All rooms with their device counts
  - All configured devices with types and channels
  - All resident accounts
  - Map published status
- The summary can be printed or photographed as the commissioning record

**Checklist:**
- [ ] All steps show **Done** in the checklist
- [ ] PLC status: Connected, ADS state = RUN
- [ ] All rooms present
- [ ] Device count matches physical count
- [ ] All residents listed
- [ ] Map published
- [ ] Hand over login credentials to residents

### 9.3 Post-Commissioning Verification (Resident App)

After commissioning, log in as a resident and verify:

- [ ] Home screen shows apartment name and room count
- [ ] All rooms visible in the room list
- [ ] Tapping a room shows correct devices
- [ ] Dimming a DALI light — physical light responds
- [ ] Toggling a relay — physical device responds
- [ ] Map view shows floor plan with device icons
- [ ] Real-time state updates — change a device physically, app updates within 5 seconds
- [ ] Settings screen shows correct role (Apartment Owner / Family Member)
- [ ] Settings shows correct connection status (Online / Mock PLC)

---

## 10. Phase 8 — Maintenance & Operations

### 10.1 Updating the Backend (Normal Code Push)

Every push to the `main` branch automatically:
1. Tests the new code
2. Builds a new Docker image tagged `:latest`
3. Pushes it to Docker Hub
4. (If `DEPLOY_ENABLED=true`) pulls the new image and restarts the stack on the NAS

**To trigger a deployment:**
```bash
git push origin main
# Watch CI at: https://github.com/IQS-LLC/phone-app/actions
```

**To check what is currently running:**
```bash
docker inspect lugh_django --format '{{.Image}}'
# Returns the image SHA currently running
```

### 10.2 Manual Update (Without CI)

```bash
# On the NAS as root
cd /volume1/docker/lugh

# Pull latest image
docker pull shara-a/lugh-django:latest

# Recreate only the Django container (zero-downtime approach)
docker compose -f docker-compose.prod.yml up -d --no-deps django

# Or restart the full stack
docker compose -f docker-compose.prod.yml up -d --remove-orphans
```

### 10.3 Rollback to a Previous Version

```bash
# List available tags on Docker Hub
docker images shara-a/lugh-django --format "table {{.Tag}}\t{{.CreatedAt}}"

# Roll back by pinning a specific SHA tag
# Edit docker-compose.prod.yml, change:
#   image: ${DOCKERHUB_USERNAME}/lugh-django:latest
# to:
#   image: shara-a/lugh-django:sha-<COMMIT_SHA>

docker compose -f docker-compose.prod.yml up -d --no-deps django
```

To roll back via Git:

```bash
# On the dev machine
git revert HEAD
git push origin main
# CI will build and deploy the reverted code
```

### 10.4 Database Backup

```bash
# Create a timestamped backup
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
docker exec lugh_db pg_dump \
  -U lugh_user \
  -d lugh_db \
  --format=custom \
  --no-acl \
  --no-owner \
  > /volume1/docker/lugh/backups/lugh_db_${TIMESTAMP}.dump

echo "Backup saved: lugh_db_${TIMESTAMP}.dump"
```

**Set up automatic daily backups:**

```bash
# Create backup script
cat > /volume1/docker/lugh/backup.sh << 'EOF'
#!/bin/bash
BACKUP_DIR=/volume1/docker/lugh/backups
mkdir -p "$BACKUP_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
docker exec lugh_db pg_dump \
  -U lugh_user -d lugh_db \
  --format=custom \
  > "${BACKUP_DIR}/lugh_db_${TIMESTAMP}.dump"
# Keep only the last 30 backups
ls -t "${BACKUP_DIR}"/lugh_db_*.dump | tail -n +31 | xargs -r rm
EOF
chmod +x /volume1/docker/lugh/backup.sh
```

Add to Synology Task Scheduler as a scheduled task:
- **Type:** Scheduled task
- **Schedule:** Daily at 03:00
- **Script:** `bash /volume1/docker/lugh/backup.sh`

### 10.5 Database Restore

```bash
# Restore from a backup file
docker exec -i lugh_db pg_restore \
  -U lugh_user \
  -d lugh_db \
  --clean \
  --if-exists \
  < /volume1/docker/lugh/backups/lugh_db_20260722_030000.dump
```

> ⚠️ **WARNING:** `--clean` drops and recreates all database objects before restoring. This will destroy current data. Stop the Django and Celery containers before restoring to prevent write conflicts:
> ```bash
> docker compose stop django celery-worker celery-beat
> # ... restore ...
> docker compose start django celery-worker celery-beat
> ```

### 10.6 Viewing Logs

```bash
# All containers, last 100 lines, follow
docker compose -f /volume1/docker/lugh/docker-compose.prod.yml logs --tail=100 -f

# Specific container
docker logs lugh_django --tail=100 -f
docker logs lugh_celery_worker --tail=100 -f
docker logs lugh_nginx --tail=100 -f

# Filter Django logs for errors only
docker logs lugh_django 2>&1 | grep -i error
```

### 10.7 Replacing a Beckhoff CX PLC

When a PLC is replaced with a new unit:

1. Install TwinCAT 3 runtime on the new CX
2. Deploy the PLC program to the new CX
3. Set TwinCAT to **RUN** state
4. The new CX will have the same IP (if configured identically) — if the IP changes:
   - Update `.env`: `PLC_IP=<new_ip>` and `PLC_NETID=<new_ip>.1.1`
   - Restart the stack: `docker compose restart django celery-worker`
   - In the app (as admin): Settings → Controllers → update IP and AMS Net ID
   - Run `POST /devices/<id>/test/` to verify
   - Add ADS route on new CX pointing to NAS (Section 7.3)

### 10.8 Replacing the NAS

1. Install DSM on the new NAS
2. Follow Phase 1 completely
3. Restore the Docker volumes from backup:
   ```bash
   # On the old NAS (if accessible):
   tar czf /tmp/lugh_volumes.tar.gz /volume1/docker/lugh/
   # Transfer to new NAS, then:
   tar xzf lugh_volumes.tar.gz -C /
   ```
4. The new NAS will have a different IP — update:
   - ADS route on the CX (replace old NAS IP with new NAS IP)
   - `EXTRA_ALLOWED_HOSTS` in `.env`
5. If using a permanent Cloudflare tunnel, update the tunnel's origin IP:
   ```bash
   cloudflared tunnel route ip add <NEW_NAS_IP>/32 lugh
   ```

### 10.9 Adding a New Apartment

1. Log in to the app as a staff user
2. Open the Commissioning Wizard
3. Select the apartment to commission (create new if needed)
4. Follow all 9 steps (Phase 7)
5. If the new apartment uses a different PLC:
   - Register the new PLCDevice via `POST /devices/`
   - Associate it with the new apartment

### 10.10 Replacing a Resident (Tenant Changeover)

1. Log in to the app as admin → Settings → User Management
2. Disable the departing resident's account:
   - Find the user → Disable (not delete — preserves audit logs)
3. Create a new account for the incoming resident (Commissioning Wizard → Step 8, or User Management → Add User)
4. Assign the new user to the apartment membership
5. Transfer or reset any personalised settings (scenes, automations) as needed

> 💡 **NOTE:** Admin and staff users can never be deleted through the app — only through the Django admin panel at `/admin/`. This prevents accidental lockout.

---

## 11. Troubleshooting

### 11.1 Django Container is Unhealthy

**Symptoms:** `docker ps` shows `lugh_django` as `unhealthy`. App shows 502 Bad Gateway.

**Diagnosis:**
```bash
docker logs lugh_django --tail=50
docker inspect lugh_django --format='{{json .State.Health}}'
```

**Common causes and fixes:**

| Cause | Log Indicator | Fix |
|---|---|---|
| Database not ready | `could not connect to server: Connection refused` | Wait for `lugh_db` to be healthy first |
| Wrong `DB_PASSWORD` | `FATAL: password authentication failed` | Check `.env` — `POSTGRES_PASSWORD` must equal `DB_PASSWORD` |
| Migration failed | `django.db.utils.ProgrammingError` | Run `docker exec lugh_django python manage.py migrate` manually |
| Missing `SECRET_KEY` | `RuntimeError: Refusing to start` | Set `SECRET_KEY` in `.env` |
| Port 8000 already in use | `Address already in use` | Check for another process on 8000: `ss -tlnp | grep 8000` |

### 11.2 Nginx Returns 502 Bad Gateway

**Symptoms:** Browser shows "502 Bad Gateway". `/health/` from outside returns 502.

**Diagnosis:**
```bash
docker logs lugh_nginx --tail=20
# Look for: connect() failed (111: Connection refused) while connecting to upstream
```

**Cause:** Nginx is running but Django is not healthy (or just restarted).

**Fix:**
```bash
# Wait for Django to become healthy, then reload nginx
docker inspect lugh_django --format='{{.State.Health.Status}}'
# When "healthy":
docker exec lugh_nginx nginx -s reload
```

> 💡 **NOTE:** After a full stack restart, nginx resolves the Django container's IP. If Django's IP changes (happens when recreating the container), nginx needs a reload to pick up the new IP.

### 11.3 Celery Tasks Not Running

**Symptoms:** Alarms not triggering. Notifications not sent. Housekeeping tasks not running.

**Diagnosis:**
```bash
docker logs lugh_celery_worker --tail=50
docker logs lugh_celery_beat --tail=50

# Check if Celery can reach Redis
docker exec lugh_celery_worker python -c "
import redis; r = redis.from_url('redis://redis:6379/0'); print(r.ping())
"
```

**Common causes:**
- Redis is down → `docker restart lugh_redis`
- Celery Beat not running → `docker restart lugh_celery_beat`
- Wrong Redis URL → check `REDIS_URL` in compose file

### 11.4 ADS Connection Fails

**Symptoms:** PLC Connectivity step in wizard shows error. App shows "PLC Disconnected". `GET /health/` shows `"plc_mode": "disconnected"`.

**Diagnosis:**
```bash
# Test TCP connectivity
docker exec lugh_django nc -zv 192.168.0.161 48898
docker exec lugh_django nc -zv 192.168.0.161 851

# Check Django logs for ADS errors
docker logs lugh_django 2>&1 | grep -i "ads\|pyads\|ams"

# Test ADS from Django shell
docker exec lugh_django python manage.py shell -c "
import pyads
conn = pyads.Connection('192.168.0.161.1.1', pyads.PORT_TC3PLC1, '192.168.0.161')
conn.open()
print('State:', conn.read_state())
conn.close()
"
```

**Common causes and fixes:**

| Symptom | Cause | Fix |
|---|---|---|
| `nc` fails on port 48898 | No network path or firewall | Check CX firewall, LAN cables, switch |
| `nc` succeeds but ADS fails | ADS route not configured on CX | Add route (Section 7.3) |
| Route exists but still fails | PLC not in RUN state | Set TwinCAT to RUN mode |
| Intermittent disconnects | Network instability | Check switch, cables; auto-reconnect will recover |

### 11.5 Mobile App Cannot Connect to Backend

**Symptoms:** App shows "Cannot connect to server" or login fails immediately.

**Diagnosis:**
```bash
# Verify tunnel is active
curl -s https://lugh.hzortech.com/health/

# Check cloudflared status
systemctl status cloudflared
# Or for quick tunnel:
ps aux | grep cloudflared
```

**Common causes:**

| Symptom | Cause | Fix |
|---|---|---|
| `curl` fails from outside | Cloudflare tunnel down | Restart cloudflared |
| `curl` works but app fails | Wrong URL baked into APK | Rebuild APK with correct `LUGH_SERVER_URL` |
| Login 401 | Wrong credentials | Verify username/password in Django admin |
| Login 503 | Django unhealthy | Fix Django container (Section 11.1) |
| CORS error | Origin not in `CORS_ALLOWED_ORIGINS` | Add the tunnel URL to `CORS_ALLOWED_ORIGINS` in `.env` |

### 11.6 Quick Tunnel URL Changed

**Symptoms:** App worked yesterday, now shows connection error. The Cloudflare tunnel was restarted.

**Fix:**
1. Get new tunnel URL from cloudflared logs: `ps aux | grep cloudflared` then check metrics at `http://localhost:2000/metrics`
2. Update GitHub secret:
   ```bash
   gh secret set LUGH_SERVER_URL --body "https://new-url.trycloudflare.com" --repo IQS-LLC/phone-app
   ```
3. Trigger a new build:
   ```bash
   git commit --allow-empty -m "chore: rebuild apps with new tunnel URL"
   git push origin main
   ```
4. Download new APK/IPA from CI artifacts and reinstall

> 💡 **NOTE:** This problem is eliminated by setting up a permanent named tunnel (Section 4.4).

### 11.7 Database is Full / Disk Space Issue

**Diagnosis:**
```bash
df -h /volume1
docker exec lugh_db psql -U lugh_user -d lugh_db -c "
SELECT pg_size_pretty(pg_database_size('lugh_db')) AS db_size;
"
```

**Fix:**
```bash
# Clean up old Docker images
docker image prune -a --filter "until=720h"  # Remove images older than 30 days

# Vacuum the database
docker exec lugh_db psql -U lugh_user -d lugh_db -c "VACUUM ANALYZE;"

# Clear old audit logs (if audit log table exists)
docker exec lugh_django python manage.py shell -c "
from find_device.models import AuditLog
import datetime
cutoff = datetime.datetime.now() - datetime.timedelta(days=90)
deleted, _ = AuditLog.objects.filter(created_at__lt=cutoff).delete()
print(f'Deleted {deleted} old audit log entries')
"
```

### 11.8 GitHub Actions CI Fails

**Diagnosis:** Go to GitHub → Actions → click the failed run → expand the failed job → read the log.

**Common failures:**

| Job | Failure | Fix |
|---|---|---|
| Django Tests | `makemigrations --check` fails | Run `python manage.py makemigrations` locally, commit the new migration |
| Django Tests | Test assertion fails | Fix the failing test or the code it tests |
| Build Django Image | Docker Hub auth failed | Regenerate `DOCKERHUB_TOKEN` secret |
| Build Android APK | `ANDROID_KEYSTORE_B64` invalid | Re-encode keystore: `base64 -w 0 lugh-release.jks` then set secret |
| Deploy | Runner offline | Check NAS runner status; restart: `cd /volume1/docker/lugh/runner && ./svc.sh start` |
| Deploy | `docker pull` fails | Docker Hub rate limit or image not pushed yet; wait and retry |

---

## 12. Reference

### 12.1 Complete Environment Variable Reference

| Variable | Required | Default | Description |
|---|---|---|---|
| `SECRET_KEY` | Yes | (insecure default) | Django cryptographic secret. Min 50 chars. Generate with `secrets.token_urlsafe(50)` |
| `DEBUG` | No | `True` | Set to `false` in production. When false, `SECRET_KEY` env var is required |
| `DB_ENGINE` | No | `sqlite3` | Use `django.db.backends.postgresql` in production |
| `DB_NAME` | No | `db.sqlite3` | Database name. Use `lugh_db` in production |
| `DB_USER` | No | — | Database username. Use `lugh_user` in production |
| `DB_PASSWORD` | Yes | — | Database password. Must match `POSTGRES_PASSWORD` |
| `DB_HOST` | No | — | Database hostname. Use `db` (Docker service name) |
| `DB_PORT` | No | — | Database port. Use `5432` |
| `REDIS_URL` | No | `redis://localhost:6379/0` | Redis connection URL. Use `redis://redis:6379/0` |
| `EXTRA_ALLOWED_HOSTS` | No | — | Comma-separated hostnames/IPs to add to `ALLOWED_HOSTS` |
| `CORS_ALLOWED_ORIGINS` | No | — | Comma-separated allowed CORS origins (e.g. `https://lugh.hzortech.com`) |
| `PLC_MOCK` | No | `True` | Set to `false` to connect to a real PLC |
| `PLC_IP` | Yes (live) | — | Beckhoff CX IP address |
| `PLC_NETID` | Yes (live) | — | Beckhoff CX AMS Net ID (format: `x.x.x.x.1.1`) |
| `PLC_PORT` | No | `851` | TwinCAT 3 runtime ADS port |
| `PLC_DISCOVERY_SUBNETS` | No | — | CIDR subnet(s) to scan in Commissioning Wizard |
| `WEB_CONCURRENCY` | No | `1` | Gunicorn worker count. **Must stay at 1** (in-memory DeviceRegistry) |
| `TIME_ZONE` | No | `UTC` | Django timezone for scheduled tasks |
| `LOG_LEVEL` | No | `INFO` (prod) | Logging verbosity: `DEBUG`, `INFO`, `WARNING`, `ERROR` |
| `HTTPS_ENABLED` | No | `False` | Set to `true` to enable Django HSTS/secure cookie headers |

### 12.2 Useful Commands Reference

**Stack management:**
```bash
# Start
docker compose -f /volume1/docker/lugh/docker-compose.prod.yml up -d

# Stop
docker compose -f /volume1/docker/lugh/docker-compose.prod.yml down

# Restart one service
docker compose -f /volume1/docker/lugh/docker-compose.prod.yml restart django

# View all container statuses
docker compose -f /volume1/docker/lugh/docker-compose.prod.yml ps

# Pull latest images
docker compose -f /volume1/docker/lugh/docker-compose.prod.yml pull
```

**Django management:**
```bash
# Run a management command
docker exec lugh_django python manage.py <command>

# Open Django shell
docker exec -it lugh_django python manage.py shell

# Run migrations
docker exec lugh_django python manage.py migrate

# Create superuser
docker exec -it lugh_django python manage.py createsuperuser

# Collect static files
docker exec lugh_django python manage.py collectstatic --noinput

# Check for migration issues
docker exec lugh_django python manage.py makemigrations --check --dry-run
```

**Database:**
```bash
# Open PostgreSQL shell
docker exec -it lugh_db psql -U lugh_user -d lugh_db

# Backup
docker exec lugh_db pg_dump -U lugh_user -d lugh_db --format=custom > backup.dump

# Restore
docker exec -i lugh_db pg_restore -U lugh_user -d lugh_db --clean < backup.dump
```

**Logs:**
```bash
# Follow all logs
docker compose -f /volume1/docker/lugh/docker-compose.prod.yml logs -f

# Django errors only
docker logs lugh_django 2>&1 | grep -E "ERROR|CRITICAL|Exception"

# Nginx access log
docker logs lugh_nginx

# Celery task execution
docker logs lugh_celery_worker | grep "Task"
```

**Health checks:**
```bash
# Local health check
curl http://192.168.0.192:9080/health/

# Remote health check (via tunnel)
curl https://lugh.hzortech.com/health/

# Nginx internal health
curl http://192.168.0.192:9080/nginx-health
```

### 12.3 Container Name Reference

| Container Name | Service | Image |
|---|---|---|
| `lugh_django` | Django API + Gunicorn | `shara-a/lugh-django:latest` |
| `lugh_db` | PostgreSQL 15 | `postgres:15-alpine` |
| `lugh_redis` | Redis 7 | `redis:7-alpine` |
| `lugh_nginx` | Nginx 1.27 | `nginx:1.27-alpine` |
| `lugh_celery_worker` | Celery Worker | `shara-a/lugh-django:latest` |
| `lugh_celery_beat` | Celery Beat Scheduler | `shara-a/lugh-django:latest` |

### 12.4 File Location Reference

| File | Location | Purpose |
|---|---|---|
| Environment variables | `/volume1/docker/lugh/.env` | All secrets and config |
| Docker Compose | `/volume1/docker/lugh/docker-compose.prod.yml` | Stack definition |
| Nginx config | `/volume1/docker/lugh/nginx.conf` | Reverse proxy config |
| PostgreSQL data | `/volume1/docker/lugh/postgres_data/` | Database files (do not touch) |
| Redis data | `/volume1/docker/lugh/redis_data/` | Queue persistence |
| Static files | `/volume1/docker/lugh/static/` | Django admin CSS/JS |
| Media files | `/volume1/docker/lugh/media/` | Floor plan images |
| Auto-start script | `/volume1/docker/lugh/start.sh` | Boot startup script |
| Backup directory | `/volume1/docker/lugh/backups/` | DB backup files |
| GitHub runner | `/volume1/docker/lugh/runner/` | CI/CD self-hosted runner |

### 12.5 JWT Token Reference

| Token | Lifetime | Purpose |
|---|---|---|
| Access Token | 30 minutes | Sent with every API request in `Authorization: Bearer <token>` header |
| Refresh Token | 7 days | Used to obtain a new access token without re-entering credentials |

Tokens are automatically managed by the Flutter app. A resident stays logged in for up to 7 days without any action.

### 12.6 Celery Queue Reference

| Queue | Purpose | Worker |
|---|---|---|
| `plc` | PLC polling, device state updates | Celery Worker |
| `alarms` | Alarm detection and processing | Celery Worker |
| `notifications` | Push notification delivery | Celery Worker |
| `housekeeping` | Session cleanup, audit log archival, expired access removal | Celery Beat (scheduled) |

---

*End of Document — Lugh by IQS Installation & Deployment Manual v1.0*

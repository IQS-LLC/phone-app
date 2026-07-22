# Lugh by IQS
## Complete Installation, Deployment, Commissioning & Maintenance Manual

**Document version:** 1.1  
**Platform version:** As of commit `3119ae9`  
**Target hardware:** Synology RS822+ (DSM 7.2+)  
**Audience:** System installers, DevOps engineers, system administrators

---

> **How to use this document**  
> Follow the phases in order on a brand-new server. Every command is shown exactly as it must be typed.  
> Sections marked ⚠️ **WARNING** must not be skipped. Sections marked 💡 **NOTE** provide context.

---

## ★ FILL THIS IN BEFORE YOU START

**Every IP address, hostname, and identifier used in this manual is a placeholder. Fill in the table below with your actual values before executing any command. Then substitute them everywhere you see `< >` brackets.**

| Placeholder | Your Value | What It Is |
|---|---|---|
| `<NAS_IP>` | __________ | LAN IP of the Synology NAS (e.g. `10.0.0.50`) |
| `<NAS_AMS_NET_ID>` | __________ | Always `<NAS_IP>.1.1` (e.g. `10.0.0.50.1.1`) |
| `<PLC_IP>` | __________ | LAN IP of the Beckhoff CX (e.g. `10.0.0.100`) |
| `<PLC_AMS_NET_ID>` | __________ | Always `<PLC_IP>.1.1` (e.g. `10.0.0.100.1.1`) |
| `<LAN_SUBNET>` | __________ | Building LAN in CIDR notation (e.g. `10.0.0.0/24`) |
| `<TUNNEL_URL>` | __________ | Full public HTTPS URL (e.g. `https://lugh.example.com`) |
| `<TUNNEL_DOMAIN>` | __________ | Domain only, no protocol (e.g. `lugh.example.com`) |
| `<DOCKERHUB_USERNAME>` | __________ | Your Docker Hub username |
| `<GITHUB_REPO>` | __________ | Your GitHub repo (e.g. `IQS-LLC/phone-app`) |
| `<DB_PASSWORD>` | __________ | Strong password you choose for PostgreSQL |
| `<ADMIN_USERNAME>` | __________ | First Django superuser username |
| `<ADMIN_EMAIL>` | __________ | First Django superuser email |
| `<ADMIN_PASSWORD>` | __________ | First Django superuser password |

> **Where each value is used and how to change it — complete file and line reference:**
>
> ---
>
> **`<NAS_IP>`** — 5 locations
>
> | # | File / Location | Line | Current hardcoded value | Action |
> |---|---|---|---|---|
> | 1 | `/volume1/docker/lugh/.env` on NAS | `EXTRA_ALLOWED_HOSTS=` | your NAS IP | `nano /volume1/docker/lugh/.env` → edit that line → then run: `docker compose -f /volume1/docker/lugh/docker-compose.prod.yml restart django` |
> | 2 | `docker-compose.prod.yml` | 36 | `"192.168.0.192,192.168.0.158,localhost"` | Replace `192.168.0.192` with `<NAS_IP>` → commit and push |
> | 3 | `PLC_Project/settings.py` | 33 | `"192.168.0.158"` | Replace with `<NAS_IP>` (hardcoded in `ALLOWED_HOSTS`, the env var cannot override it) → commit and push |
> | 4 | GitHub secret `SERVER_HOST` | (GitHub UI, no file) | old NAS IP | Repo → Settings → Secrets and variables → Actions → `SERVER_HOST` → Update. Used by `.github/workflows/deploy.yml` line 381 for health check. |
> | 5 | Beckhoff CX ADS route | TwinCAT System Manager (no file) | old NAS IP | On engineering PC: TwinCAT System Manager → connect to CX at `<PLC_IP>` → Routes tab → delete old entry → Add Route: Name=`Lugh-NAS`, AMS Net ID=`<NAS_AMS_NET_ID>`, IP=`<NAS_IP>`, Transport=TCP/IP |
>
> ---
>
> **`<PLC_IP>`** — 4 locations
>
> | # | File / Location | Line | Current hardcoded value | Action |
> |---|---|---|---|---|
> | 1 | `/volume1/docker/lugh/.env` on NAS | `PLC_IP=` | old PLC IP | `nano /volume1/docker/lugh/.env` → edit `PLC_IP=<PLC_IP>` → then run: `docker compose -f /volume1/docker/lugh/docker-compose.prod.yml restart django celery-worker` |
> | 2 | `docker-compose.prod.yml` | 38 | `"192.168.0.161"` | Replace with `<PLC_IP>` → commit and push |
> | 3 | `PLC_Project/settings.py` | 34 | `"192.168.0.161"` | Replace with `<PLC_IP>` (hardcoded in `ALLOWED_HOSTS`) → commit and push |
> | 4 | PLCDevice record in database | app UI (no file) | old IP stored in DB | App → Settings → Controllers → tap the device → Edit → update IP field → Save → Test Connection |
>
> ---
>
> **`<PLC_AMS_NET_ID>`** — 3 locations
>
> | # | File / Location | Line | Current hardcoded value | Action |
> |---|---|---|---|---|
> | 1 | `/volume1/docker/lugh/.env` on NAS | `PLC_NETID=` | old AMS Net ID | `nano /volume1/docker/lugh/.env` → edit `PLC_NETID=<PLC_AMS_NET_ID>` (always `<PLC_IP>.1.1`) → then run: `docker compose -f /volume1/docker/lugh/docker-compose.prod.yml restart django celery-worker` |
> | 2 | `docker-compose.prod.yml` | 39 | `"192.168.0.161.1.1"` | Replace with `<PLC_AMS_NET_ID>` → commit and push |
> | 3 | PLCDevice record in database | app UI (no file) | old AMS Net ID stored in DB | App → Settings → Controllers → tap the device → Edit → update AMS Net ID field → Save → Test Connection |
>
> ---
>
> **`<LAN_SUBNET>`** — 2 locations
>
> | # | File / Location | Line | Current hardcoded value | Action |
> |---|---|---|---|---|
> | 1 | `/volume1/docker/lugh/.env` on NAS | `PLC_DISCOVERY_SUBNETS=` | old subnet | `nano /volume1/docker/lugh/.env` → edit `PLC_DISCOVERY_SUBNETS=<LAN_SUBNET>` → then run: `docker compose -f /volume1/docker/lugh/docker-compose.prod.yml restart django` |
> | 2 | `docker-compose.prod.yml` | 43 | `"192.168.0.0/24"` | Replace with `<LAN_SUBNET>` → commit and push |
>
> ---
>
> **`<TUNNEL_URL>`** — 2 locations (no file edit — requires app rebuild after secret update)
>
> | # | Location | Action |
> |---|---|---|
> | 1 | GitHub secret `LUGH_SERVER_URL` | Run: `gh secret set LUGH_SERVER_URL --body "https://<TUNNEL_DOMAIN>" --repo <GITHUB_REPO>` |
> | 2 | Baked into APK + IPA at build time | After secret update, push any commit to `main` to trigger rebuild. Download new APK/IPA from GitHub → Actions → latest run → Artifacts → `lugh-android-apk` / `lugh-ios-ipa`. Redistribute to all users — **old apps cannot be redirected without reinstall.** |
>
> ---
>
> **`<DOCKERHUB_USERNAME>`** — 3 locations
>
> | # | File / Location | Line | Action |
> |---|---|---|---|
> | 1 | `/volume1/docker/lugh/.env` on NAS | `DOCKERHUB_USERNAME=` | `nano /volume1/docker/lugh/.env` → update → then run: `docker compose -f /volume1/docker/lugh/docker-compose.prod.yml pull && docker compose -f /volume1/docker/lugh/docker-compose.prod.yml up -d` |
> | 2 | `docker-compose.prod.yml` | 82, 110, 130 | Already reads `${DOCKERHUB_USERNAME}` from `.env` — no edit needed if `.env` is updated |
> | 3 | GitHub secret `DOCKERHUB_USERNAME` | (GitHub UI) | Repo → Settings → Secrets → `DOCKERHUB_USERNAME` → update. Also regenerate and update `DOCKERHUB_TOKEN` if the Docker Hub account changed. |

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
| Reverse Proxy | Nginx 1.27 | Static files, SSE, proxying |
| Internet Tunnel | Cloudflare Tunnel (`cloudflared`) | Secure internet access without port forwarding |
| PLC Communication | pyADS 3.5.2 | ADS/AMS protocol to Beckhoff CX |
| Mobile App | Flutter (Android + iOS) | Resident and tech team interface |
| CI/CD | GitHub Actions | Automated testing, image builds, deployment |
| Registry | Docker Hub | Docker image distribution |

### 1.2 Network Topology

```
                    ┌─────────────────────────────────────────┐
                    │              INTERNET                   │
                    └──────────────────┬──────────────────────┘
                                       │ HTTPS
                                       │ (Cloudflare Edge)
                    ┌──────────────────▼──────────────────────┐
                    │         CLOUDFLARE TUNNEL               │
                    │   cloudflared running on NAS            │
                    │   Public URL: <TUNNEL_URL>              │
                    └──────────────────┬──────────────────────┘
                                       │ HTTP → localhost:9080
                    ┌──────────────────▼──────────────────────┐
                    │         SYNOLOGY NAS                    │
                    │         <NAS_IP>                        │
                    │                                         │
                    │  ┌─────────────────────────────────┐   │
                    │  │  Docker Stack (lugh_net bridge) │   │
                    │  │                                 │   │
                    │  │  lugh_nginx      :9080→80       │   │
                    │  │      ↓ proxy_pass               │   │
                    │  │  lugh_django     :8000          │   │
                    │  │      ↓              ↓           │   │
                    │  │  lugh_db        lugh_redis      │   │
                    │  │  :5432          :6379           │   │
                    │  │      ↑              ↑           │   │
                    │  │  lugh_celery_worker             │   │
                    │  │  lugh_celery_beat               │   │
                    │  └─────────────────────────────────┘   │
                    └──────────────────┬──────────────────────┘
                                       │ ADS/AMS  TCP:48898 + TCP:851
                    ┌──────────────────▼──────────────────────┐
                    │      BUILDING LAN  <LAN_SUBNET>         │
                    │                                         │
                    │  Beckhoff CX  <PLC_IP>                  │
                    │  AMS Net ID:  <PLC_AMS_NET_ID>          │
                    │  TwinCAT 3 Runtime — RUN state          │
                    └──────────────────┬──────────────────────┘
                                       │ Physical I/O
                    ┌──────────────────▼──────────────────────┐
                    │  DALI lights, wall relays, curtains,    │
                    │  door/window sensors, wall switches     │
                    └─────────────────────────────────────────┘

         Resident + Tech Team phones
         HTTPS to <TUNNEL_URL>
```

### 1.3 Communication Flow

```
Resident taps "Dim to 50%"
    ↓  HTTPS POST to <TUNNEL_URL>/plc/{apt}/control/
Cloudflare Tunnel
    ↓  HTTP → <NAS_IP>:9080
Nginx → Django (JWT verified, membership checked)
    ↓  Python → DeviceRegistry → pyADS
ADS TCP → <PLC_IP>:48898
    ↓
TwinCAT PLC executes → DALI ballast dims
    ↑
New state pushed back via SSE to app
```

### 1.4 Port Reference

| Port | Protocol | Service | Accessible From |
|---|---|---|---|
| 9080 | TCP | Nginx (HTTP) | LAN + Cloudflare Tunnel |
| 8000 | TCP | Django/Gunicorn | Docker internal only |
| 5432 | TCP | PostgreSQL | Docker internal only |
| 6379 | TCP | Redis | Docker internal only |
| 48898 | TCP | ADS Router (Beckhoff) | Building LAN only |
| 851 | TCP | TwinCAT 3 PLC Runtime | Building LAN only |
| 22 | TCP | NAS SSH | Admin workstation only |

---

## 2. Phase 0 — Prerequisites & Hardware

### 2.1 Hardware Required

| Item | Minimum Spec | Notes |
|---|---|---|
| NAS Server | Synology RS822+ | DSM 7.2 or later |
| RAM | 4 GB | 8 GB recommended |
| Storage | 10 GB free on `/volume1` | For images, DB, logs, media |
| Network | 100 Mbps LAN | NAS and PLC on same switch |
| Beckhoff CX | Any CX series | TwinCAT 3 runtime required |
| Android phone | Android 7.0+ | For APK installation |
| iOS phone | iOS 14.0+ | AltStore or Sideloadly required |

### 2.2 Accounts to Create Before Starting

| Account | URL | Used For |
|---|---|---|
| Docker Hub | hub.docker.com | Image registry for Django container |
| GitHub | github.com | Source code, CI/CD, secrets |
| Cloudflare | cloudflare.com | Internet tunnel (free tier is enough) |

### 2.3 Network Information to Confirm Before Starting

Before touching the server, confirm and write into the table at the top of this document:

- The NAS's LAN IP (`<NAS_IP>`) — check your router's DHCP table or assign a static IP
- The PLC's LAN IP (`<PLC_IP>`) — set in TwinCAT System Manager or on the CX display
- The AMS Net ID of the PLC (`<PLC_AMS_NET_ID>`) — always `<PLC_IP>.1.1`
- The AMS Net ID the NAS will use (`<NAS_AMS_NET_ID>`) — always `<NAS_IP>.1.1`
- The building LAN subnet (`<LAN_SUBNET>`) — e.g. `10.0.0.0/24`

> ⚠️ **WARNING:** If you assign the NAS a DHCP address that can change, the ADS route on the CX and the CORS configuration will break after a reboot. Assign the NAS a static LAN IP before continuing.

---

## 3. Phase 1 — Synology NAS First-Time Setup

### 3.1 Enable SSH

1. Log into DSM at `http://<NAS_IP>:5000`
2. **Control Panel → Terminal & SNMP → Enable SSH service**
3. Set port to `22`, click Apply

### 3.2 SSH Into the NAS

```bash
ssh Administrator@<NAS_IP>
# Enter your DSM Administrator password
sudo -i
# All Phase 1 commands run as root
```

**To change the NAS IP later:**  
Update your router's DHCP reservation or the NAS static IP in DSM → Network Interface. Then update `EXTRA_ALLOWED_HOSTS` in `/volume1/docker/lugh/.env` and restart: `docker compose restart django`. Also update the ADS route on the CX (Section 7.3).

### 3.3 Verify DSM Version

```bash
synoinfo get_section_key_value /etc/synoinfo.conf majorversion
# Must return 7 or higher
```

### 3.4 Install Docker (Container Manager)

1. DSM → Package Center → search **Container Manager** → Install
2. Wait for completion, then verify:

```bash
docker --version
docker compose version
```

> 💡 Always use `docker compose` (space, Compose v2 plugin). Never `docker-compose` (hyphen, legacy).

### 3.5 Fix Docker Socket Permissions

Synology resets `/var/run/docker.sock` to `root:root 660` on every reboot. The GitHub runner needs group access.

```bash
# Create docker group and add your admin user
synogroup --add docker 2>/dev/null || true
synogroup --member docker Administrator

# Verify
id Administrator | grep docker

# Install a boot-time fix script
cat > /usr/local/etc/rc.d/fix-docker-sock.sh << 'EOF'
#!/bin/bash
sleep 10
chown root:docker /var/run/docker.sock
chmod 660 /var/run/docker.sock
EOF

chmod +x /usr/local/etc/rc.d/fix-docker-sock.sh
```

> ⚠️ **WARNING:** Never use `chmod 666` on the Docker socket. It gives every process on the machine root-equivalent access to the Docker daemon.

### 3.6 Create the Directory Layout

```bash
mkdir -p /volume1/docker/lugh/{postgres_data,redis_data,static,media,backups}
chmod 750 /volume1/docker/lugh
ls -la /volume1/docker/lugh/
```

### 3.7 Install the GitHub Actions Self-Hosted Runner

This runner is what makes CI/CD deploy automatically to your NAS.

**On GitHub:**
1. Repo → **Settings → Actions → Runners → New self-hosted runner**
2. Select Linux / x64
3. Note the registration token (valid for 1 hour)

**On the NAS:**

```bash
mkdir -p /volume1/docker/lugh/runner
cd /volume1/docker/lugh/runner

# Download runner (use URL shown by GitHub, not this placeholder)
curl -o actions-runner.tar.gz -L \
  https://github.com/actions/runner/releases/download/v2.317.0/actions-runner-linux-x64-2.317.0.tar.gz

tar xzf actions-runner.tar.gz

# Configure — substitute your repo and token
./config.sh \
  --url https://github.com/<GITHUB_REPO> \
  --token <REGISTRATION_TOKEN_FROM_GITHUB> \
  --labels synology \
  --name Synology-Lugh \
  --unattended

# Install and start as a system service
./svc.sh install
./svc.sh start

# Verify
./svc.sh status
```

**Verify on GitHub:** Repo → Settings → Actions → Runners → runner shows **Idle** (green dot).

**To change the runner's registered repo later:**  
```bash
cd /volume1/docker/lugh/runner
./svc.sh stop
./config.sh remove --token <REMOVE_TOKEN>
./config.sh --url https://github.com/<NEW_REPO> --token <NEW_REGISTRATION_TOKEN> --labels synology
./svc.sh start
```

### 3.8 Configure Auto-Start on Boot

```bash
# Write the boot script
cat > /volume1/docker/lugh/start.sh << 'EOF'
#!/bin/bash
sleep 30
docker compose \
  -f /volume1/docker/lugh/docker-compose.prod.yml \
  --env-file /volume1/docker/lugh/.env \
  up -d --remove-orphans
EOF
chmod +x /volume1/docker/lugh/start.sh
```

**Register in Task Scheduler:**
1. DSM → Control Panel → Task Scheduler → Create → Triggered Task → User-defined script
2. Event: `Boot-up` | User: `root` | Enabled: yes
3. Script: `bash /volume1/docker/lugh/start.sh`
4. Save

---

## 4. Phase 2 — Network & Internet Access

### 4.1 Install cloudflared

```bash
curl -L \
  https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 \
  -o /usr/local/bin/cloudflared
chmod +x /usr/local/bin/cloudflared
cloudflared --version
```

### 4.2 Option A — Quick Tunnel (Testing / Temporary)

Use this to get a working URL immediately. The URL changes every restart.

```bash
cloudflared tunnel --url http://localhost:9080 --no-autoupdate
```

The URL is printed in the output. Write it into your table as `<TUNNEL_URL>`.

> ⚠️ **WARNING:** Quick tunnel URLs expire and change on every restart. Every time the URL changes you must update the `LUGH_SERVER_URL` GitHub secret and rebuild both apps. Use Option B for anything beyond initial testing.

### 4.3 Option B — Permanent Named Tunnel (Production)

A permanent tunnel gives you a stable URL that never changes, tied to a domain you control.

**Prerequisite:** A domain in a Cloudflare account (free plan works). `<TUNNEL_DOMAIN>` = e.g. `lugh.example.com`.

```bash
# Authenticate (opens browser URL — paste on a browser-enabled machine)
cloudflared tunnel login

# Create the tunnel — do this ONCE, ever
cloudflared tunnel create lugh
# Note the Tunnel ID in the output (a UUID like a1b2c3d4-...)

# Create DNS CNAME record pointing <TUNNEL_DOMAIN> to the tunnel
cloudflared tunnel route dns lugh <TUNNEL_DOMAIN>

# Write tunnel config
mkdir -p /etc/cloudflared
cat > /etc/cloudflared/config.yml << EOF
tunnel: <TUNNEL_ID>
credentials-file: /root/.cloudflared/<TUNNEL_ID>.json

ingress:
  - hostname: <TUNNEL_DOMAIN>
    service: http://localhost:9080
  - service: http_status:404
EOF

# Install and start as a system service
cloudflared service install
systemctl enable cloudflared
systemctl start cloudflared
```

**Verify:**
```bash
curl -s https://<TUNNEL_DOMAIN>/health/
# Expected: {"status": "ok", ...}
```

**To change the domain later:**
```bash
# Add new DNS route
cloudflared tunnel route dns lugh <NEW_TUNNEL_DOMAIN>
# Remove old route
cloudflared tunnel route dns --overwrite-dns lugh <NEW_TUNNEL_DOMAIN>
# Update config.yml hostname field
# Update LUGH_SERVER_URL GitHub secret → rebuild apps
```

### 4.4 Update LUGH_SERVER_URL GitHub Secret

After you have a tunnel URL (from either option), update the GitHub secret so CI bakes it into the app:

```bash
gh secret set LUGH_SERVER_URL \
  --body "https://<TUNNEL_DOMAIN>" \
  --repo <GITHUB_REPO>
```

> 💡 This secret is compiled into the Android APK and iOS IPA at build time. Changing it requires a new build and redistribution of both apps.

### 4.5 Firewall Rules

DSM → Control Panel → Security → Firewall:

| Rule | Action | Port | Source |
|---|---|---|---|
| SSH | Allow | 22 | Your admin workstation IP only |
| DSM Web | Allow | 5000, 5001 | Your admin workstation IP only |
| Lugh API (LAN) | Allow | 9080 | `<LAN_SUBNET>` |
| Everything else | Deny | All | All |

Port 9080 does **not** need to be open on the internet-facing router — Cloudflare Tunnel handles that via an outbound connection from the NAS.

---

## 5. Phase 3 — Deploy the Backend Stack

### 5.1 Write the .env File

All secrets and configuration live here. This file is never committed to Git.

```bash
# Generate a Django SECRET_KEY automatically
SECRET_KEY=$(python3 -c "import secrets, string; \
  chars = string.ascii_letters + string.digits + '!@#%^&*(-_=+)'; \
  print(''.join(secrets.choice(chars) for _ in range(60)))")
echo "Your SECRET_KEY: $SECRET_KEY"
# Copy it somewhere safe before continuing

cat > /volume1/docker/lugh/.env << EOF
DOCKERHUB_USERNAME=<DOCKERHUB_USERNAME>
SECRET_KEY=${SECRET_KEY}
POSTGRES_PASSWORD=<DB_PASSWORD>
DB_PASSWORD=<DB_PASSWORD>
EXTRA_ALLOWED_HOSTS=<NAS_IP>,<TUNNEL_DOMAIN>
PLC_MOCK=false
PLC_IP=<PLC_IP>
PLC_NETID=<PLC_AMS_NET_ID>
PLC_PORT=851
PLC_DISCOVERY_SUBNETS=<LAN_SUBNET>
EOF

chmod 600 /volume1/docker/lugh/.env
```

> ⚠️ **WARNING:** `POSTGRES_PASSWORD` and `DB_PASSWORD` must be identical. PostgreSQL uses `POSTGRES_PASSWORD` to initialise the database. Django uses `DB_PASSWORD` to connect. If they differ, Django will fail to connect with an authentication error.

**Where each .env value is used and what breaks if it is wrong:**

| Variable | If Wrong or Missing | How to Fix |
|---|---|---|
| `SECRET_KEY` | Django refuses to start in production | Update `.env` → `docker compose restart django celery-worker celery-beat` |
| `POSTGRES_PASSWORD` / `DB_PASSWORD` | Django gets `password authentication failed` | These must match; if you change DB_PASSWORD, also change POSTGRES_PASSWORD and reset the DB user password inside Postgres |
| `EXTRA_ALLOWED_HOSTS` | Django returns `400 Bad Request` (DisallowedHost) | Add the new IP/domain and restart `django` |
| `PLC_IP` | ADS connection fails silently; PLC shows as disconnected | Update and restart `django` + `celery-worker` |
| `PLC_NETID` | ADS handshake fails (wrong routing) | Must be `<PLC_IP>.1.1`; update and restart |
| `PLC_DISCOVERY_SUBNETS` | Commissioning wizard finds no PLCs on scan | Set to the correct LAN CIDR; restart `django` |
| `DOCKERHUB_USERNAME` | Stack fails to pull image | Must match the Docker Hub account that owns `lugh-django` |

**How to change any .env value after deployment:**

```bash
# Edit the file
nano /volume1/docker/lugh/.env

# Restart the affected services
docker compose \
  -f /volume1/docker/lugh/docker-compose.prod.yml \
  restart django celery-worker celery-beat
```

For `POSTGRES_PASSWORD` / `DB_PASSWORD` changes, see Section 10.11 (Rotating the Database Password).

### 5.2 Copy the Compose and Nginx Files

```bash
# Option A: clone the repo
cd /tmp
git clone https://github.com/<GITHUB_REPO>.git lugh-repo
cp lugh-repo/docker-compose.prod.yml /volume1/docker/lugh/
cp lugh-repo/nginx/nginx.conf        /volume1/docker/lugh/
rm -rf /tmp/lugh-repo

# Option B: download directly
curl -fsSL \
  https://raw.githubusercontent.com/<GITHUB_REPO>/main/docker-compose.prod.yml \
  -o /volume1/docker/lugh/docker-compose.prod.yml

curl -fsSL \
  https://raw.githubusercontent.com/<GITHUB_REPO>/main/nginx/nginx.conf \
  -o /volume1/docker/lugh/nginx.conf

# Option C: run the automated installer
curl -fsSL \
  https://raw.githubusercontent.com/<GITHUB_REPO>/main/scripts/nas-install.sh \
  | bash
```

### 5.3 Edit docker-compose.prod.yml for Your Environment

Open the compose file and verify these values match your `.env`:

```bash
nano /volume1/docker/lugh/docker-compose.prod.yml
```

Look for and confirm:
```yaml
environment:
  EXTRA_ALLOWED_HOSTS: "<NAS_IP>,<TUNNEL_DOMAIN>"
  PLC_IP:    "<PLC_IP>"
  PLC_NETID: "<PLC_AMS_NET_ID>"
  PLC_DISCOVERY_SUBNETS: "<LAN_SUBNET>"
```

> 💡 The compose file reads most values from `.env` via `${VARIABLE}` substitution. If a value is hardcoded in the compose file, it overrides `.env`. The IP-related values are sourced from `.env` — you should not need to edit the compose file directly for network changes.

### 5.4 Pull Images and Start the Stack

```bash
# Pull all images
docker compose \
  -f /volume1/docker/lugh/docker-compose.prod.yml \
  --env-file /volume1/docker/lugh/.env \
  pull

# Start
docker compose \
  -f /volume1/docker/lugh/docker-compose.prod.yml \
  --env-file /volume1/docker/lugh/.env \
  up -d
```

Startup order (enforced by `depends_on` + healthchecks):
1. `lugh_db` (PostgreSQL) — waits for `pg_isready`
2. `lugh_redis` — waits for `redis-cli ping`
3. `lugh_django` — runs `migrate` + `collectstatic` then starts Gunicorn
4. `lugh_celery_worker` + `lugh_celery_beat` — start after DB and Redis
5. `lugh_nginx` — starts after Django is healthy

### 5.5 Verify All Containers Are Healthy

```bash
docker compose \
  -f /volume1/docker/lugh/docker-compose.prod.yml \
  ps
```

All containers must show `running (healthy)` or `running`:

```
NAME                 STATUS
lugh_db              running (healthy)
lugh_redis           running (healthy)
lugh_django          running (healthy)
lugh_celery_worker   running
lugh_celery_beat     running
lugh_nginx           running (healthy)
```

### 5.6 Create the Admin Superuser

```bash
docker exec -it lugh_django python manage.py createsuperuser
# Enter <ADMIN_USERNAME>, <ADMIN_EMAIL>, <ADMIN_PASSWORD>
```

This is the first **Tech Team** (staff) account. Only staff accounts can access the Commissioning Wizard.

**To create additional staff accounts later:**
```bash
docker exec -it lugh_django python manage.py shell -c "
from django.contrib.auth.models import User
u = User.objects.create_user('<USERNAME>', '<EMAIL>', '<PASSWORD>')
u.is_staff = True
u.save()
print('Staff user created')
"
```

### 5.7 Verify Health Endpoints

```bash
# LAN access
curl http://<NAS_IP>:9080/health/

# Internet access (after tunnel is running)
curl https://<TUNNEL_DOMAIN>/health/
```

Expected response:
```json
{"status": "ok", "database": "ok", "redis": "ok", "plc_mode": "live"}
```

---

## 6. Phase 4 — CI/CD Pipeline (GitHub Actions)

### 6.1 What Happens on Every Push to Main

```
git push to main
    ↓
Django Tests (against real PostgreSQL)
    ↓ (pass)
    ├── Build Django Image → Docker Hub (<DOCKERHUB_USERNAME>/lugh-django:latest)
    ├── Build Android APK (signed, LUGH_SERVER_URL baked in)
    └── Build iOS IPA (unsigned, LUGH_SERVER_URL baked in)
         ↓ (if DEPLOY_ENABLED=true)
    Deploy job on self-hosted runner (NAS):
      docker pull → docker compose up -d → health check
```

### 6.2 Required GitHub Secrets

Set at: GitHub repo → **Settings → Secrets and variables → Actions → Secrets**

| Secret | Value | Where It Is Used |
|---|---|---|
| `DOCKERHUB_USERNAME` | `<DOCKERHUB_USERNAME>` | Logging in to push the image |
| `DOCKERHUB_TOKEN` | Access token from Docker Hub | Authentication to push image |
| `DJANGO_SECRET_KEY` | 60-char random string | Written to NAS `.env` on deploy |
| `DB_PASSWORD` | `<DB_PASSWORD>` | Written to NAS `.env` on deploy |
| `ANDROID_KEYSTORE_B64` | `base64 -w 0 lugh-release.jks` | Signs the Android release APK |
| `ANDROID_STORE_PASSWORD` | Keystore password | Android signing |
| `ANDROID_KEY_ALIAS` | Key alias | Android signing |
| `ANDROID_KEY_PASSWORD` | Key password | Android signing |
| `LUGH_SERVER_URL` | `https://<TUNNEL_DOMAIN>` | Baked into APK and IPA at build time |
| `SERVER_HOST` | `<NAS_IP>` | Health check after deploy |

> ⚠️ **WARNING:** `LUGH_SERVER_URL` is compiled into the apps at build time. When the tunnel URL changes, update this secret and then rebuild — otherwise the apps will point to the old, dead URL.

### 6.3 Enable Auto-Deploy

Repo → **Settings → Variables → Actions → New repository variable:**
- Name: `DEPLOY_ENABLED`
- Value: `true`

To pause deployment: set to `false`. The deploy job will be skipped without touching the running stack.

### 6.4 Downloading Build Artifacts

GitHub → **Actions** → latest successful run → **Artifacts** section → download `lugh-android-apk` or `lugh-ios-ipa`.

### 6.5 Building Apps Locally

```bash
# Android (Windows / macOS / Linux — requires Flutter + Java 17)
cd flutter_application_plc
flutter build apk --release \
  "--dart-define=LUGH_SERVER_URL=https://<TUNNEL_DOMAIN>" \
  --build-name="1.0.0" --build-number="1"

# iOS (macOS + Xcode only — cannot build on Windows or Linux)
flutter build ios --release --no-codesign \
  "--dart-define=LUGH_SERVER_URL=https://<TUNNEL_DOMAIN>"
```

**To point the app to a different server** (e.g. a test environment):  
Change `<TUNNEL_DOMAIN>` in the build command above. There is no in-app setting to change the server URL — it must be set at build time.

---

## 7. Phase 5 — Beckhoff CX PLC Integration

### 7.1 Prerequisites

- CX powered on, connected to the LAN at `<PLC_IP>`
- TwinCAT 3 runtime installed and set to **RUN** state
- PLC program deployed and executing
- NAS and CX on the same subnet (`<LAN_SUBNET>`)

**To verify the PLC's current IP:**  
On the CX display, or in TwinCAT System Manager → Target System → Properties.

**To change the PLC's IP:**  
Change it in TwinCAT System Manager. Then update `PLC_IP` and `PLC_NETID` in `/volume1/docker/lugh/.env` and restart the Django and Celery containers. Also update the PLCDevice record in the app (Settings → Controllers). Also update the ADS route on the CX to point to the NAS (Section 7.3), since routes are identified by IP.

### 7.2 Required Network Ports

Test these from the NAS to the CX before proceeding:

```bash
# Run from the NAS
docker exec lugh_django nc -zv <PLC_IP> 48898
docker exec lugh_django nc -zv <PLC_IP> 851
```

Both must succeed. If either fails:
- Check CX Windows Firewall (if running Windows CE/Embedded): allow TCP 48898 and 851 inbound
- Check any network firewall/ACL between the NAS and CX
- Verify NAS and CX are on the same switch (no inter-VLAN routing blocking them)

### 7.3 Add ADS Route on the Beckhoff CX

The CX must have a static route telling it how to reach the NAS, or ADS communication will be refused.

**Method A — TwinCAT System Manager (engineering PC with TwinCAT):**

1. Open TwinCAT System Manager on a Windows engineering PC on the same LAN
2. Connect to the CX at `<PLC_IP>`
3. Navigate to the **Routes** tab
4. Click **Add Route**, fill in:
   - Route Name: `Lugh-NAS`
   - AMS Net ID: `<NAS_AMS_NET_ID>`
   - Address (IP): `<NAS_IP>`
   - Transport Type: TCP/IP
5. Click Add Route → OK

**Method B — programmatically via Django (if the CX allows unauthenticated route addition):**

```bash
docker exec lugh_django python manage.py shell -c "
from find_device.plc.ads_client import ADSClient
client = ADSClient('<PLC_AMS_NET_ID>', '<PLC_IP>')
result = client.add_route('<NAS_AMS_NET_ID>', 'Lugh-NAS')
print('Route added:', result)
"
```

**To update the ADS route when the NAS IP changes:**  
On the CX, delete the old route entry for the old `<NAS_IP>` and add a new one for the new `<NAS_IP>` / `<NAS_AMS_NET_ID>`.

### 7.4 Verify the ADS Connection

```bash
docker exec lugh_django python manage.py shell -c "
from find_device.plc.ads_client import ADSClient
client = ADSClient('<PLC_AMS_NET_ID>', '<PLC_IP>')
ok = client.connect()
print('Connected:', ok)
if ok:
    print('Device:', client.get_device_info())
    print('ADS state:', client.read_ads_state())
    client.disconnect()
"
```

Expected when PLC is running:
```
Connected: True
Device: {'name': 'CX-xxxxx', 'version': '3.1.4.xx', ...}
ADS state: {'ads_state': 5, 'ads_state_name': 'RUN', ...}
```

ADS state 5 = RUN. Any other state means the PLC program is not executing.

### 7.5 AMS Net ID Rules

| Device | AMS Net ID Formula | Example |
|---|---|---|
| Beckhoff CX | `<PLC_IP>.1.1` | `10.0.0.100.1.1` |
| NAS (as seen by PLC) | `<NAS_IP>.1.1` | `10.0.0.50.1.1` |

The `.1.1` suffix is the TwinCAT default for the local AMS Net ID of any target. It is not configurable in this system.

**If you change either IP, both AMS Net IDs change automatically** — update them everywhere:
- `/volume1/docker/lugh/.env` → `PLC_NETID=<new_PLC_AMS_NET_ID>`
- ADS route on the CX → update to `<new_NAS_AMS_NET_ID>`
- PLCDevice record in the app (Settings → Controllers → edit)

### 7.6 PLC Variable Naming Convention

Variables are accessed by name (e.g. `gvlDALI.channel_01`). Your TwinCAT GVL must use these conventions:

| GVL | Variable Type | Controls |
|---|---|---|
| `gvlDALI` | `BYTE` | DALI light channels (0–100 = brightness %) |
| `gvlRelays` | `BOOL` | Wall relays |
| `gvlHVAC` | `REAL` / `BOOL` | Climate setpoints and states |
| `gvlAlarms` | `BOOL` | Alarm inputs |
| `gvlSensor` | `BOOL` / `REAL` | Door, window, motion sensors |
| `gvlMotor` | `INT` | Curtain motor commands (0=stop, 1=up, 2=down) |

---

## 8. Phase 6 — Mobile Application Installation

### 8.1 What URL the Apps Use

Both apps connect to `<TUNNEL_URL>` (baked in at build time). There is no in-app field to change this — the correct URL must be set via `LUGH_SERVER_URL` before building.

**If you install an app built with the wrong URL:**  
Rebuild with the correct URL and reinstall. There is no workaround.

### 8.2 Android — Install the APK

```
1. Settings → Security → Install unknown apps → enable for your file manager
2. Transfer Lugh-vX.X.X-android.apk to the phone (USB / email / Telegram)
3. Open the file → Install → Open
```

**Verify:** Login screen appears. Tap the screen — if it immediately shows a network error, the baked-in URL is wrong or the server is down.

### 8.3 iOS — Install via AltStore

```
1. Install AltStore on iPhone via altstore.io (requires AltServer on Windows/Mac)
2. AltStore → + → select Lugh-vX.X.X-ios.ipa
3. Settings → General → VPN & Device Management → Trust the developer
```

> ⚠️ **WARNING:** IPA files installed via AltStore with a free Apple ID expire after 7 days and must be reinstalled. A paid Apple Developer account ($99/year) allows installation via TestFlight with no expiry.

### 8.4 Login

```
Username: provided by the building administrator
Password: provided by the building administrator
```

Residents cannot self-register. All accounts are created by staff through the Commissioning Wizard or Django admin panel.

---

## 9. Phase 7 — Commissioning

### 9.1 Prerequisites

- Backend stack healthy (`GET <NAS_IP>:9080/health/` returns ok)
- ADS connection verified (Section 7.4)
- PLC in RUN state
- Staff account created
- Mobile app installed

### 9.2 Open the Commissioning Wizard

1. Log in as a **staff user** in the app
2. Home screen → tap amber **Commission** FAB (bottom-right)
3. The 9-step wizard opens

### 9.3 Step-by-Step

#### Step 1 — Network Discovery

Scans `<LAN_SUBNET>` for Beckhoff ADS targets.

- CX at `<PLC_IP>` should appear with connection quality Excellent/Good
- If not found: verify `PLC_DISCOVERY_SUBNETS=<LAN_SUBNET>` in `.env`, restart Django

#### Step 2 — PLC Connectivity

Enter or confirm:
- IP: `<PLC_IP>`
- AMS Net ID: `<PLC_AMS_NET_ID>`
- Port: `851`

ADS state must show **RUN**. If it shows anything else, the PLC program is not executing.

**To update PLC connection details after commissioning:**  
App → Settings → Controllers → tap the device → Edit → update IP and/or AMS Net ID → Save → Test Connection.

Also update `/volume1/docker/lugh/.env` and restart Django/Celery.

#### Step 3 — Apartment Setup

Create the apartment record. Enter name, building, floor. Add all rooms.

**To rename an apartment or room later:**  
App → Settings → the apartment card → Rename. Or via Django admin: `/admin/find_device/apartment/`.

#### Step 4 — Symbol Discovery

The backend connects to the PLC and reads all GVL variables. Symbols are classified by type (lighting, relays, sensors, etc.).

- Symbol count should be non-zero
- Expected GVL sections must appear

**To re-run discovery after PLC program changes:**  
App → Commissioning Wizard → Step 4 again, or API: `POST /discovery/<device_id>/scan/`.

#### Step 5 — Floor Plan Upload

Upload a PNG or JPEG of the apartment floor plan (max 20 MB).

**Floor plan images are stored at:** `/volume1/docker/lugh/media/`

**To replace a floor plan later:**  
Re-run this step. The new image replaces the old one. The existing device placement on the canvas is preserved.

#### Step 6 — Map Editor

Place each discovered PLC variable onto the floor plan as a device icon. Each placed device is linked to a symbol name and device type.

**To reposition a device after commissioning:**  
App → Map Editor FAB (staff only) → drag device to new position → Publish.

#### Step 7 — I/O Commissioning (Physical Test)

For each device, tap **Test**. The backend pulses the physical output:

| Device | Test Action | Duration |
|---|---|---|
| DALI light | Flash to 80% (or 20% if already bright) | 1.5 seconds |
| Wall relay | Pulse ON | 0.8 seconds |
| Curtain motor | Drive UP | 0.8 seconds |
| Sensor (door/window/motion) | Read current value | Instant — no actuation |

**Commissioning checklist — complete one row per physical device:**

| Device | Location | Symbol | Test Result |
|---|---|---|---|
| | | | ☐ Pass / ☐ Fail |
| | | | ☐ Pass / ☐ Fail |
| | | | ☐ Pass / ☐ Fail |

If a test fails:
- Verify the symbol is mapped to the correct channel
- Verify physical wiring on the DALI bus or relay output
- Check CX program — is the output variable correctly linked to the physical I/O module?

#### Step 8 — Resident Accounts

Create user accounts for each resident. Assign role:
- `owner` — full control, can manage users and devices
- `resident` — control only, read-only settings

**To add residents later:**  
App → Settings → User Management → Add User. Or Django admin → Users → Add.

**To deactivate a resident (tenant changeover):**  
App → Settings → User Management → find user → Disable. Do not delete — this preserves audit history.

#### Step 9 — Handover

Review the commissioning summary. Photograph or print it as the commissioning record.

---

## 10. Phase 8 — Maintenance & Operations

### 10.1 Updating the Backend

Push to `main` → CI builds and (if `DEPLOY_ENABLED=true`) auto-deploys to the NAS.

**Manual update without CI:**
```bash
docker pull <DOCKERHUB_USERNAME>/lugh-django:latest
docker compose -f /volume1/docker/lugh/docker-compose.prod.yml up -d --no-deps django
```

### 10.2 Rollback

```bash
# List available image tags
docker images <DOCKERHUB_USERNAME>/lugh-django

# Pin a specific SHA tag — edit docker-compose.prod.yml:
#   image: <DOCKERHUB_USERNAME>/lugh-django:sha-<COMMIT_SHA>

docker compose -f /volume1/docker/lugh/docker-compose.prod.yml up -d --no-deps django
```

### 10.3 Database Backup

```bash
# Manual backup
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
docker exec lugh_db pg_dump \
  -U lugh_user -d lugh_db --format=custom \
  > /volume1/docker/lugh/backups/lugh_db_${TIMESTAMP}.dump
```

**Automated daily backup** — add to Synology Task Scheduler:

```bash
# /volume1/docker/lugh/backup.sh
BACKUP_DIR=/volume1/docker/lugh/backups
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
docker exec lugh_db pg_dump \
  -U lugh_user -d lugh_db --format=custom \
  > "${BACKUP_DIR}/lugh_db_${TIMESTAMP}.dump"
ls -t "${BACKUP_DIR}"/lugh_db_*.dump | tail -n +31 | xargs -r rm
```

### 10.4 Database Restore

```bash
docker compose -f /volume1/docker/lugh/docker-compose.prod.yml stop django celery-worker celery-beat
docker exec -i lugh_db pg_restore \
  -U lugh_user -d lugh_db --clean --if-exists \
  < /volume1/docker/lugh/backups/lugh_db_YYYYMMDD_HHMMSS.dump
docker compose -f /volume1/docker/lugh/docker-compose.prod.yml start django celery-worker celery-beat
```

### 10.5 Viewing Logs

```bash
# Follow all containers
docker compose -f /volume1/docker/lugh/docker-compose.prod.yml logs -f

# Specific container
docker logs lugh_django --tail=100 -f

# Errors only
docker logs lugh_django 2>&1 | grep -E "ERROR|CRITICAL"
```

### 10.6 Changing the NAS IP

1. Change IP in DSM → Network Interface (or router DHCP reservation)
2. Update `/volume1/docker/lugh/.env`: `EXTRA_ALLOWED_HOSTS=<NEW_NAS_IP>,<TUNNEL_DOMAIN>`
3. Restart Django: `docker compose restart django`
4. Update ADS route on CX: remove old route (old `<NAS_IP>.1.1`), add new route (`<NEW_NAS_IP>.1.1`) → Section 7.3

### 10.7 Changing the PLC IP

1. Change IP on the CX in TwinCAT System Manager
2. Update `/volume1/docker/lugh/.env`:
   ```
   PLC_IP=<NEW_PLC_IP>
   PLC_NETID=<NEW_PLC_IP>.1.1
   ```
3. Restart Django and Celery:
   ```bash
   docker compose -f /volume1/docker/lugh/docker-compose.prod.yml restart django celery-worker
   ```
4. In the app: Settings → Controllers → tap the device → Edit → update IP and AMS Net ID → Test Connection
5. Update the ADS route on the CX: add a route back to the NAS (`<NAS_IP>` / `<NAS_AMS_NET_ID>`) — this route is from the PLC's perspective and the PLC's IP does not affect it, but verifying it is good practice

### 10.8 Changing the Tunnel URL

1. Update GitHub secret:
   ```bash
   gh secret set LUGH_SERVER_URL --body "https://<NEW_TUNNEL_DOMAIN>" --repo <GITHUB_REPO>
   ```
2. Update `/volume1/docker/lugh/.env`: `EXTRA_ALLOWED_HOSTS=<NAS_IP>,<NEW_TUNNEL_DOMAIN>`
3. Restart Django: `docker compose restart django`
4. Trigger a new CI build (push any commit to main)
5. Download new APK and IPA from CI artifacts
6. Redistribute to all users — old builds will fail to connect

### 10.9 Replacing a Beckhoff CX PLC

1. Install TwinCAT 3 and PLC program on new CX
2. Set TwinCAT to RUN
3. Configure same IP as old CX (easiest) or a new IP:
   - If same IP: no changes needed on the backend
   - If new IP: follow Section 10.7
4. Add ADS route on new CX pointing to NAS (Section 7.3)
5. Verify connection: Section 7.4

### 10.10 Replacing the NAS

1. Set up new NAS following Phase 1 completely
2. Assign same IP as old NAS (easiest) or follow Section 10.6
3. Restore database from backup (Section 10.4)
4. Copy Docker volumes from old NAS:
   ```bash
   # On old NAS
   tar czf /tmp/lugh_data.tar.gz /volume1/docker/lugh/
   # Transfer to new NAS, then extract
   tar xzf lugh_data.tar.gz -C /
   ```
5. If using permanent Cloudflare tunnel: `cloudflared tunnel route ip add <NEW_NAS_IP>/32 lugh`

### 10.11 Rotating the Database Password

```bash
# 1. Change password in Postgres
docker exec lugh_db psql -U lugh_user -d lugh_db -c \
  "ALTER USER lugh_user WITH PASSWORD '<NEW_DB_PASSWORD>';"

# 2. Update .env
nano /volume1/docker/lugh/.env
# Set: POSTGRES_PASSWORD=<NEW_DB_PASSWORD> and DB_PASSWORD=<NEW_DB_PASSWORD>

# 3. Restart Django
docker compose -f /volume1/docker/lugh/docker-compose.prod.yml restart django

# 4. Update GitHub secret (so CI deploys don't overwrite with old password)
gh secret set DB_PASSWORD --body "<NEW_DB_PASSWORD>" --repo <GITHUB_REPO>
```

### 10.12 Adding a New Apartment / Building

1. Log in as staff
2. Open the Commissioning Wizard
3. If the new apartment has its own PLC: register it first via Settings → Controllers → Add
4. Follow all 9 commissioning steps

No server restart or code change is required. Apartments are database records.

### 10.13 Tenant Changeover (Replacing a Resident)

1. App → Settings → User Management → find the departing resident → **Disable** (not delete)
2. Commissioning Wizard → Step 8 → Add the new resident
3. Hand the new resident their login credentials

---

## 11. Troubleshooting

### 11.1 Django Container is Unhealthy

**Symptoms:** `docker ps` shows `lugh_django` unhealthy. App shows 502.

```bash
docker logs lugh_django --tail=50
```

| Log Message | Cause | Fix |
|---|---|---|
| `could not connect to server: Connection refused` | PostgreSQL not ready | Wait; check `lugh_db` health |
| `FATAL: password authentication failed` | `DB_PASSWORD` ≠ `POSTGRES_PASSWORD` | Fix `.env`, restart all |
| `RuntimeError: Refusing to start` | `SECRET_KEY` not set | Set `SECRET_KEY` in `.env` |
| `DisallowedHost` | NAS IP or tunnel domain not in `EXTRA_ALLOWED_HOSTS` | Add to `.env`, restart |
| `django.db.utils.ProgrammingError` | Migration failed | Run `docker exec lugh_django python manage.py migrate` |

### 11.2 Nginx 502 Bad Gateway

**Cause:** Nginx is running but Django is not, or Django's container IP changed.

```bash
docker exec lugh_nginx nginx -s reload
# If that does not help:
docker compose -f /volume1/docker/lugh/docker-compose.prod.yml restart nginx
```

### 11.3 ADS Connection Fails

```bash
# Test network path
docker exec lugh_django nc -zv <PLC_IP> 48898
docker exec lugh_django nc -zv <PLC_IP> 851

# Test ADS handshake
docker exec lugh_django python manage.py shell -c "
import pyads
conn = pyads.Connection('<PLC_AMS_NET_ID>', pyads.PORT_TC3PLC1, '<PLC_IP>')
conn.open()
print(conn.read_state())
conn.close()
"
```

| Result | Cause | Fix |
|---|---|---|
| `nc` fails on 48898 | No network path or firewall | Check cables, switch, CX firewall |
| `nc` works, ADS fails | Route not on CX | Add ADS route (Section 7.3) |
| Route exists, ADS fails | Wrong AMS Net IDs | Verify `<PLC_AMS_NET_ID>` = `<PLC_IP>.1.1` |
| ADS works but state ≠ RUN | PLC not running | Set TwinCAT to RUN mode |

### 11.4 App Cannot Connect to Backend

```bash
# Test from any machine with internet
curl https://<TUNNEL_DOMAIN>/health/
```

| Result | Cause | Fix |
|---|---|---|
| Connection refused | Cloudflare tunnel down | Restart cloudflared on NAS |
| 502 | Django down | Fix Django container (11.1) |
| `curl` works, app fails | Wrong URL baked into app | Rebuild with correct `LUGH_SERVER_URL` |
| 401 on login | Wrong credentials | Verify in Django admin |
| CORS error | Tunnel domain not in `EXTRA_ALLOWED_HOSTS` | Add to `.env`, restart Django |

### 11.5 Quick Tunnel URL Expired

Quick tunnel URLs change every restart of cloudflared.

```bash
# Find current URL from cloudflared metrics
curl http://localhost:2000/metrics | grep trycloudflare
```

Then update the secret and rebuild:
```bash
gh secret set LUGH_SERVER_URL --body "https://<NEW_URL>.trycloudflare.com" --repo <GITHUB_REPO>
git commit --allow-empty -m "chore: rebuild apps with new tunnel URL"
git push origin main
```

Download new APK/IPA from CI artifacts and redistribute.

### 11.6 Celery Tasks Not Running

```bash
docker logs lugh_celery_worker --tail=50
docker logs lugh_celery_beat --tail=50
# Check Redis connectivity:
docker exec lugh_celery_worker python -c "
import redis; r = redis.from_url('redis://redis:6379/0'); print(r.ping())
"
```

If Redis ping fails: `docker restart lugh_redis`, then `docker restart lugh_celery_worker lugh_celery_beat`.

### 11.7 GitHub Actions Deployment Fails

| Job | Failure | Fix |
|---|---|---|
| Django Tests | `makemigrations --check` fails | Create migration: `python manage.py makemigrations` → commit |
| Build Django Image | Docker Hub auth fails | Regenerate `DOCKERHUB_TOKEN` secret |
| Build Android APK | Keystore error | Re-encode keystore: `base64 -w 0 lugh-release.jks` → update `ANDROID_KEYSTORE_B64` |
| Deploy | Runner offline | SSH to NAS → `cd /volume1/docker/lugh/runner && ./svc.sh start` |
| Deploy | `docker pull` fails | Docker Hub rate limit — wait 10 min, re-run job |

### 11.8 PLC Symbols Not Found After Discovery

```bash
# Check what symbols the PLC actually exposes
docker exec lugh_django python manage.py shell -c "
from find_device.plc.ads_client import ADSClient
client = ADSClient('<PLC_AMS_NET_ID>', '<PLC_IP>')
client.connect()
symbols = client.get_all_symbols()
print(f'Total symbols: {len(symbols)}')
for s in symbols[:20]:
    print(s['full_name'], '—', s['type_name'])
client.disconnect()
"
```

If zero symbols: the TwinCAT GVL does not expose its variables with the expected names (`gvlDALI`, `gvlRelays`, etc.). Verify the GVL naming in the TwinCAT project.

---

## 12. Reference

### 12.1 Environment Variable Reference

| Variable | Required | Where Used | How to Change |
|---|---|---|---|
| `SECRET_KEY` | Yes | Django cryptography | Update `.env` → restart `django` |
| `DB_PASSWORD` | Yes | Django → Postgres | Section 10.11 |
| `POSTGRES_PASSWORD` | Yes | Postgres init | Must equal `DB_PASSWORD` — Section 10.11 |
| `EXTRA_ALLOWED_HOSTS` | Yes | Django `ALLOWED_HOSTS` | Add `<NAS_IP>` and `<TUNNEL_DOMAIN>` → restart `django` |
| `PLC_IP` | Yes (live) | pyADS connection | Update `.env` → restart `django` + `celery-worker` |
| `PLC_NETID` | Yes (live) | pyADS AMS Net ID | Must be `<PLC_IP>.1.1` → restart `django` + `celery-worker` |
| `PLC_PORT` | No (def: 851) | ADS runtime port | Update `.env` → restart `django` |
| `PLC_MOCK` | No (def: true) | Mock vs live PLC | Set `false` for production → restart all |
| `PLC_DISCOVERY_SUBNETS` | No | Commissioning wizard scan | Set to `<LAN_SUBNET>` → restart `django` |
| `DOCKERHUB_USERNAME` | Yes | Image pull | Update `.env` and `docker-compose.prod.yml` |
| `REDIS_URL` | No (def: localhost) | Celery + Django cache | Use `redis://redis:6379/0` in Docker |
| `DEBUG` | No (def: true) | Django debug mode | Set `false` in production |
| `TIME_ZONE` | No (def: UTC) | Scheduled tasks | e.g. `Europe/Dublin` → restart `celery-beat` |
| `CORS_ALLOWED_ORIGINS` | No | API CORS policy | Add `https://<TUNNEL_DOMAIN>` → restart `django` |

### 12.2 Container Reference

| Container | Image | Listens On | Restart? |
|---|---|---|---|
| `lugh_nginx` | `nginx:1.27-alpine` | `<NAS_IP>:9080` | IP/config changes |
| `lugh_django` | `<DOCKERHUB_USERNAME>/lugh-django:latest` | Docker internal :8000 | .env changes, updates |
| `lugh_db` | `postgres:15-alpine` | Docker internal :5432 | Password changes |
| `lugh_redis` | `redis:7-alpine` | Docker internal :6379 | Rarely needed |
| `lugh_celery_worker` | same as django | — | .env changes, updates |
| `lugh_celery_beat` | same as django | — | Schedule changes |

### 12.3 File Locations

| File | Path | Edit When |
|---|---|---|
| Secrets & config | `/volume1/docker/lugh/.env` | IP changes, password rotation, PLC changes |
| Docker Compose | `/volume1/docker/lugh/docker-compose.prod.yml` | Stack structure changes |
| Nginx config | `/volume1/docker/lugh/nginx.conf` | Proxy/cache rules |
| Boot script | `/volume1/docker/lugh/start.sh` | Path changes |
| Backup script | `/volume1/docker/lugh/backup.sh` | Retention policy changes |
| Database files | `/volume1/docker/lugh/postgres_data/` | Never edit directly |
| DB backups | `/volume1/docker/lugh/backups/` | |
| Media (floor plans) | `/volume1/docker/lugh/media/` | |
| CI runner | `/volume1/docker/lugh/runner/` | Runner re-registration |

### 12.4 Useful Commands

```bash
# Stack — start / stop / restart / status
docker compose -f /volume1/docker/lugh/docker-compose.prod.yml up -d
docker compose -f /volume1/docker/lugh/docker-compose.prod.yml down
docker compose -f /volume1/docker/lugh/docker-compose.prod.yml restart django
docker compose -f /volume1/docker/lugh/docker-compose.prod.yml ps

# Django management
docker exec lugh_django python manage.py migrate
docker exec lugh_django python manage.py createsuperuser
docker exec -it lugh_django python manage.py shell

# Health checks
curl http://<NAS_IP>:9080/health/
curl https://<TUNNEL_DOMAIN>/health/

# Logs
docker logs lugh_django --tail=100 -f
docker logs lugh_nginx  --tail=100 -f

# Database shell
docker exec -it lugh_db psql -U lugh_user -d lugh_db
```

---

*End of Document — Lugh by IQS Deployment Manual v1.1*  
*All `< >` placeholders must be replaced with your actual values before executing any command.*

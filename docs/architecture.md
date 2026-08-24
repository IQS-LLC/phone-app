# Architecture

## System components

| Component | Technology | Purpose |
|---|---|---|
| Backend API | Django 5.2 / Python 3.11 / Gunicorn | REST API, JWT auth, PLC control |
| Database | PostgreSQL 15 | Persistent storage for all data |
| Task Queue | Redis 7 + Celery | Background tasks, alarms, notifications |
| Reverse Proxy | Nginx 1.27 | Static files, SSE, proxying |
| Internet exposure | Cloudflare Tunnel(s) (`cloudflared`) | Secure internet access without port forwarding |
| PLC Communication | pyADS 3.5.2 (+ optional Modbus TCP fallback) | ADS/AMS protocol to Beckhoff CX |
| Mobile App | Flutter (Android + iOS) | Resident and tech team interface |
| CI/CD | GitHub Actions | Automated testing, image builds, deployment |
| Registry | Docker Hub | Docker image distribution |

**Gunicorn runs with exactly 1 worker, deliberately** —
`find_device/plc/registry.py`'s `DeviceRegistry` holds in-memory ADS
connections per apartment; multiple worker processes would each get their
own registry and connections would break. Don't add workers without first
building a Redis-backed shared registry (a genuinely separate project, out
of scope for incremental changes).

## Network topology

```
                    ┌─────────────────────────────────────────┐
                    │              INTERNET                    │
                    └──────────────────┬──────────────────────┘
                                        │ HTTPS
                    ┌───────────────────┴───────────────────────┐
                    │      CLOUDFLARE TUNNEL POOL                │
                    │  2+ independent cloudflared processes,     │
                    │  each with its own public URL, all         │
                    │  proxying the same backend                 │
                    └───────────────────┬───────────────────────┘
                                        │ HTTP → server:9080
                    ┌───────────────────▼───────────────────────┐
                    │            SERVER (NAS or VM)              │
                    │                                            │
                    │  ┌──────────────────────────────────┐     │
                    │  │  Docker Stack (lugh_net bridge)   │     │
                    │  │                                    │    │
                    │  │  lugh_nginx      :9080→80          │    │
                    │  │      ↓ proxy_pass                  │    │
                    │  │  lugh_django     :8000              │   │
                    │  │      ↓              ↓               │   │
                    │  │  lugh_db        lugh_redis          │   │
                    │  │  :5432          :6379               │   │
                    │  │      ↑              ↑               │   │
                    │  │  lugh_celery_worker                 │   │
                    │  │  lugh_celery_beat                   │   │
                    │  └────────────────────────────────────┘    │
                    └───────────────────┬───────────────────────┘
                                        │ ADS/AMS  TCP:48898 + TCP:851
                    ┌───────────────────▼───────────────────────┐
                    │            BUILDING LAN                    │
                    │                                            │
                    │  Beckhoff CX — TwinCAT 3 Runtime, RUN state │
                    └───────────────────┬───────────────────────┘
                                        │ Physical I/O
                    ┌───────────────────▼───────────────────────┐
                    │  DALI lights, wall relays, curtains,        │
                    │  door/window sensors, wall switches         │
                    └─────────────────────────────────────────────┘

         Resident + Tech Team phones — HTTPS to whichever tunnel URL
         the app's endpoint pool currently has active
```

**Why a pool of tunnels, not one.** The server has no WAN connectivity of
its own — Cloudflare Tunnel is the only path in. A single tunnel is a single
point of failure (the free "quick tunnel" mode in particular has no uptime
guarantee and gets a brand-new URL every time the process restarts). The
Flutter app's `RuntimeConfig`
(`flutter_application_plc/lib/config/runtime_config.dart`) holds an ordered
pool of candidate URLs, tracks each one's health from real traffic, and
automatically fails over — see that file's doc comment for the full design
(circuit breaker, exponential backoff, sticky reclaim) and
`docs/deployment.md` for how to actually stand up more than one tunnel. This
is explicitly a temporary bridge, not the intended permanent architecture —
it goes away the day the server has real WAN connectivity of its own.

## Communication flow

```
Resident taps "Dim to 50%"
    ↓  HTTPS POST to <active tunnel URL>/plc/{apt}/control/
Cloudflare Tunnel
    ↓  HTTP → server:9080
Nginx → Django (JWT verified, membership checked)
    ↓  Python → DeviceRegistry → pyADS
ADS TCP → <PLC_IP>:48898
    ↓
TwinCAT PLC executes → DALI ballast dims
    ↑
New state pushed back via SSE to app
```

## Port reference

| Port | Protocol | Service | Accessible From |
|---|---|---|---|
| 9080 | TCP | Nginx (HTTP) | LAN + Cloudflare Tunnel(s) |
| 8000 | TCP | Django/Gunicorn | Docker internal only |
| 5432 | TCP | PostgreSQL | Docker internal only |
| 6379 | TCP | Redis | Docker internal only |
| 48898 | TCP | ADS Router (Beckhoff) | Building LAN only |
| 851 | TCP | TwinCAT 3 PLC Runtime | Building LAN only |
| 22 | TCP | Server SSH | Admin workstation only |

## Where to go next

- Deploying this from scratch: `docs/deployment.md`
- PLC/GVL integration and device compatibility: `docs/plc-integration.md`
- Local dev without any hardware: `docs/dev-environment.md`
- Admin/CI access, all in one place: `docs/admin-access.md`
- Something's broken: `docs/troubleshooting.md`

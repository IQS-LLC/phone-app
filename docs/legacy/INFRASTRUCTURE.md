# Lugh by IQS — Production Infrastructure

> **Superseded, 2026-08-24 — do not use.** This document describes a k3s/Helm
> deployment that the project owner has confirmed was never actually put into
> production and is not maintained. The real, current production deployment
> is NAS + Docker Compose + Cloudflare Tunnel — see `CLAUDE.md` and
> `docs/DEPLOYMENT_MANUAL.md` (soon `docs/deployment.md`) for the accurate,
> current architecture. The matching Helm chart/scripts live at
> `infra_legacy_k3s/` with the same status note. Kept here for historical
> reference only.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                    Developer Laptop                              │
│  git push → GitHub → GitHub Actions CI/CD                       │
└─────────────────────────────────┬───────────────────────────────┘
                                  │ SSH (port 8000)
                                  ▼
┌─────────────────────────────────────────────────────────────────┐
│              Production Server  192.168.0.192                   │
│                                                                  │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │                  k3s Kubernetes Cluster                  │    │
│  │  namespace: lugh                                         │    │
│  │                                                          │    │
│  │  ┌──────────┐    ┌──────────┐    ┌──────────────────┐  │    │
│  │  │  NGINX   │    │  Django  │    │   PostgreSQL      │  │    │
│  │  │ NodePort │───▶│ Gunicorn │───▶│   StatefulSet     │  │    │
│  │  │  :30080  │    │  :8000   │    │   :5432           │  │    │
│  │  └──────────┘    └────┬─────┘    └──────────────────-─┘  │    │
│  │                       │                                    │    │
│  │                  ┌────▼─────┐    ┌──────────────────┐    │    │
│  │                  │  Redis   │    │   Mock PLC        │    │    │
│  │                  │  :6379   │    │  ADS :48898       │    │    │
│  │                  └──────────┘    │  HTTP :8080       │    │    │
│  │                                  └──────────────────-─┘    │    │
│  └─────────────────────────────────────────────────────────┘    │
│                                                                  │
└────────────────────────────┬────────────────────────────────────┘
                             │
                    ┌────────▼────────┐
                    │  Flutter App    │
                    │  192.168.0.192  │
                    │  port 30080     │
                    └─────────────────┘
```

## Network Topology

| Source | Destination | Port | Protocol |
|--------|-------------|------|----------|
| Flutter App / Browser | NGINX | 30080 | HTTP |
| NGINX | Django | 8000 | HTTP |
| Django | PostgreSQL | 5432 | TCP |
| Django | Redis | 6379 | TCP |
| Django | Mock PLC / Real PLC | 48898 | ADS/TCP |
| GitHub Actions | Server SSH | 8000 | SSH |
| Developer | Server SSH | 8000 | SSH |

## Prerequisites

### On the Server (192.168.0.192)

- Ubuntu 22.04 or Debian 12 (recommended)
- Docker (for building only — k3s uses containerd)
- SSH configured on port 8000
- Outbound internet access (for pulling images from ghcr.io)

### On Developer Laptop

- SSH access to 192.168.0.192 on port 8000
- Git + GitHub account
- Helm 3.x (for manual deployments)

---

## First-Time Setup

### Step 1 — Configure GitHub Secrets

In your GitHub repository → Settings → Secrets → Actions:

```
SERVER_HOST         192.168.0.192
SERVER_SSH_PORT     8000
SERVER_SSH_USER     <your-linux-username>
SERVER_SSH_KEY      <contents of ~/.ssh/id_rsa private key>
GHCR_PAT            <GitHub PAT with packages:write scope>
```

### Step 2 — Bootstrap the Server

SSH into the server and run the bootstrap script:

```bash
ssh -p 8000 <user>@192.168.0.192

# Clone the repo (or transfer just the infra/ directory)
git clone <your-repo-url> lugh
cd lugh

# Set your GitHub username
export GITHUB_OWNER=<your-github-username>

# Run bootstrap (installs k3s, Helm, deploys everything)
bash infra/scripts/bootstrap-server.sh
```

The bootstrap script:
1. Installs k3s (lightweight Kubernetes)
2. Installs Helm 3
3. Creates the `lugh` namespace
4. Generates and stores secrets in Kubernetes
5. Performs the initial Helm deployment

### Step 3 — Set Proper Secrets

The bootstrap generates random secrets. For production, set them explicitly:

```bash
# Generate a proper Django secret key
SECRET_KEY=$(python3 -c "import secrets; print(secrets.token_urlsafe(50))")

# Set a secure DB password
DB_PASSWORD="your-secure-database-password"

# Update the K8s secret
kubectl create secret generic lugh-secrets \
    --namespace lugh \
    --from-literal="SECRET_KEY=$SECRET_KEY" \
    --from-literal="DB_PASSWORD=$DB_PASSWORD" \
    --from-literal="POSTGRES_PASSWORD=$DB_PASSWORD" \
    --dry-run=client -o yaml | kubectl apply -f -

# Restart Django to pick up the new secret
kubectl rollout restart deployment/django -n lugh
```

### Step 4 — Create Django Admin User

```bash
kubectl exec -it deployment/django -n lugh -- python manage.py createsuperuser
```

### Step 5 — Verify Everything Works

```bash
# Check all pods are Running
kubectl get pods -n lugh

# Test the API
curl http://192.168.0.192:30080/health/

# Test from Flutter app — update AppConfig.resolve() to return:
# "http://192.168.0.192:30080"
```

---

## CI/CD Flow

```
Developer commits
       │
       ▼
GitHub repository
       │
       ▼
GitHub Actions (.github/workflows/deploy.yml)
       │
       ├─ Job 1: test
       │   ├── Set up Python 3.11
       │   ├── Install dependencies
       │   ├── Start test PostgreSQL
       │   └── Run Django tests (PLC_MOCK=true)
       │
       ├─ Job 2: build (only on push to main)
       │   ├── Build lugh-django image
       │   ├── Build lugh-mock-plc image
       │   ├── Build lugh-nginx image
       │   └── Push all to ghcr.io/<owner>/
       │
       └─ Job 3: deploy (only on main, after build)
           ├── SSH into 192.168.0.192:8000
           ├── helm upgrade --install lugh
           ├── kubectl rollout restart deployment/django
           └── Verify health endpoint
```

---

## Helm Chart Structure

```
infra/helm/lugh/
├── Chart.yaml              # Chart metadata
├── values.yaml             # Default configuration
└── templates/
    ├── _helpers.tpl        # Shared template helpers
    ├── namespace.yaml      # K8s namespace
    ├── configmap.yaml      # Non-secret env vars
    ├── secrets.yaml        # Secret values (managed externally)
    ├── pvc.yaml            # Static/media persistent volumes
    ├── django-deployment.yaml
    ├── django-service.yaml
    ├── nginx-deployment.yaml
    ├── nginx-service.yaml
    ├── nginx-configmap.yaml
    ├── postgres-statefulset.yaml
    ├── postgres-service.yaml
    ├── redis-deployment.yaml
    ├── redis-service.yaml
    ├── mock-plc-deployment.yaml
    └── mock-plc-service.yaml
```

### Switching Between Mock PLC and Real PLC

**To use Mock PLC (development/testing):**
```bash
helm upgrade lugh infra/helm/lugh -n lugh \
    --reuse-values \
    --set django.env.PLC_MOCK=true \
    --set django.env.PLC_IP=mock-plc
```

**To use Real Beckhoff CX (production):**
```bash
helm upgrade lugh infra/helm/lugh -n lugh \
    --reuse-values \
    --set django.env.PLC_MOCK=false \
    --set django.env.PLC_IP=192.168.0.161 \
    --set django.env.PLC_NETID="192.168.0.161.1.1" \
    --set mockPlc.enabled=false
```

No Django code changes required. The `ADSClient` uses the same code path.

---

## Service Communication

```
NGINX (port 30080)
  ├── /static/*    → local disk (PVC lugh-static)
  ├── /media/*     → local disk (PVC lugh-media)
  └── /*           → Django:8000

Django:8000
  ├── /health/     → liveness probe
  ├── /plc/*       → DeviceRegistry → ADSClient → mock-plc:48898
  ├── /auth/*      → JWT authentication
  ├── /admin/      → Django admin
  └── /manage/*    → tech-team endpoints
  │
  ├── postgres:5432   (Django ORM / psycopg)
  └── redis:6379      (session cache)

mock-plc:48898
  └── ADS TCP protocol (pyads testserver)
  mock-plc:8080
  └── HTTP management API (/health, /state, /reset, /var/*)
```

---

## Administration Reference

Load the admin functions:
```bash
source infra/scripts/admin.sh
```

### Common Commands

```bash
# Full status overview
lugh_status

# View live Django logs
lugh_logs_django

# Restart Django (after config changes)
lugh_restart_django

# Check Django health API
lugh_health

# PostgreSQL shell
lugh_psql

# Backup database
lugh_db_backup

# Restore database
lugh_db_restore backup_20250101_120000.sql

# Redis CLI
lugh_redis_cli

# Mock PLC state inspection
lugh_mock_plc_state

# Reset mock PLC to defaults (all lights off)
lugh_mock_plc_reset

# Django management shell
lugh_django_shell

# Run migrations manually
lugh_django_migrate

# Deploy new image tag
lugh_deploy sha-abc1234

# Rollback Helm release
lugh_rollback   # rolls back one version
lugh_rollback 3  # rolls back to revision 3
```

---

## Upgrading

### Deploy a New Version

Push to `main` branch. GitHub Actions handles everything automatically:

```bash
git add .
git commit -m "feat: new feature"
git push origin main
# GitHub Actions runs: test → build → deploy
```

### Manual Deploy (without CI/CD)

```bash
# On the server
cd lugh
git pull

# Rebuild and push images (from laptop with Docker)
docker build -t ghcr.io/<owner>/lugh-django:manual .
docker push ghcr.io/<owner>/lugh-django:manual

# Deploy the new tag
helm upgrade lugh infra/helm/lugh -n lugh \
    --reuse-values \
    --set global.imageTag=manual \
    --wait
```

---

## Troubleshooting

### Pod stuck in `Pending`
```bash
kubectl describe pod <pod-name> -n lugh
# Usually: PVC not bound, resource limits, or image pull error
```

### Pod stuck in `CrashLoopBackOff`
```bash
kubectl logs <pod-name> -n lugh --previous
# Check for missing env vars, DB connection errors
```

### Django can't reach PostgreSQL
```bash
kubectl exec deployment/django -n lugh -- \
    python -c "import psycopg; psycopg.connect('host=postgres user=lugh_user dbname=lugh_db password=...')"
```

### Mock PLC not responding
```bash
kubectl logs deployment/mock-plc -n lugh
kubectl exec deployment/mock-plc -n lugh -- \
    python3 -c "import urllib.request; print(urllib.request.urlopen('http://localhost:8080/health').read())"
```

### Helm upgrade fails
```bash
# Check helm history
helm history lugh -n lugh

# Rollback
helm rollback lugh -n lugh

# Force clean install (WARNING: destroys PVCs)
helm uninstall lugh -n lugh
helm install lugh infra/helm/lugh -n lugh --create-namespace
```

### Image pull fails (private registry)
```bash
# Ensure pull secret exists
kubectl get secret ghcr-secret -n lugh

# Re-create if needed
kubectl create secret docker-registry ghcr-secret \
    --namespace lugh \
    --docker-server=ghcr.io \
    --docker-username=<github-username> \
    --docker-password=<GHCR_PAT> \
    --dry-run=client -o yaml | kubectl apply -f -
```

---

## Backup Procedure

```bash
# 1. Database backup
kubectl exec statefulset/postgres -n lugh -- \
    pg_dump -U lugh_user lugh_db > backup_$(date +%Y%m%d).sql

# 2. Static files backup (if needed)
kubectl cp lugh/$(kubectl get pod -l app=lugh-django -n lugh -o jsonpath='{.items[0].metadata.name}'):/app/staticfiles ./staticfiles-backup

# 3. Export Helm values
helm get values lugh -n lugh > values-backup.yaml
```

## Restore Procedure

```bash
# 1. Restore database
kubectl exec -i statefulset/postgres -n lugh -- \
    psql -U lugh_user -d lugh_db < backup_20250101.sql

# 2. Restart Django
kubectl rollout restart deployment/django -n lugh
```

---

## Security Notes

- All secrets stored in Kubernetes Secrets (base64, not plaintext)
- Django `DEBUG=false` in production
- Non-root containers throughout
- No hardcoded passwords anywhere in the codebase
- JWT tokens: 30-minute access, 7-day refresh
- Rate limiting: 200 req/min (configurable via Django middleware)
- PLC communication: server-side only — never exposed to Flutter app
- AuditLog: every control action recorded with user + timestamp

---

## Component Versions

| Component | Version |
|-----------|---------|
| Django | 5.2.12 |
| Gunicorn | 21.2.0 |
| PostgreSQL | 15-alpine |
| Redis | 7-alpine |
| NGINX | alpine |
| pyads | 3.5.2 |
| Python | 3.11 |
| k3s | latest stable |
| Helm | 3.14+ |

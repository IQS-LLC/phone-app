#!/usr/bin/env bash
# =============================================================================
# Lugh Smart Building Platform — Synology NAS First-Time Installation
#
# Tested on: Synology RS822+ (DSM 7.2)
# Run as:    root (sudo -i in SSH session)
# Usage:     curl -fsSL <url>/scripts/nas-install.sh | bash
#            — or —
#            bash nas-install.sh
#
# What this does:
#   1. Validates environment (DSM version, Docker, network)
#   2. Creates directory layout under /volume1/docker/lugh/
#   3. Generates a strong SECRET_KEY and prompts for remaining secrets
#   4. Writes .env, nginx.conf, and docker-compose.prod.yml
#   5. Pulls images and starts the stack
#   6. Runs migrations and creates a superuser
#   7. Verifies all services are healthy
#   8. Installs a Synology Task Scheduler entry for auto-start on boot
# =============================================================================

set -euo pipefail

# ── Colour helpers ─────────────────────────────────────────────────────────────
RED='\033[0;31m'; YEL='\033[1;33m'; GRN='\033[0;32m'; CYN='\033[0;36m'; RST='\033[0m'
info()    { echo -e "${CYN}[INFO]${RST}  $*"; }
success() { echo -e "${GRN}[OK]${RST}    $*"; }
warn()    { echo -e "${YEL}[WARN]${RST}  $*"; }
die()     { echo -e "${RED}[FAIL]${RST}  $*" >&2; exit 1; }

# ── Constants ──────────────────────────────────────────────────────────────────
LUGH_ROOT="/volume1/docker/lugh"
COMPOSE_FILE="$LUGH_ROOT/docker-compose.prod.yml"
ENV_FILE="$LUGH_ROOT/.env"
NGINX_CONF="$LUGH_ROOT/nginx.conf"
COMPOSE_URL="https://raw.githubusercontent.com/shara-a/lugh/main/docker-compose.prod.yml"
MIN_DSM_MAJOR=7
REQUIRED_DISK_GB=10

# ── 0. Root check ──────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "Run as root: sudo -i, then re-run this script."

echo ""
echo -e "${CYN}╔══════════════════════════════════════════════════════╗${RST}"
echo -e "${CYN}║      Lugh Smart Building Platform — NAS Install      ║${RST}"
echo -e "${CYN}╚══════════════════════════════════════════════════════╝${RST}"
echo ""

# ── 1. Environment checks ──────────────────────────────────────────────────────
info "Checking environment…"

# DSM version
if command -v synoinfo &>/dev/null; then
  DSM_VER=$(synoinfo get_section_key_value /etc/synoinfo.conf majorversion 2>/dev/null || echo "0")
  [[ "$DSM_VER" -ge "$MIN_DSM_MAJOR" ]] || die "DSM $MIN_DSM_MAJOR+ required (found $DSM_VER)."
  success "DSM version OK ($DSM_VER)"
else
  warn "synoinfo not found — skipping DSM version check (non-Synology host?)"
fi

# Docker
command -v docker &>/dev/null || die "Docker not found. Install Docker via Synology Package Center."
docker info &>/dev/null       || die "Docker daemon not running."
success "Docker OK ($(docker --version | awk '{print $3}' | tr -d ','))"

# docker compose v2
docker compose version &>/dev/null || die "Docker Compose v2 plugin not found."
success "Docker Compose OK"

# Free disk space on /volume1
AVAIL_GB=$(df -BG /volume1 | awk 'NR==2 {gsub("G",""); print $4}')
[[ "$AVAIL_GB" -ge "$REQUIRED_DISK_GB" ]] \
  || die "Need ${REQUIRED_DISK_GB}GB free on /volume1, only ${AVAIL_GB}GB available."
success "Disk space OK (${AVAIL_GB}GB free)"

# ── 2. Directory layout ────────────────────────────────────────────────────────
info "Creating directory layout under $LUGH_ROOT…"
for d in postgres_data redis_data static media; do
  mkdir -p "$LUGH_ROOT/$d"
done
chmod 750 "$LUGH_ROOT"
success "Directories created"

# ── 3. Collect secrets ─────────────────────────────────────────────────────────
info "Configuring secrets…"

# Generate SECRET_KEY automatically
SECRET_KEY=$(python3 -c "import secrets, string; \
  chars = string.ascii_letters + string.digits + '!@#%^&*(-_=+)'; \
  print(''.join(secrets.choice(chars) for _ in range(60)))")

# If .env already exists, offer to keep it
if [[ -f "$ENV_FILE" ]]; then
  warn ".env already exists at $ENV_FILE"
  read -rp "  Overwrite it? [y/N] " OVERWRITE
  [[ "${OVERWRITE,,}" == "y" ]] || { success "Keeping existing .env"; KEEP_ENV=1; }
fi

if [[ "${KEEP_ENV:-0}" != "1" ]]; then
  echo ""
  read -rp "Docker Hub username (for pulling lugh-django image): " DOCKERHUB_USERNAME
  [[ -n "$DOCKERHUB_USERNAME" ]] || die "Docker Hub username is required."

  read -rsp "PostgreSQL password (strong, no spaces): " PG_PASS; echo ""
  [[ -n "$PG_PASS" ]] || die "PostgreSQL password is required."

  read -rp "Django ALLOWED_HOSTS extras (comma-separated IPs/domains, e.g. 192.168.0.192): " EXTRA_HOSTS
  EXTRA_HOSTS="${EXTRA_HOSTS:-localhost}"

  read -rp "PLC IP address (e.g. 192.168.0.161): " PLC_IP
  PLC_IP="${PLC_IP:-192.168.0.161}"
  PLC_NETID="${PLC_IP}.1.1"

  read -rp "Subnet to scan for PLCs in Commissioning Wizard (CIDR, e.g. 192.168.0.0/24): " SCAN_SUBNET
  SCAN_SUBNET="${SCAN_SUBNET:-192.168.0.0/24}"

  cat > "$ENV_FILE" <<EOF
DOCKERHUB_USERNAME=${DOCKERHUB_USERNAME}
SECRET_KEY=${SECRET_KEY}
POSTGRES_PASSWORD=${PG_PASS}
EXTRA_ALLOWED_HOSTS=${EXTRA_HOSTS}
PLC_IP=${PLC_IP}
PLC_NETID=${PLC_NETID}
SCAN_SUBNET=${SCAN_SUBNET}
EOF
  chmod 600 "$ENV_FILE"
  success ".env written to $ENV_FILE"
fi

# Read back values for use below
# shellcheck disable=SC1090
source "$ENV_FILE"

# ── 4. Write nginx.conf ────────────────────────────────────────────────────────
if [[ ! -f "$NGINX_CONF" ]]; then
  info "Writing nginx.conf…"
  cat > "$NGINX_CONF" <<'NGINX'
server {
    listen 80;
    server_name _;

    client_max_body_size 50M;

    location /nginx-health {
        return 200 "healthy\n";
        add_header Content-Type text/plain;
    }

    location /static/ {
        alias /app/staticfiles/;
        expires 30d;
        add_header Cache-Control "public, immutable";
    }

    location /media/ {
        alias /app/media/;
        expires 7d;
    }

    location / {
        proxy_pass         http://django:8000;
        proxy_set_header   Host              $host;
        proxy_set_header   X-Real-IP         $remote_addr;
        proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;
        proxy_read_timeout 120s;
        proxy_connect_timeout 10s;
    }
}
NGINX
  success "nginx.conf written"
else
  info "nginx.conf already exists — skipping"
fi

# ── 5. Write docker-compose.prod.yml ──────────────────────────────────────────
if [[ ! -f "$COMPOSE_FILE" ]]; then
  info "Downloading docker-compose.prod.yml from GitHub…"
  if curl -fsSL "$COMPOSE_URL" -o "$COMPOSE_FILE" 2>/dev/null; then
    success "docker-compose.prod.yml downloaded"
  else
    die "Download failed. Copy docker-compose.prod.yml to $LUGH_ROOT manually, then re-run."
  fi
else
  info "docker-compose.prod.yml already present — skipping download"
fi

# ── 6. Pull images ─────────────────────────────────────────────────────────────
info "Pulling Docker images (this may take a few minutes)…"
docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" pull
success "Images pulled"

# ── 7. Start stack ─────────────────────────────────────────────────────────────
info "Starting stack…"
docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d
success "Stack started"

# ── 8. Wait for Django to be healthy ──────────────────────────────────────────
info "Waiting for Django to become healthy (up to 90s)…"
DEADLINE=$(( $(date +%s) + 90 ))
while true; do
  STATUS=$(docker inspect --format='{{.State.Health.Status}}' lugh_django 2>/dev/null || echo "starting")
  if [[ "$STATUS" == "healthy" ]]; then
    success "Django is healthy"
    break
  fi
  [[ $(date +%s) -lt $DEADLINE ]] || die "Django did not become healthy within 90s. Check: docker logs lugh_django"
  sleep 5
done

# ── 9. Create Django superuser ────────────────────────────────────────────────
echo ""
info "Creating Django superuser (admin account for Tech Team)…"
read -rp "  Superuser username: " SU_USER
read -rp "  Superuser email:    " SU_EMAIL
read -rsp "  Superuser password: " SU_PASS; echo ""

docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" exec django \
  python manage.py shell -c "
from django.contrib.auth import get_user_model
User = get_user_model()
if not User.objects.filter(username='${SU_USER}').exists():
    User.objects.create_superuser('${SU_USER}', '${SU_EMAIL}', '${SU_PASS}')
    print('Superuser created.')
else:
    print('Superuser already exists.')
"
success "Superuser ready"

# ── 10. Verify all services ────────────────────────────────────────────────────
echo ""
info "Service health summary:"
for SVC in lugh_db lugh_redis lugh_django lugh_nginx; do
  STATUS=$(docker inspect --format='{{.State.Health.Status}}' "$SVC" 2>/dev/null \
           || docker inspect --format='{{.State.Status}}' "$SVC" 2>/dev/null \
           || echo "not found")
  if [[ "$STATUS" == "healthy" || "$STATUS" == "running" ]]; then
    echo -e "  ${GRN}✓${RST}  $SVC  ($STATUS)"
  else
    echo -e "  ${RED}✗${RST}  $SVC  ($STATUS)"
    warn "Check: docker logs $SVC"
  fi
done

# ── 11. Auto-start on boot via Synology Task Scheduler ────────────────────────
TASK_SCRIPT="/volume1/docker/lugh/start.sh"
if [[ ! -f "$TASK_SCRIPT" ]]; then
  info "Writing boot script $TASK_SCRIPT…"
  cat > "$TASK_SCRIPT" <<BOOT
#!/bin/bash
# Lugh — auto-start on NAS boot
# Added by nas-install.sh. Do not edit manually.
sleep 30  # wait for Docker daemon to be fully ready
docker compose -f /volume1/docker/lugh/docker-compose.prod.yml \
  --env-file /volume1/docker/lugh/.env \
  up -d --remove-orphans
BOOT
  chmod +x "$TASK_SCRIPT"
  success "Boot script written"
fi

echo ""
warn "MANUAL STEP REQUIRED — Synology Task Scheduler:"
echo "  1. Open DSM → Control Panel → Task Scheduler"
echo "  2. Create → Triggered Task → User-defined script"
echo "  3. Event: Boot-up | User: root | Enabled: yes"
echo "  4. Task Settings → User-defined script:"
echo "       bash /volume1/docker/lugh/start.sh"
echo "  5. Save"
echo ""

# ── Done ───────────────────────────────────────────────────────────────────────
NAS_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}' || echo "<NAS_IP>")
echo -e "${GRN}╔══════════════════════════════════════════════════════╗${RST}"
echo -e "${GRN}║              Installation complete!                  ║${RST}"
echo -e "${GRN}╚══════════════════════════════════════════════════════╝${RST}"
echo ""
echo "  Platform URL:  http://${NAS_IP}:9080"
echo "  Admin panel:   http://${NAS_IP}:9080/admin/"
echo "  Health check:  http://${NAS_IP}:9080/health/"
echo ""
echo "  Next steps:"
echo "   1. Set Task Scheduler entry (see above)"
echo "   2. Open the Lugh app → Settings → enter http://${NAS_IP}:9080 as server URL"
echo "   3. Log in as ${SU_USER:-admin} and run the Commissioning Wizard"
echo ""

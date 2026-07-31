#!/usr/bin/env bash
# =============================================================================
# Lugh Smart Building Platform — Fresh VM Bootstrap
#
# For running the stack inside a VM (e.g. Ubuntu Server 22.04/24.04 LTS via
# Synology Virtual Machine Manager) instead of directly on DSM's Container
# Manager. Everything downstream of Docker (the compose stack, tunnel, CI/CD)
# is identical to the DSM-direct path in DEPLOYMENT_MANUAL.md — this script
# only covers what's different for a plain Linux VM: installing Docker itself
# (no Package Center), and a systemd service for boot-time start instead of
# DSM's Task Scheduler.
#
# Tested target: Ubuntu Server 22.04/24.04 LTS. Run as root (or via sudo).
# Usage: bash vm-bootstrap.sh
#
# What this does:
#   1. Validates environment (OS, disk space)
#   2. Installs Docker Engine + Compose plugin (skipped if already present)
#   3. Creates directory layout under /opt/lugh/
#   4. Generates a strong SECRET_KEY and prompts for remaining secrets
#   5. Writes .env, nginx.conf, and fetches docker-compose.prod.yml
#   6. Pulls images and starts the stack
#   7. Runs migrations and creates a superuser
#   8. Verifies all services are healthy
#   9. Installs a systemd service for auto-start on boot
# =============================================================================

set -euo pipefail

# ── Colour helpers ─────────────────────────────────────────────────────────────
RED='\033[0;31m'; YEL='\033[1;33m'; GRN='\033[0;32m'; CYN='\033[0;36m'; RST='\033[0m'
info()    { echo -e "${CYN}[INFO]${RST}  $*"; }
success() { echo -e "${GRN}[OK]${RST}    $*"; }
warn()    { echo -e "${YEL}[WARN]${RST}  $*"; }
die()     { echo -e "${RED}[FAIL]${RST}  $*" >&2; exit 1; }

# ── Constants ──────────────────────────────────────────────────────────────────
LUGH_ROOT="/opt/lugh"
COMPOSE_FILE="$LUGH_ROOT/docker-compose.prod.yml"
ENV_FILE="$LUGH_ROOT/.env"
NGINX_CONF="$LUGH_ROOT/nginx.conf"
COMPOSE_URL="https://raw.githubusercontent.com/IQS-LLC/phone-app/main/docker-compose.prod.yml"
REQUIRED_DISK_GB=10

# ── 0. Root check ──────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "Run as root: sudo bash vm-bootstrap.sh"

echo ""
echo -e "${CYN}╔══════════════════════════════════════════════════════╗${RST}"
echo -e "${CYN}║        Lugh Smart Building Platform — VM Bootstrap    ║${RST}"
echo -e "${CYN}╚══════════════════════════════════════════════════════╝${RST}"
echo ""

# ── 1. Environment checks ──────────────────────────────────────────────────────
info "Checking environment…"

if [[ -f /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  info "Detected OS: ${PRETTY_NAME:-unknown}"
  [[ "${ID:-}" == "ubuntu" || "${ID:-}" == "debian" ]] \
    || warn "This script targets Ubuntu/Debian — untested on ${ID:-this OS}, proceeding anyway."
else
  warn "/etc/os-release not found — skipping OS check."
fi

# Free disk space on /opt (or wherever it resolves to)
mkdir -p "$LUGH_ROOT"
AVAIL_GB=$(df -BG "$LUGH_ROOT" | awk 'NR==2 {gsub("G",""); print $4}')
[[ "$AVAIL_GB" -ge "$REQUIRED_DISK_GB" ]] \
  || die "Need ${REQUIRED_DISK_GB}GB free at $LUGH_ROOT, only ${AVAIL_GB}GB available."
success "Disk space OK (${AVAIL_GB}GB free)"

# ── 2. Install Docker + Compose plugin (skip if already present) ──────────────
if command -v docker &>/dev/null && docker compose version &>/dev/null; then
  success "Docker + Compose already installed ($(docker --version | awk '{print $3}' | tr -d ','))"
else
  info "Installing Docker Engine + Compose plugin…"
  apt-get update -qq
  apt-get install -y -qq ca-certificates curl gnupg
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  # shellcheck disable=SC1091
  . /etc/os-release
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME:-jammy} stable" \
    | tee /etc/apt/sources.list.d/docker.list > /dev/null
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
  docker info &>/dev/null || die "Docker installed but daemon isn't running — check: systemctl status docker"
  success "Docker + Compose installed"
fi

# ── 3. Directory layout ────────────────────────────────────────────────────────
info "Creating directory layout under $LUGH_ROOT…"
for d in postgres_data redis_data static media backups; do
  mkdir -p "$LUGH_ROOT/$d"
done
chmod 750 "$LUGH_ROOT"
success "Directories created"

# ── 4. Collect secrets ─────────────────────────────────────────────────────────
info "Configuring secrets…"

SECRET_KEY=$(python3 -c "import secrets, string; \
  chars = string.ascii_letters + string.digits + '!@#%^&*(-_=+)'; \
  print(''.join(secrets.choice(chars) for _ in range(60)))" 2>/dev/null \
  || openssl rand -base64 45)

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

  read -rp "Django ALLOWED_HOSTS extras (comma-separated IPs/domains): " EXTRA_HOSTS
  EXTRA_HOSTS="${EXTRA_HOSTS:-localhost}"

  read -rp "This VM's own LAN IP (must be reachable from the CX for AMS routing): " LOCAL_HOST
  [[ -n "$LOCAL_HOST" ]] || die "This VM's LAN IP is required for LOCAL_AMS_HOST/LOCAL_AMS_NET_ID."

  read -rp "PLC IP address (e.g. 192.168.0.161): " PLC_IP
  PLC_IP="${PLC_IP:-192.168.0.161}"
  PLC_NETID="${PLC_IP}.1.1"

  read -rp "Subnet to scan for PLCs in Commissioning Wizard (CIDR): " SCAN_SUBNET
  SCAN_SUBNET="${SCAN_SUBNET:-192.168.0.0/24}"

  read -rp "TwinCAT/CX embedded OS username (for auto route-repair, e.g. Administrator): " PLC_ROUTE_USER
  read -rsp "TwinCAT/CX embedded OS password: " PLC_ROUTE_PASS; echo ""
  [[ -n "$PLC_ROUTE_USER" && -n "$PLC_ROUTE_PASS" ]] \
    || warn "Left blank — auto route-repair will silently no-op until set later (see DEPLOYMENT_MANUAL.md 5.1)."

  cat > "$ENV_FILE" <<EOF
DOCKERHUB_USERNAME=${DOCKERHUB_USERNAME}
SECRET_KEY=${SECRET_KEY}
POSTGRES_PASSWORD=${PG_PASS}
DB_PASSWORD=${PG_PASS}
EXTRA_ALLOWED_HOSTS=${EXTRA_HOSTS}
PLC_MOCK=false
PLC_IP=${PLC_IP}
PLC_NETID=${PLC_NETID}
PLC_PORT=851
PLC_DISCOVERY_SUBNETS=${SCAN_SUBNET}
LOCAL_AMS_HOST=${LOCAL_HOST}
LOCAL_AMS_NET_ID=${LOCAL_HOST}.1.1
PLC_ROUTE_USERNAME=${PLC_ROUTE_USER}
PLC_ROUTE_PASSWORD=${PLC_ROUTE_PASS}
PLC_MODBUS_ENABLED=false
PLC_OUTAGE_WEBHOOK_URL=
HTTPS_ENABLED=false
BACKUP_RETENTION_DAYS=14
EOF
  chmod 600 "$ENV_FILE"
  success ".env written to $ENV_FILE"
fi

# shellcheck disable=SC1090
source "$ENV_FILE"

# ── 5. Write nginx.conf ────────────────────────────────────────────────────────
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

# ── 6. Write docker-compose.prod.yml ──────────────────────────────────────────
if [[ ! -f "$COMPOSE_FILE" ]]; then
  info "Downloading docker-compose.prod.yml from GitHub…"
  curl -fsSL "$COMPOSE_URL" -o "$COMPOSE_FILE" \
    || die "Download failed. Copy docker-compose.prod.yml to $LUGH_ROOT manually, then re-run."
  # This script uses /opt/lugh, not DSM's /volume1/docker/lugh — the
  # committed compose file's env_file/volumes paths assume the DSM path.
  sed -i "s#/volume1/docker/lugh#${LUGH_ROOT}#g" "$COMPOSE_FILE"
  success "docker-compose.prod.yml downloaded and paths adjusted for ${LUGH_ROOT}"
else
  info "docker-compose.prod.yml already present — skipping download"
fi

# ── 7. Pull images ─────────────────────────────────────────────────────────────
info "Pulling Docker images (this may take a few minutes)…"
docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" pull
success "Images pulled"

# ── 8. Start stack ─────────────────────────────────────────────────────────────
info "Starting stack…"
docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d
success "Stack started"

# ── 9. Wait for Django to be healthy ──────────────────────────────────────────
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

# ── 10. Create Django superuser ───────────────────────────────────────────────
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

# ── 11. Verify all services ────────────────────────────────────────────────────
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

# ── 12. Auto-start on boot via systemd ────────────────────────────────────────
SERVICE_FILE="/etc/systemd/system/lugh.service"
if [[ ! -f "$SERVICE_FILE" ]]; then
  info "Installing systemd service for boot-time start…"
  cat > "$SERVICE_FILE" <<SYSTEMD
[Unit]
Description=Lugh Smart Building Platform
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${LUGH_ROOT}
ExecStart=/usr/bin/docker compose -f ${COMPOSE_FILE} --env-file ${ENV_FILE} up -d --remove-orphans
ExecStop=/usr/bin/docker compose -f ${COMPOSE_FILE} --env-file ${ENV_FILE} down
TimeoutStartSec=180

[Install]
WantedBy=multi-user.target
SYSTEMD
  systemctl daemon-reload
  systemctl enable lugh.service
  success "systemd service installed and enabled (systemctl status lugh)"
else
  info "systemd service already installed — skipping"
fi

# ── Done ───────────────────────────────────────────────────────────────────────
VM_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}' || echo "<VM_IP>")
echo ""
echo -e "${GRN}╔══════════════════════════════════════════════════════╗${RST}"
echo -e "${GRN}║              Installation complete!                  ║${RST}"
echo -e "${GRN}╚══════════════════════════════════════════════════════╝${RST}"
echo ""
echo "  Platform URL:  http://${VM_IP}:9080"
echo "  Admin panel:   http://${VM_IP}:9080/admin/"
echo "  Health check:  http://${VM_IP}:9080/health/"
echo ""
echo "  Next steps:"
echo "   1. Continue from Section 4 (Network & Internet Access) in DEPLOYMENT_MANUAL.md"
echo "      — the tunnel, compose stack, and CI/CD steps from there are identical"
echo "        to the DSM-direct path."
echo "   2. Register a TwinCAT AMS route on the CX for ${LOCAL_HOST:-this VM}'s IP"
echo "      (System Manager → Routes → Add), or let auto route-repair do it —"
echo "      requires PLC_ROUTE_USERNAME/PASSWORD to be set (prompted above)."
echo "   3. Open the Lugh app → Settings → enter http://${VM_IP}:9080 as server URL"
echo "   4. Log in as ${SU_USER:-admin} and run the Commissioning Wizard"
echo ""

#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════════════
#  gogogo222.sh  —  Lugh Full-Stack Launch, Sync, Build & Deploy
# ════════════════════════════════════════════════════════════════════════════════
#
#  What it does (in order):
#    [1] Check all required tools are installed
#    [2] Start Docker Desktop if not running, switch to Linux context
#    [3] docker compose up — pull latest django image, bring stack up
#    [4] Wait for every container to be healthy
#    [5] Reload nginx (fixes upstream DNS caching after recreation)
#    [6] Start Cloudflare tunnel, capture the public HTTPS URL
#    [7] Update GitHub secret LUGH_SERVER_URL with the new tunnel URL
#    [8] Write build-manifest.json with current timestamp + URL
#    [9] git commit + push  → triggers CI rebuild for Android APK + iOS IPA
#   [10] Monitor CI run on GitHub Actions (streams per-job status)
#   [11] Download APK + IPA artifacts when CI finishes
#   [12] Print final summary — URL, app paths, CI link
#
#  Usage:
#    bash gogogo222.sh            # run every step
#    bash gogogo222.sh --no-wait  # run steps 1-9, exit (skip CI wait)
#    bash gogogo222.sh docker     # only steps 2-5 (stack only)
#    bash gogogo222.sh tunnel     # only steps 6-7 (tunnel + secret)
#    bash gogogo222.sh deploy     # only steps 8-11 (commit + CI + download + Helm)
#    bash gogogo222.sh status     # show running containers + current tunnel URL
#
#  Helm (optional — skips gracefully when disabled or cluster offline):
#    HELM_DEPLOY=true bash gogogo222.sh          # enable Helm deploy step
#    HELM_RELEASE=lugh                           # Helm release name (default: lugh)
#    HELM_NAMESPACE=lugh                         # k8s namespace  (default: lugh)
#    HELM_CHART=infra/helm/lugh                  # chart path relative to project dir
#    HELM_VALUES=infra/helm/lugh/values.prod.yaml  # optional extra values file
#    HELM_WAIT_TIMEOUT=300                       # seconds to wait for rollout
#
#  Logs:
#    Console: coloured, timestamped
#    File:    $LOG_DIR/gogogo222-YYYY-MM-DD_HH-MM-SS.log
#             $LOG_DIR/cloudflared-YYYY-MM-DD_HH-MM-SS.log   (cloudflared raw output)
#
#  Run from Git Bash on Windows.
# ════════════════════════════════════════════════════════════════════════════════

set -euo pipefail

# ────────────────────────────────────────────────────────────────────────────────
# [CONFIG] All tunables live here. Override with environment variables or edit.
# ────────────────────────────────────────────────────────────────────────────────

# Project
PROJECT_DIR="${PROJECT_DIR:-/c/Users/Automation/Desktop/phoneapp+apartment-16/phone-app}"
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.dev.yml}"

# Docker
DOCKER_DESKTOP_EXE="${DOCKER_DESKTOP_EXE:-/c/Program Files/Docker/Docker/Docker Desktop.exe}"
DOCKER_CONTEXT="${DOCKER_CONTEXT:-desktop-linux}"
NGINX_CONTAINER="${NGINX_CONTAINER:-lugh_nginx}"
DJANGO_CONTAINER="${DJANGO_CONTAINER:-lugh_django}"
DJANGO_IMAGE_SERVICE="${DJANGO_IMAGE_SERVICE:-django}"   # service name in compose file to pull

# Cloudflare
CLOUDFLARED_EXE="${CLOUDFLARED_EXE:-/c/Users/Automation/Desktop/cloudflared.exe}"
CLOUDFLARED_CONFIG="${CLOUDFLARED_CONFIG:-$HOME/.cloudflared/config.yml}"
TUNNEL_PORT="${TUNNEL_PORT:-8090}"

# GitHub
GITHUB_REPO="${GITHUB_REPO:-IQS-LLC/phone-app}"
GITHUB_SECRET_NAME="${GITHUB_SECRET_NAME:-LUGH_SERVER_URL}"
GIT_BRANCH="${GIT_BRANCH:-main}"
GIT_USER_EMAIL="${GIT_USER_EMAIL:-gogogo222@lugh.local}"
GIT_USER_NAME="${GIT_USER_NAME:-gogogo222-bot}"
ARTIFACT_APK_NAME="${ARTIFACT_APK_NAME:-lugh-android-apk}"
ARTIFACT_IPA_NAME="${ARTIFACT_IPA_NAME:-lugh-ios-ipa}"

# Output paths
LOG_DIR="${LOG_DIR:-/c/ProgramData/Lugh/logs}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-/c/ProgramData/Lugh/artifacts}"
DESKTOP_DIR="${DESKTOP_DIR:-/c/Users/Automation/Desktop}"
BUILD_MANIFEST_FILE="${PROJECT_DIR}/build-manifest.json"

# Timeouts (seconds)
WAIT_DOCKER="${WAIT_DOCKER:-120}"           # max wait for Docker Desktop engine
WAIT_DOCKER_POLL="${WAIT_DOCKER_POLL:-5}"   # polling interval while waiting for docker
WAIT_HEALTHY="${WAIT_HEALTHY:-120}"         # max wait for containers to be healthy
WAIT_HEALTHY_POLL="${WAIT_HEALTHY_POLL:-5}" # polling interval
WAIT_TUNNEL="${WAIT_TUNNEL:-60}"            # max wait for cloudflared URL
WAIT_TUNNEL_POLL="${WAIT_TUNNEL_POLL:-3}"   # polling interval
WAIT_CI="${WAIT_CI:-1800}"                  # max wait for CI run (30 min)
CI_POLL="${CI_POLL:-20}"                    # CI polling interval
WAIT_CI_APPEAR="${WAIT_CI_APPEAR:-90}"      # max wait for CI run to appear after push

# ────────────────────────────────────────────────────────────────────────────────
# [GLOBALS] Internal state — do not edit
# ────────────────────────────────────────────────────────────────────────────────

SCRIPT_VERSION="1.1.0"
SCRIPT_NAME="gogogo222"
SCRIPT_START=$(date +%s)
RUN_TS=$(date +%Y-%m-%d_%H-%M-%S)
RUN_DATE_HUMAN=$(date '+%Y-%m-%d %H:%M:%S')

LOG_FILE="${LOG_DIR}/${SCRIPT_NAME}-${RUN_TS}.log"
CF_LOG="${LOG_DIR}/cloudflared-${RUN_TS}.log"
CF_PID_FILE="${LOG_DIR}/cloudflared.pid"

TUNNEL_URL=""
CI_RUN_ID=""
CI_STATUS=""
CF_PID=""
PREV_TUNNEL_URL=""

NO_WAIT=false
STEP_ONLY=""     # if set, only run this step

# ────────────────────────────────────────────────────────────────────────────────
# [COLORS] ANSI — degrade gracefully when not a TTY
# ────────────────────────────────────────────────────────────────────────────────

if [ -t 1 ]; then
  RED='\033[0;31m';  GREEN='\033[0;32m'; YELLOW='\033[1;33m'
  CYAN='\033[0;36m'; WHITE='\033[1;37m'; DIM='\033[2m'
  BOLD='\033[1m';    RESET='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; CYAN=''; WHITE=''; DIM=''; BOLD=''; RESET=''
fi

# ────────────────────────────────────────────────────────────────────────────────
# [LOGGING] Every message goes to console AND log file
# ────────────────────────────────────────────────────────────────────────────────

mkdir -p "$LOG_DIR" "$ARTIFACTS_DIR"

_ts() { date '+%H:%M:%S'; }

_log_raw() {
    local level="$1"; shift
    local msg="$*"
    local color line_plain line_color

    case "$level" in
        INFO)  color="$CYAN"   ;;
        OK)    color="$GREEN"  ;;
        WARN)  color="$YELLOW" ;;
        ERROR) color="$RED"    ;;
        STEP)  color="$BOLD$WHITE" ;;
        DATA)  color="$DIM"    ;;
        *)     color="$RESET"  ;;
    esac

    line_plain="[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $msg"
    line_color="${color}[${BOLD}$(_ts)${RESET}${color}][${level}]${RESET} ${msg}"

    printf '%s\n' "$line_plain" >> "$LOG_FILE"
    printf "${line_color}\n"
}

log()       { _log_raw INFO  "$@"; }
log_ok()    { _log_raw OK    "✓ $*"; }
log_warn()  { _log_raw WARN  "⚠ $*"; }
log_error() { _log_raw ERROR "✗ $*"; }
log_data()  { _log_raw DATA  "  $*"; }

log_step() {
    local title="$*"
    local bar="────────────────────────────────────────"
    printf '\n' | tee -a "$LOG_FILE"
    _log_raw STEP "┌${bar}"
    _log_raw STEP "│  ${title}"
    _log_raw STEP "└${bar}"
}

log_cmd() {
    # Run a command, tee all output (stdout+stderr) to both console and log file
    local cmd="$*"
    log_data "$ ${cmd}"
    eval "$cmd" 2>&1 | while IFS= read -r line; do
        _log_raw DATA "$line"
    done
    return "${PIPESTATUS[0]:-0}"
}

die() {
    log_error "$*"
    log_error "Full log: ${LOG_FILE}"
    exit 1
}

elapsed() {
    local secs=$(( $(date +%s) - SCRIPT_START ))
    printf '%dm%02ds' $(( secs / 60 )) $(( secs % 60 ))
}

# ────────────────────────────────────────────────────────────────────────────────
# [CLEANUP] On exit — always print where the log is
# ────────────────────────────────────────────────────────────────────────────────

_on_exit() {
    local code=$?
    if [ $code -ne 0 ]; then
        log_error "Script aborted (exit $code) after $(elapsed)"
    fi
    log "Log saved: ${LOG_FILE}"
    if [ -n "$CF_LOG" ] && [ -f "$CF_LOG" ]; then
        log "Cloudflared log: ${CF_LOG}"
    fi
}
trap _on_exit EXIT

# ────────────────────────────────────────────────────────────────────────────────
# [ARGS] Parse command-line arguments
# ────────────────────────────────────────────────────────────────────────────────

parse_args() {
    for arg in "$@"; do
        case "$arg" in
            --no-wait) NO_WAIT=true ;;
            docker|tunnel|deploy|status) STEP_ONLY="$arg" ;;
            --help|-h)
                grep '^#  ' "$0" | sed 's/^#  //'
                exit 0
                ;;
            *)
                log_warn "Unknown argument: $arg (ignored)"
                ;;
        esac
    done
}

# ────────────────────────────────────────────────────────────────────────────────
# STEP 1 — Check dependencies
# ────────────────────────────────────────────────────────────────────────────────

step_check_deps() {
    log_step "STEP 1 / DEPENDENCY CHECK"

    local missing=0
    for cmd in docker git gh curl; do
        if command -v "$cmd" &>/dev/null; then
            local ver
            ver=$(eval "$cmd --version 2>/dev/null | head -1" || echo "?")
            log_ok "${cmd}: ${ver}"
        else
            log_error "Missing required tool: ${cmd}"
            (( missing++ )) || true
        fi
    done

    # cloudflared is optional but logged
    if [ -f "$CLOUDFLARED_EXE" ]; then
        local cf_ver; cf_ver=$("$CLOUDFLARED_EXE" --version 2>/dev/null | head -1 || echo "?")
        log_ok "cloudflared: ${cf_ver}"
    else
        log_warn "cloudflared not found at ${CLOUDFLARED_EXE} — tunnel step will be skipped"
    fi

    # Named tunnel config (overrides quick tunnel)
    if [ -f "$CLOUDFLARED_CONFIG" ]; then
        log_ok "Named tunnel config: ${CLOUDFLARED_CONFIG}"
    fi

    # GitHub CLI: check auth
    if command -v gh &>/dev/null; then
        local gh_user; gh_user=$(gh auth status 2>&1 | grep 'Logged in' || echo "not logged in")
        log_data "gh auth: ${gh_user}"
    fi

    # Git: check repo
    if git -C "$PROJECT_DIR" rev-parse HEAD &>/dev/null; then
        log_ok "git repo: ${PROJECT_DIR}"
    else
        log_warn "Not a git repo: ${PROJECT_DIR}"
    fi

    [ $missing -eq 0 ] || die "Fix ${missing} missing tool(s) then re-run"
    log_ok "All dependencies OK"
}

# ────────────────────────────────────────────────────────────────────────────────
# STEP 2 — Docker Desktop
# ────────────────────────────────────────────────────────────────────────────────

step_docker_desktop() {
    log_step "STEP 2 / DOCKER DESKTOP"

    # Switch context first (no-op if already correct)
    docker context use "$DOCKER_CONTEXT" >> "$LOG_FILE" 2>&1 || true
    log_data "Docker context: ${DOCKER_CONTEXT}"

    # Fast path — already running
    if docker info >> "$LOG_FILE" 2>&1; then
        local info; info=$(docker info 2>/dev/null | grep -E 'Server Version|OS Type|Total Memory' | head -3 || true)
        log_ok "Docker Desktop already running"
        while IFS= read -r line; do log_data "$line"; done <<< "$info"
        return 0
    fi

    log "Docker Desktop not running — launching..."
    if [ -f "$DOCKER_DESKTOP_EXE" ]; then
        "$DOCKER_DESKTOP_EXE" >> "$LOG_FILE" 2>&1 &
        log_data "Launched: ${DOCKER_DESKTOP_EXE}"
    else
        log_warn "Docker Desktop exe not found at '${DOCKER_DESKTOP_EXE}'"
        log_warn "Please start Docker Desktop manually then re-run"
    fi

    log "Waiting up to ${WAIT_DOCKER}s for Docker engine..."
    local elapsed=0
    while [ $elapsed -lt "$WAIT_DOCKER" ]; do
        sleep "$WAIT_DOCKER_POLL"
        elapsed=$(( elapsed + WAIT_DOCKER_POLL ))
        docker context use "$DOCKER_CONTEXT" >> "$LOG_FILE" 2>&1 || true
        if docker info >> "$LOG_FILE" 2>&1; then
            log_ok "Docker Desktop ready (${elapsed}s)"
            return 0
        fi
        log_data "  ...engine not ready yet (${elapsed}/${WAIT_DOCKER}s)"
    done

    die "Docker Desktop did not start within ${WAIT_DOCKER}s"
}

# ────────────────────────────────────────────────────────────────────────────────
# STEP 3 — Docker Compose stack
# ────────────────────────────────────────────────────────────────────────────────

step_compose_up() {
    log_step "STEP 3 / DOCKER COMPOSE STACK"

    cd "$PROJECT_DIR"
    log_data "compose file: ${PROJECT_DIR}/${COMPOSE_FILE}"

    # Pull only the Django image (avoids Docker Hub rate limits for base images)
    log "Pulling latest Django image from GHCR..."
    if docker compose -f "$COMPOSE_FILE" pull "$DJANGO_IMAGE_SERVICE" >> "$LOG_FILE" 2>&1; then
        log_ok "Django image pulled"
    else
        log_warn "Pull failed — will use cached image (this is OK)"
    fi

    # Bring the entire stack up
    log "Running: docker compose up -d --remove-orphans"
    if docker compose -f "$COMPOSE_FILE" up -d --remove-orphans 2>&1 | tee -a "$LOG_FILE"; then
        log_ok "docker compose up done"
    else
        die "docker compose up failed — check log: ${LOG_FILE}"
    fi
}

# ────────────────────────────────────────────────────────────────────────────────
# STEP 4 — Wait for containers to be healthy
# ────────────────────────────────────────────────────────────────────────────────

step_wait_healthy() {
    log_step "STEP 4 / CONTAINER HEALTH"

    cd "$PROJECT_DIR"

    log "Waiting up to ${WAIT_HEALTHY}s for all containers to be healthy..."
    local elapsed=0
    while [ $elapsed -lt "$WAIT_HEALTHY" ]; do
        sleep "$WAIT_HEALTHY_POLL"
        elapsed=$(( elapsed + WAIT_HEALTHY_POLL ))

        # Count containers NOT in a healthy/running steady state
        local not_ready
        not_ready=$(docker compose -f "$COMPOSE_FILE" ps --format json 2>/dev/null \
            | grep -cE '"health":"(starting|unhealthy)"|"State":"restarting"' 2>/dev/null || echo 0)

        local total
        total=$(docker compose -f "$COMPOSE_FILE" ps -q 2>/dev/null | wc -l)

        log_data "Containers: ${total} total — ${not_ready} not ready (${elapsed}/${WAIT_HEALTHY}s)"

        if [ "$not_ready" -eq 0 ] && [ "$total" -gt 0 ]; then
            log_ok "All containers reached healthy/running state"
            break
        fi
    done

    # Print final container table to both console and log
    log "Container status:"
    docker compose -f "$COMPOSE_FILE" ps 2>&1 | tee -a "$LOG_FILE"

    # Dump recent logs from each container for troubleshooting
    log "Capturing recent container logs..."
    for svc in $(docker compose -f "$COMPOSE_FILE" ps --services 2>/dev/null); do
        local svc_log="${LOG_DIR}/container-${svc}-${RUN_TS}.log"
        docker compose -f "$COMPOSE_FILE" logs --tail=50 "$svc" > "$svc_log" 2>&1
        log_data "  ${svc} logs → ${svc_log}"
    done
    log_ok "Container logs saved to ${LOG_DIR}/"
}

# ────────────────────────────────────────────────────────────────────────────────
# STEP 5 — Nginx reload (fix upstream DNS caching)
# ────────────────────────────────────────────────────────────────────────────────

step_nginx_reload() {
    log_step "STEP 5 / NGINX DNS RELOAD"

    log "Reloading nginx upstream resolution..."
    if docker exec "$NGINX_CONTAINER" nginx -s reload 2>&1 | tee -a "$LOG_FILE"; then
        log_ok "nginx reloaded — upstream IPs re-resolved"
    else
        log_warn "nginx reload failed (container may still be starting — will retry)"
        sleep 5
        if docker exec "$NGINX_CONTAINER" nginx -s reload 2>&1 | tee -a "$LOG_FILE"; then
            log_ok "nginx reloaded on retry"
        else
            log_warn "nginx reload still failed — stack may be unhealthy"
        fi
    fi

    # Health check via nginx → django path
    log "Health check via nginx (localhost:${TUNNEL_PORT}/health/)..."
    local health; health=$(curl -sf --max-time 10 "http://localhost:${TUNNEL_PORT}/health/" 2>/dev/null || echo "")
    if [ "$health" = "healthy" ]; then
        log_ok "Stack health: healthy"
    else
        log_warn "Health response: '${health}' — nginx may need a moment"
        sleep 5
        health=$(curl -sf --max-time 10 "http://localhost:${TUNNEL_PORT}/health/" 2>/dev/null || echo "")
        [ "$health" = "healthy" ] && log_ok "Stack health (retry): healthy" || \
            log_warn "Stack health: '${health}' — continuing anyway"
    fi
}

# ────────────────────────────────────────────────────────────────────────────────
# STEP 6 — Cloudflare tunnel
# ────────────────────────────────────────────────────────────────────────────────

step_tunnel() {
    log_step "STEP 6 / CLOUDFLARE TUNNEL"

    # ── Named tunnel (permanent URL) ─────────────────────────────────────────
    if [ -f "$CLOUDFLARED_CONFIG" ]; then
        log_ok "Named tunnel config found: ${CLOUDFLARED_CONFIG}"
        # Extract hostname from config (permanent URL — never changes)
        TUNNEL_URL=$(grep -oE 'hostname:\s*\S+' "$CLOUDFLARED_CONFIG" 2>/dev/null \
            | awk '{print $2}' | head -1 || echo "")
        [ -n "$TUNNEL_URL" ] && TUNNEL_URL="https://${TUNNEL_URL}"

        # The named tunnel runs as a Windows service; check it's active
        local svc_status
        svc_status=$(sc.exe query cloudflared 2>/dev/null | grep STATE || echo "")
        if echo "$svc_status" | grep -q "RUNNING"; then
            log_ok "cloudflared service: RUNNING"
        else
            log_warn "cloudflared service not running — starting it"
            sc.exe start cloudflared >> "$LOG_FILE" 2>&1 || \
                log_warn "Could not start cloudflared service — start it manually"
        fi

        log_ok "Permanent tunnel URL: ${TUNNEL_URL}"
        return 0
    fi

    # ── Quick tunnel (random URL per session) ────────────────────────────────
    if [ ! -f "$CLOUDFLARED_EXE" ]; then
        log_warn "cloudflared not found — skipping tunnel (apps will use last known URL)"
        return 0
    fi

    # Read previous URL (if any) for comparison in summary
    PREV_TUNNEL_URL=$(cat "${LOG_DIR}/current-tunnel-url.txt" 2>/dev/null || echo "")

    # Kill any running cloudflared quick tunnel so we get a fresh URL
    log "Stopping any existing cloudflared quick tunnel..."
    local old_pid; old_pid=$(cat "$CF_PID_FILE" 2>/dev/null || echo "")
    if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
        kill "$old_pid" 2>/dev/null || true
        log_data "Killed old cloudflared PID ${old_pid}"
    fi
    # Also try by process name on Windows
    cmd //c "taskkill /F /IM cloudflared.exe" >> "$LOG_FILE" 2>&1 || true
    sleep 2

    log "Starting cloudflared quick tunnel on port ${TUNNEL_PORT}..."
    log_data "cloudflared log: ${CF_LOG}"

    "$CLOUDFLARED_EXE" tunnel \
        --url "http://localhost:${TUNNEL_PORT}" \
        --no-autoupdate \
        --loglevel info \
        > "$CF_LOG" 2>&1 &
    CF_PID=$!
    echo "$CF_PID" > "$CF_PID_FILE"
    log_data "cloudflared PID: ${CF_PID}"

    # Wait for tunnel URL to appear in cloudflared output
    log "Waiting up to ${WAIT_TUNNEL}s for tunnel URL..."
    local elapsed=0
    while [ $elapsed -lt "$WAIT_TUNNEL" ]; do
        sleep "$WAIT_TUNNEL_POLL"
        elapsed=$(( elapsed + WAIT_TUNNEL_POLL ))

        TUNNEL_URL=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$CF_LOG" 2>/dev/null \
            | head -1 || echo "")

        if [ -n "$TUNNEL_URL" ]; then
            log_ok "Tunnel URL: ${TUNNEL_URL}"
            echo "$TUNNEL_URL" > "${LOG_DIR}/current-tunnel-url.txt"
            break
        fi

        # Log any error lines from cloudflared
        grep -i "error\|ERR" "$CF_LOG" 2>/dev/null | tail -2 | \
            while IFS= read -r line; do log_data "  cf: $line"; done

        log_data "  ...waiting for URL (${elapsed}/${WAIT_TUNNEL}s)"
    done

    if [ -z "$TUNNEL_URL" ]; then
        log_warn "Tunnel URL not captured after ${WAIT_TUNNEL}s"
        log_warn "Check cloudflared log: ${CF_LOG}"
        log_warn "Continuing without tunnel — secret will not be updated"
        return 0
    fi

    # Verify the tunnel reaches the backend end-to-end
    log "Testing tunnel → backend end-to-end..."
    local resp; resp=$(curl -sf --max-time 15 "${TUNNEL_URL}/health/" 2>/dev/null || echo "")
    if [ "$resp" = "healthy" ]; then
        log_ok "End-to-end tunnel test: healthy"
    else
        log_warn "Tunnel test returned: '${resp}' — backend may still be warming up"
    fi
}

# ────────────────────────────────────────────────────────────────────────────────
# STEP 7 — Update GitHub secret
# ────────────────────────────────────────────────────────────────────────────────

step_update_secret() {
    log_step "STEP 7 / GITHUB SECRET"

    if [ -z "$TUNNEL_URL" ]; then
        log_warn "No tunnel URL — skipping secret update"
        return 0
    fi

    if [ "$TUNNEL_URL" = "$PREV_TUNNEL_URL" ]; then
        log "URL unchanged from previous run (${TUNNEL_URL})"
        log "Secret update: skipped (same URL)"
    else
        log "Setting ${GITHUB_SECRET_NAME} = ${TUNNEL_URL}"
        if gh secret set "$GITHUB_SECRET_NAME" \
            --body "$TUNNEL_URL" \
            --repo "$GITHUB_REPO" >> "$LOG_FILE" 2>&1; then
            log_ok "GitHub secret updated: ${GITHUB_SECRET_NAME}"
        else
            log_error "Failed to update GitHub secret — check gh auth"
        fi
    fi

    # Show all secrets (names only, not values)
    log "Current secrets in ${GITHUB_REPO}:"
    gh secret list --repo "$GITHUB_REPO" 2>&1 | tee -a "$LOG_FILE" | \
        while IFS= read -r line; do log_data "  $line"; done || true
}

# ────────────────────────────────────────────────────────────────────────────────
# STEP 8 — Write build manifest + git commit + push
# ────────────────────────────────────────────────────────────────────────────────

step_commit_push() {
    log_step "STEP 8 / BUILD MANIFEST + GIT COMMIT + PUSH"

    cd "$PROJECT_DIR"

    local build_date; build_date=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    local build_ts;   build_ts=$(date +%s)
    local git_sha;    git_sha=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
    local build_num;  build_num=$(( build_ts % 1000000 ))

    log "Writing ${BUILD_MANIFEST_FILE}..."
    cat > "$BUILD_MANIFEST_FILE" <<EOF
{
  "_note": "Auto-updated by gogogo222.sh — do not edit manually",
  "build_date": "${build_date}",
  "build_timestamp": ${build_ts},
  "build_number": ${build_num},
  "server_url": "${TUNNEL_URL:-unknown}",
  "git_sha_before": "${git_sha}",
  "trigger": "${SCRIPT_NAME}",
  "run_ts": "${RUN_TS}"
}
EOF
    log_ok "build-manifest.json written"
    log_data "  server_url: ${TUNNEL_URL:-unknown}"
    log_data "  build_date: ${build_date}"
    log_data "  build_num:  ${build_num}"

    # Stage only the manifest (don't accidentally commit secrets or binaries)
    git add "$BUILD_MANIFEST_FILE"

    # Set git identity for the commit
    git config user.email "$GIT_USER_EMAIL" 2>/dev/null || true
    git config user.name  "$GIT_USER_NAME"  2>/dev/null || true

    # Check if there's something staged
    if git diff --staged --quiet; then
        log_warn "No changes staged (manifest unchanged?) — forcing empty rebuild commit"
        git commit --allow-empty \
            -m "ci: rebuild ${build_date} url=${TUNNEL_URL:-no-tunnel}" \
            2>&1 | tee -a "$LOG_FILE"
    else
        git commit \
            -m "ci: rebuild ${build_date} url=${TUNNEL_URL:-no-tunnel}" \
            2>&1 | tee -a "$LOG_FILE"
    fi

    log "Pushing to origin/${GIT_BRANCH}..."
    git push origin "$GIT_BRANCH" 2>&1 | tee -a "$LOG_FILE"

    local pushed_sha; pushed_sha=$(git rev-parse HEAD)
    log_ok "Pushed commit ${pushed_sha:0:7} to ${GIT_BRANCH}"
    log_ok "CI will now build: Android APK + iOS IPA + Django image"
    echo "$pushed_sha" > "${LOG_DIR}/last-pushed-sha.txt"
}

# ────────────────────────────────────────────────────────────────────────────────
# STEP 9 — Monitor CI run
# ────────────────────────────────────────────────────────────────────────────────

step_wait_ci() {
    log_step "STEP 9 / CI BUILD MONITOR"

    if $NO_WAIT; then
        log_warn "--no-wait set: skipping CI monitoring"
        log "Watch CI at: https://github.com/${GITHUB_REPO}/actions"
        return 0
    fi

    # Find the run triggered by our push (poll until it appears)
    local pushed_sha; pushed_sha=$(cat "${LOG_DIR}/last-pushed-sha.txt" 2>/dev/null || echo "")
    log "Looking for CI run for commit ${pushed_sha:0:7}..."

    local elapsed=0
    while [ $elapsed -lt "$WAIT_CI_APPEAR" ]; do
        sleep 5; elapsed=$(( elapsed + 5 ))

        CI_RUN_ID=$(gh run list \
            --repo "$GITHUB_REPO" \
            --branch "$GIT_BRANCH" \
            --event push \
            --limit 5 \
            --json databaseId,headSha \
            --jq ".[] | select(.headSha == \"${pushed_sha}\") | .databaseId" \
            2>/dev/null | head -1 || echo "")

        if [ -z "$CI_RUN_ID" ] || [ "$CI_RUN_ID" = "null" ]; then
            # Fallback: just take the very latest run
            CI_RUN_ID=$(gh run list \
                --repo "$GITHUB_REPO" \
                --branch "$GIT_BRANCH" \
                --event push \
                --limit 1 \
                --json databaseId \
                --jq '.[0].databaseId' \
                2>/dev/null || echo "")
        fi

        if [ -n "$CI_RUN_ID" ] && [ "$CI_RUN_ID" != "null" ]; then
            log_ok "CI run found: #${CI_RUN_ID}"
            log_data "  https://github.com/${GITHUB_REPO}/actions/runs/${CI_RUN_ID}"
            break
        fi

        log_data "  ...run not yet visible (${elapsed}/${WAIT_CI_APPEAR}s)"
    done

    if [ -z "$CI_RUN_ID" ] || [ "$CI_RUN_ID" = "null" ]; then
        log_warn "CI run not found — check GitHub Actions manually"
        log_warn "  https://github.com/${GITHUB_REPO}/actions"
        CI_RUN_ID=""
        return 1
    fi

    # Poll until CI completes
    log "Polling CI run #${CI_RUN_ID} every ${CI_POLL}s (max ${WAIT_CI}s)..."
    local elapsed=0
    while [ $elapsed -lt "$WAIT_CI" ]; do
        sleep "$CI_POLL"; elapsed=$(( elapsed + CI_POLL ))

        local run_json
        run_json=$(gh run view "$CI_RUN_ID" \
            --repo "$GITHUB_REPO" \
            --json status,conclusion,jobs \
            2>/dev/null || echo '{"status":"unknown","conclusion":null,"jobs":[]}')

        local status conclusion
        status=$(echo "$run_json"     | grep -o '"status":"[^"]*"'     | head -1 | cut -d'"' -f4 || echo "unknown")
        conclusion=$(echo "$run_json" | grep -o '"conclusion":"[^"]*"'  | head -1 | cut -d'"' -f4 || echo "pending")

        # Per-job summary
        log "CI #${CI_RUN_ID} [${elapsed}s/${WAIT_CI}s] — ${status} / ${conclusion}"
        echo "$run_json" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    for j in d.get('jobs', []):
        c = (j.get('conclusion') or j.get('status') or '?').upper()
        icon = '✓' if c == 'SUCCESS' else ('✗' if c in ('FAILURE','CANCELLED') else '…')
        print(f'  {icon} [{c}] {j[\"name\"]}')
except: pass
" 2>/dev/null | while IFS= read -r line; do log_data "$line"; done || true

        if [ "$status" = "completed" ]; then
            CI_STATUS="$conclusion"
            case "$conclusion" in
                success)
                    log_ok "CI build succeeded!"
                    return 0
                    ;;
                failure)
                    # Check if build jobs passed even if deploy failed (NAS offline)
                    local builds_ok
                    builds_ok=$(echo "$run_json" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    names = ['Build Android APK', 'Build iOS IPA']
    ok = all(
        any(j['name'] == n and j.get('conclusion') == 'success' for j in d.get('jobs',[]))
        for n in names
    )
    print('true' if ok else 'false')
except: print('false')
" 2>/dev/null || echo "false")
                    if [ "$builds_ok" = "true" ]; then
                        log_warn "CI shows 'failure' but build jobs (Android + iOS) succeeded"
                        log_warn "(Deploy job likely failed — NAS offline. That's expected.)"
                        CI_STATUS="partial"
                        return 0
                    fi
                    log_error "CI build failed"
                    log_error "  https://github.com/${GITHUB_REPO}/actions/runs/${CI_RUN_ID}"
                    return 1
                    ;;
                cancelled)
                    log_warn "CI was cancelled"
                    CI_STATUS="cancelled"
                    return 1
                    ;;
                *)
                    log_warn "Unexpected conclusion: ${conclusion}"
                    CI_STATUS="$conclusion"
                    return 1
                    ;;
            esac
        fi
    done

    log_warn "CI timed out after ${WAIT_CI}s — run may still be in progress"
    log_warn "  https://github.com/${GITHUB_REPO}/actions/runs/${CI_RUN_ID}"
    CI_STATUS="timeout"
    return 1
}

# ────────────────────────────────────────────────────────────────────────────────
# STEP 10 — Download artifacts
# ────────────────────────────────────────────────────────────────────────────────

step_download_artifacts() {
    log_step "STEP 10 / ARTIFACT DOWNLOAD"

    if [ -z "$CI_RUN_ID" ]; then
        log_warn "No CI run ID — cannot download artifacts"
        return 0
    fi

    local out="${ARTIFACTS_DIR}/${RUN_TS}"
    mkdir -p "$out"
    log "Artifact destination: ${out}"

    # APK
    log "Downloading Android APK (${ARTIFACT_APK_NAME})..."
    if gh run download "$CI_RUN_ID" \
        --repo "$GITHUB_REPO" \
        --name "$ARTIFACT_APK_NAME" \
        --dir "$out" 2>&1 | tee -a "$LOG_FILE"; then

        local apk; apk=$(find "$out" -name "*.apk" | head -1)
        if [ -n "$apk" ]; then
            local dest="${DESKTOP_DIR}/lugh-android-latest.apk"
            cp "$apk" "$dest"
            local size; size=$(du -sh "$dest" 2>/dev/null | cut -f1)
            log_ok "APK: ${dest} (${size})"
        else
            log_warn "APK artifact downloaded but no .apk file found in ${out}"
        fi
    else
        log_warn "APK download failed (check CI log)"
    fi

    # IPA
    log "Downloading iOS IPA (${ARTIFACT_IPA_NAME})..."
    if gh run download "$CI_RUN_ID" \
        --repo "$GITHUB_REPO" \
        --name "$ARTIFACT_IPA_NAME" \
        --dir "$out" 2>&1 | tee -a "$LOG_FILE"; then

        local ipa; ipa=$(find "$out" -name "*.ipa" | head -1)
        if [ -n "$ipa" ]; then
            local dest="${DESKTOP_DIR}/lugh-ios-latest.ipa"
            cp "$ipa" "$dest"
            local size; size=$(du -sh "$dest" 2>/dev/null | cut -f1)
            log_ok "IPA: ${dest} (${size})"
        else
            log_warn "IPA artifact downloaded but no .ipa file found in ${out}"
        fi
    else
        log_warn "IPA download failed (check CI log)"
    fi
}

# ────────────────────────────────────────────────────────────────────────────────
# HELM DEPLOY — upgrade the k3s / Kubernetes cluster if available
#
# Environment vars (all optional — step always skips gracefully when unset):
#   HELM_DEPLOY=true         enable this step
#   HELM_RELEASE=lugh        Helm release name (default: lugh)
#   HELM_NAMESPACE=lugh      k8s namespace (default: lugh)
#   HELM_CHART=infra/helm/lugh  path to chart directory (relative to PROJECT_DIR)
#   HELM_VALUES=             path to extra values file (optional)
#   KUBECONFIG               path to kubeconfig (default: ~/.kube/config)
#   HELM_WAIT_TIMEOUT=300    seconds to wait for rollout (default: 300)
# ────────────────────────────────────────────────────────────────────────────────

step_helm_deploy() {
    log_step "STEP HELM / KUBERNETES DEPLOY"

    # ── Guard: opt-in only ──────────────────────────────────────────────────
    if [ "${HELM_DEPLOY:-false}" != "true" ]; then
        log "HELM_DEPLOY is not 'true' — skipping Helm deploy (Docker Compose mode)"
        log_data "Set HELM_DEPLOY=true and ensure kubectl/helm are reachable to enable"
        return 0
    fi

    # ── Guard: check required binaries ─────────────────────────────────────
    local missing=false
    if ! command -v helm &>/dev/null; then
        log_warn "helm not found in PATH — cannot deploy"
        missing=true
    fi
    if ! command -v kubectl &>/dev/null; then
        log_warn "kubectl not found in PATH — cannot deploy"
        missing=true
    fi
    if $missing; then
        log_warn "Helm deploy skipped — install helm + kubectl and re-run with HELM_DEPLOY=true"
        log_data "  helm:    https://helm.sh/docs/intro/install/"
        log_data "  kubectl: https://kubernetes.io/docs/tasks/tools/"
        return 0
    fi

    # ── Config ─────────────────────────────────────────────────────────────
    local release="${HELM_RELEASE:-lugh}"
    local namespace="${HELM_NAMESPACE:-lugh}"
    local chart="${HELM_CHART:-infra/helm/lugh}"
    local values_file="${HELM_VALUES:-}"
    local timeout="${HELM_WAIT_TIMEOUT:-300}"

    log_data "Release   : ${release}"
    log_data "Namespace : ${namespace}"
    log_data "Chart     : ${PROJECT_DIR}/${chart}"
    log_data "Timeout   : ${timeout}s"

    # ── Guard: chart must exist ─────────────────────────────────────────────
    local chart_path="${PROJECT_DIR}/${chart}"
    if [ ! -f "${chart_path}/Chart.yaml" ]; then
        log_warn "Chart not found at ${chart_path}/Chart.yaml — skipping"
        return 0
    fi

    # ── Guard: cluster must be reachable ────────────────────────────────────
    if ! kubectl cluster-info &>/dev/null; then
        log_warn "kubectl cannot reach cluster — k3s offline or KUBECONFIG not set"
        log_data "When NAS k3s is back: export KUBECONFIG=/path/to/config and re-run"
        return 0
    fi

    # ── Ensure namespace exists ─────────────────────────────────────────────
    log "Ensuring namespace '${namespace}' exists..."
    kubectl get namespace "$namespace" &>/dev/null \
        || kubectl create namespace "$namespace"

    # ── Build helm upgrade command ──────────────────────────────────────────
    local cmd=(
        helm upgrade --install "$release" "$chart_path"
        --namespace "$namespace"
        --create-namespace
        --wait
        --timeout "${timeout}s"
        --atomic
        --cleanup-on-fail
    )

    # Image tag: use the git SHA that was just pushed (matches CI build tag)
    local image_tag
    image_tag="sha-$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null || echo 'latest')"
    cmd+=(--set "image.tag=${image_tag}")

    # Server URL from tunnel (if available)
    if [ -n "$TUNNEL_URL" ]; then
        cmd+=(--set "env.LUGH_SERVER_URL=${TUNNEL_URL}")
    fi

    # Extra values file (e.g. infra/helm/lugh/values.prod.yaml)
    if [ -n "$values_file" ] && [ -f "$values_file" ]; then
        cmd+=(-f "$values_file")
        log_data "Extra values: ${values_file}"
    fi

    log "Running: ${cmd[*]}"
    printf '%s\n' "${cmd[*]}" >> "$LOG_FILE"

    if "${cmd[@]}" 2>&1 | tee -a "$LOG_FILE"; then
        log_ok "Helm deploy succeeded — release '${release}' in namespace '${namespace}'"

        # Show rollout status
        log "Rollout status:"
        kubectl rollout status deployment/"${release}-django" \
            -n "$namespace" --timeout="${timeout}s" 2>&1 | tee -a "$LOG_FILE" || true

        # Show pods
        log "Pods in '${namespace}':"
        kubectl get pods -n "$namespace" 2>&1 | tee -a "$LOG_FILE"
    else
        log_error "Helm deploy FAILED — see log for details"
        log "Helm history:"
        helm history "$release" -n "$namespace" 2>&1 | tee -a "$LOG_FILE" || true
        log "Pod events:"
        kubectl get events -n "$namespace" --sort-by='.lastTimestamp' 2>&1 | tail -20 | tee -a "$LOG_FILE" || true
        log_warn "Stack still running via Docker Compose — Helm failure is non-fatal"
    fi
}

# ────────────────────────────────────────────────────────────────────────────────
# STATUS — show current state without changing anything
# ────────────────────────────────────────────────────────────────────────────────

step_status() {
    log_step "STATUS"

    # Docker
    log "Docker containers:"
    cd "$PROJECT_DIR"
    docker compose -f "$COMPOSE_FILE" ps 2>&1 | tee -a "$LOG_FILE"

    # Tunnel
    local url; url=$(cat "${LOG_DIR}/current-tunnel-url.txt" 2>/dev/null || echo "unknown")
    log_data "Current tunnel URL: ${url}"

    # Health
    log "Health check (local): $(curl -sf http://localhost:${TUNNEL_PORT}/health/ 2>/dev/null || echo 'no response')"
    if [ -n "$url" ] && [ "$url" != "unknown" ]; then
        log "Health check (tunnel): $(curl -sf "${url}/health/" 2>/dev/null || echo 'no response')"
    fi

    # Last CI run
    log "Last CI run:"
    gh run list --repo "$GITHUB_REPO" --limit 1 --branch "$GIT_BRANCH" 2>&1 | tee -a "$LOG_FILE"

    # Apps on Desktop
    for f in "${DESKTOP_DIR}/lugh-android-latest.apk" "${DESKTOP_DIR}/lugh-ios-latest.ipa"; do
        if [ -f "$f" ]; then
            log_ok "$(basename "$f"): exists ($(du -sh "$f" 2>/dev/null | cut -f1))"
        else
            log_warn "$(basename "$f"): not found"
        fi
    done
}

# ────────────────────────────────────────────────────────────────────────────────
# FINAL SUMMARY
# ────────────────────────────────────────────────────────────────────────────────

print_summary() {
    local el; el=$(elapsed)

    printf '\n' | tee -a "$LOG_FILE"
    _log_raw STEP "════════════════════════════════════════════════════"
    _log_raw STEP "  LUGH STACK READY  —  finished in ${el}"
    _log_raw STEP "════════════════════════════════════════════════════"
    printf '\n' | tee -a "$LOG_FILE"

    log_ok "Server URL  : ${TUNNEL_URL:-NOT SET — check tunnel}"
    log_ok "Local URL   : http://localhost:${TUNNEL_PORT}"
    log_ok "Health      : $(curl -sf http://localhost:${TUNNEL_PORT}/health/ 2>/dev/null || echo '?')"
    log_ok "Android APK : ${DESKTOP_DIR}/lugh-android-latest.apk"
    log_ok "iOS IPA     : ${DESKTOP_DIR}/lugh-ios-latest.ipa"
    log_ok "CI Run      : https://github.com/${GITHUB_REPO}/actions/runs/${CI_RUN_ID:-?}"
    log_ok "CI Status   : ${CI_STATUS:-not monitored}"
    log_ok "Log file    : ${LOG_FILE}"

    printf '\n' | tee -a "$LOG_FILE"
    _log_raw INFO "Android: copy APK to phone → Settings › Security › Unknown sources → install"
    _log_raw INFO "iOS:     drag IPA into Sideloadly with iPhone plugged in, trust cert after"
    printf '\n' | tee -a "$LOG_FILE"
}

# ────────────────────────────────────────────────────────────────────────────────
# MAIN
# ────────────────────────────────────────────────────────────────────────────────

main() {
    parse_args "$@"

    # Banner
    printf '\n'
    printf "${BOLD}${CYAN}╔══════════════════════════════════════════════════╗${RESET}\n"
    printf "${BOLD}${CYAN}║          gogogo222.sh  v${SCRIPT_VERSION}                    ║${RESET}\n"
    printf "${BOLD}${CYAN}║  Lugh Full-Stack Launch, Build & Deploy          ║${RESET}\n"
    printf "${BOLD}${CYAN}╚══════════════════════════════════════════════════╝${RESET}\n"
    printf "${CYAN}  Started : ${RUN_DATE_HUMAN}${RESET}\n"
    printf "${CYAN}  Log     : ${LOG_FILE}${RESET}\n"
    printf '\n'

    log "=== ${SCRIPT_NAME} v${SCRIPT_VERSION} start — run_ts=${RUN_TS} ==="
    log "args: $*"
    log "STEP_ONLY=${STEP_ONLY} NO_WAIT=${NO_WAIT}"

    case "$STEP_ONLY" in
        # ── Selective mode ──────────────────────────────────────────────────
        docker)
            step_check_deps
            step_docker_desktop
            step_compose_up
            step_wait_healthy
            step_nginx_reload
            print_summary
            ;;
        tunnel)
            step_check_deps
            step_tunnel
            step_update_secret
            print_summary
            ;;
        deploy)
            step_check_deps
            step_commit_push
            step_wait_ci && step_download_artifacts || true
            step_helm_deploy
            print_summary
            ;;
        status)
            step_status
            ;;

        # ── Full run (default) ───────────────────────────────────────────────
        "")
            step_check_deps
            step_docker_desktop
            step_compose_up
            step_wait_healthy
            step_nginx_reload
            step_tunnel
            step_update_secret
            step_commit_push
            if ! $NO_WAIT; then
                step_wait_ci && step_download_artifacts || \
                    log_warn "CI incomplete — download artifacts manually when CI finishes"
            else
                log_warn "--no-wait: skipping CI monitoring"
                log "Watch CI at: https://github.com/${GITHUB_REPO}/actions"
            fi
            step_helm_deploy
            print_summary
            ;;

        *)
            die "Unknown step: '${STEP_ONLY}'. Valid: docker | tunnel | deploy | status"
            ;;
    esac

    log "=== ${SCRIPT_NAME} done ==="
}

main "$@"

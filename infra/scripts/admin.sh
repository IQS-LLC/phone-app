#!/usr/bin/env bash
# =============================================================================
# Lugh Admin Reference — Copy-paste commands for daily operations
# Server: 192.168.0.192  |  SSH port: 8000  |  K8s namespace: lugh
# =============================================================================

NS="lugh"

# ── SSH ───────────────────────────────────────────────────────────────────────
alias lugh-ssh='ssh -p 8000 <USER>@192.168.0.192'

# ── Pods ──────────────────────────────────────────────────────────────────────
alias lugh-pods='kubectl get pods -n lugh -o wide'
alias lugh-watch='watch kubectl get pods -n lugh'

# ── Logs ─────────────────────────────────────────────────────────────────────
lugh_logs_django()    { kubectl logs -f deployment/django    -n $NS --tail=100 "$@"; }
lugh_logs_nginx()     { kubectl logs -f deployment/nginx     -n $NS --tail=100 "$@"; }
lugh_logs_redis()     { kubectl logs -f deployment/redis     -n $NS --tail=100 "$@"; }
lugh_logs_postgres()  { kubectl logs -f statefulset/postgres -n $NS --tail=100 "$@"; }
lugh_logs_mock_plc()  { kubectl logs -f deployment/mock-plc  -n $NS --tail=100 "$@"; }

# ── Restart ───────────────────────────────────────────────────────────────────
lugh_restart_django()    { kubectl rollout restart deployment/django    -n $NS; }
lugh_restart_nginx()     { kubectl rollout restart deployment/nginx     -n $NS; }
lugh_restart_mock_plc()  { kubectl rollout restart deployment/mock-plc  -n $NS; }
lugh_restart_all()       {
    kubectl rollout restart deployment/django   -n $NS
    kubectl rollout restart deployment/nginx    -n $NS
    kubectl rollout restart deployment/redis    -n $NS
    kubectl rollout restart deployment/mock-plc -n $NS
}

# ── Scale ─────────────────────────────────────────────────────────────────────
# NOTE: Do not scale Django above 1 replica until DeviceRegistry uses Redis state
lugh_scale_django()   { kubectl scale deployment/django   -n $NS --replicas=$1; }
lugh_scale_nginx()    { kubectl scale deployment/nginx    -n $NS --replicas=$1; }

# ── Helm ──────────────────────────────────────────────────────────────────────
alias lugh-helm-status='helm status lugh -n lugh'
alias lugh-helm-history='helm history lugh -n lugh'
alias lugh-helm-values='helm get values lugh -n lugh'

# Upgrade with a new image tag
lugh_deploy() {
    local TAG="${1:-latest}"
    helm upgrade lugh ./infra/helm/lugh \
        --namespace $NS \
        --reuse-values \
        --set global.imageTag="$TAG" \
        --wait --timeout=5m0s
}

# Rollback to previous release
lugh_rollback() {
    local REVISION="${1:-}"
    helm rollback lugh $REVISION -n $NS --wait
}

# ── Resource usage ────────────────────────────────────────────────────────────
alias lugh-top-pods='kubectl top pods -n lugh'
alias lugh-top-nodes='kubectl top nodes'

# ── Health ────────────────────────────────────────────────────────────────────
lugh_health() {
    echo "=== Django health ==="
    curl -s http://192.168.0.192:30080/health/ | python3 -m json.tool || echo "FAILED"
    echo ""
    echo "=== Mock PLC health ==="
    kubectl exec -n $NS deployment/mock-plc -- \
        python3 -c "import urllib.request; print(urllib.request.urlopen('http://localhost:8080/health').read().decode())" 2>/dev/null || echo "port-forward needed"
}

# ── Services ──────────────────────────────────────────────────────────────────
alias lugh-services='kubectl get svc -n lugh'
alias lugh-endpoints='kubectl get endpoints -n lugh'

# ── Persistent Volumes ────────────────────────────────────────────────────────
alias lugh-pvcs='kubectl get pvc -n lugh'
alias lugh-pvs='kubectl get pv'

# ── PostgreSQL ────────────────────────────────────────────────────────────────
lugh_psql() {
    kubectl exec -it statefulset/postgres -n $NS -- \
        psql -U lugh_user -d lugh_db
}

lugh_db_backup() {
    local DATE=$(date +%Y%m%d_%H%M%S)
    kubectl exec statefulset/postgres -n $NS -- \
        pg_dump -U lugh_user lugh_db > "backup_$DATE.sql"
    echo "Backup saved: backup_$DATE.sql"
}

lugh_db_restore() {
    local FILE="$1"
    kubectl exec -i statefulset/postgres -n $NS -- \
        psql -U lugh_user -d lugh_db < "$FILE"
}

# ── Redis ─────────────────────────────────────────────────────────────────────
lugh_redis_cli() {
    kubectl exec -it deployment/redis -n $NS -- redis-cli
}

lugh_redis_info() {
    kubectl exec deployment/redis -n $NS -- redis-cli info | grep -E "connected_clients|used_memory_human|uptime_in_days"
}

# ── Django management ─────────────────────────────────────────────────────────
lugh_django_shell() {
    kubectl exec -it deployment/django -n $NS -- python manage.py shell
}

lugh_django_migrate() {
    kubectl exec deployment/django -n $NS -- python manage.py migrate --noinput
}

lugh_django_createsuperuser() {
    kubectl exec -it deployment/django -n $NS -- python manage.py createsuperuser
}

lugh_django_collectstatic() {
    kubectl exec deployment/django -n $NS -- python manage.py collectstatic --noinput
}

# ── Mock PLC management ───────────────────────────────────────────────────────
lugh_mock_plc_state() {
    kubectl exec deployment/mock-plc -n $NS -- \
        python3 -c "
import urllib.request, json
r = urllib.request.urlopen('http://localhost:8080/state')
print(json.dumps(json.loads(r.read()), indent=2))
"
}

lugh_mock_plc_reset() {
    kubectl exec deployment/mock-plc -n $NS -- \
        python3 -c "
import urllib.request
r = urllib.request.urlopen(urllib.request.Request('http://localhost:8080/reset', data=b''))
print(r.read().decode())
"
}

# Port-forward mock PLC HTTP API to localhost
lugh_mock_plc_forward() {
    kubectl port-forward svc/mock-plc 8080:8080 -n $NS
}

# ── pyADS / PLC ───────────────────────────────────────────────────────────────
lugh_plc_health() {
    curl -s http://192.168.0.192:30080/plc/ | python3 -m json.tool
}

lugh_plc_state() {
    curl -s http://192.168.0.192:30080/plc/state/ | python3 -m json.tool
}

lugh_plc_diagnostics() {
    curl -s http://192.168.0.192:30080/plc/diagnostics/ | python3 -m json.tool
}

# ── Quick diagnostics ─────────────────────────────────────────────────────────
lugh_status() {
    echo ""
    echo "╔══════════════════════════════════════╗"
    echo "║        Lugh Platform Status          ║"
    echo "╚══════════════════════════════════════╝"
    echo ""
    kubectl get pods -n $NS -o wide
    echo ""
    echo "── Services ────────────────────────────"
    kubectl get svc -n $NS
    echo ""
    echo "── PVCs ────────────────────────────────"
    kubectl get pvc -n $NS
    echo ""
    echo "── Helm ────────────────────────────────"
    helm status lugh -n $NS --short 2>/dev/null || echo "Helm release not found"
}

echo "Lugh admin functions loaded. Run 'lugh_status' for overview."

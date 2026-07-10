#!/usr/bin/env bash
# =============================================================================
# Lugh Server Bootstrap
# Run once on the production server (192.168.0.192) to install k3s + Helm
# and perform the initial deployment.
#
# Usage:
#   ssh -p 8000 <user>@192.168.0.192
#   curl -fsSL https://raw.githubusercontent.com/.../infra/scripts/bootstrap-server.sh | bash
# =============================================================================
set -euo pipefail

NAMESPACE="lugh"
GITHUB_OWNER="${GITHUB_OWNER:-}"   # Set via env: export GITHUB_OWNER=your-github-username

echo "========================================"
echo " Lugh Production Server Bootstrap"
echo " Server: 192.168.0.192"
echo "========================================"

# ── 1. Install k3s (lightweight Kubernetes) ───────────────────────────────────
if ! command -v k3s &>/dev/null; then
    echo "[1/6] Installing k3s..."
    curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server --disable traefik" sh -
    # Configure kubectl
    mkdir -p ~/.kube
    sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
    sudo chown "$(id -u):$(id -g)" ~/.kube/config
    export KUBECONFIG=~/.kube/config
    echo "k3s installed successfully"
else
    echo "[1/6] k3s already installed — skipping"
fi

# ── 2. Wait for k3s to be ready ───────────────────────────────────────────────
echo "[2/6] Waiting for k3s cluster to be ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=120s

# ── 3. Install Helm ───────────────────────────────────────────────────────────
if ! command -v helm &>/dev/null; then
    echo "[3/6] Installing Helm..."
    curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
else
    echo "[3/6] Helm already installed — skipping"
fi

# ── 4. Create namespace + secrets ─────────────────────────────────────────────
echo "[4/6] Creating namespace and secrets..."
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# Generate secure passwords if not already set
SECRET_KEY="${SECRET_KEY:-$(python3 -c 'import secrets; print(secrets.token_urlsafe(50))')}"
DB_PASSWORD="${DB_PASSWORD:-$(openssl rand -base64 32 | tr -d '/+=' | head -c 32)}"

kubectl create secret generic lugh-secrets \
    --namespace="$NAMESPACE" \
    --from-literal="SECRET_KEY=$SECRET_KEY" \
    --from-literal="DB_PASSWORD=$DB_PASSWORD" \
    --from-literal="POSTGRES_PASSWORD=$DB_PASSWORD" \
    --dry-run=client -o yaml | kubectl apply -f -

echo "  SECRET_KEY: (generated, stored in K8s secret)"
echo "  DB_PASSWORD: (generated, stored in K8s secret)"

# ── 5. Configure GHCR image pull secret ───────────────────────────────────────
if [ -n "${GHCR_PAT:-}" ]; then
    echo "[5/6] Configuring GitHub Container Registry pull secret..."
    kubectl create secret docker-registry ghcr-secret \
        --namespace="$NAMESPACE" \
        --docker-server=ghcr.io \
        --docker-username="$GITHUB_OWNER" \
        --docker-password="$GHCR_PAT" \
        --dry-run=client -o yaml | kubectl apply -f -
else
    echo "[5/6] GHCR_PAT not set — skipping pull secret (needed for private images)"
    echo "      Set GHCR_PAT=<token> and re-run if images are private"
fi

# ── 6. Initial Helm deployment ────────────────────────────────────────────────
echo "[6/6] Initial Helm deployment..."
helm upgrade --install lugh ./infra/helm/lugh \
    --namespace="$NAMESPACE" \
    --create-namespace \
    --set global.imageOwner="$GITHUB_OWNER" \
    --set global.imageTag=latest \
    --wait \
    --timeout=5m0s

echo ""
echo "========================================"
echo " Bootstrap complete!"
echo "========================================"
echo ""
echo " Backend URL:    http://192.168.0.192:30080"
echo " Admin panel:    http://192.168.0.192:30080/admin/"
echo " Mock PLC HTTP:  kubectl port-forward svc/mock-plc 8080:8080 -n lugh"
echo ""
echo " Quick status:"
kubectl get pods -n "$NAMESPACE"
echo ""
echo " View logs:"
echo "   kubectl logs -f deployment/django -n $NAMESPACE"
echo ""

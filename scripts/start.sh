#!/usr/bin/env bash
# One-time cluster bootstrap. After this, deploy manifest changes with: git push origin main
set -euo pipefail

PROFILE="${MINIKUBE_PROFILE:-newprofile}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

die() { echo "ERROR: $*" >&2; exit 1; }

echo "==> 1/6  Docker"
docker info >/dev/null 2>&1 || die "Start Docker Desktop first."

echo "==> 2/6  Minikube ($PROFILE)"
minikube start -p "$PROFILE" --driver=docker --memory="${MINIKUBE_MEMORY:-4096}" --cpus="${MINIKUBE_CPUS:-2}"
for _ in $(seq 1 60); do
  kubectl --context "$PROFILE" get --raw=/readyz >/dev/null 2>&1 && break
  sleep 2
done
kubectl --context "$PROFILE" get --raw=/readyz >/dev/null 2>&1 \
  || { echo "ERROR: apiserver not ready" >&2; exit 1; }
kubectl config use-context "$PROFILE" >/dev/null
minikube -p "$PROFILE" addons enable metrics-server \
  || { echo "ERROR: failed to enable metrics-server" >&2; exit 1; }

echo "==> 3/6  Build image (one Dockerfile → demo-api:latest)"
eval "$(minikube -p "$PROFILE" docker-env)"
docker build -t demo-api:latest .

echo "==> 4/6  Seed Argo CD (first install only; pinned to match Helm chart)"
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
if ! kubectl get deployment argocd-server -n argocd >/dev/null 2>&1; then
  kubectl apply -k bootstrap/argo-cd
fi
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-server \
  -n argocd --timeout=300s

echo "==> 5/6  Bootstrap Autopilot GitOps"
if ! kubectl get application autopilot-bootstrap -n argocd >/dev/null 2>&1; then
  kubectl apply -f install/autopilot-bootstrap.yaml
fi
kubectl annotate application autopilot-bootstrap -n argocd \
  argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 || true

echo "==> 6/6  Wait for Argo CD to sync from GitHub"
for i in $(seq 1 30); do
  if kubectl get application minikube-fastapi -n argocd >/dev/null 2>&1; then
    SYNC=$(kubectl get application minikube-fastapi -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null || true)
    if [[ "$SYNC" == "Synced" ]]; then
      break
    fi
  fi
  sleep 5
done

ARGOCD_PWD=""
if kubectl get secret argocd-initial-admin-secret -n argocd >/dev/null 2>&1; then
  ARGOCD_PWD=$(kubectl -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath="{.data.password}" | base64 -d)
fi

echo ""
echo "=============================================="
echo "  Ready — GitOps is automatic from here"
echo "=============================================="
echo ""
echo "Argo CD  user: admin"
echo "Argo CD  pass: ${ARGOCD_PWD:-<run password command below>}"
echo ""
echo "Open UI (Terminal A):"
echo "  kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo "  https://localhost:8080"
echo ""
echo "Open apps:"
echo "  kubectl port-forward -n fastapi-ns svc/fastapi 8000:8000"
echo "  kubectl port-forward -n api2-ns svc/api2 8001:8000"
echo "  kubectl port-forward -n api3-ns svc/api3 8002:8000"
echo ""
echo "Upgrade Argo CD (Git only):"
echo "  edit bootstrap/argo-cd.yaml → sources[0].targetRevision  →  git push"
echo ""
echo "Deploy manifest changes (no kubectl apply):"
echo "  edit apps/*/overlays/minikube/  or  infrastructure/  →  git push origin main"
echo "  Argo CD auto-syncs within ~15–60 seconds."
echo ""
kubectl get application -n argocd 2>/dev/null || true

#!/usr/bin/env bash
# Flux-only bootstrap. Deploys Flux + mirrored apps with Flux-owned Redis/RBAC.
# No Argo CD required.
set -euo pipefail

PROFILE="${MINIKUBE_PROFILE:-newprofile}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

die() { echo "ERROR: $*" >&2; exit 1; }

echo "==> 1/5  Prerequisites"
docker info >/dev/null 2>&1 || die "Start Docker Desktop first."
command -v flux >/dev/null 2>&1 || die "Install Flux CLI: brew install fluxcd/tap/flux"
command -v kubectl >/dev/null 2>&1 || die "kubectl is required."

echo "==> 2/5  Minikube ($PROFILE)"
minikube start -p "$PROFILE" --driver=docker --memory=3072 --cpus=2
minikube -p "$PROFILE" addons enable metrics-server >/dev/null 2>&1 || true

echo "==> 3/5  Build image (demo-api:latest)"
eval "$(minikube -p "$PROFILE" docker-env)"
docker build -t demo-api:latest .

echo "==> 4/5  Install Flux controllers + sync from Git"
kubectl apply -k flux/clusters/minikube/flux-system
kubectl -n flux-system wait --for=condition=available deploy --all --timeout=300s

echo "==> 5/5  Wait for Flux apps"
for i in $(seq 1 48); do
  READY=0
  for ns in flux-fastapi-ns flux-api2-ns flux-api3-ns; do
    if kubectl get deploy -n "$ns" --no-headers 2>/dev/null | grep -q .; then
      READY=$((READY + 1))
    fi
  done
  if [[ "$READY" -ge 3 ]]; then
    break
  fi
  sleep 5
done

echo ""
echo "=============================================="
echo "  Flux CD ready (Flux-only path)"
echo "=============================================="
echo ""
echo "Status:"
echo "  flux get all -A"
echo ""
echo "Apps:"
echo "  kubectl port-forward -n flux-fastapi-ns svc/fastapi 8100:8000"
echo "  kubectl port-forward -n flux-api2-ns svc/api2 8101:8000"
echo "  kubectl port-forward -n flux-api3-ns svc/api3 8102:8000"
echo ""
echo "GitOps (no kubectl apply):"
echo "  edit apps/*/overlays/flux  or  flux/infrastructure  →  git push origin main"
echo ""
echo "Upgrade Flux controllers:"
echo "  flux install --export > flux/clusters/minikube/flux-system/gotk-components.yaml"
echo "  git push origin main"
echo ""
flux get kustomizations -A 2>/dev/null || kubectl get kustomizations -A 2>/dev/null || true

#!/usr/bin/env bash
# Install Flux beside Argo CD on the same Minikube profile.
# Argo owns: fastapi-ns, api2-ns, api3-ns
# Flux owns: flux-fastapi-ns, flux-api2-ns, flux-api3-ns
set -euo pipefail

PROFILE="${MINIKUBE_PROFILE:-newprofile}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

die() { echo "ERROR: $*" >&2; exit 1; }

echo "==> 1/5  Prerequisites (run ./scripts/start.sh first so Argo infra/redis exist)"
docker info >/dev/null 2>&1 || die "Start Docker Desktop first."
command -v flux >/dev/null 2>&1 || die "Install Flux CLI: brew install fluxcd/tap/flux"
command -v kubectl >/dev/null 2>&1 || die "kubectl is required."
kubectl get ns argocd >/dev/null 2>&1 || die "Argo CD not found — run ./scripts/start.sh first."

echo "==> 2/5  Minikube ($PROFILE)"
minikube start -p "$PROFILE" --driver=docker --memory=3072 --cpus=2
minikube -p "$PROFILE" addons enable metrics-server >/dev/null 2>&1 || true

echo "==> 3/5  Ensure demo-api image exists"
eval "$(minikube -p "$PROFILE" docker-env)"
if ! docker image inspect demo-api:latest >/dev/null 2>&1; then
  docker build -t demo-api:latest .
fi

echo "==> 4/5  Install / reconcile Flux controllers"
kubectl apply -k flux/clusters/minikube/flux-system
kubectl -n flux-system wait --for=condition=available deploy --all --timeout=300s

echo "==> 5/5  Wait for Flux app mirrors"
for i in $(seq 1 40); do
  READY=0
  for ns in flux-fastapi-ns flux-api2-ns flux-api3-ns; do
    if kubectl get deploy -n "$ns" >/dev/null 2>&1; then
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
echo "  Flux CD ready (side-by-side with Argo CD)"
echo "=============================================="
echo ""
echo "Flux status:"
echo "  flux get all -A"
echo ""
echo "Flux apps (mirrors of Argo apps):"
echo "  kubectl port-forward -n flux-fastapi-ns svc/fastapi 8100:8000"
echo "  kubectl port-forward -n flux-api2-ns svc/api2 8101:8000"
echo "  kubectl port-forward -n flux-api3-ns svc/api3 8102:8000"
echo ""
echo "Argo apps (unchanged):"
echo "  kubectl port-forward -n fastapi-ns svc/fastapi 8000:8000"
echo "  kubectl port-forward -n api2-ns svc/api2 8001:8000"
echo "  kubectl port-forward -n api3-ns svc/api3 8002:8000"
echo ""
echo "GitOps:"
echo "  Argo path:  apps/*/overlays/minikube  →  fastapi-ns / api2-ns / api3-ns"
echo "  Flux path:  apps/*/overlays/flux      →  flux-*-ns"
echo "  Push to main → both reconcile (~15s)"
echo ""
echo "Upgrade Flux controllers:"
echo "  flux install --export > flux/clusters/minikube/flux-system/gotk-components.yaml"
echo "  git push origin main"
echo ""
flux get kustomizations -A 2>/dev/null || kubectl get kustomizations -n flux-system 2>/dev/null || true

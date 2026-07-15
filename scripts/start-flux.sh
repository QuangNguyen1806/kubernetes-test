#!/usr/bin/env bash
# Flux-only bootstrap using Flux Operator + FluxInstance (self-managed).
# Apps: create apps/<name>/overlays/flux + ./scripts/generate-flux-apps.sh (no apps.yaml edits).
set -euo pipefail

PROFILE="${MINIKUBE_PROFILE:-newprofile}"
MEMORY="${MINIKUBE_MEMORY:-3072}"
CPUS="${MINIKUBE_CPUS:-2}"
# Pin operator install for reproducible bootstrap; HelmRelease keeps it updated in-cluster.
OPERATOR_VERSION="${FLUX_OPERATOR_VERSION:-v0.55.0}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

die() { echo "ERROR: $*" >&2; exit 1; }

wait_apiserver() {
  echo "    waiting for apiserver..."
  for _ in $(seq 1 60); do
    if kubectl --context "$PROFILE" get --raw=/readyz >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}

echo "==> 1/6  Prerequisites"
docker info >/dev/null 2>&1 || die "Start Docker Desktop first."
command -v flux >/dev/null 2>&1 || die "Install Flux CLI: brew install fluxcd/tap/flux"
command -v kubectl >/dev/null 2>&1 || die "kubectl is required."

echo "==> 2/6  Minikube ($PROFILE, ${MEMORY}MB)"
if ! minikube start -p "$PROFILE" --driver=docker --memory="$MEMORY" --cpus="$CPUS"; then
  echo "    minikube start failed — deleting profile and retrying once..."
  minikube delete -p "$PROFILE" || true
  minikube start -p "$PROFILE" --driver=docker --memory="$MEMORY" --cpus="$CPUS" \
    || die "minikube start failed twice. Give Docker Desktop more memory or set MINIKUBE_MEMORY=2500."
fi
wait_apiserver || die "apiserver never became ready. Try: minikube delete -p $PROFILE && restart Docker."
kubectl config use-context "$PROFILE" >/dev/null

echo "    enabling metrics-server (for HPA)..."
minikube -p "$PROFILE" addons enable metrics-server \
  || die "failed to enable metrics-server addon"
kubectl -n kube-system wait --for=condition=available deploy/metrics-server --timeout=180s \
  || echo "WARNING: metrics-server not Ready yet — HPA may warn until it is."

echo "==> 3/6  Build image + refresh Flux app index"
eval "$(minikube -p "$PROFILE" docker-env)"
docker build -t demo-api:latest .
chmod +x scripts/generate-flux-apps.sh
./scripts/generate-flux-apps.sh

echo "==> 4/6  Install Flux Operator (${OPERATOR_VERSION})"
kubectl apply -f "https://github.com/controlplaneio-fluxcd/flux-operator/releases/download/${OPERATOR_VERSION}/install.yaml"
kubectl -n flux-system wait --for=condition=available deploy/flux-operator --timeout=300s

echo "==> 5/6  Apply FluxInstance (self-managed Flux + Git sync)"
kubectl apply -f flux/clusters/minikube/flux-system/flux-instance.yaml
# Wait until instance reports Ready (controllers installed + sync configured)
for _ in $(seq 1 90); do
  ready=$(kubectl get fluxinstance flux -n flux-system -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
  if [[ "$ready" == "True" ]]; then
    break
  fi
  sleep 5
done
kubectl get fluxinstance flux -n flux-system
ready=$(kubectl get fluxinstance flux -n flux-system -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
[[ "$ready" == "True" ]] || die "FluxInstance not Ready — check: kubectl describe fluxinstance flux -n flux-system"

kubectl -n flux-system wait --for=condition=available \
  deploy/source-controller deploy/kustomize-controller deploy/helm-controller \
  --timeout=300s

echo "==> 6/6  Wait for Flux apps (fail if not Ready)"
flux reconcile source git flux-system -n flux-system --timeout=2m || true
flux reconcile kustomization flux-system -n flux-system --with-source --timeout=3m || true

APPS_OK=0
for _ in $(seq 1 60); do
  READY_KS=0
  for ks in flux-infrastructure flux-apps; do
    status=$(kubectl get kustomization "$ks" -n flux-system -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
    if [[ "$status" == "True" ]]; then
      READY_KS=$((READY_KS + 1))
    fi
  done

  READY_DEPLOY=0
  for pair in flux-fastapi-ns/fastapi flux-api2-ns/api2 flux-api3-ns/api3; do
    ns="${pair%/*}"
    name="${pair#*/}"
    avail=$(kubectl get deploy "$name" -n "$ns" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo 0)
    if [[ "${avail:-0}" -ge 1 ]]; then
      READY_DEPLOY=$((READY_DEPLOY + 1))
    fi
  done

  if [[ "$READY_KS" -ge 2 && "$READY_DEPLOY" -ge 3 ]]; then
    APPS_OK=1
    break
  fi
  sleep 5
done

if [[ "$APPS_OK" -ne 1 ]]; then
  echo ""
  echo "ERROR: Flux apps did not become Ready in time."
  ./scripts/flux-status.sh || true
  die "bootstrap incomplete — see flux-status output above."
fi

REDIS_READY=$(kubectl get statefulset redis -n flux-redis-ns -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
[[ "${REDIS_READY:-0}" -ge 1 ]] || die "flux Redis is not Ready in flux-redis-ns"

echo ""
echo "=============================================="
echo "  Flux CD ready (Operator + single app path)"
echo "=============================================="
echo ""
echo "Add a new Flux app (one place):"
echo "  1. mkdir -p apps/<name>/overlays/flux && copy from apps/api2/overlays/flux"
echo "  2. ./scripts/generate-flux-apps.sh"
echo "  3. git add apps/<name> apps/flux-apps && git push"
echo ""
echo "Monitor / troubleshoot:"
echo "  ./scripts/flux-status.sh"
echo ""
echo "Apps:"
echo "  kubectl port-forward -n flux-fastapi-ns svc/fastapi 8100:8000"
echo "  kubectl port-forward -n flux-api2-ns svc/api2 8101:8000"
echo "  kubectl port-forward -n flux-api3-ns svc/api3 8102:8000"
echo ""
echo "Self-manage:"
echo "  Flux controllers → edit flux-instance.yaml distribution.version → git push"
echo "  Flux Operator    → HelmRelease flux-operator (operator.yaml) tracks 0.55.x"
echo ""
./scripts/flux-status.sh

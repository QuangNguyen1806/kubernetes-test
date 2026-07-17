#!/usr/bin/env bash
# Flux-only bootstrap using Flux Operator + FluxInstance (self-managed).
# Apps: create apps/<name>/overlays/flux + ./scripts/generate-flux-apps.sh (no apps.yaml edits).
set -euo pipefail

PROFILE="${MINIKUBE_PROFILE:-newprofile}"
MEMORY="${MINIKUBE_MEMORY:-3072}"
CPUS="${MINIKUBE_CPUS:-2}"
# Pin bootstrap chart; ResourceSet in operator.yaml owns ongoing upgrades in-cluster.
OPERATOR_VERSION="${FLUX_OPERATOR_VERSION:-0.55.0}"
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

# Minikube can report "Done!" (exit 0) even when the kubelet inside the
# container is stuck (stale certs/identity from reusing an old container).
# That shows up as node status "Unknown"/NotReady and NodeRestriction
# "no relationship found between node ... and this object" errors — apiserver
# readyz still passes, so we need a separate, explicit node-Ready check.
wait_node_ready() {
  echo "    waiting for node to report Ready..."
  for _ in $(seq 1 45); do
    status=$(kubectl --context "$PROFILE" get node "$PROFILE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
    if [[ "$status" == "True" ]]; then
      return 0
    fi
    sleep 2
  done
  return 1
}

start_minikube() {
  minikube start -p "$PROFILE" --driver=docker --memory="$MEMORY" --cpus="$CPUS"
}

echo "==> 1/6  Prerequisites"
docker info >/dev/null 2>&1 || die "Start Docker Desktop first."
command -v flux >/dev/null 2>&1 || die "Install Flux CLI: brew install fluxcd/tap/flux"
command -v helm >/dev/null 2>&1 || die "Install Helm 3: brew install helm"
command -v kubectl >/dev/null 2>&1 || die "kubectl is required."

echo "==> 2/6  Minikube ($PROFILE, ${MEMORY}MB)"
if ! start_minikube; then
  echo "    minikube start failed — deleting profile and retrying once..."
  minikube delete -p "$PROFILE" || true
  start_minikube \
    || die "minikube start failed twice. Give Docker Desktop more memory or set MINIKUBE_MEMORY=2500."
fi
wait_apiserver || die "apiserver never became ready. Try: minikube delete -p $PROFILE && restart Docker."
kubectl config use-context "$PROFILE" >/dev/null

if ! wait_node_ready; then
  echo "    node stuck NotReady (stale container state) — deleting profile and retrying once..."
  minikube delete -p "$PROFILE" || true
  start_minikube || die "minikube start failed on retry after deleting stale profile."
  wait_apiserver || die "apiserver never became ready after profile recreate."
  kubectl config use-context "$PROFILE" >/dev/null
  wait_node_ready || die "node still NotReady after recreating profile — check: kubectl describe node $PROFILE"
fi

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

echo "==> 4/6  Bootstrap Flux Operator (Helm ${OPERATOR_VERSION}; Git owns upgrades after sync)"
if helm status flux-operator -n flux-system >/dev/null 2>&1; then
  echo "    flux-operator Helm release already exists — skipping install"
else
  helm install flux-operator oci://ghcr.io/controlplaneio-fluxcd/charts/flux-operator \
    --namespace flux-system --create-namespace \
    --version "${OPERATOR_VERSION}" \
    --wait --timeout 5m
fi
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

echo "==> 6/6  Wait for Git sync + self-manage + apps"
flux reconcile source git flux-system -n flux-system --timeout=2m || true
flux reconcile kustomization flux-system -n flux-system --with-source --timeout=3m || true

echo "    waiting for self-manage (ResourceSet + Operator HelmRelease)..."
for _ in $(seq 1 60); do
  rs=$(kubectl get resourceset flux-operator -n flux-system -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
  hr=$(kubectl get helmrelease flux-operator -n flux-system -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
  if [[ "$rs" == "True" && "$hr" == "True" ]]; then
    break
  fi
  sleep 5
done
kubectl get resourceset,helmrelease,ocirepository -n flux-system 2>/dev/null | grep -E 'flux-operator|NAME' || true
rs=$(kubectl get resourceset flux-operator -n flux-system -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
hr=$(kubectl get helmrelease flux-operator -n flux-system -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
[[ "$rs" == "True" ]] || die "ResourceSet flux-operator not Ready — Git self-manage failed"
[[ "$hr" == "True" ]] || die "HelmRelease flux-operator not Ready — Operator not self-managed from Git"

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
echo "Self-manage (Git is source of truth after bootstrap):"
echo "  Flux controllers → flux-instance.yaml distribution.version → git push"
echo "  Flux Operator    → operator.yaml ResourceSet inputs.version (0.55.x) → git push"
echo ""
./scripts/flux-status.sh

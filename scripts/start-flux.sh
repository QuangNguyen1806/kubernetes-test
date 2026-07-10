#!/usr/bin/env bash
# Flux-only bootstrap. Deploys Flux + apps with Flux-owned Redis/RBAC.
# No Argo CD required.
set -euo pipefail

PROFILE="${MINIKUBE_PROFILE:-newprofile}"
MEMORY="${MINIKUBE_MEMORY:-4096}"
CPUS="${MINIKUBE_CPUS:-2}"
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

echo "==> 1/5  Prerequisites"
docker info >/dev/null 2>&1 || die "Start Docker Desktop first."
command -v flux >/dev/null 2>&1 || die "Install Flux CLI: brew install fluxcd/tap/flux"
command -v kubectl >/dev/null 2>&1 || die "kubectl is required."

echo "==> 2/5  Minikube ($PROFILE, ${MEMORY}MB)"
if ! minikube start -p "$PROFILE" --driver=docker --memory="$MEMORY" --cpus="$CPUS"; then
  echo "    minikube start failed — deleting profile and retrying once..."
  minikube delete -p "$PROFILE" || true
  minikube start -p "$PROFILE" --driver=docker --memory="$MEMORY" --cpus="$CPUS" \
    || die "minikube start failed twice. Restart Docker Desktop and retry."
fi
wait_apiserver || die "apiserver never became ready. Try: minikube delete -p $PROFILE && restart Docker."
kubectl config use-context "$PROFILE" >/dev/null

echo "    enabling metrics-server (for HPA)..."
minikube -p "$PROFILE" addons enable metrics-server \
  || die "failed to enable metrics-server addon"
kubectl -n kube-system wait --for=condition=available deploy/metrics-server --timeout=180s \
  || echo "WARNING: metrics-server not Ready yet — HPA may warn until it is."

echo "==> 3/5  Build image (demo-api:latest)"
eval "$(minikube -p "$PROFILE" docker-env)"
docker build -t demo-api:latest .

echo "==> 4/5  Install Flux controllers, then Git sync"
# Apply controllers/CRDs first — sync CRs need the CRDs registered.
kubectl apply -f flux/clusters/minikube/flux-system/gotk-components.yaml
kubectl wait --for=condition=Established \
  crd/kustomizations.kustomize.toolkit.fluxcd.io \
  crd/gitrepositories.source.toolkit.fluxcd.io \
  --timeout=120s
kubectl -n flux-system wait --for=condition=available deploy --all --timeout=300s
kubectl apply -f flux/clusters/minikube/flux-system/gotk-sync.yaml

echo "==> 5/5  Wait for Flux apps (fail if not Ready)"
# Kick an immediate reconcile so we don't wait on the poll interval.
flux reconcile source git flux-system -n flux-system --timeout=2m || true
flux reconcile kustomization flux-system -n flux-system --with-source --timeout=3m || true

APPS_OK=0
for _ in $(seq 1 60); do
  READY_KS=0
  for ks in flux-infrastructure flux-fastapi flux-api2 flux-api3; do
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

  if [[ "$READY_KS" -ge 4 && "$READY_DEPLOY" -ge 3 ]]; then
    APPS_OK=1
    break
  fi
  sleep 5
done

if [[ "$APPS_OK" -ne 1 ]]; then
  echo ""
  echo "ERROR: Flux apps did not become Ready in time."
  flux get kustomizations -A 2>/dev/null || kubectl get kustomizations -A
  kubectl get pods -A | rg 'flux-|Error|Crash|Pending|ImagePull' || true
  die "bootstrap incomplete — check 'flux get all -A' and Minikube resources."
fi

REDIS_READY=$(kubectl get statefulset redis -n flux-redis-ns -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
[[ "${REDIS_READY:-0}" -ge 1 ]] || die "flux Redis is not Ready in flux-redis-ns"

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
flux get kustomizations -A

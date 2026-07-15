#!/usr/bin/env bash
# Troubleshoot / monitor Flux CD (FluxInstance, Kustomizations, apps).
set -euo pipefail

PROFILE="${MINIKUBE_PROFILE:-newprofile}"
kubectl config use-context "$PROFILE" >/dev/null 2>&1 || true

echo "=== Flux Operator / Instance ==="
kubectl get deploy -n flux-system -l app.kubernetes.io/name=flux-operator 2>/dev/null || kubectl get deploy -n flux-system | rg -i 'flux-operator|NAME' || true
kubectl get fluxinstance -n flux-system -o wide 2>/dev/null || echo "(no FluxInstance)"
kubectl get fluxreport -n flux-system -o yaml 2>/dev/null | head -80 || true

echo ""
echo "=== Sources ==="
flux get sources git -A 2>/dev/null || kubectl get gitrepositories -A

echo ""
echo "=== Kustomizations ==="
flux get kustomizations -A 2>/dev/null || kubectl get kustomizations -A
echo ""
echo "--- Not Ready ---"
kubectl get kustomizations -A -o json 2>/dev/null \
  | python3 -c '
import json,sys
data=json.load(sys.stdin)
for i in data.get("items",[]):
  ns=i["metadata"]["namespace"]; name=i["metadata"]["name"]
  conds=i.get("status",{}).get("conditions",[])
  ready=next((c for c in conds if c.get("type")=="Ready"), None)
  if not ready or ready.get("status")!="True":
    msg=(ready or {}).get("message","unknown")
    print(f"{ns}/{name}: {msg}")
' 2>/dev/null || true

echo ""
echo "=== App namespaces ==="
for ns in flux-fastapi-ns flux-api2-ns flux-api3-ns flux-redis-ns; do
  echo "-- $ns"
  kubectl get deploy,pods,svc -n "$ns" 2>/dev/null || echo "  (missing)"
done

echo ""
echo "=== Recent warnings ==="
kubectl get events -A --field-selector type=Warning --sort-by='.lastTimestamp' 2>/dev/null | tail -20 || true

echo ""
echo "Useful commands:"
echo "  flux reconcile source git flux-system -n flux-system"
echo "  flux reconcile kustomization flux-apps -n flux-system --with-source"
echo "  flux logs --level=error --all-namespaces"
echo "  kubectl describe kustomization flux-apps -n flux-system"
echo "  ./scripts/flux-status.sh"

#!/usr/bin/env bash
# Troubleshoot / monitor Flux CD (FluxInstance, Kustomizations, apps).
set -euo pipefail

PROFILE="${MINIKUBE_PROFILE:-newprofile}"
kubectl config use-context "$PROFILE" >/dev/null 2>&1 || true

echo "=== Flux Operator / Instance (self-manage) ==="
kubectl get deploy -n flux-system -l app.kubernetes.io/name=flux-operator 2>/dev/null || kubectl get deploy -n flux-system | rg -i 'flux-operator|NAME' || true
kubectl get fluxinstance -n flux-system -o wide 2>/dev/null || echo "(no FluxInstance)"
kubectl get resourceset,helmrelease,ocirepository -n flux-system 2>/dev/null \
  | rg 'flux-operator|flux-system|NAME' || true
echo ""
echo "--- Self-manage Ready? ---"
for kind in fluxinstance resourceset helmrelease; do
  name=flux
  [[ "$kind" == "fluxinstance" ]] || name=flux-operator
  status=$(kubectl get "$kind" "$name" -n flux-system -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Missing")
  echo "  $kind/$name: $status"
done
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
echo "=== Monitoring (Prometheus + Grafana) ==="
status=$(kubectl get kustomization flux-monitoring -n flux-system -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Missing")
echo "  kustomization/flux-monitoring: $status"
hr=$(kubectl get helmrelease kube-prometheus-stack -n flux-system -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Missing")
echo "  helmrelease/kube-prometheus-stack: $hr"
kubectl get pods -n monitoring 2>/dev/null || echo "  (monitoring namespace not created yet)"

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

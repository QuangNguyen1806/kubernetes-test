#!/usr/bin/env bash
# Failing/passing gate for monitoring Ready on Minikube.
# Exit 0 = Grafana + Prometheus Ready; Exit 1 = not Ready (the bug).
set -euo pipefail
PROFILE="${MINIKUBE_PROFILE:-newprofile}"
TIMEOUT_S="${MONITORING_READY_TIMEOUT:-300}"

kubectl config use-context "$PROFILE" >/dev/null 2>&1 || true

deadline=$((SECONDS + TIMEOUT_S))
while (( SECONDS < deadline )); do
  g=$(kubectl get deploy kube-prometheus-stack-grafana -n monitoring \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
  p=$(kubectl get sts prometheus-kube-prometheus-stack-prometheus -n monitoring \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
  if [[ "${g:-0}" -ge 1 && "${p:-0}" -ge 1 ]]; then
    echo "PASS: Grafana readyReplicas=$g Prometheus readyReplicas=$p"
    kubectl get pods -n monitoring
    exit 0
  fi
  sleep 5
done

echo "FAIL: monitoring not Ready within ${TIMEOUT_S}s"
echo "--- pods ---"
kubectl get pods -n monitoring -o wide 2>/dev/null || true
echo "--- grafana events ---"
kubectl describe pod -n monitoring -l app.kubernetes.io/name=grafana 2>/dev/null | sed -n '/Events:/,$p' | head -20 || true
echo "--- images present? ---"
minikube -p "$PROFILE" image ls 2>/dev/null | grep -iE 'grafana/grafana|prometheus/prometheus' || echo "(grafana/prometheus images MISSING from minikube)"
exit 1

#!/usr/bin/env bash
# Failing/passing gate for monitoring Ready on Minikube.
# Exit 0 = Grafana + Prometheus Ready; Exit 1 = not Ready (the bug).
set -euo pipefail
PROFILE="${MINIKUBE_PROFILE:-newprofile}"
TIMEOUT_S="${MONITORING_READY_TIMEOUT:-300}"
# Prevent silent multi-minute hangs when the apiserver is overloaded.
KUBECTL=(kubectl --context "$PROFILE" --request-timeout=10s)

kubectl config use-context "$PROFILE" >/dev/null 2>&1 || true

echo "Checking monitoring Ready (timeout=${TIMEOUT_S}s, kubectl request-timeout=10s)..."
if ! "${KUBECTL[@]}" get --raw=/readyz >/dev/null 2>&1; then
  echo "ERROR: apiserver not reachable (TLS/timeout)." >&2
  echo "Cluster is likely overloaded. Try:" >&2
  echo "  kubectl --request-timeout=10s get node" >&2
  echo "  minikube stop -p $PROFILE && minikube start -p $PROFILE" >&2
  echo "  # or: minikube delete -p $PROFILE && ./scripts/start-flux.sh" >&2
  exit 1
fi

deadline=$((SECONDS + TIMEOUT_S))
while (( SECONDS < deadline )); do
  g=$("${KUBECTL[@]}" get deploy kube-prometheus-stack-grafana -n monitoring \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
  p=$("${KUBECTL[@]}" get sts prometheus-kube-prometheus-stack-prometheus -n monitoring \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
  # Loki single-binary may be StatefulSet or Deployment depending on chart.
  l=$("${KUBECTL[@]}" get sts -n monitoring -l app.kubernetes.io/name=loki \
    -o jsonpath='{.items[0].status.readyReplicas}' 2>/dev/null || echo 0)
  if [[ -z "${l}" || "${l}" == "0" ]]; then
    l=$("${KUBECTL[@]}" get deploy -n monitoring -l app.kubernetes.io/name=loki \
      -o jsonpath='{.items[0].status.readyReplicas}' 2>/dev/null || echo 0)
  fi
  echo "  $(date +%H:%M:%S) grafana_ready=${g:-0} prometheus_ready=${p:-0} loki_ready=${l:-0}"
  if [[ "${g:-0}" -ge 1 && "${p:-0}" -ge 1 ]]; then
    echo "PASS: Grafana readyReplicas=$g Prometheus readyReplicas=$p (loki=${l:-0})"
    "${KUBECTL[@]}" get pods -n monitoring
    exit 0
  fi
  sleep 5
done

echo "FAIL: monitoring not Ready within ${TIMEOUT_S}s"
echo "--- pods ---"
"${KUBECTL[@]}" get pods -n monitoring -o wide 2>/dev/null || true
echo "--- grafana events ---"
"${KUBECTL[@]}" describe pod -n monitoring -l app.kubernetes.io/name=grafana 2>/dev/null | sed -n '/Events:/,$p' | head -20 || true
echo "--- images present? ---"
minikube -p "$PROFILE" image ls 2>/dev/null | grep -iE 'grafana/grafana|prometheus/prometheus' || echo "(grafana/prometheus images MISSING from minikube)"
exit 1

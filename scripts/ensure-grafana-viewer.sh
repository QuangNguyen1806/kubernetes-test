#!/usr/bin/env bash
# Ensure Grafana Viewer user exists now (does not wait for CronJob schedule).
set -euo pipefail
PROFILE="${MINIKUBE_PROFILE:-newprofile}"
kubectl config use-context "$PROFILE" >/dev/null 2>&1 || true

ADMIN_USER=$(kubectl get secret grafana-auth -n monitoring -o jsonpath='{.data.admin-user}' | base64 -d)
ADMIN_PASS=$(kubectl get secret grafana-auth -n monitoring -o jsonpath='{.data.admin-password}' | base64 -d)
VIEWER_USER=$(kubectl get secret grafana-auth -n monitoring -o jsonpath='{.data.viewer-user}' | base64 -d)
VIEWER_PASS=$(kubectl get secret grafana-auth -n monitoring -o jsonpath='{.data.viewer-password}' | base64 -d)

kubectl -n monitoring delete job grafana-create-viewer-now --ignore-not-found >/dev/null 2>&1 || true
kubectl -n monitoring create job grafana-create-viewer-now --from=cronjob/grafana-create-viewer
kubectl -n monitoring wait --for=condition=complete job/grafana-create-viewer-now --timeout=180s

echo "Grafana Viewer ready:"
echo "  user: $VIEWER_USER"
echo "  pass: $VIEWER_PASS"
echo "  (admin: $ADMIN_USER / $ADMIN_PASS)"

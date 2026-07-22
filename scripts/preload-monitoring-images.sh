#!/usr/bin/env bash
# Pre-pull monitoring + logging images into the Minikube docker daemon.
set -euo pipefail

PROFILE="${MINIKUBE_PROFILE:-newprofile}"

IMAGES=(
  "docker.io/grafana/grafana:13.1.0"
  "quay.io/prometheus/prometheus:v3.13.1-distroless"
  "quay.io/prometheus-operator/prometheus-operator:v0.92.1"
  "quay.io/prometheus-operator/prometheus-config-reloader:v0.92.1"
  "docker.io/grafana/loki:3.4.2"
  "docker.io/grafana/promtail:3.4.2"
  "docker.io/nginxinc/nginx-unprivileged:1.27-alpine"
  "docker.io/curlimages/curl:8.11.1"
)

echo "==> Preloading monitoring images into minikube ($PROFILE)"
eval "$(minikube -p "$PROFILE" docker-env)"
for img in "${IMAGES[@]}"; do
  echo "    pulling $img ..."
  if docker pull "$img"; then
    echo "    OK $img"
  else
    echo "WARNING: failed to pull $img — monitoring may stay ContainerCreating" >&2
  fi
done
eval "$(minikube -p "$PROFILE" docker-env -u)" 2>/dev/null || true
echo "==> Monitoring image preload done"

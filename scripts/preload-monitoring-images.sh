#!/usr/bin/env bash
# Pre-pull monitoring images into the Minikube docker daemon.
# Why: kubelet pulls from inside the Minikube container are pathologically slow/hung
# on Docker Desktop (grafana ~1GB), so HelmRelease waits time out and pods stay
# ContainerCreating. Pulling via `minikube docker-env` uses the same path as demo-api.
set -euo pipefail

PROFILE="${MINIKUBE_PROFILE:-newprofile}"

IMAGES=(
  "docker.io/grafana/grafana:13.1.0"
  "quay.io/prometheus/prometheus:v3.13.1-distroless"
  "quay.io/prometheus-operator/prometheus-operator:v0.92.1"
  "quay.io/prometheus-operator/prometheus-config-reloader:v0.92.1"
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
# Return shell docker client to the host daemon for subsequent commands.
eval "$(minikube -p "$PROFILE" docker-env -u)" 2>/dev/null || true
echo "==> Monitoring image preload done"

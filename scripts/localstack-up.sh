#!/usr/bin/env bash
# Start LocalStack (Community) for Terraform local AWS emulation.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

die() { echo "ERROR: $*" >&2; exit 1; }

docker info >/dev/null 2>&1 || die "Start Docker Desktop first."
command -v docker >/dev/null 2>&1 || die "docker is required."

echo "==> Starting LocalStack (docker compose)"
if ! docker compose -f docker-compose.localstack.yml up -d; then
  echo "HINT: Docker pull/start failed. Check disk space (df -h) and Docker Desktop health." >&2
  echo "      LocalStack images are large (~1–2 GiB). Free space, then retry." >&2
  die "docker compose up failed"
fi

echo "==> Waiting for LocalStack health..."
for _ in $(seq 1 60); do
  if curl -sf http://localhost:4566/_localstack/health >/dev/null 2>&1; then
    echo "PASS: LocalStack healthy at http://localhost:4566"
    curl -s http://localhost:4566/_localstack/health | head -c 500 || true
    echo
    exit 0
  fi
  sleep 2
done

die "LocalStack did not become healthy. Check: docker compose -f docker-compose.localstack.yml logs"

#!/usr/bin/env bash
# Stop LocalStack containers (volume preserved unless --volumes).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

docker info >/dev/null 2>&1 || { echo "Docker not running — nothing to stop."; exit 0; }

if [[ "${1:-}" == "--volumes" ]]; then
  echo "==> Stopping LocalStack and removing volume"
  docker compose -f docker-compose.localstack.yml down -v
else
  echo "==> Stopping LocalStack (persistent volume kept)"
  docker compose -f docker-compose.localstack.yml down
fi
echo "Done."

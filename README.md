# FastAPI on Minikube — GitOps with Argo CD Autopilot

## Quick start (just the commands)

```bash
cd "/Users/mac/Kubernetes Test"
./scripts/start.sh
```

```bash
# Terminal A — Argo CD UI
kubectl port-forward svc/argocd-server -n argocd 8080:443
# https://localhost:8080  user: admin
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d && echo

# Terminal B — fastapi
kubectl port-forward -n fastapi-ns svc/api 8000:8000

# Terminal C — api2
kubectl port-forward -n api2-ns svc/api 8001:8000
```

**Deploy config changes** (no kubectl):

```bash
# edit apps/fastapi/overlays/minikube/kustomization.yaml or apps/api2/...
git add -A && git commit -m "update" && git push origin main
```

**Rebuild after Python code changes** (one image, all instances):

```bash
eval "$(minikube -p newprofile docker-env)"
docker build -t demo-api:latest -t fastapi:latest -t api2:latest .
kubectl rollout restart deployment/api -n fastapi-ns
kubectl rollout restart deployment/api -n api2-ns
```

**Teardown:** `minikube delete -p newprofile`

---

One **codebase** (`app/`), one **Dockerfile**, one image (`demo-api:latest`). Two deployments (fastapi + api2) differ only by Kustomize overlay config (`APP_NAME`, `REDIS_KEY`, `MESSAGE`). Argo CD auto-syncs from GitHub after `./scripts/start.sh`.

| Instance | Argo CD App | Namespace | Port-forward |
|----------|-------------|-----------|--------------|
| fastapi | `minikube-fastapi` | `fastapi-ns` | `svc/api` → 8000 |
| api2 | `minikube-api2` | `api2-ns` | `svc/api` → 8001 |

Repo: https://github.com/QuangNguyen1806/kubernetes-test.git

---

## Prerequisites

- [Docker Desktop](https://www.docker.com/products/docker-desktop/) (running)
- `minikube`, `kubectl`, `docker`, `argocd` CLI

---

## Step 1 — One-time setup

```bash
cd "/Users/mac/Kubernetes Test"
chmod +x scripts/start.sh
./scripts/start.sh
```

Builds one image with three tags (`demo-api`, `fastapi`, `api2`), bootstraps Argo CD + Autopilot.

---

## Step 2 — Open Argo CD and apps

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
kubectl port-forward -n fastapi-ns svc/api 8000:8000
kubectl port-forward -n api2-ns svc/api 8001:8000
curl http://127.0.0.1:8000/
curl http://127.0.0.1:8001/
```

Argo CD login: user `admin`, password from `argocd-initial-admin-secret` (see quick start).

---

## Step 3 — Deploy changes (Git only)

Edit overlay `configMapGenerator` in e.g. `apps/fastapi/overlays/minikube/kustomization.yaml`:

```yaml
configMapGenerator:
  - name: app-config
    literals:
      - APP_NAME=fastapi
      - REDIS_KEY=items
      - MESSAGE=Hello from GitOps!
```

```bash
git add apps/fastapi/overlays/minikube/kustomization.yaml
git commit -m "GitOps: update MESSAGE"
git push origin main
```

---

## Add another instance

```bash
cp -r apps/api2/overlays/minikube apps/myapp/overlays/minikube
# edit kustomization.yaml literals + namespace in config.json
# add namespace to infrastructure/namespaces/base/namespaces.yaml
git push origin main
# ApplicationSet creates minikube-myapp automatically
```

---

## Repository layout

```
app/                    single Python codebase
Dockerfile              single build → demo-api:latest
apps/
  shared/base/          deployment, service, hpa (shared)
  fastapi/overlays/minikube/   config + patches + config.json
  api2/overlays/minikube/
bootstrap/  projects/  infrastructure/  install/  scripts/
```

---

## Troubleshooting

| Problem | Fix |
|---------|-----|
| `connection refused` on kubectl | Docker Desktop → `./scripts/start.sh` |
| No `minikube-fastapi` | Push `config.json` to GitHub `main` |
| `argo-cd` OutOfSync | Harmless — Argo CD is healthy |
| ImagePullBackOff | `eval "$(minikube -p newprofile docker-env)"` + rebuild image |

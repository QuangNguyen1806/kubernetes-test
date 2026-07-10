# FastAPI on Minikube — GitOps with Argo CD Autopilot

One **codebase** (`app/`), one **Dockerfile**, one image (`demo-api:latest`).  
Instances (fastapi / api2 / api3) differ only by Kustomize config (`APP_NAME`, `REDIS_KEY`, `MESSAGE`).

## Quick start

```bash
cd "/Users/mac/Kubernetes Test"
./scripts/start.sh
```

```bash
# Argo CD UI
kubectl port-forward svc/argocd-server -n argocd 8080:443
# https://localhost:8080  user: admin
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d && echo

# Apps
kubectl port-forward -n fastapi-ns svc/fastapi 8000:8000
kubectl port-forward -n api2-ns svc/api2 8001:8000
kubectl port-forward -n api3-ns svc/api3 8002:8000
```

**Deploy config changes** (no kubectl — `git push` to `main` auto-syncs in ~15s):

```bash
git add -A && git commit -m "update" && git push origin main
```

**Upgrade Argo CD** (self-managed):

```bash
# edit bootstrap/argo-cd.yaml → spec.sources[0].targetRevision
git add bootstrap/argo-cd.yaml && git commit -m "Upgrade Argo CD chart" && git push origin main
```

**Rebuild after Python code changes** (one image, all instances):

```bash
eval "$(minikube -p newprofile docker-env)"
docker build -t demo-api:latest .
kubectl rollout restart deployment/fastapi -n fastapi-ns
kubectl rollout restart deployment/api2 -n api2-ns
kubectl rollout restart deployment/api3 -n api3-ns
```

**Teardown:** `minikube delete -p newprofile`

| Instance | Argo CD App | Namespace | Port-forward |
|----------|-------------|-----------|--------------|
| fastapi | `minikube-fastapi` | `fastapi-ns` | 8000 |
| api2 | `minikube-api2` | `api2-ns` | 8001 |
| api3 | `minikube-api3` | `api3-ns` | 8002 |
| Argo CD | `argo-cd` | `argocd` | 8080 |

Repo: https://github.com/QuangNguyen1806/kubernetes-test.git

---

## Prerequisites

- Docker Desktop (running)
- `minikube`, `kubectl`, `docker`, `argocd` CLI

---

## How GitOps works

| What | How |
|------|-----|
| Manifest deploys | `syncPolicy.automated` + `selfHeal` on every Application |
| Fast Git detection | `timeout.reconciliation=15s` (no webhook required) |
| New app instance | Add `apps/<name>/overlays/minikube/config.json` + push → ApplicationSet creates it |
| Infra | `cluster-resources-in-cluster` syncs `infrastructure/` |
| Argo CD version | Change Helm `targetRevision` in `bootstrap/argo-cd.yaml` → push |

`bootstrap/argo-cd/kustomization.yaml` is **seed only** (first `./scripts/start.sh`). Live Argo CD version is the Helm chart `targetRevision`.

### Not automatic (Minikube)

| What | Command |
|------|---------|
| Python code changes | rebuild `demo-api:latest` + `kubectl rollout restart` |
| First boot | `./scripts/start.sh` |
| Local URLs | `kubectl port-forward` |

---

## Troubleshooting

| Problem | Fix |
|---------|-----|
| `connection refused` on kubectl | Start Docker → `./scripts/start.sh` |
| ImagePullBackOff | `eval "$(minikube -p newprofile docker-env)"` && `docker build -t demo-api:latest .` |
| ComparisonError `:8081` | Seed must stay on v2.14.x — do not use Argo CD `stable` (v3.x) in seed |
| No app in Argo CD | Ensure `config.json` is on GitHub `main` |

---

## Repository layout

```
app/            single Python codebase (APP_NAME / REDIS_KEY / MESSAGE from env)
Dockerfile      single build → demo-api:latest
apps/
  fastapi/      overlay + config.json
  api2/
  api3/
bootstrap/      Autopilot + Argo CD Helm Application (self-managed)
projects/       AppProject + ApplicationSet
infrastructure/ namespaces, rbac, redis
install/        autopilot-bootstrap.yaml (once)
scripts/        start.sh
```

```
autopilot-bootstrap → argo-cd (Helm), root, cluster-resources
  root → ApplicationSet → minikube-fastapi, minikube-api2, minikube-api3
  cluster-resources → infrastructure/
```

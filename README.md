# FastAPI on Minikube — GitOps with Argo CD + Flux CD

One **codebase** (`app/`), one **Dockerfile**, one image (`demo-api:latest`).  
**Argo CD** and **Flux CD** both run side-by-side on the same cluster, each deploying mirrored app instances into **separate namespaces** (no resource fighting).

## Quick start

### Flux-only (no Argo)

```bash
cd "/Users/mac/Kubernetes Test"
./scripts/start-flux.sh
```

```bash
flux get all -A
kubectl port-forward -n flux-fastapi-ns svc/fastapi 8100:8000
kubectl port-forward -n flux-api2-ns svc/api2 8101:8000
kubectl port-forward -n flux-api3-ns svc/api3 8102:8000
```

Flux owns its own Redis (`flux-redis-ns`), RBAC, and app namespaces.

### Argo + Flux (side-by-side)

```bash
cd "/Users/mac/Kubernetes Test"
./scripts/start.sh       # Argo CD + apps in fastapi-ns / api2-ns / api3-ns
./scripts/start-flux.sh  # Flux CD + mirrored apps in flux-*-ns
```

```bash
# Argo CD UI
kubectl port-forward svc/argocd-server -n argocd 8080:443
# https://localhost:8080  user: admin

# Argo apps
kubectl port-forward -n fastapi-ns svc/fastapi 8000:8000
kubectl port-forward -n api2-ns svc/api2 8001:8000
kubectl port-forward -n api3-ns svc/api3 8002:8000

# Flux apps (mirrors)
kubectl port-forward -n flux-fastapi-ns svc/fastapi 8100:8000
kubectl port-forward -n flux-api2-ns svc/api2 8101:8000
kubectl port-forward -n flux-api3-ns svc/api3 8102:8000
```

**Deploy config changes** (no kubectl — `git push` to `main` auto-syncs in ~15s):

```bash
# Argo-owned:  apps/*/overlays/minikube
# Flux-owned:  apps/*/overlays/flux
git add -A && git commit -m "update" && git push origin main
```

**Upgrade Argo CD** (self-managed):

```bash
# edit bootstrap/argo-cd.yaml → spec.sources[0].targetRevision
git push origin main
```

**Upgrade Flux controllers** (self-managed):

```bash
flux install --export > flux/clusters/minikube/flux-system/gotk-components.yaml
git add flux/clusters/minikube/flux-system/gotk-components.yaml
git commit -m "Upgrade Flux" && git push origin main
```

**Rebuild after Python code changes** (one image, all instances):

```bash
eval "$(minikube -p newprofile docker-env)"
docker build -t demo-api:latest .
kubectl rollout restart deployment/fastapi -n fastapi-ns
kubectl rollout restart deployment/api2 -n api2-ns
kubectl rollout restart deployment/api3 -n api3-ns
kubectl rollout restart deployment/fastapi -n flux-fastapi-ns
kubectl rollout restart deployment/api2 -n flux-api2-ns
kubectl rollout restart deployment/api3 -n flux-api3-ns
```

**Teardown:** `minikube delete -p newprofile`

| Interface | Instance | Namespace | Port-forward |
|-----------|----------|-----------|--------------|
| Argo | fastapi | `fastapi-ns` | 8000 |
| Argo | api2 | `api2-ns` | 8001 |
| Argo | api3 | `api3-ns` | 8002 |
| Flux | fastapi | `flux-fastapi-ns` | 8100 |
| Flux | api2 | `flux-api2-ns` | 8101 |
| Flux | api3 | `flux-api3-ns` | 8102 |
| Argo UI | — | `argocd` | 8080 |

Repo: https://github.com/QuangNguyen1806/kubernetes-test.git

---

## Prerequisites

- Docker Desktop (running)
- `minikube`, `kubectl`, `docker`
- Flux-only: `flux` CLI (`brew install fluxcd/tap/flux`)
- Argo path: also `argocd` CLI (optional)

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
app/            single Python codebase
Dockerfile      → demo-api:latest
apps/
  */overlays/minikube/   Argo CD instances
  */overlays/flux/       Flux CD mirrors (separate namespaces)
bootstrap/      Argo CD Autopilot + Helm self-management
flux/
  clusters/minikube/     Flux controllers + app/infra Kustomizations
  infrastructure/        Flux-only namespaces, RBAC, Redis (flux-redis-ns)
projects/       Argo AppProject + ApplicationSet
infrastructure/ Argo-owned namespaces, rbac, redis
scripts/        start.sh (Argo) + start-flux.sh (Flux)
```

```
Argo: autopilot-bootstrap → apps/*/overlays/minikube → *-ns
Flux: flux-system → apps/*/overlays/flux → flux-*-ns
Same Git repo, same cluster, no overlapping objects.
```

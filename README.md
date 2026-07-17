# FastAPI on Minikube — GitOps with Argo CD + Flux CD

One **codebase** (`app/`), one **Dockerfile**, one image (`demo-api:latest`).  
Argo and Flux can run side-by-side in **separate namespaces** (no resource fighting).

## Quick start

### Flux-only (Flux Operator)

```bash
cd "/Users/mac/Kubernetes Test"
./scripts/start-flux.sh
./scripts/flux-status.sh
```

```bash
kubectl port-forward -n flux-fastapi-ns svc/fastapi 8100:8000
kubectl port-forward -n flux-api2-ns svc/api2 8101:8000
kubectl port-forward -n flux-api3-ns svc/api3 8102:8000
```

### Argo + Flux

```bash
./scripts/start.sh
./scripts/start-flux.sh
```

---

## Add a new app (one place per tool)

### Flux (no edits to `flux/clusters/.../apps.yaml`)

```bash
cp -R apps/api2/overlays/flux apps/myapp/overlays/flux
# edit namespace / APP_NAME / MESSAGE / config.json in the new overlay
./scripts/generate-flux-apps.sh   # refreshes apps/flux-apps/kustomization.yaml
git add apps/myapp apps/flux-apps && git commit -m "Add myapp to Flux" && git push
```

### Argo (ApplicationSet discovery)

```bash
cp -R apps/api2/overlays/minikube apps/myapp/overlays/minikube
# edit config.json + kustomization literals
git add apps/myapp && git commit -m "Add myapp to Argo" && git push
```

| Tool | Register by | Auto-wired via |
|------|-------------|----------------|
| **Flux** | `apps/<name>/overlays/flux/` + `generate-flux-apps.sh` | single `flux-apps` Kustomization |
| **Argo** | `apps/<name>/overlays/minikube/config.json` | ApplicationSet |

---

## Self-managed Flux

After `./scripts/start-flux.sh` seeds the cluster once, **Git owns all upgrades**:

| What | Git manifest | Upgrade by |
|------|--------------|------------|
| **Flux controllers** | `flux/clusters/minikube/flux-system/flux-instance.yaml` | Edit `distribution.version` (e.g. `2.x`) → push |
| **Flux Operator** | `flux/clusters/minikube/operator.yaml` | Edit ResourceSet `inputs.version` (e.g. `0.55.x`) → push |
| **Cluster sync** | `FluxInstance.spec.sync` | Path `flux/clusters/minikube` (includes instance + operator manifests) |

Bootstrap only installs the Operator (Helm) and applies `FluxInstance` once so Git sync can take over.

---

## Monitoring (Prometheus + Grafana)

Cluster-level dashboards (pod CPU/memory, restarts, deployment health) via `kube-prometheus-stack`, self-managed the same way as everything else:

| What | Git manifest |
|------|--------------|
| Chart source | `flux/monitoring/helmrepository.yaml` |
| Prometheus + Grafana + kube-state-metrics | `flux/monitoring/helmrelease.yaml` (trimmed for Minikube memory: no Alertmanager, no control-plane scrape targets, low resource requests, 6h retention) |
| Sync wiring | `flux/clusters/minikube/monitoring.yaml` (depends on `flux-infrastructure`) |

```bash
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80
# open http://localhost:3000  (user: admin / password: admin — demo only)
```

Prometheus and the default Kubernetes dashboards are pre-wired via the Grafana sidecar — no manual data source setup needed.

Upgrade the chart: edit `version` in `helmrelease.yaml` → `git push`.

---

## Troubleshoot / monitor Flux

```bash
./scripts/flux-status.sh
flux get kustomizations -A
flux logs --level=error --all-namespaces
kubectl describe kustomization flux-apps -n flux-system
kubectl get fluxinstance flux -n flux-system -o yaml
kubectl get fluxreport flux -n flux-system -o yaml   # if available
```

---

## Deploy config changes

```bash
# Argo: apps/*/overlays/minikube
# Flux: apps/*/overlays/flux  (+ generate-flux-apps.sh if you added/removed an app)
git push origin main
```

**Rebuild after Python code changes:**

```bash
eval "$(minikube -p newprofile docker-env)"
docker build -t demo-api:latest .
kubectl rollout restart deployment -n flux-fastapi-ns
kubectl rollout restart deployment -n flux-api2-ns
kubectl rollout restart deployment -n flux-api3-ns
```

**Teardown:** `minikube delete -p newprofile`

| Interface | Namespace | Port-forward |
|-----------|-----------|--------------|
| Argo fastapi | `fastapi-ns` | 8000 |
| Argo api2 | `api2-ns` | 8001 |
| Argo api3 | `api3-ns` | 8002 |
| Flux fastapi | `flux-fastapi-ns` | 8100 |
| Flux api2 | `flux-api2-ns` | 8101 |
| Flux api3 | `flux-api3-ns` | 8102 |

Repo: https://github.com/QuangNguyen1806/kubernetes-test.git

---

## Prerequisites

- Docker Desktop, `minikube`, `kubectl`, `docker`
- Flux: `flux` CLI (`brew install fluxcd/tap/flux`)
- Helm 3 (`brew install helm`) — Flux Operator bootstrap
- Argo path: `argocd` CLI optional

---

## Repository layout

```
app/ + Dockerfile          shared app image (demo-api)
apps/
  <name>/overlays/minikube/   Argo (config.json → ApplicationSet)
  <name>/overlays/flux/       Flux (discovered into apps/flux-apps/)
  flux-apps/                  GENERATED index for Flux (do not hand-edit)
bootstrap/                    Argo Autopilot + Helm self-management
flux/
  clusters/minikube/
    flux-system/flux-instance.yaml   Flux Operator managed Flux + Git sync
    operator.yaml                    ResourceSet → self-manage Operator (OCI + HelmRelease)
    apps.yaml                        single flux-apps Kustomization
    infrastructure.yaml
    monitoring.yaml                  Kustomization → ./flux/monitoring
  infrastructure/             Flux Redis, RBAC (flux-intern-app), namespaces
  monitoring/                 kube-prometheus-stack (Prometheus + Grafana)
scripts/
  start-flux.sh               Flux Operator bootstrap
  generate-flux-apps.sh       refresh apps/flux-apps from overlays
  flux-status.sh              monitor / troubleshoot
  start.sh                    Argo bootstrap
```

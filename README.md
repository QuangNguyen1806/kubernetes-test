# FastAPI on Minikube — GitOps with Argo CD + Flux CD

One **codebase** (`app/`), one **Dockerfile**, one image (`demo-api:latest`).  
Argo and Flux can run side-by-side in **separate namespaces** (no resource fighting).

## Quick start

### Flux-only (Flux Operator + monitoring)

```bash
cd "/Users/mac/Kubernetes Test"
./scripts/start-flux.sh
./scripts/flux-status.sh
./scripts/verify-monitoring.sh
./scripts/ensure-grafana-viewer.sh   # creates Grafana Viewer user if needed
```

```bash
# Apps
kubectl port-forward -n flux-fastapi-ns svc/fastapi 8100:8000
kubectl port-forward -n flux-api2-ns svc/api2 8101:8000
kubectl port-forward -n flux-api3-ns svc/api3 8102:8000

# Grafana
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80
# http://localhost:3000
# admin/admin  or  viewer/viewer
```

### Argo + Flux

```bash
./scripts/start.sh
./scripts/start-flux.sh
```

---

## Permissions (manage & grant access)

### Kubernetes read-only user (`viewer`)

Git defines `ClusterRole` `flux-app-viewer` + RoleBindings in Flux app namespaces and `monitoring` (`flux/infrastructure/viewer-rbac.yaml`).

```bash
./scripts/create-viewer-kubeconfig.sh
# writes ~/.kube/viewer-newprofile.kubeconfig

KUBECONFIG=~/.kube/viewer-newprofile.kubeconfig kubectl get pods -n flux-fastapi-ns
KUBECONFIG=~/.kube/viewer-newprofile.kubeconfig kubectl logs -n flux-fastapi-ns deploy/fastapi --tail=50

# Should be Forbidden:
KUBECONFIG=~/.kube/viewer-newprofile.kubeconfig kubectl delete pod -n flux-fastapi-ns --all
```

| Role | Can |
|------|-----|
| **viewer** (K8s) | get/list/watch pods, logs, services, deployments, HPA in `flux-*-ns` + `monitoring` |
| **admin** (your minikube context) | everything |

To grant another person: create a cert with `/CN=<name>/O=viewers` (group `viewers` is already bound) or add a `RoleBinding` subject.

### Grafana users

| User | Password | Role |
|------|----------|------|
| `admin` | `admin` | Admin (full) |
| `viewer` | `viewer` | Viewer (dashboards read-only) |

Credentials live in Secret `grafana-auth` (namespace `monitoring`).  
A CronJob (`grafana-create-viewer`) keeps the Viewer user present; run `./scripts/ensure-grafana-viewer.sh` to create it immediately.

---

## Application logs (view & query)

### kubectl (always available)

```bash
kubectl logs -n flux-fastapi-ns deploy/fastapi -f
kubectl logs -n flux-api2-ns deploy/api2 --since=10m
kubectl logs -n flux-api3-ns -l app=api3 --tail=100
```

Apps emit structured access logs (JSON-ish) via middleware in `app/main.py`.

### Grafana Explore → Loki

1. Open Grafana → **Explore**
2. Datasource: **Loki**
3. Example LogQL:

```logql
{namespace="flux-fastapi-ns"}
{namespace=~"flux-.*"} |= "ERROR"
{namespace="flux-api2-ns"} |= "created item"
```

Pipeline: pods stdout → **Promtail** → **Loki** → Grafana.

---

## Dashboard: CPU, memory, application logs

Provisioned in Git as ConfigMap `flux-apps-dashboard` → Grafana folder **Flux Apps**.

Open: **Dashboards → Flux Apps → Flux Apps — CPU, Memory & Logs**

| Panel | Source |
|-------|--------|
| CPU by pod | Prometheus (`container_cpu_usage_seconds_total`) |
| Memory by pod | Prometheus (`container_memory_working_set_bytes`) |
| HTTP req/s | Prometheus (`http_requests_total` from `/metrics`) |
| Latency p95 | Prometheus (`http_request_duration_seconds`) |
| HTTP 5xx rate | Prometheus (`http_requests_total{status="5xx"}`) |
| Application logs | Loki (`{namespace=~"flux-.*"}`) |

Generate traffic so metrics/logs appear:

```bash
curl -s http://localhost:8100/
curl -s http://localhost:8100/items
curl -s -X POST http://localhost:8100/items -H 'content-type: application/json' -d '{"name":"a","value":"b"}'
```

App `/metrics` is scraped via Flux `ServiceMonitor`s (`apps/*/overlays/flux/servicemonitor.yaml`).

---

## Add a new app (one place per tool)

### Flux (no edits to `flux/clusters/.../apps.yaml`)

```bash
cp -R apps/api2/overlays/flux apps/myapp/overlays/flux
# edit namespace / APP_NAME / MESSAGE / config.json / ServiceMonitor name
# add namespace (+ viewer RoleBinding) under flux/infrastructure/
./scripts/generate-flux-apps.sh
git add apps/myapp apps/flux-apps flux/infrastructure && git commit -m "Add myapp to Flux" && git push
```

### Argo (ApplicationSet discovery)

```bash
cp -R apps/api2/overlays/minikube apps/myapp/overlays/minikube
git add apps/myapp && git commit -m "Add myapp to Argo" && git push
```

| Tool | Register by | Auto-wired via |
|------|-------------|----------------|
| **Flux** | `apps/<name>/overlays/flux/` + `generate-flux-apps.sh` | single `flux-apps` Kustomization |
| **Argo** | `apps/<name>/overlays/minikube/config.json` | ApplicationSet |

Flux overlays cap **HPA maxReplicas: 1** (Minikube memory). Argo base still allows up to 3.

---

## Self-managed Flux

| What | Git manifest | Upgrade by |
|------|--------------|------------|
| **Flux controllers** | `flux/clusters/minikube/flux-system/flux-instance.yaml` | Edit `distribution.version` → push |
| **Flux Operator** | `flux/clusters/minikube/operator.yaml` | Edit ResourceSet `inputs.version` → push |
| **Cluster sync** | `FluxInstance.spec.sync` | Path `flux/clusters/minikube` |

---

## Monitoring stack (GitOps)

| Component | Manifest |
|-----------|----------|
| Prometheus + Grafana | `flux/monitoring/helmrelease.yaml` |
| Loki | `flux/monitoring/loki.yaml` |
| Promtail | `flux/monitoring/promtail.yaml` |
| Dashboard | `flux/monitoring/dashboards/flux-apps-dashboard.yaml` |
| Grafana auth Secret | `flux/monitoring/grafana-auth-secret.yaml` |
| Viewer CronJob | `flux/monitoring/grafana-viewer-job.yaml` |
| Sync | `flux/clusters/minikube/monitoring.yaml` |

```bash
./scripts/preload-monitoring-images.sh
./scripts/verify-monitoring.sh
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80
```

---

## Troubleshoot

```bash
./scripts/flux-status.sh
./scripts/verify-monitoring.sh
flux get kustomizations -A
flux get helmreleases -A
kubectl get servicemonitor -A
kubectl logs -n monitoring -l app.kubernetes.io/name=promtail --tail=50
```

If the API hangs / node NotReady (memory pressure):

```bash
minikube delete -p newprofile
./scripts/start-flux.sh
```

---

## Deploy config / code changes

```bash
# Manifests
git push origin main

# Python / Dockerfile → rebuild image
eval "$(minikube -p newprofile docker-env)"
docker build -t demo-api:latest .
kubectl rollout restart deployment -n flux-fastapi-ns,flux-api2-ns,flux-api3-ns
```

**Teardown:** `minikube delete -p newprofile`

Repo: https://github.com/QuangNguyen1806/kubernetes-test.git

---

## Prerequisites

- Docker Desktop, `minikube`, `kubectl`, `docker`, `openssl` (viewer kubeconfig)
- Flux CLI, Helm 3

---

## Repository layout

```
app/ + Dockerfile                 shared image (demo-api) + /metrics + access logs
apps/<name>/overlays/flux/        Flux overlay, HPA cap, ServiceMonitor
flux/infrastructure/              namespaces, Redis, app RBAC, viewer RBAC
flux/monitoring/                  Prometheus, Grafana, Loki, Promtail, dashboards
scripts/
  start-flux.sh                   bootstrap
  preload-monitoring-images.sh
  verify-monitoring.sh
  create-viewer-kubeconfig.sh     K8s viewer user
  ensure-grafana-viewer.sh        Grafana Viewer user
  flux-status.sh
```

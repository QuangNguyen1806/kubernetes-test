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
kubectl port-forward -n fastapi-ns svc/fastapi 8000:8000

# Terminal C — api2
kubectl port-forward -n api2-ns svc/api2 8001:8000
```

**Deploy config changes** (no kubectl):

```bash
# edit apps/fastapi/base/kustomization.yaml or apps/api2/base/kustomization.yaml
git add -A && git commit -m "update" && git push origin main
```

**Rebuild after Python code changes:**

```bash
eval "$(minikube -p newprofile docker-env)"
docker build -t fastapi:latest .
docker build -f Dockerfile.api2 -t api2:latest .
kubectl rollout restart deployment/fastapi -n fastapi-ns
kubectl rollout restart deployment/api2 -n api2-ns
```

**Teardown:** `minikube delete -p newprofile`

---

Two apps (fastapi + api2) on Minikube. Manifests live in Git; **Argo CD watches GitHub and auto-syncs** — after the one-time setup below you never run `kubectl apply` for deployments.

| App | Argo CD Application | URL (after port-forward) |
|-----|---------------------|--------------------------|
| fastapi | `minikube-fastapi` | http://127.0.0.1:8000 |
| api2 | `minikube-api2` | http://127.0.0.1:8001 |

Repo: https://github.com/QuangNguyen1806/kubernetes-test.git

---

## Prerequisites

Install once on your Mac:

- [Docker Desktop](https://www.docker.com/products/docker-desktop/) (running)
- `minikube`, `kubectl`, `docker`, `argocd` CLI

---

## Step 1 — One-time setup (single command)

```bash
cd "/Users/mac/Kubernetes Test"
chmod +x scripts/start.sh
./scripts/start.sh
```

This script:

1. Starts Minikube (`newprofile`)
2. Builds `fastapi:latest` and `api2:latest` images
3. Seeds Argo CD from `bootstrap/argo-cd/` (first install only)
4. Argo CD self-manages via Helm chart in `bootstrap/argo-cd.yaml`
5. Applies `install/autopilot-bootstrap.yaml` (Autopilot App-of-Apps)
6. Waits for Argo CD to pull GitHub and deploy everything

**You only need kubectl inside this script.** After it finishes, Argo CD owns all manifest deploys.

---

## Step 2 — Open Argo CD and the apps

**Terminal A** — Argo CD UI:

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

Open **https://localhost:8080**

| Field | Value |
|-------|-------|
| Username | `admin` |
| Password | `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" \| base64 -d && echo` |

CLI login (optional):

```bash
export ARGOCD_PWD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
argocd login localhost:8080 --username admin --password "$ARGOCD_PWD" --insecure --grpc-web
argocd app list --grpc-web
```

**Terminal B** — fastapi:

```bash
kubectl port-forward -n fastapi-ns svc/fastapi 8000:8000
curl http://127.0.0.1:8000/
```

**Terminal C** — api2:

```bash
kubectl port-forward -n api2-ns svc/api2 8001:8000
curl http://127.0.0.1:8001/
```

---

## Step 3 — Deploy changes (automatic, Git only)

Edit a manifest in Git, push — **do not run `kubectl apply`**.

Example — change the fastapi message in `apps/fastapi/base/kustomization.yaml`:

```yaml
configMapGenerator:
  - name: app-config
    literals:
      - MESSAGE=Hello from GitOps!
```

```bash
git add apps/fastapi/base/kustomization.yaml
git commit -m "GitOps: update fastapi MESSAGE"
git push origin main
```

Argo CD detects the push and syncs automatically (~15–60 s). Watch in the UI or:

```bash
argocd app wait minikube-fastapi --sync --health --grpc-web --timeout 120
curl http://127.0.0.1:8000/
```

Same for api2 — edit `apps/api2/base/kustomization.yaml`, push, watch `minikube-api2`.

### Why this is automatic

| What | How |
|------|-----|
| Manifest deploys | `syncPolicy.automated` on every Application |
| Drift correction | `selfHeal: true` reverts manual cluster edits |
| New app | Add `apps/foo/overlays/minikube/config.json` + push → ApplicationSet creates `minikube-foo` |
| Infra (Redis, namespaces) | `cluster-resources-in-cluster` syncs from Git |

### What is NOT automatic (Minikube limitation)

| What | Command |
|------|---------|
| Python **code** changes | `eval "$(minikube -p newprofile docker-env)"` then `docker build` + `kubectl rollout restart deployment/<app> -n <ns>` |
| First cluster boot | `./scripts/start.sh` (once) |
| Local URLs | `kubectl port-forward` (Argo CD has no public ingress on Minikube) |

---

## Step 4 — Verify GitOps (optional)

```bash
# All apps should show Synced
argocd app list --grpc-web

# Revision should match your latest git commit
argocd app get minikube-fastapi --grpc-web | grep Revision

# Self-heal test: edit ConfigMap in cluster → Argo CD reverts it
kubectl edit configmap -n fastapi-ns -l app.kubernetes.io/name=app-config
# wait ~1 min, curl again — MESSAGE should match Git
```

---

## Teardown

```bash
minikube delete -p newprofile
```

Re-run `./scripts/start.sh` to start fresh.

---

## Troubleshooting

| Problem | Fix |
|---------|-----|
| `connection refused` on kubectl | Start Docker Desktop → `./scripts/start.sh` |
| `bootstrap: app path does not exist` | Push latest code to GitHub, then re-run `./scripts/start.sh` |
| No `minikube-fastapi` app | Ensure `apps/fastapi/overlays/minikube/config.json` is on GitHub `main` |
| Git pushed but app unchanged | `argocd app get minikube-fastapi --grpc-web` — check Revision vs `git log -1` |
| `argo-cd` shows OutOfSync | Harmless ConfigMap drift — Argo CD itself is healthy |
| Argo CD version management | Set chart version in `bootstrap/argo-cd.yaml` (`spec.sources[].targetRevision`) |

---

## Repository layout (reference)

```
apps/           fastapi + api2 (Kustomize base/overlays + config.json)
bootstrap/      Argo CD install + Autopilot wiring
projects/       minikube AppProject + ApplicationSet
infrastructure/ namespaces, rbac, redis
install/        autopilot-bootstrap.yaml (applied once by start.sh)
scripts/        start.sh
```

Autopilot flow:

```
autopilot-bootstrap → argo-cd, root, cluster-resources
  root → projects/minikube → ApplicationSet → minikube-fastapi, minikube-api2
  cluster-resources → cluster-resources-in-cluster → infrastructure/
```

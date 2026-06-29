# FastAPI on Minikube (multi-app, Kustomize + GitOps)

Kubernetes manifests use **Kustomize** (`base` + `overlays/minikube`). **ArgoCD** uses an **App of Apps** bootstrap to sync everything from Git.

## Repository layout

```
├── app/, app2/                         # application source
├── apps/
│   ├── fastapi/base + overlays/minikube
│   └── api2/base + overlays/minikube
├── infrastructure/
│   ├── namespaces/base
│   ├── rbac/base
│   └── redis/base + overlays/minikube
├── argocd/
│   ├── bootstrap.yaml                  # App of Apps (apply once)
│   └── applications/                   # child Application CRs
└── .github/workflows/build.yml         # CI: build + push to GHCR
```

## Prerequisites

- Docker Desktop running
- `minikube`, `kubectl`, `docker`, `argocd` CLI installed
- Profile: **`newprofile`**

## Apps

| App | Code | Kustomize path | Image | Namespace | Port |
|-----|------|----------------|-------|-----------|------|
| fastapi | `app/` | `apps/fastapi/overlays/minikube` | `fastapi:latest` | `fastapi-ns` | 8000 |
| api2 | `app2/` | `apps/api2/overlays/minikube` | `api2:latest` | `api2-ns` | 8001 |

Redis runs once in `fastapi-ns` (`infrastructure/redis`); api2 shares it cross-namespace.

Repo: `https://github.com/QuangNguyen1806/kubernetes-test.git`

---

## 1. Start cluster and build images

```bash
cd "/Users/mac/Kubernetes Test"

minikube start -p newprofile --driver=docker --memory=3072 --cpus=2
minikube -p newprofile addons enable metrics-server

eval "$(minikube -p newprofile docker-env)"
docker build -t fastapi:latest .
docker build -f Dockerfile.api2 -t api2:latest .
```

---

## 2. Deploy with Kustomize (without ArgoCD)

Apply in order (namespaces → rbac → redis → apps):

```bash
kubectl apply -k infrastructure/namespaces/base
kubectl apply -k infrastructure/rbac/base
kubectl apply -k infrastructure/redis/overlays/minikube
kubectl apply -k apps/fastapi/overlays/minikube
kubectl apply -k apps/api2/overlays/minikube

kubectl rollout status deployment/fastapi -n fastapi-ns --timeout=120s
kubectl rollout status deployment/api2 -n api2-ns --timeout=120s
```

Preview rendered manifests:

```bash
kubectl kustomize apps/fastapi/overlays/minikube
```

---

## 3. Install ArgoCD and bootstrap GitOps (once)

```bash
kubectl create namespace argocd

kubectl apply -n argocd --server-side -f \
  https://raw.githubusercontent.com/argoproj/argo-cd/v2.13.2/manifests/install.yaml

kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-server \
  -n argocd --timeout=300s

# App of Apps — registers all child Applications from Git
kubectl apply -f argocd/bootstrap.yaml

kubectl get application -n argocd
```

| ArgoCD App | Git path | Sync wave |
|------------|----------|-----------|
| `bootstrap` | `argocd/applications/` | — |
| `infra-namespaces` | `infrastructure/namespaces/base` | 0 |
| `infra-rbac` | `infrastructure/rbac/base` | 1 |
| `infra-redis` | `infrastructure/redis/overlays/minikube` | 2 |
| `fastapi` | `apps/fastapi/overlays/minikube` | 3 |
| `api2` | `apps/api2/overlays/minikube` | 3 |

> Use `--server-side` on ArgoCD install to avoid CRD annotation errors.

---

## 4. Log in to ArgoCD

**Terminal A** (keep open):

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

Open **https://localhost:8080** — user `admin`, password:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d && echo
```

CLI:

```bash
argocd login localhost:8080 --username admin --password <PASSWORD> --insecure --grpc-web
argocd app list --grpc-web
argocd app get fastapi --grpc-web
```

---

## 5. Access both apps

**Terminal B:**

```bash
kubectl port-forward -n fastapi-ns svc/fastapi 8000:8000
```

**Terminal C:**

```bash
kubectl port-forward -n api2-ns svc/api2 8001:8000
```

```bash
curl http://127.0.0.1:8000/
curl http://127.0.0.1:8001/
```

---

## 6. GitOps demo — change ConfigMap via Git

ConfigMaps use `configMapGenerator` in each app's `base/kustomization.yaml`. When `MESSAGE` changes, Kustomize gives the ConfigMap a new hash suffix and updates the Deployment reference — **pods roll out automatically** (no manual `rollout restart`).

**fastapi** — edit `apps/fastapi/base/kustomization.yaml`:

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

# ArgoCD auto-syncs; or:
argocd app sync fastapi --grpc-web
kubectl rollout status deployment/fastapi -n fastapi-ns
curl http://127.0.0.1:8000/
```

**api2** — same pattern in `apps/api2/base/kustomization.yaml`.

---

## 7. GitOps demo — self-heal

```bash
kubectl edit configmap -n fastapi-ns -l app.kubernetes.io/name=app-config
# ArgoCD selfHeal reverts drift after sync
argocd app sync fastapi --grpc-web
```

---

## 8. Other tests

```bash
curl -X POST http://127.0.0.1:8000/items \
  -H "Content-Type: application/json" \
  -d '{"name":"book","value":"redis-guide"}'
curl http://127.0.0.1:8000/items

curl -X POST http://127.0.0.1:8001/items \
  -H "Content-Type: application/json" \
  -d '{"name":"tool","value":"api2-test"}'
curl http://127.0.0.1:8001/items

kubectl get hpa -n fastapi-ns
kubectl get hpa -n api2-ns

kubectl auth can-i get configmaps --as=system:serviceaccount:fastapi-ns:fastapi-sa -n intern-app
kubectl auth can-i get configmaps --as=system:serviceaccount:api2-ns:api2-sa -n intern-app
```

---

## 9. Rebuild after code changes

```bash
eval "$(minikube -p newprofile docker-env)"
docker build -t fastapi:latest .
docker build -f Dockerfile.api2 -t api2:latest .
kubectl rollout restart deployment/fastapi -n fastapi-ns
kubectl rollout restart deployment/api2 -n api2-ns
```

For registry-based deploys, CI pushes to `ghcr.io/<owner>/kubernetes-test/<app>:<sha>`. Update `images:` in the overlay and set `imagePullPolicy: IfNotPresent`.

---

## 10. Add a third app

```bash
cp -r apps/api2 apps/api3
cp -r app2 app3
# Rename api2 → api3 in apps/api3/ and app3/
# Add argocd/applications/api3.yaml (copy api2.yaml, change path + name)
# Register in bootstrap by placing the new Application YAML in argocd/applications/
```

---

## 11. Teardown

```bash
minikube delete -p newprofile
```

---

## Troubleshooting

| Problem | Fix |
|---------|-----|
| `DOCKER_NOT_RUNNING` | Start Docker Desktop |
| `memory` error on start | Use `--memory=3072` not 4096 |
| ArgoCD CRD `annotations: Too long` | Install with `--server-side` |
| `argocd-repo-server` CrashLoop on ARM | Use ArgoCD **v2.13.2** |
| `ImagePullBackOff` | `eval "$(minikube -p newprofile docker-env)"` + rebuild images |
| ConfigMap change not in app | Ensure you edited `kustomization.yaml` literals; wait for rollout |
| `argocd login` / sync fails | Port-forward 8080 open; use `--grpc-web` |
| HPA shows OutOfSync | Expected — `ignoreDifferences` on replicas in Application |
| App sync before Redis | Check sync waves; `infra-redis` is wave 2, apps are wave 3 |

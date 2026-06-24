# FastAPI on Minikube

## Prerequisites

- Docker Desktop running
- `minikube`, `kubectl`, `docker`, `argocd` CLI installed
- Profile: **`newprofile`**

---

## 1. Start cluster and build image

```bash
cd "/Users/mac/Kubernetes Test"

minikube start -p newprofile --driver=docker --memory=3072 --cpus=2
minikube -p newprofile addons enable metrics-server

eval "$(minikube -p newprofile docker-env)"
docker build -t fastapi:latest .
docker build -f Dockerfile.api2 -t api2:latest .
```

---

## 2. Install ArgoCD (once)

```bash
kubectl create namespace argocd

kubectl apply -n argocd --server-side -f \
  https://raw.githubusercontent.com/argoproj/argo-cd/v2.13.2/manifests/install.yaml

kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-server \
  -n argocd --timeout=300s
```

> Use `--server-side` to avoid CRD annotation errors with plain `kubectl apply`.

---

## 3. Register ArgoCD Applications

```bash
kubectl apply -f argocd/application.yaml
kubectl apply -f argocd/application-api2.yaml

kubectl get application -n argocd
# fastapi → path k8s/       → namespace fastapi-ns
# api2    → path k8s-api2/  → namespace api2-ns
```

Repo: `https://github.com/QuangNguyen1806/kubernetes-test.git`

---

## Multi-app layout

| App | Code | Manifests | Image | Namespace | Port |
|-----|------|-----------|-------|-----------|------|
| fastapi | `app/` | `k8s/` | `fastapi:latest` | `fastapi-ns` | 8000 |
| api2 | `app2/` | `k8s-api2/` | `api2:latest` | `api2-ns` | 8001 |

Redis runs once in `fastapi-ns`; api2 connects to it cross-namespace.

### Deploy both apps (manual)

```bash
kubectl apply -f k8s/
kubectl apply -f k8s-api2/
kubectl rollout status deployment/fastapi -n fastapi-ns
kubectl rollout status deployment/api2 -n api2-ns
```

### Access both apps

```bash
# Terminal B
kubectl port-forward -n fastapi-ns svc/fastapi 8000:8000

# Terminal C
kubectl port-forward -n api2-ns svc/api2 8001:8000
```

```bash
curl http://127.0.0.1:8000/
curl http://127.0.0.1:8001/
```

### Add a third app (same pattern)

1. Copy `app2/` → `app3/`, `k8s-api2/` → `k8s-api3/`
2. Rename labels, namespace, image tag
3. Copy `argocd/application-api2.yaml` → `application-api3.yaml`
4. `docker build -f Dockerfile.api3 -t api3:latest .`
5. `kubectl apply -f argocd/application-api3.yaml`

---

## 4. Log in to ArgoCD

### Terminal A — port-forward UI (keep open)

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

Open: **https://localhost:8080** (accept cert warning)

### Get admin password

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d && echo
```

- **Username:** `admin`
- **Password:** output from command above

### CLI login (optional)

```bash
argocd login localhost:8080 --username admin --password <PASSWORD> --insecure --grpc-web
argocd app get fastapi --grpc-web
argocd app get api2 --grpc-web
```

---

## 5. Access the FastAPI app

### Terminal B — port-forward app (keep open)

```bash
kubectl port-forward -n fastapi-ns svc/fastapi 8000:8000
```

```bash
curl http://127.0.0.1:8000/
```

Expected:

```json
{"configmap":{"MESSAGE":"Goodbye from ConfigMap"},"secret":{"API_KEY":"sk-s****"}}
```

---

## 6. GitOps demo — change via Git

**1. Edit ConfigMap locally:**

```yaml
# k8s/configmap.yaml
MESSAGE: "Hello from GitOps!"
```

**2. Commit and push:**

```bash
git add k8s/configmap.yaml
git commit -m "GitOps demo: update MESSAGE"
git push origin main
```

**3. Sync (auto within ~3 min, or force):**

```bash
argocd app sync fastapi --grpc-web
argocd app sync api2 --grpc-web
# or click Refresh → Sync in the UI
```

**4. Restart pods** (env vars don't hot-reload):

```bash
kubectl rollout restart deployment/fastapi -n fastapi-ns
kubectl rollout status deployment/fastapi -n fastapi-ns
```

**5. Verify:**

```bash
curl http://127.0.0.1:8000/
# MESSAGE should be "Hello from GitOps!"
```

---

## 7. GitOps demo — self-heal (drift detection)

**1. Manually change cluster (drift from Git):**

```bash
kubectl edit configmap app-config -n fastapi-ns
# change MESSAGE to "Hacked!"
```

**2. Watch ArgoCD UI** — app shows **OutOfSync**

**3. Self-heal reverts it** (`selfHeal: true` in application.yaml), or force:

```bash
argocd app sync fastapi --grpc-web
argocd app sync api2 --grpc-web
```

**4. Confirm Git version restored:**

```bash
kubectl get configmap app-config -n fastapi-ns -o yaml | grep MESSAGE
```

---

## 8. Other tests

```bash
# Redis
curl -X POST http://127.0.0.1:8000/items \
  -H "Content-Type: application/json" \
  -d '{"name":"book","value":"redis-guide"}'
curl http://127.0.0.1:8000/items

# HPA
kubectl get hpa fastapi -n fastapi-ns

# RBAC (yes)
kubectl auth can-i get configmaps \
  --as=system:serviceaccount:fastapi-ns:fastapi-sa -n intern-app

# RBAC (no)
kubectl auth can-i create configmaps \
  --as=system:serviceaccount:fastapi-ns:fastapi-sa -n intern-app
```

---

## 9. After code changes (not GitOps — image rebuild)

ArgoCD syncs YAML only. Rebuild image manually:

```bash
eval "$(minikube -p newprofile docker-env)"
docker build -t fastapi:latest .
docker build -f Dockerfile.api2 -t api2:latest .
kubectl rollout restart deployment/fastapi -n fastapi-ns
kubectl rollout restart deployment/api2 -n api2-ns
```

---

## 10. Teardown

```bash
minikube delete -p newprofile
```

---

## Troubleshooting

| Problem | Fix |
|---------|-----|
| `DOCKER_NOT_RUNNING` | Start Docker Desktop |
| ArgoCD CRD `annotations: Too long` | Use `--server-side` on install |
| `argocd-repo-server` CrashLoop on ARM | Use ArgoCD **v2.13.2** (not v3.x) |
| App `ImagePullBackOff` | Re-run `eval "$(minikube -p newprofile docker-env)"` + `docker build` |
| ConfigMap change not in app | `kubectl rollout restart deployment/fastapi -n fastapi-ns` |
| `argocd login` fails | Ensure port-forward on 8080 is running |

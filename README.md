# FastAPI on Minikube (multi-app)

## Prerequisites

- Docker Desktop running
- `minikube`, `kubectl`, `docker`, `argocd` CLI installed
- Profile: **`newprofile`**

## Apps

| App | Code | Manifests | Image | Namespace | Port |
|-----|------|-----------|-------|-----------|------|
| fastapi | `app/` | `k8s/` | `fastapi:latest` | `fastapi-ns` | 8000 |
| api2 | `app2/` | `k8s-api2/` | `api2:latest` | `api2-ns` | 8001 |

Redis runs once in `fastapi-ns`; api2 shares it cross-namespace.

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

## 2. Deploy both apps

```bash
kubectl apply -f k8s/
kubectl apply -f k8s-api2/

kubectl rollout status deployment/fastapi -n fastapi-ns --timeout=120s
kubectl rollout status deployment/api2 -n api2-ns --timeout=120s
kubectl get pods -n fastapi-ns
kubectl get pods -n api2-ns
```

---

## 3. Install ArgoCD and register both apps (once)

```bash
kubectl create namespace argocd

kubectl apply -n argocd --server-side -f \
  https://raw.githubusercontent.com/argoproj/argo-cd/v2.13.2/manifests/install.yaml

kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-server \
  -n argocd --timeout=300s

kubectl apply -f argocd/application.yaml
kubectl apply -f argocd/application-api2.yaml

kubectl get application -n argocd
```

| ArgoCD App | Git path | Namespace |
|------------|----------|-----------|
| fastapi | `k8s/` | `fastapi-ns` |
| api2 | `k8s-api2/` | `api2-ns` |

Repo: `https://github.com/QuangNguyen1806/kubernetes-test.git`

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
argocd app get fastapi --grpc-web
argocd app get api2 --grpc-web
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

Expected api2 response includes `"app":"api2"`.

---

## 6. GitOps demo — change via Git

**fastapi:**

```bash
# edit k8s/configmap.yaml → MESSAGE: "Hello from GitOps!"
git add k8s/configmap.yaml
git commit -m "GitOps: update fastapi MESSAGE"
git push origin main

argocd app sync fastapi --grpc-web
kubectl rollout restart deployment/fastapi -n fastapi-ns
curl http://127.0.0.1:8000/
```

**api2:**

```bash
# edit k8s-api2/configmap.yaml → MESSAGE: "Hello from api2 GitOps!"
git add k8s-api2/configmap.yaml
git commit -m "GitOps: update api2 MESSAGE"
git push origin main

argocd app sync api2 --grpc-web
kubectl rollout restart deployment/api2 -n api2-ns
curl http://127.0.0.1:8001/
```

---

## 7. GitOps demo — self-heal

```bash
kubectl edit configmap app-config -n fastapi-ns   # change MESSAGE to "Hacked!"
# ArgoCD UI shows OutOfSync → selfHeal reverts, or:
argocd app sync fastapi --grpc-web

kubectl edit configmap app-config -n api2-ns
argocd app sync api2 --grpc-web
```

---

## 8. Other tests

```bash
# Redis (fastapi)
curl -X POST http://127.0.0.1:8000/items \
  -H "Content-Type: application/json" \
  -d '{"name":"book","value":"redis-guide"}'
curl http://127.0.0.1:8000/items

# Redis (api2 — separate key prefix)
curl -X POST http://127.0.0.1:8001/items \
  -H "Content-Type: application/json" \
  -d '{"name":"tool","value":"api2-test"}'
curl http://127.0.0.1:8001/items

# HPA
kubectl get hpa -n fastapi-ns
kubectl get hpa -n api2-ns

# RBAC
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

---

## 10. Add a third app

```bash
cp -r app2 app3
cp -r k8s-api2 k8s-api3
cp argocd/application-api2.yaml argocd/application-api3.yaml
# rename namespace, labels, image → api3 in k8s-api3/ and application-api3.yaml

docker build -f Dockerfile.api3 -t api3:latest .
kubectl apply -f k8s-api3/
kubectl apply -f argocd/application-api3.yaml
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
| ConfigMap change not in app | `kubectl rollout restart deployment/<app> -n <ns>` |
| `argocd login` / sync fails | Port-forward 8080 open; use `--grpc-web` |
| HPA shows OutOfSync | Expected — `ignoreDifferences` on replicas in Application |

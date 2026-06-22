# FastAPI on Minikube

## Deploy (manual)

```bash
cd "/Users/mac/Kubernetes Test"
minikube start -p newprofile --driver=docker
minikube -p newprofile addons enable metrics-server
eval "$(minikube -p newprofile docker-env)"
docker build -t fastapi:latest .
kubectl apply -f k8s/
kubectl port-forward -n fastapi-ns svc/fastapi 8000:8000
```

## GitOps (ArgoCD)

```bash
# Install ArgoCD (once)
kubectl create namespace argocd
kubectl apply -n argocd --server-side -f \
  https://raw.githubusercontent.com/argoproj/argo-cd/v2.13.2/manifests/install.yaml

# UI
kubectl port-forward svc/argocd-server -n argocd 8080:443
# https://localhost:8080  user: admin
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d

# Register app (or apply argocd/application.yaml)
kubectl apply -f argocd/application.yaml
argocd login localhost:8080 --username admin --password <PASSWORD> --insecure
argocd app sync fastapi
```

### GitOps demo

1. Edit `k8s/configmap.yaml` → change `MESSAGE`
2. `git push`
3. ArgoCD auto-syncs (or `argocd app sync fastapi`)
4. `kubectl rollout restart deployment/fastapi -n fastapi-ns`
5. `curl http://127.0.0.1:8000/` — new message

**Self-heal demo:** `kubectl edit configmap app-config -n fastapi-ns` → ArgoCD reverts to Git.

## Test

```bash
curl http://127.0.0.1:8000/
curl -X POST http://127.0.0.1:8000/items -H "Content-Type: application/json" -d '{"name":"book","value":"redis-guide"}'
kubectl get hpa fastapi -n fastapi-ns
kubectl auth can-i get configmaps --as=system:serviceaccount:fastapi-ns:fastapi-sa -n intern-app
```

## Rebuild / teardown

```bash
eval "$(minikube -p newprofile docker-env)" && docker build -t fastapi:latest . && kubectl rollout restart deployment/fastapi -n fastapi-ns
minikube delete -p newprofile
```

# FastAPI on Minikube

## Deploy

```bash
cd "/Users/mac/Kubernetes Test"
minikube start -p newprofile --driver=docker
minikube -p newprofile addons enable metrics-server
eval "$(minikube -p newprofile docker-env)"
docker build -t fastapi:latest .
kubectl apply -f k8s/
kubectl rollout status deployment/fastapi -n fastapi-ns --timeout=120s
kubectl rollout restart deployment/fastapi -n fastapi-ns
kubectl port-forward -n fastapi-ns svc/fastapi 8000:8000
```



          envFrom:
            - configMapRef:
                name: app-config
            - secretRef:
                name: app-secret

## Test

```bash
curl http://127.0.0.1:8000/
curl -X POST http://127.0.0.1:8000/items -H "Content-Type: application/json" -d '{"name":"book","value":"redis-guide"}'
curl http://127.0.0.1:8000/items
kubectl get hpa fastapi -n fastapi-ns

RoleBinding test
# should be yes
kubectl auth can-i get configmaps --as=system:serviceaccount:fastapi-ns:fastapi-sa -n intern-app
kubectl auth can-i list secrets     --as=system:serviceaccount:fastapi-ns:fastapi-sa -n intern-app
# should be no
kubectl auth can-i create configmaps --as=system:serviceaccount:fastapi-ns:fastapi-sa -n intern-app
kubectl auth can-i get configmaps    --as=system:serviceaccount:fastapi-ns:fastapi-sa -n fastapi-ns
```

## Rebuild / teardown

```bash
eval "$(minikube docker-env)" && docker build -t fastapi:latest . && kubectl rollout restart deployment/fastapi -n fastapi-ns
minikube delete
```

**Requires:** Docker Desktop running, ~10 GB free disk.

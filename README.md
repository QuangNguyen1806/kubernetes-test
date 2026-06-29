# FastAPI on Minikube (Argo CD Autopilot layout)

Kubernetes manifests use **Kustomize** (`base` + `overlays/minikube`). **Argo CD** follows the [Argo CD Autopilot](https://github.com/argoproj-labs/argocd-autopilot) repository pattern: `bootstrap/` → `projects/` → `apps/` with **ApplicationSet** + `config.json`.

## Repository layout

```
├── app/, app2/                              # application source
├── apps/
│   ├── fastapi/base + overlays/minikube/
│   │   └── config.json                      # ApplicationSet discovers this
│   └── api2/base + overlays/minikube/
│       └── config.json
├── bootstrap/
│   ├── argo-cd/                             # Argo CD self-managed from Git
│   ├── cluster-resources/                   # infra via ApplicationSet
│   ├── argo-cd.yaml, root.yaml, cluster-resources.yaml
├── projects/
│   └── minikube.yaml                        # AppProject + ApplicationSet
├── infrastructure/                          # namespaces, rbac, redis
├── install/
│   └── autopilot-bootstrap.yaml             # apply once after Argo CD install
└── .github/workflows/build.yml
```

## Prerequisites

- Docker Desktop running
- `minikube`, `kubectl`, `docker`, `argocd` CLI installed
- Profile: **`newprofile`**

## Apps

| App | Code | Kustomize path | Argo CD Application | Namespace | Port |
|-----|------|----------------|---------------------|-----------|------|
| fastapi | `app/` | `apps/fastapi/overlays/minikube` | `minikube-fastapi` | `fastapi-ns` | 8000 |
| api2 | `app2/` | `apps/api2/overlays/minikube` | `minikube-api2` | `api2-ns` | 8001 |

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

## 2. Deploy with Kustomize (without Argo CD)

```bash
kubectl apply -k bootstrap/cluster-resources/in-cluster
kubectl apply -k apps/fastapi/overlays/minikube
kubectl apply -k apps/api2/overlays/minikube

kubectl rollout status deployment/fastapi -n fastapi-ns --timeout=120s
kubectl rollout status deployment/api2 -n api2-ns --timeout=120s
```

---

## 3. Install Argo CD and bootstrap Autopilot (once)

**Step A** — install Argo CD (first time only):

```bash
kubectl create namespace argocd

kubectl apply -k bootstrap/argo-cd

kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-server \
  -n argocd --timeout=300s
```

**Step B** — apply the Autopilot bootstrap Application:

```bash
kubectl apply -f install/autopilot-bootstrap.yaml
```

This creates three child resources from `bootstrap/`:

| Application | Role |
|-------------|------|
| `argo-cd` | Argo CD manages itself from `bootstrap/argo-cd/` |
| `root` | Syncs `projects/` (AppProjects + ApplicationSets) |
| `cluster-resources` (ApplicationSet) | Deploys `bootstrap/cluster-resources/in-cluster/` (infra) |

Then `root` deploys `projects/minikube.yaml`, which creates:

| Resource | Role |
|----------|------|
| `minikube` AppProject | Project scope for local cluster |
| `minikube` ApplicationSet | Discovers `apps/**/minikube/config.json` |
| `minikube-fastapi`, `minikube-api2` | Auto-created Applications |

```bash
kubectl get application,applicationset,appproject -n argocd
```

> Argo CD is pinned to **v2.13.2** in `bootstrap/argo-cd/` (ARM-friendly). Use `kubectl apply -k` not plain `kubectl apply` for the install.

---

## 4. Log in to Argo CD

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

Password:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d && echo
```

```bash
argocd login localhost:8080 --username admin --password <PASSWORD> --insecure --grpc-web
argocd app list --grpc-web
```

---

## 5. Access both apps

```bash
kubectl port-forward -n fastapi-ns svc/fastapi 8000:8000
kubectl port-forward -n api2-ns svc/api2 8001:8000

curl http://127.0.0.1:8000/
curl http://127.0.0.1:8001/
```

---

## 6. GitOps demo — change ConfigMap via Git

Edit `MESSAGE` in `apps/fastapi/base/kustomization.yaml` (`configMapGenerator` literals). Push to Git — Argo CD syncs and pods roll out automatically.

```bash
git add apps/fastapi/base/kustomization.yaml
git commit -m "GitOps: update fastapi MESSAGE"
git push origin main

argocd app sync minikube-fastapi --grpc-web
kubectl rollout status deployment/fastapi -n fastapi-ns
```

---

## 7. Add a third app (Autopilot pattern)

```bash
cp -r apps/api2 apps/api3
cp -r app2 app3
# Rename api2 → api3 in apps/api3/ and app3/

# Create overlay config for ApplicationSet discovery:
cat > apps/api3/overlays/minikube/config.json <<'EOF'
{
  "appName": "api3",
  "userGivenName": "api3",
  "destNamespace": "api3-ns",
  "destServer": "https://kubernetes.default.svc",
  "srcPath": "apps/api3/overlays/minikube",
  "srcRepoURL": "https://github.com/QuangNguyen1806/kubernetes-test.git",
  "srcTargetRevision": "main"
}
EOF

# Add api3-ns to infrastructure/namespaces/base/namespaces.yaml
git push origin main
# ApplicationSet creates minikube-api3 automatically
```

To add another environment (e.g. staging), create `projects/staging.yaml` and `apps/*/overlays/staging/config.json`.

---

## 8. Rebuild after code changes

```bash
eval "$(minikube -p newprofile docker-env)"
docker build -t fastapi:latest .
docker build -f Dockerfile.api2 -t api2:latest .
kubectl rollout restart deployment/fastapi -n fastapi-ns
kubectl rollout restart deployment/api2 -n api2-ns
```

CI pushes images to `ghcr.io/<owner>/kubernetes-test/<app>:<sha>` on push to `main`.

---

## 9. Teardown

```bash
minikube delete -p newprofile
```

---

## Autopilot flow (diagram)

```
autopilot-bootstrap
  ├── argo-cd          (self-managed Argo CD)
  ├── root
  │     └── projects/minikube.yaml
  │           ├── AppProject: minikube
  │           └── ApplicationSet → minikube-fastapi, minikube-api2
  └── cluster-resources (ApplicationSet)
        └── cluster-resources-in-cluster → infrastructure/
```

---

## Troubleshooting

| Problem | Fix |
|---------|-----|
| `DOCKER_NOT_RUNNING` | Start Docker Desktop |
| Argo CD CRD errors on ARM | Use v2.13.2 in `bootstrap/argo-cd/` |
| `argocd-repo-server` CrashLoop | Same — stay on v2.13.2 |
| No `minikube-fastapi` app | Check `config.json` exists under `apps/*/overlays/minikube/` |
| App before Redis ready | `cluster-resources` sync wave 1, apps wave 3 |
| HPA OutOfSync | Expected — `ignoreDifferences` on replicas |
| Migrating from old `argocd/` layout | Delete old Applications; apply `install/autopilot-bootstrap.yaml` |

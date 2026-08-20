# Kubernetes Test Lab

A hands-on lab repo for running **FastAPI microservices on Minikube** with **GitOps** (Flux CD and optional Argo CD), full **observability** (Prometheus, Grafana, Loki), and **Terraform** workflows for both **LocalStack** (fake AWS) and **real AWS** (Lambda, API Gateway, S3, billing alerts).

**Repository:** https://github.com/QuangNguyen1806/kubernetes-test.git

---

## What this project is

| Area | What you get |
|------|----------------|
| **Application** | One shared FastAPI image (`demo-api`) with Redis, `/metrics`, structured access logs |
| **Kubernetes** | Three demo apps (`fastapi`, `api2`, `api3`) on Minikube, deployed via Flux |
| **GitOps** | Flux Operator + self-managed FluxInstance; optional Argo CD side-by-side |
| **Observability** | Prometheus, Grafana dashboards, Loki + Promtail, ServiceMonitors |
| **Access control** | K8s read-only `viewer` user + Grafana Viewer role |
| **Local AWS** | Terraform + LocalStack (safe local IaC, STS smoke-check) |
| **Real AWS** | Terraform: Lambda (**container from ECR**), API Gateway, S3, DynamoDB CRUD, billing, **ECR** (app + lambda images) |

The FastAPI apps use **Redis only** today — they do not call AWS. The AWS stacks are separate learning/demo paths.

### ECR (Amazon Docker registry)

| Scope | What | How |
|-------|------|-----|
| **A** | Empty ECR repos | Terraform `aws_ecr_repository` (app + lambda) |
| **B** | Build & push images | `./scripts/ecr-push.sh` |
| **C** | Lambda runs container from ECR | Terraform `package_type=Image` after push |
| **D** | Minikube runs FastAPI from ECR | `./scripts/ecr-minikube-sync.sh` or `USE_ECR=1 ./scripts/start-flux.sh` |
| **E** | CI push to ECR | GitHub Actions + `PUSH_TO_ECR=true` + OIDC role |

```bash
unset AWS_ENDPOINT_URL
./scripts/ecr-push.sh                 # B: push FastAPI + Lambda images
# then terraform apply (C uses the Lambda image)
./scripts/ecr-minikube-sync.sh        # D: load app image into Minikube
```

---

## Prerequisites

### Kubernetes lab (required for Minikube path)

| Tool | Purpose |
|------|---------|
| [Docker Desktop](https://www.docker.com/products/docker-desktop/) | Minikube driver (allocate **≥ 6 GiB RAM**) |
| [minikube](https://minikube.sigs.k8s.io/) | Local cluster (`newprofile` by default) |
| [kubectl](https://kubernetes.io/docs/tasks/tools/) | Cluster access |
| [Flux CLI](https://fluxcd.io/flux/installation/) | Bootstrap helpers |
| [Helm 3](https://helm.sh/) | Used by Flux for charts |
| `openssl` | Viewer kubeconfig script |

### AWS / Terraform (optional)

| Tool | Purpose |
|------|---------|
| [Terraform](https://developer.hashicorp.com/terraform/install) `>= 1.5` | IaC |
| [AWS CLI v2](https://aws.amazon.com/cli/) | Real AWS (`aws configure`) |
| Docker Compose | LocalStack only |

---

## Install & clone

```bash
git clone https://github.com/QuangNguyen1806/kubernetes-test.git
cd kubernetes-test
```

No Python venv is required for the K8s path unless you hack on `app/` locally. For AWS scripts you need `terraform`, `aws`, `curl`, and `python3` on your PATH.

---

## Quick start — Kubernetes (Flux)

### 1. Bootstrap the cluster

```bash
./scripts/start-flux.sh
```

This starts Minikube, installs the Flux Operator, syncs Git manifests, waits for apps + monitoring, and prints status.

### 2. Check health

```bash
./scripts/flux-status.sh
./scripts/verify-monitoring.sh
./scripts/ensure-grafana-viewer.sh   # optional Grafana Viewer user
```

### 3. Use the apps

```bash
# Terminal 1 — FastAPI apps
kubectl port-forward -n flux-fastapi-ns svc/fastapi 8100:8000
kubectl port-forward -n flux-api2-ns svc/api2 8101:8000
kubectl port-forward -n flux-api3-ns svc/api3 8102:8000

# Terminal 2 — Grafana
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80
```

| URL | What |
|-----|------|
| http://localhost:8100/docs | Swagger UI (fastapi) |
| http://localhost:8100/health | Health check |
| http://localhost:8100/metrics | Prometheus metrics |
| http://localhost:3000 | Grafana (`admin`/`admin` or `viewer`/`viewer`) |

Generate traffic so dashboards populate:

```bash
curl -s http://localhost:8100/
curl -s http://localhost:8100/items
curl -s -X POST http://localhost:8100/items -H 'content-type: application/json' -d '{"name":"a","value":"b"}'
```

### 4. Tear down

```bash
minikube delete -p newprofile
```

---

## Quick start — Argo CD + Flux (optional)

```bash
./scripts/start.sh          # Argo CD
./scripts/start-flux.sh     # Flux on top
```

---

## Quick start — Local AWS (LocalStack)

Safe local Terraform against fake AWS on port 4566. **No real charges.**

```bash
./scripts/localstack-up.sh
./scripts/tf-localstack.sh init
./scripts/tf-localstack.sh apply    # STS smoke-check
./scripts/tf-localstack.sh verify
./scripts/tf-localstack.sh destroy
./scripts/localstack-down.sh
```

Details: [`terraform/README.md`](terraform/README.md) · Env template: [`.env.example`](.env.example)

---

## Quick start — Real AWS (Terraform lab)

Creates API Gateway → Lambda → S3, plus billing alerts (SNS + Budget) and **remote Terraform state** in S3.

```bash
unset AWS_ENDPOINT_URL          # must be real AWS, not LocalStack
cp terraform-aws/terraform.tfvars.example terraform-aws/terraform.tfvars
# edit billing_email to YOUR real email

./scripts/tf-aws.sh demo-validation   # show variable validation
./scripts/tf-aws.sh bootstrap         # create state bucket → writes backend.hcl (local, gitignored)
./scripts/tf-aws.sh apply
./scripts/tf-aws.sh test              # full checklist
curl "$(terraform -chdir=terraform-aws output -raw api_url)/"

./scripts/tf-aws.sh destroy           # tear down lab resources
./scripts/tf-aws.sh destroy-bootstrap # last: remove state bucket
```

**Important:** Confirm the SNS subscription email after apply or billing alerts will not arrive.

Full walkthrough + AWS Console demo: [`terraform-aws/README.md`](terraform-aws/README.md)

### Files you must NOT commit (gitignored)

- `terraform-aws/terraform.tfvars` — your email and settings
- `terraform-aws/backend.hcl` — your state bucket name
- `terraform-aws/*.tfstate*` — Terraform state
- `.env` — local secrets

---

## Permissions & access

### Kubernetes read-only user (`viewer`)

```bash
./scripts/create-viewer-kubeconfig.sh
# writes ~/.kube/viewer-newprofile.kubeconfig

KUBECONFIG=~/.kube/viewer-newprofile.kubeconfig kubectl get pods -n flux-fastapi-ns
```

Defined in `flux/infrastructure/viewer-rbac.yaml`.

### Grafana users (lab defaults)

| User | Password | Role |
|------|----------|------|
| `admin` | `admin` | Admin |
| `viewer` | `viewer` | Viewer |

---

## Logs & dashboards

### kubectl

```bash
kubectl logs -n flux-fastapi-ns deploy/fastapi -f
```

### Grafana Explore → Loki

```logql
{namespace="flux-fastapi-ns"}
{namespace=~"flux-.*"} |= "ERROR"
```

### Dashboard

**Dashboards → Flux Apps → Flux Apps — CPU, Memory & Logs** (provisioned from Git)

---

## Add a new app

### Flux (recommended)

```bash
cp -R apps/api2/overlays/flux apps/myapp/overlays/flux
# edit namespace, APP_NAME, ServiceMonitor, etc.
./scripts/generate-flux-apps.sh
git add apps/myapp apps/flux-apps flux/infrastructure
git commit -m "Add myapp to Flux"
git push
```

### Argo CD

```bash
cp -R apps/api2/overlays/minikube apps/myapp/overlays/minikube
git add apps/myapp && git commit -m "Add myapp to Argo" && git push
```

---

## Deploy code changes

```bash
eval "$(minikube -p newprofile docker-env)"
docker build -t demo-api:latest .
kubectl rollout restart deployment -n flux-fastapi-ns,flux-api2-ns,flux-api3-ns
```

Manifest changes: `git push origin main` — Flux reconciles from Git.

---

## Troubleshooting

```bash
./scripts/flux-status.sh
./scripts/verify-monitoring.sh
flux get kustomizations -A
kubectl logs -n monitoring -l app.kubernetes.io/name=promtail --tail=50
```

If the node is NotReady / API hangs (often memory):

```bash
minikube delete -p newprofile
./scripts/start-flux.sh
```

For AWS Terraform issues:

```bash
./scripts/tf-aws.sh validate
./scripts/tf-aws.sh demo-validation
```

---

## Repository layout

```
app/ + Dockerfile                 Shared FastAPI image + /metrics
apps/<name>/overlays/flux/        Per-app Flux overlay, HPA, ServiceMonitor
flux/
  clusters/minikube/              Flux sync entrypoints (apps, infra, monitoring, logging)
  infrastructure/                 Namespaces, Redis, RBAC, viewer access
  monitoring/                     Prometheus, Grafana, dashboards
  logging/                        Loki + Promtail
scripts/
  start-flux.sh                   Minikube + Flux bootstrap
  flux-status.sh                  Reconciliation status
  verify-monitoring.sh            Prometheus/Grafana/Loki checks
  tf-localstack.sh                Terraform ↔ LocalStack
  tf-aws.sh                       Terraform ↔ real AWS
terraform/                        LocalStack IaC
terraform-aws/                    Real AWS IaC (modules: lambda, billing, bootstrap)
docker-compose.localstack.yml     LocalStack Community
.env.example                      LocalStack env template
```

---

## Self-managed Flux upgrades

| Component | Manifest | Change |
|-----------|----------|--------|
| Flux controllers | `flux/clusters/minikube/flux-system/flux-instance.yaml` | `distribution.version` |
| Flux Operator | `flux/clusters/minikube/operator.yaml` | ResourceSet `inputs.version` |

Push to Git — Flux reconciles itself.

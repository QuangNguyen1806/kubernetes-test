#!/usr/bin/env bash
# Create a certificate-based kubeconfig for the read-only "viewer" user.
# Requires cluster-admin kubeconfig (default from minikube).
set -euo pipefail

PROFILE="${MINIKUBE_PROFILE:-newprofile}"
OUT="${VIEWER_KUBECONFIG:-$HOME/.kube/viewer-newprofile.kubeconfig}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

kubectl config use-context "$PROFILE" >/dev/null 2>&1 || true

echo "==> Generating client cert for user 'viewer'"
openssl genrsa -out "$TMP/viewer.key" 2048 >/dev/null 2>&1
openssl req -new -key "$TMP/viewer.key" -out "$TMP/viewer.csr" -subj "/CN=viewer/O=viewers" >/dev/null 2>&1

# Sign with Minikube CA
CA_CRT="$HOME/.minikube/profiles/$PROFILE/ca.crt"
CA_KEY="$HOME/.minikube/profiles/$PROFILE/ca.key"
if [[ ! -f "$CA_CRT" || ! -f "$CA_KEY" ]]; then
  # Fallback path used by some minikube installs
  CA_CRT="$HOME/.minikube/ca.crt"
  CA_KEY="$HOME/.minikube/ca.key"
fi
[[ -f "$CA_CRT" && -f "$CA_KEY" ]] || { echo "ERROR: Minikube CA not found under ~/.minikube" >&2; exit 1; }

openssl x509 -req -in "$TMP/viewer.csr" -CA "$CA_CRT" -CAkey "$CA_KEY" \
  -CAcreateserial -out "$TMP/viewer.crt" -days 365 >/dev/null 2>&1

SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
CLUSTER=$(kubectl config view --minify -o jsonpath='{.clusters[0].name}')

kubectl config --kubeconfig="$OUT" set-cluster "$CLUSTER" \
  --server="$SERVER" --certificate-authority="$CA_CRT" --embed-certs=true >/dev/null
kubectl config --kubeconfig="$OUT" set-credentials viewer \
  --client-certificate="$TMP/viewer.crt" --client-key="$TMP/viewer.key" --embed-certs=true >/dev/null
kubectl config --kubeconfig="$OUT" set-context viewer@"$PROFILE" \
  --cluster="$CLUSTER" --user=viewer >/dev/null
kubectl config --kubeconfig="$OUT" use-context viewer@"$PROFILE" >/dev/null

echo "Wrote $OUT"
echo ""
echo "Test (should succeed):"
echo "  KUBECONFIG=$OUT kubectl get pods -n flux-fastapi-ns"
echo "  KUBECONFIG=$OUT kubectl logs -n flux-fastapi-ns deploy/fastapi --tail=20"
echo ""
echo "Test (should FAIL Forbidden):"
echo "  KUBECONFIG=$OUT kubectl delete pod -n flux-fastapi-ns --all"

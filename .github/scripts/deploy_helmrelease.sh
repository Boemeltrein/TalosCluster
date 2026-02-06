#!/usr/bin/env bash
set -euo pipefail

HELMRELEASE_PATH="${1:-}"

if [[ -z "$HELMRELEASE_PATH" ]]; then
  echo "❌ No HelmRelease path provided"
  exit 1
fi

echo "🔍 Processing HelmRelease: $HELMRELEASE_PATH"

# --------------------------------------------------
# Extract HelmRelease metadata
# --------------------------------------------------
RELEASE_NAME="$(yq '.metadata.name' "$HELMRELEASE_PATH")"
NAMESPACE="$(yq '.metadata.namespace' "$HELMRELEASE_PATH")"
CHART_NAME="$(yq '.spec.chart.spec.chart' "$HELMRELEASE_PATH")"
CHART_VERSION="$(yq '.spec.chart.spec.version' "$HELMRELEASE_PATH")"
REPO_NAME="$(yq '.spec.chart.spec.sourceRef.name' "$HELMRELEASE_PATH")"
REPO_FILE="repositories/helm/${REPO_NAME}.yaml"
REPO_URL="$(yq '.spec.url' "$REPO_FILE")"

echo "📦 Chart: $CHART_NAME@$CHART_VERSION"
echo "🌍 Repo:  $REPO_URL"
echo "📂 NS:    $NAMESPACE"

# --------------------------------------------------
# Prepare values
# --------------------------------------------------
VALUES_FILE="$(mktemp)"
yq '.spec.values // {}' "$HELMRELEASE_PATH" > "$VALUES_FILE"

# Remove persistence for ephemeral CI cluster
yq -i 'del(.persistence)' "$VALUES_FILE" || true

# Remove cnpg for ephemeral CI cluster
yq -i 'del(.cnpg)' "$VALUES_FILE" || true

# Disable ingress
yq -i '.ingress = {}' "$VALUES_FILE" || true

# --------------------------------------------------
# Setup chart reference
# --------------------------------------------------
if [[ "$REPO_URL" == oci://* ]]; then
  CHART_REF="$REPO_URL/$CHART_NAME"
else
  helm repo add ci-repo "$REPO_URL" >/dev/null 2>&1 || true
  helm repo update >/dev/null 2>&1
  CHART_REF="ci-repo/$CHART_NAME"
fi

# --------------------------------------------------
# Render manifests for dependency detection
# --------------------------------------------------
RENDERED="$(mktemp)"

helm template "$RELEASE_NAME" "$CHART_REF" \
  --version "$CHART_VERSION" \
  --namespace "$NAMESPACE" \
  --values "$VALUES_FILE" \
  > "$RENDERED"

# --------------------------------------------------
# Detect dependencies
# --------------------------------------------------
install_cnpg=false
install_volsync=false
install_ingress=false
install_certmanager=false

grep -q "postgresql.cnpg.io" "$RENDERED" && install_cnpg=true
grep -q "volsync.backube" "$RENDERED" && install_volsync=true
grep -q "kind: Ingress" "$RENDERED" && install_ingress=true
grep -q "cert-manager.io" "$RENDERED" && install_certmanager=true

echo "🔎 Dependencies:"
echo "  CNPG:        $install_cnpg"
echo "  VolSync:     $install_volsync"
echo "  Ingress:     $install_ingress"
echo "  CertManager: $install_certmanager"

# --------------------------------------------------
# Install dependencies
# --------------------------------------------------
if $install_cnpg; then
  echo "🗄 Installing CloudNativePG..."
  helm install cloudnative-pg oci://ghcr.io/cloudnative-pg/charts/cloudnative-pg --namespace cloudnative-pg --create-namespace --wait
  if [[ "$?" != "0" ]]; then
      echo "Failed to install CloudNativePG"
      exit 1
  fi
  echo "Done installing CloudNativePG"
fi

if $install_volsync; then
  echo "💾 Installing VolSync CRDs..."
  kubectl apply -f https://raw.githubusercontent.com/backube/volsync/main/config/crd/bases/volsync.backube_replicationsources.yaml
  kubectl apply -f https://raw.githubusercontent.com/backube/volsync/main/config/crd/bases/volsync.backube_replicationdestinations.yaml
fi

if $install_ingress; then
  echo "🌐 Installing ingress-nginx..."
  helm install ingress-nginx oci://ghcr.io/home-operations/charts-mirror/ingress-nginx --namespace ingress-nginx --create-namespace \
      --set controller.ingressClassResource.default=true --set controller.publishService.enabled=false --set controller.service.type="ClusterIP" --set controller.config.allow-snippet-annotations=true --set controller.config.annotations-risk-level="Critical" --wait
  if [[ "$?" != "0" ]]; then
      echo "Failed to install ingress-nginx"
      exit 1
  fi
  echo "Done installing ingress-nginx"
fi

if $install_certmanager; then
  echo "🔐 Installing cert-manager..."
  kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml
  kubectl wait deployment --all -n cert-manager --for=condition=Available --timeout=180s
fi

# --------------------------------------------------
# Deploy chart
# --------------------------------------------------
echo "🚀 Deploying $RELEASE_NAME..."

set +e
helm upgrade --install "$RELEASE_NAME" "$CHART_REF" \
  --version "$CHART_VERSION" \
  --namespace "$NAMESPACE" \
  --create-namespace \
  --values "$VALUES_FILE" \
  --wait \
  --timeout 5m
HELM_RC=$?
set -e

# --------------------------------------------------
# Debug info
# --------------------------------------------------
echo "📦 Pods:"
kubectl get pods -n "$NAMESPACE" -o wide || true

echo "📅 Events:"
kubectl get events -n "$NAMESPACE" --sort-by=.metadata.creationTimestamp || true

for pod in $(kubectl get pods -n "$NAMESPACE" -o name 2>/dev/null); do
  echo "==== Logs for $pod ===="
  kubectl logs -n "$NAMESPACE" "$pod" --all-containers --tail=200 || true
done

# --------------------------------------------------
# Exit result
# --------------------------------------------------
if [ "$HELM_RC" -ne 0 ]; then
  echo "❌ Deployment failed"
  exit "$HELM_RC"
fi

echo "✅ Deployment succeeded"

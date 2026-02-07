#!/usr/bin/env bash
set -euo pipefail

HELMRELEASE_PATH="${1:-}"

if [[ -z "$HELMRELEASE_PATH" ]]; then
  echo "❌ No HelmRelease path provided"
  exit 1
fi

echo "🔍 Processing HelmRelease: $HELMRELEASE_PATH"

# --------------------------------------------------
# Check stopAll
# --------------------------------------------------
STOP_ALL=$(yq '.spec.values.global.stopAll // "false"' "$HELMRELEASE_PATH")

if [[ "$STOP_ALL" == "true" ]]; then
  echo "=============================================="
  echo "⏭ SKIPPED: $HELMRELEASE_PATH"
  echo "Reason: global.stopAll=true"
  echo "=============================================="
  exit 0
fi

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

echo "📦 Chart:        $CHART_NAME@$CHART_VERSION"
echo "🌍 Repository:   $REPO_URL"
echo "📂 Namespace:    $NAMESPACE"

# --------------------------------------------------
# Prepare values
# --------------------------------------------------
RAW_VALUES="$(mktemp)"
VALUES_FILE="$(mktemp)"

# Extract values
yq '.spec.values // {}' "$HELMRELEASE_PATH" > "$RAW_VALUES"

# --------------------------------------------------
# Extract ${VAR} placeholders from values YAML
# --------------------------------------------------
VARS_IN_FILE="$(
  grep -o '\${[A-Za-z_][A-Za-z0-9_]*}' "$RAW_VALUES" | sort -u
)"

# --------------------------------------------------
# Determine which vars exist and which are missing
# --------------------------------------------------
EXISTING_VARS=""
MISSING_VARS=""

while IFS= read -r var; do
  name="${var:2:-1}"  # strip ${ and }

  if printenv "$name" >/dev/null 2>&1; then
    EXISTING_VARS+="${var} "
  else
    MISSING_VARS+="${var} "
  fi
done <<< "$VARS_IN_FILE"

# --------------------------------------------------
# Optional: fail if required vars are missing
# (toggle via STRICT_ENV=true)
# --------------------------------------------------
if [[ "${STRICT_ENV:-false}" == "true" && -n "$MISSING_VARS" ]]; then
  echo "❌ Missing required environment variables:"
  printf '  %s\n' $MISSING_VARS
  exit 1
fi

# --------------------------------------------------
# Substitute only existing variables
# Missing ones remain literal ${VAR}
# --------------------------------------------------
envsubst "$EXISTING_VARS" < "$RAW_VALUES" > "$VALUES_FILE"

# Debug
echo "✔ Replaced vars:"
printf '  %s\n' $EXISTING_VARS

if [[ -n "$MISSING_VARS" ]]; then
  echo "⚠ Unresolved vars left in values (kept as-is):"
  printf '  %s\n' $MISSING_VARS
fi

# --------------------------------------------------
# Remove PVC and CNPG because of backup restore issues
# --------------------------------------------------

# Remove persistence for ephemeral CI cluster
yq -i 'del(.persistence)' "$VALUES_FILE" || true

# Remove cnpg for ephemeral CI cluster
yq -i 'del(.cnpg)' "$VALUES_FILE" || true

# # Disable ingress
# yq -i '.ingress = {}' "$VALUES_FILE" || true

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
install_prometheus=false

grep -q "postgresql.cnpg.io" "$RENDERED" && install_cnpg=true
grep -q "volsync.backube" "$RENDERED" && install_volsync=true
grep -q "kind: Ingress" "$RENDERED" && install_ingress=true
grep -q "cert-manager.io" "$RENDERED" && install_certmanager=true
grep -q "monitoring.coreos.com" "$RENDERED" && install_prometheus=true

echo "🔎 Dependencies:"
echo "  CNPG:        $install_cnpg"
echo "  VolSync:     $install_volsync"
echo "  Ingress:     $install_ingress"
echo "  CertManager: $install_certmanager"
echo "  Prometheus:  $install_prometheus"

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
  if [[ "$?" != "0" ]]; then
      echo "Failed to install Volsync CRDs"
      exit 1
  fi
  echo "Done installing Volsync CRDs"
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
  if [[ "$?" != "0" ]]; then
      echo "Failed to install certmanager"
      exit 1
  fi
  echo "Done installing certmanager"
fi

if $install_prometheus; then
  echo "📊 Installing Prometheus Operator CRDs..."

  kubectl apply -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/main/example/prometheus-operator-crd/monitoring.coreos.com_servicemonitors.yaml
  kubectl apply -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/main/example/prometheus-operator-crd/monitoring.coreos.com_podmonitors.yaml
  kubectl apply -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/main/example/prometheus-operator-crd/monitoring.coreos.com_prometheusrules.yaml
  if [[ "$?" != "0" ]]; then
      echo "Failed to install Prometheus Operator CRDs"
      exit 1
  fi
  echo "Done installing Prometheus Operator CRDs"
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

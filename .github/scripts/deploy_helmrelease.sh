#!/usr/bin/env bash
set -euo pipefail

HELMRELEASE_PATH="${1:-}"

# --------------------------------------------------
# Colors & Formatting
# --------------------------------------------------
RED='\033[0;31m'
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m' # reset

# --------------------------------------------------
# Logging Functions
# --------------------------------------------------
print_header() {
  local title="$1"
  local emoji="$2"
  local width=80
  local display_title="$emoji $title"
  
  # Get actual display width
  local visual_width=$(echo -n "$display_title" | wc -L)
  local padding=$(( (width - visual_width - 2) / 2 ))
  
  echo -e "${BOLD}╔$(printf '═%.0s' {1..78})╗${NC}"
  printf "${BOLD}║${NC}%*s${BOLD}${CYAN}%s${NC}%*s${BOLD}║${NC}\n" \
    $padding "" "$display_title" $((width - padding - visual_width - 2)) ""
  echo -e "${BOLD}╚$(printf '═%.0s' {1..78})╝${NC}"
}

print_section() {
  echo " "
  echo -e "${BLUE}${BOLD}$1${NC}"
  echo -e "${DIM}$(printf '─%.0s' $(seq 1 78))${NC}"
}

print_sub_section() {
  echo -e "${BLUE}$1${NC}"
}

# --------------------------------------------------
# Check Helmrelease Path
# --------------------------------------------------

if [[ -z "$HELMRELEASE_PATH" ]]; then
  echo "❌ No HelmRelease path provided"
  exit 1
fi

print_header "HelmRelease Deployment Test" "🚀"

print_section "⚙️ Processing: $HELMRELEASE_PATH"

# --------------------------------------------------
# Check stopAll
# --------------------------------------------------
STOP_ALL=$(yq '.spec.values.global.stopAll // "false"' "$HELMRELEASE_PATH")

if [[ "$STOP_ALL" == "true" ]]; then
  echo -e "${YELLOW}⏭  ${BOLD}DEPLOYMENT SKIPPED  ⏭${NC}"
  echo -e "${YELLOW}Reason:  global.stopAll=true${NC}"
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
APP_DIR="$(dirname "$HELMRELEASE_PATH")"
CI_VALUES_FILE="$APP_DIR/ci/ci-values.yaml"

echo "📦 Chart:         $CHART_NAME@$CHART_VERSION"
echo "🌍 Repository:    $REPO_URL"
echo "🏷️ Release Name:  $RELEASE_NAME"
echo "📂 Namespace:     $NAMESPACE"

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
# Substitute only existing variables
# Missing ones remain literal ${VAR}
# --------------------------------------------------
envsubst "$EXISTING_VARS" < "$RAW_VALUES" > "$VALUES_FILE"

# --------------------------------------------------
# Change PVC and CNPG because of backup restore issues
# --------------------------------------------------
# Disable volsync
yq -i '
  (.. | select(type == "!!map" and has("volsync")).volsync[]?.src.enabled) = false |
  (.. | select(type == "!!map" and has("volsync")).volsync[]?.dest.enabled) = false
' "$VALUES_FILE"

# Remove NFS persistence entries
yq -i '
  .persistence? |= with_entries(select(.value.type? != "nfs")) |
  del(.persistence | select(. == {}))
' "$VALUES_FILE"

# Remove cnpg for ephemeral CI cluster
yq -i 'del(.cnpg)' "$VALUES_FILE" || true

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
  > "$RENDERED" 2>/dev/null

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
echo "     CNPG:        $install_cnpg"
echo "     VolSync:     $install_volsync"
echo "     Ingress:     $install_ingress"
echo "     CertManager: $install_certmanager"
echo "     Prometheus:  $install_prometheus"

# --------------------------------------------------
# Install dependencies
# --------------------------------------------------
print_section "🔧 Installing dependencies"

if $install_cnpg; then
  echo "::group::🗄 Installing CloudNativePG..."
  helm install cloudnative-pg oci://ghcr.io/cloudnative-pg/charts/cloudnative-pg --namespace cloudnative-pg --create-namespace --wait
  if [[ "$?" != "0" ]]; then
      echo "❌ Failed to install CloudNativePG"
      exit 1
  fi
  echo "🗄 Done installing CloudNativePG"
  echo "::endgroup::"
fi

if $install_volsync; then
  echo "::group::💾 Installing VolSync CRDs..."
  kubectl apply -f https://raw.githubusercontent.com/backube/volsync/main/config/crd/bases/volsync.backube_replicationsources.yaml
  kubectl apply -f https://raw.githubusercontent.com/backube/volsync/main/config/crd/bases/volsync.backube_replicationdestinations.yaml
  if [[ "$?" != "0" ]]; then
      echo "❌ Failed to install Volsync CRDs"
      exit 1
  fi
  echo "💾 Done installing Volsync CRDs"  
  echo "::endgroup::"
fi

if $install_ingress; then
  echo "::group::🌐 Installing ingress-nginx..."
  helm install ingress-nginx oci://ghcr.io/home-operations/charts-mirror/ingress-nginx --namespace ingress-nginx --create-namespace \
      --set controller.ingressClassResource.default=true --set controller.publishService.enabled=false --set controller.service.type="ClusterIP" --set controller.config.allow-snippet-annotations=true --set controller.config.annotations-risk-level="Critical" --wait
  if [[ "$?" != "0" ]]; then
      echo "❌ Failed to install ingress-nginx"
      exit 1
  fi
  echo "🌐 Done installing ingress-nginx"
  echo "::endgroup::"
fi

if $install_certmanager; then
  echo "::group::🔐 Installing cert-manager..."
  kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml
  kubectl wait deployment --all -n cert-manager --for=condition=Available --timeout=180s
  if [[ "$?" != "0" ]]; then
      echo "❌ Failed to install certmanager"
      exit 1
  fi
  echo "🔐 Done installing certmanager"
  echo "::endgroup::"
fi

if $install_prometheus; then
  echo "::group::📊 Installing Prometheus Operator CRDs..."

  kubectl apply -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/main/example/prometheus-operator-crd/monitoring.coreos.com_servicemonitors.yaml
  kubectl apply -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/main/example/prometheus-operator-crd/monitoring.coreos.com_podmonitors.yaml
  kubectl apply -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/main/example/prometheus-operator-crd/monitoring.coreos.com_prometheusrules.yaml
  if [[ "$?" != "0" ]]; then
      echo "❌ Failed to install Prometheus Operator CRDs"
      exit 1
  fi
  echo " 📊 Done installing Prometheus Operator CRDs"
  echo "::endgroup::"
fi

# --------------------------------------------------
# Environment substitution summary
# --------------------------------------------------
print_section "🧬 Values Manipulation for CI Testing"
print_sub_section "🔄 Environment Variable substitution"

replaced_count=$(wc -w <<< "$EXISTING_VARS")
missing_count=$(wc -w <<< "$MISSING_VARS")

if [[ "$replaced_count" -gt 0 ]]; then
  echo -e "${GREEN}      ✔ Replaced variables:${NC}"
  printf '        • %s\n' $EXISTING_VARS
else
  echo -e "${GREEN}      ✔ Replaced variables: none${NC}"
fi

if [[ "$missing_count" -gt 0 ]]; then
  echo -e "${YELLOW}      ⚠ Unresolved variables (kept as-is):${NC}"
  printf '        • %s\n' $MISSING_VARS
else
  echo -e "${GREEN}      ✔ No unresolved variables${NC}"
fi

# --------------------------------------------------
# Warning munipilated section
# --------------------------------------------------
print_sub_section "🔄 Changed Values by CI"
echo "      ⚠️ Volsync src and dest enabled set to false"
echo "      ⚠️ NFS persistence entries removed"
echo "      ⚠️ CNPG entries removed"

# --------------------------------------------------
# Value Dump for debugging
# --------------------------------------------------
print_sub_section "📄 Final values used for deploying"
echo "      ::group::🧩 Rendered Helm values (after CI patches):"
echo -e "${BOLD}${BLUE}📄 values.yaml (after CI patches)${NC}"
yq -P '.' "$VALUES_FILE"
echo " "
echo "::endgroup::"

# --------------------------------------------------
# CI Values file check
# --------------------------------------------------
HELM_VALUES_ARGS=(--values "$VALUES_FILE")

if [[ -f "$CI_VALUES_FILE" ]]; then
  echo "      ::group::🧪 Used CI values: $CI_VALUES_FILE"
  echo -e "${BOLD}${BLUE}📄 ci-values.yaml${NC}"
  yq -P '.' "$CI_VALUES_FILE"
  echo " "
  echo "::endgroup::"

  HELM_VALUES_ARGS+=(--values "$CI_VALUES_FILE")
fi

# --------------------------------------------------
# Deploy chart
# --------------------------------------------------
print_section "🚀 Deploying $RELEASE_NAME..."

set +e
helm upgrade --install "$RELEASE_NAME" "$CHART_REF" \
  --version "$CHART_VERSION" \
  --namespace "$NAMESPACE" \
  --create-namespace \
  "${HELM_VALUES_ARGS[@]}" \
  --wait \
  --timeout 5m
HELM_RC=$?
set -e

# --------------------------------------------------
# Debug info
# --------------------------------------------------
print_section "🐛 Debug info"
print_sub_section "📦 Pods:"
kubectl get pods -n "$NAMESPACE" -o wide || true

print_sub_section "📅 Events:"
kubectl get events -n "$NAMESPACE" --sort-by=.metadata.creationTimestamp || true

for pod in $(kubectl get pods -n "$NAMESPACE" -o name 2>/dev/null); do
  echo "==== Logs for $pod ===="
  kubectl logs -n "$NAMESPACE" "$pod" --all-containers --tail=200 || true
done

# --------------------------------------------------
# Exit result
# --------------------------------------------------
print_section "🏁 Result"
if [ "$HELM_RC" -ne 0 ]; then
  echo "❌ Deployment failed"
  exit "$HELM_RC"
fi

echo "✅ Deployment succeeded"

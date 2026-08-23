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
  echo -e "${BOLD}$(printf '═%.0s' {1..78})${NC}"
  echo -e "${BLUE}${BOLD}$2  $1  $2${NC}"
  echo -e "${BOLD}$(printf '═%.0s' {1..78})${NC}"
}

print_section() {
  echo " "
  echo -e "${BLUE}${BOLD}$1${NC}"
  echo -e "${DIM}$(printf '─%.0s' {1..78})${NC}"
}

print_sub_section() {
  echo -e "${BLUE}$1${NC}"
}

# --------------------------------------------------
# Dependency Functions
# --------------------------------------------------
resolve_dependency_chart() {
  local helmrelease_path="$1"
  local chart_name source_name source_file source_url

  if [[ ! -f "$helmrelease_path" ]]; then
    echo "❌ Dependency HelmRelease not found: $helmrelease_path"
    return 1
  fi

  if [[ "$(yq -r '.spec.chartRef.name // ""' "$helmrelease_path")" != "" ]]; then
    source_name="$(yq -r '.spec.chartRef.name' "$helmrelease_path")"
    source_file="repositories/oci/${source_name}.yaml"

    if [[ ! -f "$source_file" ]]; then
      echo "❌ Dependency OCIRepository not found: $source_file"
      return 1
    fi

    DEPENDENCY_CHART_REF="$(yq -r '.spec.url' "$source_file")"
    DEPENDENCY_CHART_VERSION="$(yq -r '.spec.ref.tag' "$source_file")"
  else
    chart_name="$(yq -r '.spec.chart.spec.chart // ""' "$helmrelease_path")"
    source_name="$(yq -r '.spec.chart.spec.sourceRef.name // ""' "$helmrelease_path")"
    DEPENDENCY_CHART_VERSION="$(yq -r '.spec.chart.spec.version // ""' "$helmrelease_path")"
    source_file="repositories/helm/${source_name}.yaml"

    if [[ -z "$chart_name" || -z "$source_name" || ! -f "$source_file" ]]; then
      echo "❌ Unable to resolve dependency chart from: $helmrelease_path"
      return 1
    fi

    source_url="$(yq -r '.spec.url' "$source_file")"
    if [[ "$source_url" == oci://* ]]; then
      DEPENDENCY_CHART_REF="${source_url}/${chart_name}"
    else
      helm repo add "$source_name" "$source_url" --force-update >/dev/null
      DEPENDENCY_CHART_REF="${source_name}/${chart_name}"
    fi
  fi

  if [[ -z "$DEPENDENCY_CHART_REF" || -z "$DEPENDENCY_CHART_VERSION" ]]; then
    echo "❌ Dependency chart reference or version is empty: $helmrelease_path"
    return 1
  fi
}

install_dependency_crds() {
  local dependency_name="$1"
  local dependency_icon="$2"
  local helmrelease_path="$3"
  local dependency_values rendered_crds crd_count

  resolve_dependency_chart "$helmrelease_path"
  dependency_values="$(mktemp)"
  rendered_crds="$(mktemp)"
  yq '.spec.values // {}' "$helmrelease_path" > "$dependency_values"

  echo "::group::${dependency_icon} Installing ${dependency_name} CRDs (${DEPENDENCY_CHART_VERSION})..."
  helm template "ci-${dependency_name}" "$DEPENDENCY_CHART_REF" \
    --version "$DEPENDENCY_CHART_VERSION" \
    --include-crds \
    --no-hooks \
    --values "$dependency_values" \
  | yq ea -r 'select(.kind == "CustomResourceDefinition")' \
  > "$rendered_crds"

  crd_count="$(grep -c '^kind: CustomResourceDefinition$' "$rendered_crds" || true)"
  if [[ "$crd_count" -eq 0 ]]; then
    echo "❌ No CRDs rendered for ${dependency_name}"
    return 1
  fi

  kubectl apply --server-side --force-conflicts --filename "$rendered_crds"
  kubectl wait \
    --for=condition=Established \
    --timeout=120s \
    --filename "$rendered_crds"
  echo "${dependency_icon} Installed ${crd_count} ${dependency_name} CRD(s)"
  echo "::endgroup::"
}

install_cnpg_operator() {
  local helmrelease_path="clusters/main/kubernetes/system/cloudnative-pg/app/helm-release.yaml"

  resolve_dependency_chart "$helmrelease_path"

  echo "::group::🗄️ Installing CloudNativePG operator (${DEPENDENCY_CHART_VERSION})..."
  helm install cloudnative-pg "$DEPENDENCY_CHART_REF" \
    --version "$DEPENDENCY_CHART_VERSION" \
    --namespace cloudnative-pg \
    --create-namespace \
    --set crds.create=true \
    --set monitoring.podMonitorEnabled=false \
    --set monitoring.grafanaDashboard.create=false \
    --wait \
    --timeout 5m
  echo "🗄️ Done installing CloudNativePG operator"
  echo "::endgroup::"
}

rendered_uses_api_group() {
  local api_group="$1"
  API_GROUP="$api_group" yq ea -e \
    'select((.apiVersion // "") | test("^" + strenv(API_GROUP) + "/"))' \
    "$RENDERED" >/dev/null 2>&1
}

# --------------------------------------------------
# Check Helmrelease Path
# --------------------------------------------------

if [[ -z "$HELMRELEASE_PATH" ]]; then
  echo "❌ No HelmRelease path provided"
  exit 1
fi

# --------------------------------------------------
# Check stopAll
# --------------------------------------------------
# STOP_ALL=$(yq '.spec.values.global.stopAll // "false"' "$HELMRELEASE_PATH")
# 
# if [[ "$STOP_ALL" == "true" ]]; then
#   echo -e "${YELLOW}⏭  ${BOLD}DEPLOYMENT SKIPPED  ⏭${NC}"
#   echo -e "${YELLOW}Reason:  global.stopAll=true${NC}"
#   exit 0
# fi

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
#CI_VALUES_FILE="$APP_DIR/ci/ci-values.yaml"
CI_VALUES_FILE="ci/$CHART_NAME.yaml"

# --------------------------------------------------
# Setup chart repository reference
# --------------------------------------------------
if [[ "$REPO_URL" == oci://* ]]; then
  CHART_REF="$REPO_URL/$CHART_NAME"
else
  helm repo add ci-repo "$REPO_URL" >/dev/null 2>&1 || true
  helm repo update >/dev/null 2>&1
  CHART_REF="ci-repo/$CHART_NAME"
fi

print_header "HelmRelease Deployment Test by Boemeltrein" "🚂"

print_section "⚙️ Processing: $HELMRELEASE_PATH"

echo "📦 Chart:         $CHART_NAME@$CHART_VERSION"
echo "🌍 Repository:    $REPO_URL"
echo "🏷️ Release Name:  $RELEASE_NAME"
echo "📂 Namespace:     $NAMESPACE"


# --------------------------------------------------
# Environment Variable substitution
# --------------------------------------------------
print_section "🧬 Values Manipulation for CI Testing"

print_sub_section "🔄 Environment Variable substitution"
RAW_VALUES="$(mktemp)"
VALUES_FILE="$(mktemp)"

# Extract values
yq '.spec.values // {}' "$HELMRELEASE_PATH" > "$RAW_VALUES"

# Extract ${VAR} placeholders from values YAML
VARS_IN_FILE="$(
  grep -o '\${[A-Za-z_][A-Za-z0-9_]*}' "$RAW_VALUES" | sort -u || true
)"

# Determine which vars exist and which are missing
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

# Substitute only existing variables, missing ones remain literal ${VAR}
envsubst "$EXISTING_VARS" < "$RAW_VALUES" > "$VALUES_FILE"

# Summary of substitutions for logging
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
# Change PVC and CNPG because of backup restore issues
# --------------------------------------------------
print_sub_section "🔄 CI value mutations"
changed=false

# Disable volsync
if yq -e '
  (.. | select(type == "!!map" and has("volsync")).volsync[]?.src.enabled == true) or
  (.. | select(type == "!!map" and has("volsync")).volsync[]?.dest.enabled == true)
' "$VALUES_FILE" >/dev/null 2>&1; then

  yq -i '
    (.. | select(type == "!!map" and has("volsync")).volsync[]?.src.enabled) = false |
    (.. | select(type == "!!map" and has("volsync")).volsync[]?.dest.enabled) = false
  ' "$VALUES_FILE"

  echo "      ⚠️ Volsync src/dest disabled for CI"
  changed=true
fi

# Remove NFS persistence entries
if yq -e '
  (.persistence? // {})
  | to_entries[]
  | select(.value.type? == "nfs")
' "$VALUES_FILE" >/dev/null 2>&1; then

  yq -i '
    .persistence |= with_entries(select(.value.type? != "nfs")) |
    del(.persistence | select(. == {}))
  ' "$VALUES_FILE"

  echo "      ⚠️ NFS persistence removed for CI"
  changed=true
fi

# Remove cnpg for ephemeral CI cluster
if yq -e 'has("cnpg")' "$VALUES_FILE" >/dev/null 2>&1; then
  yq -i 'del(.cnpg)' "$VALUES_FILE"
  echo "      ⚠️ CNPG removed for CI"
  changed=true
fi

# Force global.stopAll=false
if yq -e '.global.stopAll == true' "$VALUES_FILE" >/dev/null 2>&1; then
  yq -i '.global.stopAll = false' "$VALUES_FILE"
  echo "      ⚠️ global.stopAll forced to false"
  changed=true
fi

if [ "$changed" = false ]; then
  echo "      ℹ️ No CI mutations needed"
fi

# --------------------------------------------------
# Value Dump for debugging
# --------------------------------------------------
print_sub_section "📄 Final values used for deploying"
echo "::group::    🧩 Rendered Helm values:"
echo -e "${BOLD}${BLUE}📄 values.yaml (after CI patches)${NC}"
yq -P '.' "$VALUES_FILE"
echo " "
echo "::endgroup::"

# --------------------------------------------------
# CI Values file check
# --------------------------------------------------
HELM_VALUES_ARGS=(--values "$VALUES_FILE")

if [[ -f "$CI_VALUES_FILE" ]]; then
  echo "::group::    🧪 Used CI values:"
  echo -e "${BOLD}${BLUE}📄 $CI_VALUES_FILE${NC}"
  yq -P '.' "$CI_VALUES_FILE"
  echo " "
  echo "::endgroup::"

  HELM_VALUES_ARGS+=(--values "$CI_VALUES_FILE")
fi

# --------------------------------------------------
# Render manifests for dependency detection
# --------------------------------------------------
print_section "🔧 Installing dependencies"

RENDERED="$(mktemp)"

helm template "$RELEASE_NAME" "$CHART_REF" \
  --version "$CHART_VERSION" \
  --namespace "$NAMESPACE" \
  "${HELM_VALUES_ARGS[@]}" \
  > "$RENDERED" 2>/dev/null

# --------------------------------------------------
# Detect dependencies
# --------------------------------------------------
install_cnpg=false
install_certmanager=false
install_prometheus=false
install_metallb=false
install_gateway=false
install_grafana=false
install_nfd=false

rendered_uses_api_group "postgresql.cnpg.io" && install_cnpg=true
rendered_uses_api_group "cert-manager.io" && install_certmanager=true
rendered_uses_api_group "monitoring.coreos.com" && install_prometheus=true
rendered_uses_api_group "metallb.io" && install_metallb=true
rendered_uses_api_group "gateway.networking.k8s.io" && install_gateway=true
rendered_uses_api_group "grafana.integreatly.org" && install_grafana=true
rendered_uses_api_group "nfd.k8s-sigs.io" && install_nfd=true

echo "🔎 Dependencies:"
echo "     CNPG:        $install_cnpg"
echo "     CertManager: $install_certmanager"
echo "     Prometheus:  $install_prometheus"
echo "     MetalLB:     $install_metallb"
echo "     Gateway API: $install_gateway"
echo "     Grafana:     $install_grafana"
echo "     NFD:         $install_nfd"

# --------------------------------------------------
# Install dependencies
# --------------------------------------------------

if $install_cnpg; then
  install_cnpg_operator
fi

if $install_certmanager; then
  install_dependency_crds \
    "cert-manager" \
    "🔐" \
    "clusters/main/kubernetes/system/cert-manager/app/helm-release.yaml"
fi

if $install_prometheus; then
  install_dependency_crds \
    "kube-prometheus-stack" \
    "📊" \
    "clusters/main/kubernetes/observability/kube-prometheus-stack/app/helm-release.yaml"
fi

if $install_metallb; then
  install_dependency_crds \
    "metallb" \
    "📡" \
    "clusters/main/kubernetes/system/metallb/app/helm-release.yaml"
fi

if $install_gateway; then
  install_dependency_crds \
    "envoy-gateway" \
    "🌉" \
    "clusters/main/kubernetes/networking/envoy-gateway/app/helm-release.yaml"
fi

if $install_grafana; then
  install_dependency_crds \
    "grafana-operator" \
    "📈" \
    "clusters/main/kubernetes/observability/grafana-operator/app/helm-release.yaml"
fi

if $install_nfd; then
  install_dependency_crds \
    "node-feature-discovery" \
    "🖥️" \
    "clusters/main/kubernetes/kube-system/node-feature-discovery/app/helm-release.yaml"
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
  --skip-crds \
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
  print_sub_section "📜 Logs for $pod:"
  kubectl logs -n "$NAMESPACE" "$pod" --all-containers --tail=200 || true
done

# --------------------------------------------------
# Exit result
# --------------------------------------------------
print_section "🎯 Result"
if [ "$HELM_RC" -ne 0 ]; then
  echo "❌ Deployment failed"
  exit "$HELM_RC"
fi

echo "✅ Deployment succeeded"

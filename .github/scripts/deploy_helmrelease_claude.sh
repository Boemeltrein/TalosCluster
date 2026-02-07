#!/usr/bin/env bash
set -euo pipefail

HELMRELEASE_PATH="${1:-}"

# --------------------------------------------------
# Colors & Formatting
# --------------------------------------------------
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# --------------------------------------------------
# Logging Functions
# --------------------------------------------------
print_header() {
  local title="$1"
  local emoji="$2"
  local width=80
  local display_title="$emoji $title"
  local title_len=${#display_title}
  local padding=$(( (width - title_len - 2) / 2 ))
  
  echo
  echo -e "${BOLD}${BLUE}╔$(printf '═%.0s' $(seq 1 $((width-2))))╗${NC}"
  printf "${BOLD}${BLUE}║${NC}%*s${BOLD}${CYAN}%s${NC}%*s${BOLD}${BLUE}║${NC}\n" \
    $padding "" "$display_title" $((width - padding - title_len - 2)) ""
  echo -e "${BOLD}${BLUE}╚$(printf '═%.0s' $(seq 1 $((width-2))))╝${NC}"
  echo
}

print_section() {
  echo
  echo -e "${BOLD}${MAGENTA}▶${NC} ${BOLD}$1${NC}"
  echo -e "${DIM}$(printf '─%.0s' $(seq 1 78))${NC}"
}

print_info() {
  echo -e "  ${BLUE}ℹ${NC}  $1"
}

print_success() {
  echo -e "  ${GREEN}✔${NC}  $1"
}

print_warning() {
  echo -e "  ${YELLOW}⚠${NC}  $1"
}

print_error() {
  echo -e "  ${RED}✖${NC}  $1"
}

print_step() {
  echo -e "${CYAN}➜${NC} $1"
}

print_key_value() {
  local key="$1"
  local value="$2"
  printf "  ${DIM}%-20s${NC} ${BOLD}%s${NC}\n" "$key:" "$value"
}

# --------------------------------------------------
# Check Helmrelease Path
# --------------------------------------------------
if [[ -z "$HELMRELEASE_PATH" ]]; then
  print_error "No HelmRelease path provided"
  exit 1
fi

print_header "HelmRelease Deployment Test" "🚀"
print_info "Processing: ${BOLD}$HELMRELEASE_PATH${NC}"

# --------------------------------------------------
# Check stopAll
# --------------------------------------------------
STOP_ALL=$(yq '.spec.values.global.stopAll // "false"' "$HELMRELEASE_PATH")

if [[ "$STOP_ALL" == "true" ]]; then
  echo
  echo -e "${YELLOW}╔════════════════════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${YELLOW}║                         ⏭️  DEPLOYMENT SKIPPED ⏭️                            ║${NC}"
  echo -e "${YELLOW}╠════════════════════════════════════════════════════════════════════════════╣${NC}"
  echo -e "${YELLOW}║${NC}  Release: ${BOLD}$HELMRELEASE_PATH${NC}"
  echo -e "${YELLOW}║${NC}  Reason:  ${BOLD}global.stopAll=true${NC}"
  echo -e "${YELLOW}╚════════════════════════════════════════════════════════════════════════════╝${NC}"
  echo
  exit 0
fi

# --------------------------------------------------
# Extract HelmRelease metadata
# --------------------------------------------------
print_section "📋 Release Configuration"

RELEASE_NAME="$(yq '.metadata.name' "$HELMRELEASE_PATH")"
NAMESPACE="$(yq '.metadata.namespace' "$HELMRELEASE_PATH")"
CHART_NAME="$(yq '.spec.chart.spec.chart' "$HELMRELEASE_PATH")"
CHART_VERSION="$(yq '.spec.chart.spec.version' "$HELMRELEASE_PATH")"
REPO_NAME="$(yq '.spec.chart.spec.sourceRef.name' "$HELMRELEASE_PATH")"
REPO_FILE="repositories/helm/${REPO_NAME}.yaml"
REPO_URL="$(yq '.spec.url' "$REPO_FILE")"
APP_DIR="$(dirname "$HELMRELEASE_PATH")"
CI_VALUES_FILE="$APP_DIR/ci/ci-values.yaml"

print_key_value "Release Name" "$RELEASE_NAME"
print_key_value "Namespace" "$NAMESPACE"
print_key_value "Chart" "$CHART_NAME"
print_key_value "Version" "$CHART_VERSION"
print_key_value "Repository" "$REPO_URL"

# --------------------------------------------------
# Prepare values
# --------------------------------------------------
print_section "🔧 Processing Values"

RAW_VALUES="$(mktemp)"
VALUES_FILE="$(mktemp)"

yq '.spec.values // {}' "$HELMRELEASE_PATH" > "$RAW_VALUES"

# --------------------------------------------------
# Extract ${VAR} placeholders from values YAML
# --------------------------------------------------
VARS_IN_FILE="$(
  grep -o '\${[A-Za-z_][A-Za-z0-9_]*}' "$RAW_VALUES" | sort -u
)"

EXISTING_VARS=""
MISSING_VARS=""

while IFS= read -r var; do
  name="${var:2:-1}"
  if printenv "$name" >/dev/null 2>&1; then
    EXISTING_VARS+="${var} "
  else
    MISSING_VARS+="${var} "
  fi
done <<< "$VARS_IN_FILE"

envsubst "$EXISTING_VARS" < "$RAW_VALUES" > "$VALUES_FILE"

# --------------------------------------------------
# Environment substitution summary
# --------------------------------------------------
replaced_count=$(wc -w <<< "$EXISTING_VARS")
missing_count=$(wc -w <<< "$MISSING_VARS")

echo
if [[ "$replaced_count" -gt 0 ]]; then
  print_success "Substituted ${BOLD}${replaced_count}${NC} environment variable(s) 🔄"
  for var in $EXISTING_VARS; do
    echo -e "    ${DIM}•${NC} $var"
  done
else
  print_info "No environment variables to substitute ✨"
fi

if [[ "$missing_count" -gt 0 ]]; then
  echo
  print_warning "Unresolved ${BOLD}${missing_count}${NC} variable(s) (kept as-is) ⚠️"
  for var in $MISSING_VARS; do
    echo -e "    ${DIM}•${NC} $var"
  done
fi

# --------------------------------------------------
# Change PVC and CNPG because of backup restore issues
# --------------------------------------------------
print_step "Applying CI-specific patches... 🔧"

yq -i '
  (.. | select(type == "!!map" and has("volsync")).volsync[]?.src.enabled) = false |
  (.. | select(type == "!!map" and has("volsync")).volsync[]?.dest.enabled) = false
' "$VALUES_FILE"

yq -i '
  .persistence? |= with_entries(select(.value.type? != "nfs")) |
  del(.persistence | select(. == {}))
' "$VALUES_FILE"

yq -i 'del(.cnpg)' "$VALUES_FILE" || true

print_success "CI patches applied (disabled: volsync, NFS, CNPG backups) ✅"

# --------------------------------------------------
# Value Dump for debugging
# --------------------------------------------------
echo "::group::Rendered Helm values"
echo
print_section "📄 Rendered Values (after CI patches)"
echo
yq -P '.' "$VALUES_FILE"
echo
echo "::endgroup::"

# --------------------------------------------------
# Setup chart reference
# --------------------------------------------------
if [[ "$REPO_URL" == oci://* ]]; then
  CHART_REF="$REPO_URL/$CHART_NAME"
else
  print_step "Adding Helm repository... 📚"
  helm repo add ci-repo "$REPO_URL" >/dev/null 2>&1 || true
  helm repo update >/dev/null 2>&1
  CHART_REF="ci-repo/$CHART_NAME"
  print_success "Repository configured ✅"
fi

# --------------------------------------------------
# Render manifests for dependency detection
# --------------------------------------------------
print_section "🔍 Dependency Detection"

RENDERED="$(mktemp)"

print_step "Rendering chart templates... 📝"
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

echo
print_info "Required dependencies:"
echo
print_key_value "  🗄️  CloudNativePG" "$($install_cnpg && echo "${GREEN}yes${NC}" || echo "${DIM}no${NC}")"
print_key_value "  💾 VolSync" "$($install_volsync && echo "${GREEN}yes${NC}" || echo "${DIM}no${NC}")"
print_key_value "  🌐 Ingress-NGINX" "$($install_ingress && echo "${GREEN}yes${NC}" || echo "${DIM}no${NC}")"
print_key_value "  🔐 Cert-Manager" "$($install_certmanager && echo "${GREEN}yes${NC}" || echo "${DIM}no${NC}")"
print_key_value "  📊 Prometheus CRDs" "$($install_prometheus && echo "${GREEN}yes${NC}" || echo "${DIM}no${NC}")"

# --------------------------------------------------
# Install dependencies
# --------------------------------------------------
print_section "📦 Installing Dependencies"
echo "::group::🔧 Installing dependencies"

if $install_cnpg; then
  print_step "Installing CloudNativePG... 🗄️"
  if helm install cloudnative-pg oci://ghcr.io/cloudnative-pg/charts/cloudnative-pg \
      --namespace cloudnative-pg --create-namespace --wait >/dev/null 2>&1; then
    print_success "CloudNativePG installed ✅"
  else
    print_error "Failed to install CloudNativePG ❌"
    exit 1
  fi
fi

if $install_volsync; then
  print_step "Installing VolSync CRDs... 💾"
  if kubectl apply -f https://raw.githubusercontent.com/backube/volsync/main/config/crd/bases/volsync.backube_replicationsources.yaml >/dev/null 2>&1 && \
     kubectl apply -f https://raw.githubusercontent.com/backube/volsync/main/config/crd/bases/volsync.backube_replicationdestinations.yaml >/dev/null 2>&1; then
    print_success "VolSync CRDs installed ✅"
  else
    print_error "Failed to install VolSync CRDs ❌"
    exit 1
  fi
fi

if $install_ingress; then
  print_step "Installing ingress-nginx... 🌐"
  if helm install ingress-nginx oci://ghcr.io/home-operations/charts-mirror/ingress-nginx \
      --namespace ingress-nginx --create-namespace \
      --set controller.ingressClassResource.default=true \
      --set controller.publishService.enabled=false \
      --set controller.service.type="ClusterIP" \
      --set controller.config.allow-snippet-annotations=true \
      --set controller.config.annotations-risk-level="Critical" \
      --wait >/dev/null 2>&1; then
    print_success "Ingress-NGINX installed ✅"
  else
    print_error "Failed to install ingress-nginx ❌"
    exit 1
  fi
fi

if $install_certmanager; then
  print_step "Installing cert-manager... 🔐"
  if kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml >/dev/null 2>&1 && \
     kubectl wait deployment --all -n cert-manager --for=condition=Available --timeout=180s >/dev/null 2>&1; then
    print_success "Cert-Manager installed ✅"
  else
    print_error "Failed to install cert-manager ❌"
    exit 1
  fi
fi

if $install_prometheus; then
  print_step "Installing Prometheus Operator CRDs... 📊"
  if kubectl apply -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/main/example/prometheus-operator-crd/monitoring.coreos.com_servicemonitors.yaml >/dev/null 2>&1 && \
     kubectl apply -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/main/example/prometheus-operator-crd/monitoring.coreos.com_podmonitors.yaml >/dev/null 2>&1 && \
     kubectl apply -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/main/example/prometheus-operator-crd/monitoring.coreos.com_prometheusrules.yaml >/dev/null 2>&1; then
    print_success "Prometheus Operator CRDs installed ✅"
  else
    print_error "Failed to install Prometheus Operator CRDs ❌"
    exit 1
  fi
fi

if ! $install_cnpg && ! $install_volsync && ! $install_ingress && ! $install_certmanager && ! $install_prometheus; then
  print_info "No additional dependencies required 🎉"
fi

echo "::endgroup::"

# --------------------------------------------------
# Deploy chart
# --------------------------------------------------
print_section "🚀 Helm Deployment"

HELM_VALUES_ARGS=(--values "$VALUES_FILE")

if [[ -f "$CI_VALUES_FILE" ]]; then
  print_info "Using additional CI values: ${BOLD}$CI_VALUES_FILE${NC} 🧪"
  HELM_VALUES_ARGS+=(--values "$CI_VALUES_FILE")
fi

echo
print_step "Deploying ${BOLD}$RELEASE_NAME${NC} to namespace ${BOLD}$NAMESPACE${NC}..."

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

echo

# --------------------------------------------------
# Debug info
# --------------------------------------------------
if [ "$HELM_RC" -ne 0 ]; then
  print_section "🔍 Debugging Information"
  
  echo
  print_step "Pod Status: 🐳"
  kubectl get pods -n "$NAMESPACE" -o wide 2>/dev/null || print_warning "No pods found"
  
  echo
  print_step "Recent Events: 📅"
  kubectl get events -n "$NAMESPACE" --sort-by=.metadata.creationTimestamp 2>/dev/null || print_warning "No events found"
  
  echo
  print_step "Pod Logs: 📋"
  for pod in $(kubectl get pods -n "$NAMESPACE" -o name 2>/dev/null); do
    echo
    echo -e "${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}Logs for:${NC} ${BOLD}$pod${NC}"
    echo -e "${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    kubectl logs -n "$NAMESPACE" "$pod" --all-containers --tail=400 2>/dev/null || print_warning "Could not retrieve logs"
  done
fi

# --------------------------------------------------
# Exit result
# --------------------------------------------------
echo
echo -e "${DIM}$(printf '═%.0s' $(seq 1 80))${NC}"

if [ "$HELM_RC" -ne 0 ]; then
  echo
  echo -e "${RED}╔════════════════════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${RED}║                        ❌ DEPLOYMENT FAILED ❌                              ║${NC}"
  echo -e "${RED}╠════════════════════════════════════════════════════════════════════════════╣${NC}"
  echo -e "${RED}║${NC}  Release:   ${BOLD}$RELEASE_NAME${NC}"
  echo -e "${RED}║${NC}  Namespace: ${BOLD}$NAMESPACE${NC}"
  echo -e "${RED}║${NC}  Exit Code: ${BOLD}$HELM_RC${NC}"
  echo -e "${RED}╚════════════════════════════════════════════════════════════════════════════╝${NC}"
  echo
  exit "$HELM_RC"
fi

echo
echo -e "${GREEN}╔════════════════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║                      ✅ DEPLOYMENT SUCCESSFUL ✅                            ║${NC}"
echo -e "${GREEN}╠════════════════════════════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║${NC}  Release:   ${BOLD}$RELEASE_NAME${NC}"
echo -e "${GREEN}║${NC}  Namespace: ${BOLD}$NAMESPACE${NC}"
echo -e "${GREEN}║${NC}  Chart:     ${BOLD}$CHART_NAME@$CHART_VERSION${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════════════════════════════╝${NC}"
echo

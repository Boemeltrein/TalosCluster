#!/usr/bin/env bash
set -o errexit
set -o pipefail

KUBERNETES_DIR=${1:-}
FLUX_ENTRY_FILE=${FLUX_ENTRY_FILE:-./clusters/main/flux-entry/ks.yaml}

[[ -z "${KUBERNETES_DIR}" ]] && echo "Kubernetes location not specified" && exit 1

kustomize_args=("--load-restrictor=LoadRestrictionsNone")
kustomize_config="kustomization.yaml"
kubeconform_args=(
    "-strict"
    "-ignore-missing-schemas"
    "-skip"
    "Secret,ConfigMap,tuppr.home-operations.com/v1alpha1/TalosUpgrade,tuppr.home-operations.com/v1alpha1/KubernetesUpgrade"
    "-schema-location"
    "default"
    "-schema-location"
    "https://k8s-schemas.home-operations.com/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json"
    "-verbose"
)

# App builds do not inherit the patches injected by their parent Flux Kustomization.
# Read the shared HelmRelease patches from flux-entry so CI validates the effective specs.
validation_dir="$(mktemp -d)"
trap 'rm -rf "${validation_dir}"' EXIT

cat > "${validation_dir}/kustomization.yaml" <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - resources.yaml
EOF

yq eval-all '
  [select(.kind == "Kustomization" and .metadata.name == "flux-entry")] | .[0] |
  {"patches": [
    .spec.patches[].patch | from_yaml | .spec.patches[] |
    select(.target.group == "helm.toolkit.fluxcd.io" and .target.kind == "HelmRelease")
  ]}
' "${FLUX_ENTRY_FILE}" >> "${validation_dir}/kustomization.yaml"

validate_rendered_manifests() {
    cat > "${validation_dir}/resources.yaml"
    kustomize build "${validation_dir}" | kubeconform "${kubeconform_args[@]}"
}

echo "=== Validating standalone manifests in ${KUBERNETES_DIR} ==="
find "${KUBERNETES_DIR}" -maxdepth 1 -type f -name '*.yaml' -print0 | while IFS= read -r -d $'\0' file;
do
    kubeconform "${kubeconform_args[@]}" "${file}"
    if [[ ${PIPESTATUS[0]} != 0 ]]; then
        exit 1
    fi
done

echo "=== Validating kustomizations in ${KUBERNETES_DIR}/ ==="
find "${KUBERNETES_DIR}" -type f -name $kustomize_config -print0 | while IFS= read -r -d $'\0' file;
do
    echo "=== Validating kustomizations in ${file/%$kustomize_config} ==="
    kustomize build "${file/%$kustomize_config}" "${kustomize_args[@]}" | validate_rendered_manifests
    if [[ ${PIPESTATUS[0]} != 0 ]]; then
        exit 1
    fi
done
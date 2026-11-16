#!/usr/bin/env bash
set -o errexit
set -o pipefail

KUBERNETES_DIR=$1

[[ -z "${KUBERNETES_DIR}" ]] && echo "Kubernetes location not specified" && exit 1

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
ci_config="${repo_root}/ci/.config.yaml"

# Substitute only the approved CI values; preserve all other placeholders.
for ci_variable in DOMAIN PODNET; do
    if ! ci_value="$(yq -er ".dummyEnv.${ci_variable} | select(tag == \"!!str\" and length > 0)" "${ci_config}")"; then
        echo "Invalid or missing dummyEnv.${ci_variable} in ${ci_config}: expected a non-empty string." >&2
        exit 1
    fi
    export "${ci_variable}=${ci_value}"
done

kustomize_args=("--load-restrictor=LoadRestrictionsNone")
kustomize_config="kustomization.yaml"
kubeconform_args=(
    "-strict"
    "-ignore-missing-schemas"
    "-skip"
    "Secret,ConfigMap"
    "-schema-location"
    "default"
    "-schema-location"
    "https://k8s-schemas.home-operations.com/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json"
    "-verbose"
)

echo "=== Validating standalone manifests in ${KUBERNETES_DIR} ==="
find "${KUBERNETES_DIR}" -maxdepth 1 -type f -name '*.yaml' -print0 | while IFS= read -r -d $'\0' file;
do
    envsubst '${DOMAIN} ${PODNET}' < "${file}" | kubeconform "${kubeconform_args[@]}"
    if [[ ${PIPESTATUS[0]} != 0 ]]; then
        exit 1
    fi
done

echo "=== Validating kustomizations in ${KUBERNETES_DIR}/ ==="
find "${KUBERNETES_DIR}" -type f -name $kustomize_config -print0 | while IFS= read -r -d $'\0' file;
do
    echo "=== Validating kustomizations in ${file/%$kustomize_config} ==="
    kustomize build "${file/%$kustomize_config}" "${kustomize_args[@]}" \
        | envsubst '${DOMAIN} ${PODNET}' \
        | kubeconform "${kubeconform_args[@]}"
    if [[ ${PIPESTATUS[0]} != 0 ]]; then
        exit 1
    fi
done

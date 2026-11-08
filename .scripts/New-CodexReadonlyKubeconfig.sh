(
set -euo pipefail
umask 077

# Set the context with permission to issue service account tokens.
ADMIN_CONTEXT='admin@boemelcluster'
OUTPUT_DIR="$(mktemp -d "$HOME/codex-readonly.XXXXXX")"

# Verify that GitOps has recreated the service account.
kubectl --context="$ADMIN_CONTEXT" \
  -n codex get serviceaccount codex-readonly

# Request a token valid for 365 days.
kubectl --context="$ADMIN_CONTEXT" \
  -n codex create token codex-readonly \
  --duration=8760h -o json |
  cat > "$OUTPUT_DIR/token.json"

# Build a portable kubeconfig containing only the service account credentials.
kubectl --context="$ADMIN_CONTEXT" config view \
  --minify --flatten --raw -o json |
  jq --slurpfile token "$OUTPUT_DIR/token.json" '{
    apiVersion: "v1",
    kind: "Config",
    clusters: .clusters,
    users: [{
      name: "codex-readonly",
      user: {token: $token[0].status.token}
    }],
    contexts: [{
      name: "codex-readonly",
      context: {
        cluster: .clusters[0].name,
        user: "codex-readonly",
        namespace: "codex"
      }
    }],
    "current-context": "codex-readonly"
  }' > "$OUTPUT_DIR/kubeconfig"

# Convert the kubeconfig to YAML while preserving credentials.
kubectl --kubeconfig="$OUTPUT_DIR/kubeconfig" \
  config view --raw -o yaml |
  cat > "$OUTPUT_DIR/kubeconfig.yaml"

mv -- "$OUTPUT_DIR/kubeconfig.yaml" "$OUTPUT_DIR/kubeconfig"

jq -r '"Token geldig tot: \(.status.expirationTimestamp)"' \
  "$OUTPUT_DIR/token.json"
rm -- "$OUTPUT_DIR/token.json"

# Verify permission to list pods across all namespaces.
kubectl --kubeconfig="$OUTPUT_DIR/kubeconfig" \
  --request-timeout=10s auth can-i list pods --all-namespaces

printf '\nNieuwe kubeconfig: %s/kubeconfig\n' "$OUTPUT_DIR"
)
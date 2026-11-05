# Historical cluster logs

`Get-ClusterLogs.ps1` reads Loki through the Kubernetes API using PowerShell 7+
and `kubectl`. It works for any namespace and for deleted Pods whose logs were
collected by Alloy and are still retained by Loki (currently 14 days).

The script runs locally. It uses the existing kubeconfig and explicitly selects
the `codex-readonly` context by default; `-Context` can select another configured
context. No additional credentials are needed.

## Usage

```powershell
# Inspect a request without invoking kubectl or contacting the cluster.
./scripts/Get-ClusterLogs.ps1 -Namespace home-assistant -Since 2h -Preview

# Read logs from a namespace.
./scripts/Get-ClusterLogs.ps1 -Namespace home-assistant -Since 2h

# Read one container and filter its log text literally.
./scripts/Get-ClusterLogs.ps1 -Namespace flux-system -Container helm-controller -Contains metallb -Since 24h

# Match Pod names with a Loki regular expression.
./scripts/Get-ClusterLogs.ps1 -Namespace metallb -PodPattern 'metallb-frr-k8s-statuscleaner-.*' -Since 24h

# Query a fixed time window with an explicit timezone offset.
./scripts/Get-ClusterLogs.ps1 -Namespace metallb -Start '2026-11-05T00:00:00+01:00' -End '2026-11-05T00:25:00+01:00' -Json

# Searching all namespaces requires an explicit switch.
./scripts/Get-ClusterLogs.ps1 -AllNamespaces -Since 15m -Limit 100 -Json
```

`-Pod` matches an exact name; `-PodPattern` uses Loki's regular-expression syntax.
`-Since` accepts a positive integer followed by `s`, `m`, `h`, or `d` and defaults
to `1h`. Absolute timestamps must include `Z` or an offset, such as `+01:00`.
The end of a Loki query range is exclusive. Output times are UTC.

The script returns PowerShell objects containing the timestamp, namespace, Pod,
container and full log line. `-Json` returns a JSON array, including `[]` when no
logs match. The default limit is 500 lines, with a maximum of 5000. It retrieves
the newest matching lines and sorts that selection chronologically; a warning
indicates a potentially truncated result. Narrow the window for larger searches.

Project rules requiring explicit permission before `kubectl` also apply when
Codex runs this script. `-Preview` is offline and does not run `kubectl`.
Keep log exports local; logs may contain sensitive application data.

## Access and deployment

The `codex-loki-reader` Role and RoleBinding in the Codex app grant the existing
`codex/codex-readonly` ServiceAccount only `get` on `services/proxy`, for the exact
resource name `http:grafana-loki:3100` in namespace `grafana-loki`.

The namespace in that Role identifies the Loki service, not the namespaces whose
logs can be read. All logs stored in this Loki instance are accessible. RBAC
restricts the service and HTTP verb, not Loki URL paths or LogQL label selectors.
The helper itself uses only the fixed `query_range` endpoint. The grant does not
add port-forward, exec, write, or Secret-reading permissions.

After the user merges the Draft PR and Flux applies the RBAC, test a small query
against a namespace with known logs. A Forbidden response means the Role is not
yet applied or the selected context uses another identity. Empty results can
mean the labels/time range do not match or the logs were never collected; a Pod
that never started may have no container logs.

## Offline validation

```powershell
pwsh -NoProfile -File ./scripts/tests/Get-ClusterLogs.Tests.ps1
```

The tests replace `kubectl` with a local mock, covering request boundaries,
escaping, time conversion, response handling and failures without cluster access.

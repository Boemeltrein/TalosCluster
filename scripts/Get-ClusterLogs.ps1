#Requires -Version 7.0
<#
.SYNOPSIS
Reads historical cluster logs from Loki using the existing Kubernetes credentials.
.DESCRIPTION
Select a namespace or explicitly use -AllNamespaces. Filters are optional and
combine with AND. The request uses only GET on the fixed Loki service proxy.
Project instructions requiring permission for kubectl also apply to this script.
Use -Preview to inspect the request without running kubectl or contacting the cluster.
.EXAMPLE
./scripts/Get-ClusterLogs.ps1 -Namespace home-assistant -Since 2h
.EXAMPLE
./scripts/Get-ClusterLogs.ps1 -Namespace flux-system -Container helm-controller -Contains metallb -Since 24h
.EXAMPLE
./scripts/Get-ClusterLogs.ps1 -AllNamespaces -Since 15m -Limit 100 -Preview
.EXAMPLE
./scripts/Get-ClusterLogs.ps1 -Namespace metallb -PodPattern 'metallb-frr-k8s-statuscleaner-.*' -Start '2026-11-05T00:00:00+01:00' -End '2026-11-05T00:25:00+01:00' -Json
#>
[CmdletBinding(DefaultParameterSetName = 'Relative')]
param(
    [ValidatePattern('^[a-z0-9]([-a-z0-9]*[a-z0-9])?$')]
    [string]$Namespace,

    [switch]$AllNamespaces,

    [string]$Pod,
    [string]$PodPattern,
    [string]$Container,
    [string]$Contains,

    [Parameter(ParameterSetName = 'Relative')]
    [ValidatePattern('^[1-9][0-9]*[smhd]$')]
    [string]$Since = '1h',

    [Parameter(Mandatory, ParameterSetName = 'Absolute')]
    [string]$Start,

    [Parameter(Mandatory, ParameterSetName = 'Absolute')]
    [string]$End,

    [ValidateRange(1, 5000)]
    [int]$Limit = 500,

    [ValidateNotNullOrEmpty()]
    [string]$Context = 'codex-readonly',

    [switch]$Preview,
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

if ([bool]$Namespace -eq [bool]$AllNamespaces) {
    throw 'Specify either -Namespace or -AllNamespaces.'
}
if ($Pod -and $PodPattern) {
    throw 'Specify either -Pod (exact name) or -PodPattern (Loki regular expression).'
}

function ConvertTo-UtcInstant([string]$Value) {
    # Require an explicit offset so Windows locale and timezone cannot shift the query.
    if ($Value -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,7})?(?:Z|[+-]\d{2}:\d{2})$') {
        throw 'Use an ISO 8601 timestamp with Z or an offset, such as 2026-11-05T00:00:00+01:00.'
    }
    return [DateTimeOffset]::Parse(
        $Value, [Globalization.CultureInfo]::InvariantCulture
    ).ToUniversalTime()
}

if ($PSCmdlet.ParameterSetName -eq 'Absolute') {
    $startUtc = ConvertTo-UtcInstant $Start
    $endUtc = ConvertTo-UtcInstant $End
}
else {
    $endUtc = [DateTimeOffset]::UtcNow
    $units = @{ s = 1; m = 60; h = 3600; d = 86400 }
    $seconds = [double]$Since.Substring(0, $Since.Length - 1) * $units[$Since.Substring($Since.Length - 1)]
    $startUtc = $endUtc.AddSeconds(-$seconds)
}
if ($startUtc -ge $endUtc) {
    throw '-Start must be earlier than -End.'
}

# JSON string escaping is also valid for quoted LogQL strings.
$matchers = [Collections.Generic.List[string]]::new()
if ($AllNamespaces) {
    $matchers.Add('namespace=~".+"')
}
else {
    $matchers.Add('namespace=' + (ConvertTo-Json -InputObject $Namespace -Compress))
}
if ($Pod) {
    $matchers.Add('pod=' + (ConvertTo-Json -InputObject $Pod -Compress))
}
if ($PodPattern) {
    $matchers.Add('pod=~' + (ConvertTo-Json -InputObject $PodPattern -Compress))
}
if ($Container) {
    $matchers.Add('container=' + (ConvertTo-Json -InputObject $Container -Compress))
}
$logQuery = '{' + ($matchers -join ',') + '}'
if ($Contains) {
    $logQuery += ' |= ' + (ConvertTo-Json -InputObject $Contains -Compress)
}

$queryParameters = [ordered]@{
    query = $logQuery
    start = $startUtc.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    end = $endUtc.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    limit = [string]$Limit
    direction = 'backward'
}
$encodedParameters = foreach ($entry in $queryParameters.GetEnumerator()) {
    $entry.Key + '=' + [Uri]::EscapeDataString($entry.Value)
}
$requestPath = '/api/v1/namespaces/grafana-loki/services/http:grafana-loki:3100/proxy/loki/api/v1/query_range?' + ($encodedParameters -join '&')

if ($Preview) {
    [pscustomobject]@{
        Context = $Context
        Method = 'GET'
        LogQL = $logQuery
        StartUtc = $startUtc.ToString('o')
        EndUtc = $endUtc.ToString('o')
        Limit = $Limit
        Path = $requestPath
    }
    return
}

# Pass an argument array to avoid shell interpolation of labels and log text.
$kubectlArguments = @('--context', $Context, '--request-timeout=60s', 'get', '--raw', $requestPath)
$responseLines = @(& kubectl @kubectlArguments 2>&1)
if ($LASTEXITCODE -ne 0) {
    throw "Loki query failed (kubectl exit code $LASTEXITCODE): $($responseLines -join [Environment]::NewLine)"
}
$response = ($responseLines -join [Environment]::NewLine) | ConvertFrom-Json -AsHashtable
if ($response.status -ne 'success' -or $response.data.resultType -ne 'streams') {
    throw 'Loki did not return a successful log-stream response.'
}

$rows = @(
    foreach ($stream in $response.data.result) {
        foreach ($entry in $stream.values) {
            # Preserve the exact nanosecond timestamp alongside the display time.
            $ticks = [long]([System.Numerics.BigInteger]::Parse($entry[0]) / 100)
            [pscustomobject]@{
                TimeUtc = [DateTimeOffset]::UnixEpoch.AddTicks($ticks).ToString('o')
                Namespace = $stream.stream['namespace']
                Pod = $stream.stream['pod']
                Container = $stream.stream['container']
                Line = $entry[1]
                TimestampNs = $entry[0]
            }
        }
    }
)
# Loki returns the newest matching entries; present that selection chronologically.
$rows = @($rows | Sort-Object { [decimal]$_.TimestampNs })
if ($rows.Count -ge $Limit) {
    Write-Warning "The $Limit-line limit was reached. Older matching lines may be omitted; narrow the time range or raise -Limit (maximum 5000)."
}
if ($Json) {
    ConvertTo-Json -InputObject $rows -Depth 5
}
else {
    $rows
}

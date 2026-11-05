#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
$reader = Join-Path $PSScriptRoot '../Get-ClusterLogs.ps1'
$script:passed = 0
$global:ClusterLogsTestState = @{}
$global:ClusterLogsTestState.Calls = [Collections.Generic.List[object]]::new()
$global:ClusterLogsTestState.ExitCode = 0
$global:ClusterLogsTestState.Response = '{"status":"success","data":{"resultType":"streams","result":[]}}'

# This function shadows the executable. Tests never contact Kubernetes.
function kubectl {
    $global:ClusterLogsTestState.Calls.Add(@($args))
    Set-Variable -Name LASTEXITCODE -Value $global:ClusterLogsTestState.ExitCode -Scope 1
    $global:ClusterLogsTestState.Response
}

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:passed++
}

function Assert-Rejected([scriptblock]$Action, [string]$Message) {
    $before = $global:ClusterLogsTestState.Calls.Count
    $rejected = $false
    try { & $Action | Out-Null } catch { $rejected = $true }
    Assert-True $rejected $Message
    Assert-True ($global:ClusterLogsTestState.Calls.Count -eq $before) 'Invalid input contacted kubectl.'
}

$preview = & $reader -Namespace home-assistant -Since 2h -Preview
Assert-True ($global:ClusterLogsTestState.Calls.Count -eq 0) 'Preview invoked kubectl.'
Assert-True ($preview.Context -eq 'codex-readonly') 'Preview changed the default identity.'
Assert-True ($preview.LogQL -eq '{namespace="home-assistant"}') 'Namespace was not selected exactly.'
$duration = [DateTimeOffset]::Parse($preview.EndUtc) - [DateTimeOffset]::Parse($preview.StartUtc)
Assert-True ($duration.TotalHours -eq 2) 'Relative time range is incorrect.'

$preview = & $reader -AllNamespaces -Since 15m -Limit 100 -Preview
Assert-True ($preview.LogQL -eq '{namespace=~".+"}') 'All-namespace selector is invalid.'
Assert-True ($preview.Limit -eq 100) 'Line limit was not preserved.'

$preview = & $reader -Namespace flux-system -Container helm-controller -Start '2026-11-05T00:00:00+01:00' -End '2026-11-05T00:25:00+01:00' -Preview
Assert-True ($preview.StartUtc -eq '2026-11-04T23:00:00.0000000+00:00') 'Start timezone conversion is incorrect.'
Assert-True ($preview.EndUtc -eq '2026-11-04T23:25:00.0000000+00:00') 'End timezone conversion is incorrect.'
Assert-True ($preview.LogQL.Contains('container="helm-controller"')) 'Container filter is missing.'

# Quoted user text must remain a single LogQL string and a single URL parameter.
$literal = 'failed "request" at C:\logs &limit=9999'
$preview = & $reader -Namespace grafana-loki -Contains $literal -Preview
$quotedFilter = ($preview.LogQL -split ' \|= ', 2)[1]
Assert-True (($quotedFilter | ConvertFrom-Json) -eq $literal) 'Literal text changed or broke out of its LogQL string.'
$parameters = @{}
foreach ($part in ($preview.Path -split '\?', 2)[1] -split '&') {
    $pair = $part -split '=', 2
    $parameters[$pair[0]] = [Uri]::UnescapeDataString($pair[1])
}
Assert-True ($parameters.Count -eq 5 -and $parameters.limit -eq '500') 'Text injected a URL parameter.'
Assert-True ($parameters.query -eq $preview.LogQL) 'URL encoding changed the query.'

$preview = & $reader -Namespace default -PodPattern 'worker-[a-z0-9]+.*' -Preview
Assert-True ($preview.LogQL.Contains('pod=~"worker-[a-z0-9]+.*"')) 'Pod pattern was not preserved.'
Assert-Rejected { & $reader -Preview } 'Implicit cross-namespace access was accepted.'
Assert-Rejected { & $reader -Namespace default -AllNamespaces -Preview } 'Conflicting namespace selectors were accepted.'
Assert-Rejected { & $reader -Namespace default -Pod a -PodPattern 'a.*' -Preview } 'Conflicting Pod selectors were accepted.'
Assert-Rejected { & $reader -Namespace default -Since 0h -Preview } 'A zero duration was accepted.'
Assert-Rejected { & $reader -Namespace default -Since 2weeks -Preview } 'An unsupported duration was accepted.'
Assert-Rejected { & $reader -Namespace default -Limit 5001 -Preview } 'An excessive limit was accepted.'
Assert-Rejected { & $reader -Namespace default -Start '2026-11-05T00:00:00' -End '2026-11-05T01:00:00Z' -Preview } 'A timezone-free timestamp was accepted.'
Assert-Rejected { & $reader -Namespace default -Start '2026-11-05T01:00:00Z' -End '2026-11-05T00:00:00Z' -Preview } 'A reversed time range was accepted.'

$global:ClusterLogsTestState.Response = @{
    status = 'success'
    data = @{
        resultType = 'streams'
        result = @(
            @{
                stream = @{ namespace = 'home-assistant'; pod = 'home-assistant-b'; container = 'main' }
                values = @(
                    @('1793834400000000002', "newest`nmultiline"),
                    @('1793834400000000000', 'oldest')
                )
            }
            @{
                stream = @{ namespace = 'home-assistant'; pod = 'home-assistant-a'; container = 'main' }
                values = @(, @('1793834400000000001', 'middle'))
            }
        )
    }
} | ConvertTo-Json -Depth 10 -Compress
$rows = @(& $reader -Namespace home-assistant -Since 1h)
Assert-True ($rows.Count -eq 3) 'Log entries were lost across streams.'
Assert-True ($rows[0].Line -eq 'oldest' -and $rows[1].Line -eq 'middle') 'Cross-stream nanosecond sorting is incorrect.'
Assert-True ($rows[2].Line -eq "newest`nmultiline") 'Multiline log content changed.'
Assert-True ($rows[1].Pod -eq 'home-assistant-a') 'Stream labels were lost.'
Assert-True ($rows[1].TimestampNs -eq '1793834400000000001') 'Timestamp precision was lost.'
$call = $global:ClusterLogsTestState.Calls[$global:ClusterLogsTestState.Calls.Count - 1]
Assert-True (($call[0..4] -join '|') -eq '--context|codex-readonly|--request-timeout=60s|get|--raw') 'Request used an unexpected context or operation.'
Assert-True ($call.Count -eq 6) 'Request was split into extra shell arguments.'
Assert-True ($call[5].StartsWith('/api/v1/namespaces/grafana-loki/services/http:grafana-loki:3100/proxy/loki/api/v1/query_range?')) 'Request escaped the fixed Loki endpoint.'

$json = & $reader -Namespace home-assistant -Json
$decoded = ConvertFrom-Json -InputObject $json -NoEnumerate
Assert-True ($decoded.Count -eq 3 -and $decoded[2].Line -eq "newest`nmultiline") 'JSON output lost entries or content.'
$warnings = @()
& $reader -Namespace home-assistant -Limit 3 -WarningVariable warnings -WarningAction SilentlyContinue | Out-Null
Assert-True ($warnings.Count -eq 1) 'A potentially truncated result had no warning.'

$global:ClusterLogsTestState.Response = '{"status":"success","data":{"resultType":"streams","result":[]}}'
$empty = & $reader -Namespace default -Json
Assert-True ($empty -eq '[]') 'Empty JSON output is not an array.'

$global:ClusterLogsTestState.Response = 'Error from server (Forbidden): service proxy is forbidden'
$global:ClusterLogsTestState.ExitCode = 1
$failure = $null
try { & $reader -Namespace default | Out-Null } catch { $failure = $_.Exception.Message }
Assert-True ($failure -like '*Forbidden*') 'A kubectl error was reported as empty logs.'

$global:ClusterLogsTestState.ExitCode = 0
$global:ClusterLogsTestState.Response = '{"status":"error","error":"query rejected"}'
$failure = $null
try { & $reader -Namespace default | Out-Null } catch { $failure = $_.Exception.Message }
Assert-True ($failure -like '*successful log-stream*') 'A Loki failure was accepted.'

Write-Output "PASS: $script:passed offline assertions; no cluster access."

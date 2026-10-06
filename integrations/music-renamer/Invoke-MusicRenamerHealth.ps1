[CmdletBinding()]
param(
    [string]$CorrelationId = [guid]::NewGuid().ToString('D'),
    [string]$Template = '{artist} - {title}',
    [bool]$WarningAcknowledged = $false,
    [string]$FixturePath,
    [string]$RuntimeRoot,
    [ValidateRange(1, 300)][int]$TimeoutSeconds = 30
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'MusicRenamerIntegration.psm1') -Force
$parameters = @{
    CorrelationId = $CorrelationId
    Template = $Template
    WarningAcknowledged = $WarningAcknowledged
    FixturePath = $FixturePath
    TimeoutSeconds = $TimeoutSeconds
}
if (-not [string]::IsNullOrWhiteSpace($RuntimeRoot)) { $parameters.RuntimeRoot = $RuntimeRoot }
$result = Invoke-MusicRenamerAdapterHealth @parameters
if (-not [string]::IsNullOrWhiteSpace($result.diagnostics)) {
    [Console]::Error.Write($result.diagnostics)
}
$result.PSObject.Properties.Remove('diagnostics')
[Console]::Out.WriteLine(($result | ConvertTo-Json -Depth 8 -Compress))
if ($result.adapter_status -ne 'healthy') { exit 1 }

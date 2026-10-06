[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$CoreSourcePath,
    [string]$ExpectedGitCommit,
    [string]$RuntimeRoot,
    [ValidateRange(30, 3600)][int]$TimeoutSeconds = 600
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'MusicRenamerIntegration.psm1') -Force
$parameters = @{
    CoreSourcePath = $CoreSourcePath
    ExpectedGitCommit = $ExpectedGitCommit
    TimeoutSeconds = $TimeoutSeconds
}
if (-not [string]::IsNullOrWhiteSpace($RuntimeRoot)) { $parameters.RuntimeRoot = $RuntimeRoot }
$result = Install-MusicRenamerManagedRuntime @parameters
$result | ConvertTo-Json -Depth 5

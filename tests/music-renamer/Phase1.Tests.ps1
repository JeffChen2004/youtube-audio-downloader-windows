param(
    [Parameter(Mandatory=$true)][string]$ManagedRuntimeRoot,
    [Parameter(Mandatory=$true)][string]$CoreSourcePath
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$integrationRoot = Join-Path $repoRoot 'integrations\music-renamer'
Import-Module (Join-Path $integrationRoot 'MusicRenamerIntegration.psm1') -Force

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "Assertion failed: $Message" }
}

function Write-TestAdapter([string]$Path, [string]$Body) {
    [System.IO.File]::WriteAllText($Path, $Body, [System.Text.UTF8Encoding]::new($false))
}

$tempRoot = Join-Path $PSScriptRoot ('phase1-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot | Out-Null
try {
    $resolved = Resolve-MusicRenamerManagedPython -RuntimeRoot $ManagedRuntimeRoot
    Assert-True ($resolved.Executable -eq (Join-Path ([System.IO.Path]::GetFullPath($ManagedRuntimeRoot)) 'python.exe')) 'managed interpreter resolution must use an exact repository-owned path'
    Assert-True (Test-MusicRenamerPythonVersion ([version]'3.11')) 'Python 3.11 must be accepted'
    Assert-True (-not (Test-MusicRenamerPythonVersion ([version]'3.10.14'))) 'Python 3.10 must be rejected'

    $version = Get-MusicRenamerProjectVersion $CoreSourcePath
    $manifest = Write-MusicRenamerRuntimeManifest -RuntimeRoot $tempRoot -CoreSourcePath $CoreSourcePath -CorePackageVersion $version -ExpectedGitCommit 'test-expectation'
    $healthy = Invoke-MusicRenamerAdapterHealth -RuntimeRoot $ManagedRuntimeRoot -ManifestPath $manifest -CorrelationId 'powershell-health'
    Assert-True ($healthy.adapter_status -eq 'healthy') "health check failed: $($healthy.error.summary)"
    Assert-True ($healthy.core_health.pyside6_loaded -eq $false) 'PySide6 must remain unloaded'

    $missing = Invoke-MusicRenamerAdapterHealth -RuntimeRoot (Join-Path $tempRoot 'missing-runtime') -CorrelationId 'missing-runtime'
    Assert-True ($missing.error.code -eq 'runtime_unavailable') 'missing runtime must fail as infrastructure failure'

    $malformedAdapter = Join-Path $tempRoot 'malformed.py'
    Write-TestAdapter $malformedAdapter 'print("not-json")'
    $malformed = Invoke-MusicRenamerAdapterHealth -RuntimeRoot $ManagedRuntimeRoot -AdapterPath $malformedAdapter -ManifestPath $manifest -CorrelationId 'malformed'
    Assert-True ($malformed.error.code -eq 'malformed_transport') 'malformed stdout must fail closed'

    $nonzeroAdapter = Join-Path $tempRoot 'nonzero.py'
    Write-TestAdapter $nonzeroAdapter "import sys`nprint('{}')`nsys.exit(7)`n"
    $nonzero = Invoke-MusicRenamerAdapterHealth -RuntimeRoot $ManagedRuntimeRoot -AdapterPath $nonzeroAdapter -ManifestPath $manifest -CorrelationId 'nonzero'
    Assert-True ($nonzero.error.code -eq 'adapter_nonzero_exit') 'nonzero exit must fail closed'

    $mismatchAdapter = Join-Path $tempRoot 'mismatch.py'
    Write-TestAdapter $mismatchAdapter 'print("{\"protocol_version\":1,\"correlation_id\":\"other\",\"adapter_status\":\"healthy\",\"runtime_health\":{\"status\":\"healthy\"},\"core_health\":{\"status\":\"healthy\"},\"error\":null}")'
    $mismatch = Invoke-MusicRenamerAdapterHealth -RuntimeRoot $ManagedRuntimeRoot -AdapterPath $mismatchAdapter -ManifestPath $manifest -CorrelationId 'expected'
    Assert-True ($mismatch.error.code -eq 'correlation_mismatch') 'correlation mismatch must fail closed'

    $timeoutAdapter = Join-Path $tempRoot 'timeout.py'
    Write-TestAdapter $timeoutAdapter "import time`ntime.sleep(30)`n"
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $timeout = Invoke-MusicRenamerAdapterHealth -RuntimeRoot $ManagedRuntimeRoot -AdapterPath $timeoutAdapter -ManifestPath $manifest -CorrelationId 'timeout' -TimeoutSeconds 1
    $watch.Stop()
    Assert-True ($timeout.error.code -eq 'adapter_timeout') 'timeout must return a structured failure'
    Assert-True ($watch.Elapsed.TotalSeconds -lt 10) 'timed out adapter must be terminated promptly'

    Write-Output 'Phase 1 PowerShell contract tests passed.'
} finally {
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}

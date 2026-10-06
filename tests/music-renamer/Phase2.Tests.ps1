param(
    [Parameter(Mandatory=$true)][string]$ManagedRuntimeRoot
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

$tempRoot = Join-Path $PSScriptRoot ('phase2-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot | Out-Null
try {
    $manifest = Join-Path $tempRoot 'manifest.json'
    [System.IO.File]::WriteAllText($manifest, '{}', [System.Text.UTF8Encoding]::new($false))
    $domainAdapter = Join-Path $tempRoot 'domain.py'
    Write-TestAdapter $domainAdapter @'
import json, sys
request = json.loads(sys.stdin.read().lstrip("\ufeff"))
assert request["operation"] == "rename"
assert request["source_path"] == "C:\\fixture\\source.opus"
assert request["config"]["template"] == "{title}"
assert request["config"]["warning_acknowledged"] is False
assert request["config"]["artist_aliases"][0]["target"] == "Canonical"
assert request["config"]["title_cleanup_rules"][0]["kind"] == "remove_prefix"
assert request["config"]["extraction"]["artist_quoted_title"] is True
response = {
    "protocol_version": 1,
    "correlation_id": request["correlation_id"],
    "operation": "rename",
    "adapter_status": "completed",
    "classification": "rejected",
    "path": {"original_path": request["source_path"], "destination_path": None, "verified_final_path": None, "final_location": None},
    "planning": {"status": "error", "destination_path": None, "issue_codes": ["fixture_reject"], "issues": [], "warnings": [], "errors": ["fixture"], "metadata": {}},
    "preflight": None,
    "execution": None,
    "rejection_reason": "fixture_reject",
    "error": None,
}
print(json.dumps(response, separators=(",", ":")))
'@
    $aliases = @([pscustomobject]@{ source='Channel'; target='Canonical' })
    $cleanup = @([pscustomobject]@{ kind='remove_prefix'; text='Official: ' })
    $domain = Invoke-MusicRenamerAdapterRename -SourcePath 'C:\fixture\source.opus' -Template '{title}' -ArtistAliases $aliases -TitleCleanupRules $cleanup -EnableArtistQuotedTitle $true -CorrelationId 'phase2-domain' -RuntimeRoot $ManagedRuntimeRoot -AdapterPath $domainAdapter -ManifestPath $manifest
    Assert-True ($domain.adapter_status -eq 'completed') "domain result must remain completed; code=$($domain.error.code); summary=$($domain.error.summary); diagnostics=$($domain.diagnostics)"
    Assert-True ($domain.classification -eq 'rejected') 'domain rejection must not become infrastructure failure'
    Assert-True ($domain.correlation_id -eq 'phase2-domain') 'correlation ID must be preserved'

    $missingSource = Join-Path $tempRoot 'missing.opus'
    $realDomain = Invoke-MusicRenamerAdapterRename -SourcePath $missingSource -CorrelationId 'phase2-real-domain' -RuntimeRoot $ManagedRuntimeRoot
    Assert-True ($realDomain.adapter_status -eq 'completed') 'real adapter source rejection must remain a domain response'
    Assert-True ($realDomain.classification -eq 'rejected') 'missing source must be rejected'
    Assert-True ($realDomain.planning.issue_codes[0] -eq 'source_missing') 'missing source must retain its structured issue code'

    $mismatchAdapter = Join-Path $tempRoot 'mismatch.py'
    Write-TestAdapter $mismatchAdapter ((Get-Content -Raw -LiteralPath $domainAdapter).Replace('request["correlation_id"]', '"other"'))
    $mismatch = Invoke-MusicRenamerAdapterRename -SourcePath 'C:\fixture\source.opus' -Template '{title}' -ArtistAliases $aliases -TitleCleanupRules $cleanup -EnableArtistQuotedTitle $true -CorrelationId 'phase2-expected' -RuntimeRoot $ManagedRuntimeRoot -AdapterPath $mismatchAdapter -ManifestPath $manifest
    Assert-True ($mismatch.error.code -eq 'correlation_mismatch') 'correlation mismatch must fail closed'

    $malformedAdapter = Join-Path $tempRoot 'malformed.py'
    Write-TestAdapter $malformedAdapter 'print("not-json")'
    $malformed = Invoke-MusicRenamerAdapterRename -SourcePath 'C:\fixture\source.opus' -RuntimeRoot $ManagedRuntimeRoot -AdapterPath $malformedAdapter -ManifestPath $manifest
    Assert-True ($malformed.error.code -eq 'malformed_transport') 'malformed response must fail closed'

    $timeoutAdapter = Join-Path $tempRoot 'timeout.py'
    Write-TestAdapter $timeoutAdapter "import time`ntime.sleep(30)`n"
    $timeout = Invoke-MusicRenamerAdapterRename -SourcePath 'C:\fixture\source.opus' -RuntimeRoot $ManagedRuntimeRoot -AdapterPath $timeoutAdapter -ManifestPath $manifest -TimeoutSeconds 1
    Assert-True ($timeout.error.code -eq 'adapter_timeout') 'rename timeout must terminate and fail closed'

    Write-Output 'Phase 2 PowerShell contract tests passed.'
} finally {
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}

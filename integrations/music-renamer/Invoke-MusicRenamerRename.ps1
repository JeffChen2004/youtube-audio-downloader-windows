[CmdletBinding()]
param(
    [string]$RuntimeRoot,
    [string]$AdapterPath,
    [string]$ManifestPath,
    [ValidateRange(1, 300)][int]$TimeoutSeconds = 30,
    [string]$MutationGate = '',
    [string]$CancelFile = '',
    [string]$JobCancelFile = ''
)

$ErrorActionPreference = 'Stop'
[Console]::InputEncoding = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
Import-Module (Join-Path $PSScriptRoot 'MusicRenamerIntegration.psm1') -Force
$correlationId = $null
try {
    # This is the existing adapter request/response protocol, forwarded through
    # the Phase 2 caller. There is no second naming or transport protocol.
    $request = [Console]::In.ReadToEnd() | ConvertFrom-Json
    $correlationId = $request.correlation_id
    if ($request.protocol_version -ne 1 -or $request.operation -ne 'rename' -or
        [string]::IsNullOrWhiteSpace($correlationId)) { throw 'Invalid request envelope' }
    $snapshot = ConvertTo-MusicRenamerConfigSnapshot $request.config
    $config = $snapshot | ConvertFrom-Json
    $parameters = @{
        SourcePath = $request.source_path
        CorrelationId = $correlationId
        Template = $config.template
        WarningAcknowledged = $config.warning_acknowledged
        ArtistAliases = @($config.artist_aliases)
        TitleCleanupRules = @($config.title_cleanup_rules)
        EnableArtistQuotedTitle = $config.extraction.artist_quoted_title
        EnableTitleSlashArtist = $config.extraction.title_slash_artist
        TimeoutSeconds = $TimeoutSeconds
    }
    foreach ($name in @('RuntimeRoot','AdapterPath','ManifestPath','MutationGate','CancelFile','JobCancelFile')) {
        $value = Get-Variable -Name $name -ValueOnly
        if (-not [string]::IsNullOrWhiteSpace($value)) { $parameters[$name] = $value }
    }
    $result = Invoke-MusicRenamerAdapterRename @parameters
    # Child stderr may include arbitrary adapter diagnostics. Production bridge
    # logs only classified codes; do not forward the full response into logs.
    $result.PSObject.Properties.Remove('diagnostics')
} catch {
    $result = [pscustomobject]@{
        protocol_version=1; correlation_id=$correlationId; operation='rename'
        adapter_status='error'; error=[pscustomobject]@{ code='invalid_request'; summary='Rename invocation failed validation.' }
    }
}
[Console]::Out.WriteLine(($result | ConvertTo-Json -Depth 20 -Compress))
if ($result.adapter_status -ne 'completed') { exit 1 }

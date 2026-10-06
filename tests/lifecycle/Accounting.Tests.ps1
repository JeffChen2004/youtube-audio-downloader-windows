param(
    [string]$RunLogPath,
    [int]$ChildExitCode = 0
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$sourcePath = Join-Path $repoRoot 'YoutubeAudioDownloader.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw 'Downloader parser errors' }
# Load actual function definitions, without executing startup, GUI, or persistence.
foreach ($name in @('New-DownloadStatistics', 'Get-DownloadItemKey', 'Test-BrowserCookieDatabaseLocked',
                    'Write-PreferredFormatSelectionLog', 'Write-DownloadProcessLine',
                    'Write-DownloadSummary', 'Complete-DownloadSession')) {
    $function = $ast.Find({ param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }, $true)
    if ($null -eq $function) { throw "Missing production function: $name" }
    Invoke-Expression $function.Extent.Text
}

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "Assertion failed: $Message" }
}
function Write-Log([string]$Message) { }
function Drain-DownloadProcessOutput($Context) { }
function Close-DownloadJob { }
function Write-TrackedPlaylistSummary($Configuration, $Statistics, $Stopped, $ProcessFailed) { }
function Update-TrackedPlaylistTimestamps($Path, $Success) { $script:TimestampSuccess = $Success }
function Start-NextTrackedPlaylistCheck { }

function Get-FixtureJobStatus([bool]$ChildFailed, [string[]]$RenameStatuses) {
    if ($ChildFailed) { return 'failed' }
    if ($RenameStatuses -contains 'requires_attention') { return 'requires_attention' }
    if ($RenameStatuses -contains 'rejected' -or $RenameStatuses -contains 'failed') {
        return 'completed_with_rename_errors'
    }
    return 'completed'
}

$itemJson = '{"id":"first","playlist_index":1,"playlist_count":2,"n_entries":2,"format_id":"251"}'
$stats = New-DownloadStatistics
Write-DownloadProcessLine ('__YAD_ITEM_START__' + $itemJson) $true $stats
Write-DownloadProcessLine 'ERROR: fixture postprocessor failed' $true $stats
Assert-True ($stats.Failed.Contains('video:first')) 'ERROR must initially add Failed'
Write-DownloadProcessLine ('__YAD_ITEM_SUCCESS__' + $itemJson) $true $stats
Assert-True ($stats.Success.Contains('video:first')) 'after_video currently adds Success'
Assert-True (-not $stats.Failed.Contains('video:first')) 'known behavior: after_video removes Failed'
# Handled domain statuses travel separately and never rely on ERROR lines.
$separate = @{}
foreach ($status in @('not_requested','succeeded','unchanged','rejected','failed','requires_attention')) {
    $separate['video:first'] = $status
    Assert-True ($stats.Success.Contains('video:first') -and $stats.Failed.Count -eq 0) 'rename status must not overwrite download accounting'
}
Assert-True ((Get-FixtureJobStatus $false @('rejected','succeeded')) -eq 'completed_with_rename_errors') 'rejection remains a separate job concern'
Assert-True ((Get-FixtureJobStatus $false @('failed','succeeded')) -eq 'completed_with_rename_errors') 'handled failure remains a separate job concern'
Assert-True ((Get-FixtureJobStatus $false @('requires_attention','succeeded')) -eq 'requires_attention') 'incomplete recovery must demand attention'
Assert-True ((Get-FixtureJobStatus $true @('succeeded')) -eq 'failed') 'nonzero child must fail job'

if ($RunLogPath) {
    $stats = New-DownloadStatistics
    $separate = @{}
    foreach ($line in Get-Content -LiteralPath $RunLogPath) {
        Write-DownloadProcessLine $line $true $stats
        $offset = $line.IndexOf('__YAD_LIFECYCLE__', [System.StringComparison]::Ordinal)
        if ($offset -ge 0) {
            $event = $line.Substring($offset + '__YAD_LIFECYCLE__'.Length) | ConvertFrom-Json
            if ($event.rename_status) { $separate["video:$($event.id)"] = [string]$event.rename_status }
        }
    }
    $downloadTimer = [pscustomobject]@{}
    $downloadTimer | Add-Member -MemberType ScriptMethod -Name Stop -Value { }
    $startButton = [pscustomobject]@{ Enabled=$false }
    $cancelButton = [pscustomobject]@{ Enabled=$true; Text='' }
    $Script:ActiveProcess = [pscustomobject]@{ ExitCode=$ChildExitCode }
    $Script:HeadlessMode = $true
    $Script:DownloadCancelled = $false
    $context = [pscustomobject]@{
        PreserveSource=$false; HealthRequest=$null; ProviderFailure=$null; ProviderSession=$null
        Statistics=$stats; PlaylistRequested=$true; TrackerConfiguration=[pscustomobject]@{ playlist_title='fixture' }
        TrackerConfigPath='test-only-no-write'
    }
    Complete-DownloadSession $context
    $report = [ordered]@{
        child_exit_code=$ChildExitCode
        success_count=$stats.Success.Count
        failed_count=$stats.Failed.Count
        current_tracker_success=$Script:HeadlessLastResult.success
        timestamp_success=$Script:TimestampSuccess
        rename_status=$separate
        fixture_job_status=(Get-FixtureJobStatus ($ChildExitCode -ne 0) @($separate.Values))
    }
    Write-Output ('__YAD_ACCOUNTING__' + ($report | ConvertTo-Json -Depth 6 -Compress))
} else {
    Write-Output 'Phase 2.5 PowerShell accounting contract tests passed (known Failed removal reproduced).'
}

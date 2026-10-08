param([Parameter(Mandatory=$true)][string]$ManagedRuntimeRoot)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $repo 'tests/lifecycle/Accounting.Tests.ps1')
Import-Module (Join-Path $repo 'integrations/music-renamer/MusicRenamerIntegration.psm1') -Force
$module = Get-Module MusicRenamerIntegration
$launcher = Join-Path $repo 'integrations/music-renamer/Invoke-MusicRenamerRename.ps1'
$shell = Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
$snapshot = New-MusicRenamerDownloadSnapshot -Enabled
$config = $snapshot | ConvertFrom-Json
Assert-True ($config.warning_acknowledged -eq $false) 'default warnings must require explicit acknowledgement'
Assert-True (-not (New-MusicRenamerDownloadSnapshot)) 'disabled must not read config or create snapshot'
Assert-True (@(Get-MusicRenamerPostprocessorArguments '').Count -eq 0) 'disabled must not register bridge'
Assert-True ((Get-MusicRenamerPostprocessorArguments $snapshot)[1] -eq 'MusicRenamer:when=after_move') 'opt-in bridge stage'
$bad = $snapshot | ConvertFrom-Json
$bad.PSObject.Properties.Remove('warning_acknowledged')
$rejected = $false
try { ConvertTo-MusicRenamerConfigSnapshot $bad | Out-Null } catch { $rejected=$true }
Assert-True $rejected 'snapshot cannot silently omit warning acknowledgement'

$stats = New-DownloadStatistics
[void]$stats.Success.Add('video:first')
$stats.RenameEnabled = $true
Assert-True ((Get-DownloadJobProjection $stats $false $false).status -eq 'failed') 'missing opt-in result cannot be full success'
foreach ($status in @('succeeded','unchanged','unsupported','rejected','failed','requires_attention','infrastructure_failed')) {
    $attention = $status -in @('requires_attention','infrastructure_failed')
    $event = [ordered]@{ schema_version=1; id='first'; rename_status=$status; verified_final_path= $(if($attention){$null}else{'C:\fixture\source.opus'})
        path_validity=$(if($attention){'unverified'}else{'verified'}); recovery_status='not_reported'; issue_code=$null; requires_attention=$attention }
    Write-DownloadProcessLine ('__YAD_RENAME_RESULT__' + ($event | ConvertTo-Json -Compress)) $true $stats
    $expected = if($status -eq 'infrastructure_failed'){'failed'}elseif($status -in @('rejected','failed','requires_attention')){'completed_with_rename_errors'}else{'completed'}
    Assert-True ((Get-DownloadJobProjection $stats $false $false).status -eq $expected) "job projection for $status"
    Assert-True ($stats.Success.Count -eq 1 -and $stats.Failed.Count -eq 0) 'rename status must not rewrite download sets'
}
Assert-True ((Get-DownloadJobProjection $stats $true $false).status -eq 'cancelled') 'cancellation wins'
Write-DownloadProcessLine '__YAD_RENAME_RESULT__{"schema_version":1}' $true $stats
Assert-True $stats.RenameTransportFailure 'malformed event fails closed'

$pending = New-DownloadStatistics
$pending.RenameEnabled = $true
[void]$pending.Items.Add('video:pending')
Assert-True ((Get-DownloadJobProjection $pending $true $false).requires_attention) 'cancelled pending rename cannot claim safe recovery'
Assert-True ((Get-DownloadJobProjection $pending $false $true).requires_attention) 'failed pending rename needs manual review'

# Exercise the final headless serialization projection, not only its internal result.
$envelopeAssignment = $ast.Find({ param($node)
    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$resultEnvelope'
}, $true)
Assert-True ($null -ne $envelopeAssignment) 'headless envelope must exist'
$EnableMusicRenamer = $true
$loadedAssemblyNames = @()
$Script:HeadlessLastResult = [pscustomobject]@{
    success=$false; status='completed_with_rename_errors'; download_success=$true
    requires_attention=$true; rename_results=@([pscustomobject]@{rename_status='requires_attention'})
}
Invoke-Expression $envelopeAssignment.Extent.Text
Assert-True ($resultEnvelope.status -eq 'completed_with_rename_errors' -and $resultEnvelope.download_success) 'headless output preserves partial result separately from download'
Assert-True ($resultEnvelope.requires_attention -and $resultEnvelope.rename_requested -and $resultEnvelope.rename_results.Count -eq 1) 'headless output retains rename projection'

$temp = Join-Path $PSScriptRoot ('transport-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null
try {
    $adapter = Join-Path $temp 'stub.py'
    $pidFile = Join-Path $temp 'adapter.pid'
    $request = [ordered]@{ protocol_version=1; operation='rename'; correlation_id='phase3'; source_path='C:\fixture\source.opus'; config=$config } | ConvertTo-Json -Depth 10 -Compress
    foreach ($case in @('malformed','nonzero','timeout','correlation','protocol')) {
        $body = switch ($case) {
            'malformed' { 'print("not-json")' }
            'nonzero' { 'import sys; print("{}"); sys.exit(7)' }
            'timeout' { "import os, time`nfrom pathlib import Path`nPath(r'$pidFile').write_text(str(os.getpid()))`ntime.sleep(30)" }
            default {
                $correlation = if($case -eq 'correlation'){'other'}else{'phase3'}
                $protocol = if($case -eq 'protocol'){99}else{1}
                "import json`nprint(json.dumps(dict(protocol_version=$protocol, correlation_id='$correlation', operation='rename', adapter_status='completed', classification='rejected', path={}, planning={}, preflight=None, execution=None, rejection_reason=None, error=None)))"
            }
        }
        [System.IO.File]::WriteAllText($adapter,$body,[System.Text.UTF8Encoding]::new($false))
        $raw = & $module { param($exe,$scriptPath,$root,$stub,$inputJson)
            Invoke-MusicRenamerRawProcess -FileName $exe -Arguments @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$scriptPath,'-RuntimeRoot',$root,'-AdapterPath',$stub,'-TimeoutSeconds','1') -StandardInput $inputJson -TimeoutSeconds 15
        } $shell $launcher $ManagedRuntimeRoot $adapter $request
        Assert-True (-not $raw.TimedOut -and $raw.ExitCode -ne 0) "launcher must fail closed: $case"
        $result = $raw.Stdout | ConvertFrom-Json
        $expected = switch($case) { 'malformed'{'malformed_transport'} 'nonzero'{'adapter_nonzero_exit'} 'timeout'{'adapter_timeout'} 'correlation'{'correlation_mismatch'} 'protocol'{'protocol_mismatch'} }
        Assert-True ($result.error.code -eq $expected) "transport code: $case ($($result.error.code))"
        if($case -eq 'timeout') {
            $childPid = [int][System.IO.File]::ReadAllText($pidFile)
            Assert-True (-not (Get-Process -Id $childPid -ErrorAction SilentlyContinue)) 'timeout must stop managed adapter'
        }
    }
    # Exercise the actual Downloader cancellation function + Job Object, not a
    # test reimplementation of process-tree termination.
    $tokens=$null; $errors=$null
    $ast=[System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'YoutubeAudioDownloader.ps1'),[ref]$tokens,[ref]$errors)
    $controller=$ast.Find({param($node) $node -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $node.Value.Contains('public static class DownloadProcessController')},$true)
    if(-not ('YtAudioDownloader.DownloadProcessController' -as [type])) { Add-Type -TypeDefinition $controller.Value }
    foreach($name in @('Request-RenamerSafeStop','Release-RenamerStopGate','Stop-DownloadProcessTree')) {
        $stop=$ast.Find({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)
        Invoke-Expression $stop.Extent.Text
    }
    [System.IO.File]::WriteAllText($adapter,"import os, time`nfrom pathlib import Path`nPath(r'$pidFile').write_text(str(os.getpid()))`ntime.sleep(30)",[System.Text.UTF8Encoding]::new($false))
    Remove-Item -LiteralPath $pidFile -Force
    $psi=[System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName=$shell; $psi.UseShellExecute=$false; $psi.CreateNoWindow=$true
    $psi.RedirectStandardInput=$true; $psi.RedirectStandardOutput=$true; $psi.RedirectStandardError=$true
    foreach($arg in @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$launcher,'-RuntimeRoot',$ManagedRuntimeRoot,'-AdapterPath',$adapter)) { $psi.ArgumentList.Add($arg) }
    $Script:ActiveProcess=[System.Diagnostics.Process]::Start($psi)
    $outTask=$Script:ActiveProcess.StandardOutput.ReadToEndAsync()
    $errTask=$Script:ActiveProcess.StandardError.ReadToEndAsync()
    $Script:DownloadJobHandle=[YtAudioDownloader.DownloadProcessController]::CreateKillOnCloseJob()
    [YtAudioDownloader.DownloadProcessController]::AssignToJob($Script:DownloadJobHandle,$Script:ActiveProcess.Handle)
    $Script:ActiveProcess.StandardInput.Write($request); $Script:ActiveProcess.StandardInput.Close()
    $deadline=[datetime]::UtcNow.AddSeconds(10)
    while(-not (Test-Path -LiteralPath $pidFile) -and [datetime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 50 }
    Assert-True (Test-Path -LiteralPath $pidFile) 'adapter must start before cancellation test'
    $childPid=[int][System.IO.File]::ReadAllText($pidFile)
    $Script:DownloadState='Running'
    $cancelButton=[pscustomobject]@{ Text=''; Enabled=$true }
    Stop-DownloadProcessTree
    Assert-True ($Script:ActiveProcess.WaitForExit(5000)) 'user cancellation stops launcher'
    Assert-True (-not (Get-Process -Id $childPid -ErrorAction SilentlyContinue)) 'user cancellation stops managed adapter'
    Assert-True $Script:DownloadCancelled 'actual cancellation state must be set'
    Write-Output 'Phase 3 snapshot/accounting/transport/timeout/cancellation tests passed.'
} finally {
    if($Script:DownloadJobHandle -and $Script:DownloadJobHandle -ne [IntPtr]::Zero) {
        [YtAudioDownloader.DownloadProcessController]::CloseJob($Script:DownloadJobHandle)
        $Script:DownloadJobHandle=[IntPtr]::Zero
    }
    if($Script:ActiveProcess) { $Script:ActiveProcess.Dispose(); $Script:ActiveProcess=$null }
    if(Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
}

param([string]$CommandPath,[string]$ControlRoot,[string]$Scenario)
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $repo 'tests/lifecycle/Accounting.Tests.ps1')
$controller=$ast.Find({param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $n.Value.Contains('public static class DownloadProcessController')},$true)
if(-not ('YtAudioDownloader.DownloadProcessController' -as [type])){Add-Type -TypeDefinition $controller.Value}
foreach($name in @('Request-RenamerSafeStop','Release-RenamerStopGate','Stop-DownloadProcessTree','Close-DownloadJob','Suspend-DownloadProcess')){
    $fn=$ast.Find({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
    Invoke-Expression $fn.Extent.Text
}
$name='Local\YAD.Test.Job.'+[guid]::NewGuid().ToString('N')
$Script:RenamerJobGate=[System.Threading.Mutex]::new($false,$name)
$Script:RenamerCancelFile=Join-Path $ControlRoot 'job-cancel.tmp'
$Script:RenamerStopLogged=$false
$command=Get-Content -Raw -LiteralPath $CommandPath | ConvertFrom-Json
$psi=[System.Diagnostics.ProcessStartInfo]::new()
$psi.FileName=$command[0]; $psi.UseShellExecute=$false; $psi.CreateNoWindow=$true
$psi.RedirectStandardOutput=$true; $psi.RedirectStandardError=$true
foreach($arg in $command[1..($command.Count-1)]){$psi.ArgumentList.Add($arg)}
$psi.Environment['YAD_RENAMER_GATE']=$name
$psi.Environment['YAD_RENAMER_CANCEL']=$Script:RenamerCancelFile
$psi.Environment['YAD_TEST_CONTROL']=$ControlRoot
$psi.Environment['YAD_TEST_SCENARIO']=$Scenario
$Script:DownloadCancelled=$false; $Script:DownloadState='Running'
$cancelButton=[pscustomobject]@{Text='';Enabled=$true}
[void]$Script:RenamerJobGate.WaitOne()
$Script:ActiveProcess=[System.Diagnostics.Process]::Start($psi)
$out=$Script:ActiveProcess.StandardOutput.ReadToEndAsync(); $err=$Script:ActiveProcess.StandardError.ReadToEndAsync()
$Script:DownloadJobHandle=[YtAudioDownloader.DownloadProcessController]::CreateKillOnCloseJob()
[YtAudioDownloader.DownloadProcessController]::AssignToJob($Script:DownloadJobHandle,$Script:ActiveProcess.Handle)
$Script:RenamerJobGate.ReleaseMutex()
try {
    $deadline=[datetime]::UtcNow.AddSeconds(20)
    $ready=Join-Path $ControlRoot 'ready'
    while(-not (Test-Path -LiteralPath $ready) -and [datetime]::UtcNow -lt $deadline -and -not $Script:ActiveProcess.HasExited){Start-Sleep -Milliseconds 20}
    if (-not (Test-Path -LiteralPath $ready) -and $Script:ActiveProcess.HasExited) { throw ('controlled adapter failed before barrier: '+$out.Result+$err.Result) }
    Assert-True (Test-Path -LiteralPath $ready) 'controlled adapter barrier reached'
    $adapterPid=[int][System.IO.File]::ReadAllText($ready)
    if($Scenario -like 'cancel_*'){
        Assert-True (-not (Suspend-DownloadProcess)) 'pause must not suspend protected transaction'
        Stop-DownloadProcessTree
        Assert-True $Script:DownloadCancelled 'normal user stop registered'
        Assert-True (-not $Script:ActiveProcess.HasExited) 'stop must defer, not kill protected bridge'
        $handle=$Script:DownloadJobHandle
        Close-DownloadJob
        Assert-True ($Script:DownloadJobHandle -eq $handle) 'kill-on-close Job Object must not close while protected'
        Assert-True ([bool](Get-Process -Id $adapterPid -ErrorAction SilentlyContinue)) 'adapter remains alive after stop/close request'
    } elseif($Scenario -in @('timeout_execution','outer_timeout_execution')) {
        Start-Sleep -Milliseconds $(if($Scenario -eq 'outer_timeout_execution'){17200}else{2200})
        Assert-True ([bool](Get-Process -Id $adapterPid -ErrorAction SilentlyContinue)) 'execution timeout must not kill adapter'
    }
    [System.IO.File]::WriteAllText((Join-Path $ControlRoot 'release'),'release')
    Assert-True ($Script:ActiveProcess.WaitForExit(15000)) 'terminal transaction and child exit'
    Assert-True (-not (Get-Process -Id $adapterPid -ErrorAction SilentlyContinue)) 'adapter exits normally after terminal result'
    $stdout=$out.Result; $stderr=$err.Result
    [System.IO.File]::WriteAllText((Join-Path $ControlRoot 'stdout.log'),$stdout)
    [System.IO.File]::WriteAllText((Join-Path $ControlRoot 'stderr.log'),$stderr)
    $stats=New-DownloadStatistics; $stats.RenameEnabled=$true
    foreach($line in ($stdout+$stderr -split "`r?`n")){Write-DownloadProcessLine $line $true $stats}
    $projection=Get-DownloadJobProjection $stats $Script:DownloadCancelled ($Script:ActiveProcess.ExitCode -ne 0)
    Write-Output ('__CANCEL_REPORT__'+(@{status=$projection.status;requires_attention=$projection.requires_attention;results=@($stats.RenameResults.Values);exit_code=$Script:ActiveProcess.ExitCode}|ConvertTo-Json -Depth 10 -Compress))
} finally {
    # Tests release their own barrier even after assertion failure, never kill a
    # Core operation at the barrier to make a test finish.
    [System.IO.File]::WriteAllText((Join-Path $ControlRoot 'release'),'release')
    [void]$Script:ActiveProcess.WaitForExit(30000)
    Close-DownloadJob
    $Script:ActiveProcess.Dispose()
}

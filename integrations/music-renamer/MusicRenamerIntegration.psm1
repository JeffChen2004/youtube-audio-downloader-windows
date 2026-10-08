Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:ProtocolVersion = 1
$script:MinimumPythonVersion = [version]'3.11'
$script:DefaultPythonVersion = '3.12.10'
$script:IntegrationRoot = Split-Path -Parent $PSScriptRoot
$script:AppRoot = Split-Path -Parent $script:IntegrationRoot
$script:DefaultRuntimeRoot = Join-Path $script:AppRoot 'tools\music-renamer-runtime'
$script:DefaultAdapterPath = Join-Path $PSScriptRoot 'adapter.py'

function ConvertTo-MusicRenamerProcessArgument([string]$Value) {
    if ($Value.Length -eq 0) { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\\"')
    $escaped = [regex]::Replace($escaped, '(\\*)$', '$1$1')
    return '"' + $escaped + '"'
}

function New-MusicRenamerFailure([string]$CorrelationId, [string]$Code, [string]$Summary, [string]$Diagnostics = '') {
    return [pscustomobject]@{
        protocol_version = $script:ProtocolVersion
        correlation_id = $CorrelationId
        adapter_status = 'error'
        runtime_health = [pscustomobject]@{ status = 'unhealthy' }
        core_health = [pscustomobject]@{ status = 'unknown'; pyside6_loaded = $null }
        error = [pscustomobject]@{ code = $Code; summary = $Summary }
        diagnostics = $Diagnostics
    }
}

function Test-MusicRenamerPythonVersion([version]$Version) {
    return $Version -ge $script:MinimumPythonVersion
}

function Invoke-MusicRenamerRawProcess {
    param(
        [Parameter(Mandatory=$true)][string]$FileName,
        [Parameter(Mandatory=$true)][string[]]$Arguments,
        [string]$StandardInput = '',
        [ValidateRange(1, 3600)][int]$TimeoutSeconds = 30,
        [string]$WorkingDirectory = $script:AppRoot,
        [string]$MutationGate = '',
        [string]$CancelFile = ''
    )
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $FileName
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.Arguments = (($Arguments | ForEach-Object { ConvertTo-MusicRenamerProcessArgument $_ }) -join ' ')
    $process = [System.Diagnostics.Process]::new()
    $gate = $null
    $process.StartInfo = $psi
    if (-not $process.Start()) { throw "Process could not be started: $FileName" }
    try {
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if ($StandardInput.Length -gt 0) { $process.StandardInput.Write($StandardInput) }
        $process.StandardInput.Close()
        $gate = if ($MutationGate) { [System.Threading.Mutex]::new($false, $MutationGate) } else { $null }
        $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
        $escalated = $false
        while (-not $process.WaitForExit(100)) {
            if ([datetime]::UtcNow -lt $deadline) { continue }
            if ($CancelFile) { [System.IO.File]::WriteAllText($CancelFile, 'timeout') }
            $owned = $false
            try {
                if ($gate) {
                    try { $owned = $gate.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
                } else { $owned = $true }
                if ($owned) {
                    if ($process.HasExited) { break }
                    $process.Kill()
                    $process.WaitForExit()
                    return [pscustomobject]@{ TimedOut=$true; ExitCode=$null; Stdout=$stdoutTask.Result; Stderr=($stderrTask.Result + 'pre-mutation process timed out and was terminated') }
                }
                if (-not $escalated) {
                    [Console]::Error.WriteLine('[MusicRenamer] timeout deferred: waiting for terminal Core result')
                    $escalated = $true
                }
            } finally { if ($gate -and $owned) { $gate.ReleaseMutex() } }
        }
        return [pscustomobject]@{
            TimedOut = $false
            TimeoutDeferred = $escalated
            ExitCode = $process.ExitCode
            Stdout = $stdoutTask.Result
            Stderr = $stderrTask.Result
        }
    } finally {
        # An unexpected transport/stop-file error must not orphan an executing
        # adapter and release the enclosing job protection while it still runs.
        if (-not $process.HasExited) { $process.WaitForExit() }
        if ($gate) { $gate.Dispose() }
        $process.Dispose()
    }
}

function Get-MusicRenamerManagedPythonPath([string]$RuntimeRoot = $script:DefaultRuntimeRoot) {
    return Join-Path ([System.IO.Path]::GetFullPath($RuntimeRoot)) 'python.exe'
}

function Resolve-MusicRenamerManagedPython([string]$RuntimeRoot = $script:DefaultRuntimeRoot) {
    $python = Get-MusicRenamerManagedPythonPath $RuntimeRoot
    if (-not (Test-Path -LiteralPath $python -PathType Leaf)) {
        throw "Managed Python is unavailable: $python"
    }
    $probe = Invoke-MusicRenamerRawProcess -FileName $python -Arguments @('--version') -TimeoutSeconds 10
    if ($probe.TimedOut -or $probe.ExitCode -ne 0) {
        throw "Managed Python version probe failed: $python"
    }
    $versionOutput = ($probe.Stdout + ' ' + $probe.Stderr).Trim()
    $versionMatch = [regex]::Match($versionOutput, '^Python\s+(\d+\.\d+\.\d+)')
    if (-not $versionMatch.Success) {
        throw "Managed Python returned an invalid version: $versionOutput"
    }
    $versionText = $versionMatch.Groups[1].Value
    $version = $null
    if (-not [version]::TryParse($versionText, [ref]$version)) {
        throw "Managed Python returned an invalid version: $versionText"
    }
    if (-not (Test-MusicRenamerPythonVersion $version)) {
        throw "Managed Python $version is incompatible; Python 3.11 or newer is required."
    }
    return [pscustomobject]@{ Executable=$python; Version=$version }
}

function Get-MusicRenamerProjectVersion([string]$CoreSourcePath) {
    $pyproject = Join-Path $CoreSourcePath 'pyproject.toml'
    if (-not (Test-Path -LiteralPath $pyproject -PathType Leaf)) { throw "Core pyproject.toml is unavailable: $pyproject" }
    $text = Get-Content -Raw -LiteralPath $pyproject
    $match = [regex]::Match($text, '(?m)^version\s*=\s*"([^"]+)"\s*$')
    if (-not $match.Success) { throw 'Core package version could not be read from pyproject.toml.' }
    return $match.Groups[1].Value
}

function Write-MusicRenamerRuntimeManifest {
    param(
        [Parameter(Mandatory=$true)][string]$RuntimeRoot,
        [Parameter(Mandatory=$true)][string]$CoreSourcePath,
        [Parameter(Mandatory=$true)][string]$CorePackageVersion,
        [AllowNull()][string]$ExpectedGitCommit
    )
    $manifestPath = Join-Path $RuntimeRoot 'integration-manifest.json'
    $manifest = [ordered]@{
        schema_version = 1
        core_source_path = [System.IO.Path]::GetFullPath($CoreSourcePath)
        core_package_version = $CorePackageVersion
        core_git_commit = if ([string]::IsNullOrWhiteSpace($ExpectedGitCommit)) { $null } else { $ExpectedGitCommit }
    }
    $tempPath = $manifestPath + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    [System.IO.File]::WriteAllText($tempPath, ($manifest | ConvertTo-Json -Depth 4), [System.Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tempPath -Destination $manifestPath -Force
    return $manifestPath
}

function Install-MusicRenamerManagedRuntime {
    param(
        [Parameter(Mandatory=$true)][string]$CoreSourcePath,
        [string]$ExpectedGitCommit,
        [string]$RuntimeRoot = $script:DefaultRuntimeRoot,
        [string]$PythonVersion = $script:DefaultPythonVersion,
        [ValidateRange(30, 3600)][int]$TimeoutSeconds = 600
    )
    $runtimeFullPath = [System.IO.Path]::GetFullPath($RuntimeRoot)
    $coreFullPath = [System.IO.Path]::GetFullPath($CoreSourcePath)
    if (-not (Test-Path -LiteralPath (Join-Path $coreFullPath 'src\music_renamer_core\__init__.py') -PathType Leaf)) {
        throw "Music Renamer Core source is unavailable: $coreFullPath"
    }
    New-Item -ItemType Directory -Force -Path $runtimeFullPath | Out-Null
    $python = Get-MusicRenamerManagedPythonPath $runtimeFullPath
    if (-not (Test-Path -LiteralPath $python -PathType Leaf)) {
        $archive = Join-Path ([System.IO.Path]::GetTempPath()) ("python-$PythonVersion-" + [guid]::NewGuid().ToString('N') + '.zip')
        $getPip = Join-Path ([System.IO.Path]::GetTempPath()) ('get-pip-' + [guid]::NewGuid().ToString('N') + '.py')
        try {
            $uri = "https://www.python.org/ftp/python/$PythonVersion/python-$PythonVersion-embed-amd64.zip"
            Invoke-WebRequest -UseBasicParsing -Uri $uri -OutFile $archive
            Expand-Archive -LiteralPath $archive -DestinationPath $runtimeFullPath -Force
            $signature = Get-AuthenticodeSignature -LiteralPath $python
            if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'Python Software Foundation') {
                throw 'Managed python.exe does not have a valid Python Software Foundation signature.'
            }

            $pth = Get-ChildItem -LiteralPath $runtimeFullPath -Filter 'python*._pth' | Select-Object -First 1
            if (-not $pth) { throw 'Managed Python path configuration file was not found.' }
            $pthLines = @(Get-Content -LiteralPath $pth.FullName)
            $updatedPth = [System.Collections.Generic.List[string]]::new()
            foreach ($line in $pthLines) {
                if ($line.Trim() -eq '#import site') { $updatedPth.Add('import site') }
                else { $updatedPth.Add($line) }
            }
            if (-not ($updatedPth -contains 'Lib\site-packages')) { $updatedPth.Add('Lib\site-packages') }
            [System.IO.File]::WriteAllLines($pth.FullName, $updatedPth, [System.Text.UTF8Encoding]::new($false))
            New-Item -ItemType Directory -Force -Path (Join-Path $runtimeFullPath 'Lib\site-packages') | Out-Null

            Invoke-WebRequest -UseBasicParsing -Uri 'https://bootstrap.pypa.io/get-pip.py' -OutFile $getPip
            $pipBootstrap = Invoke-MusicRenamerRawProcess -FileName $python -Arguments @($getPip, '--disable-pip-version-check', '--no-warn-script-location') -TimeoutSeconds $TimeoutSeconds
            if ($pipBootstrap.TimedOut) { throw 'Managed pip bootstrap timed out and was terminated.' }
            if ($pipBootstrap.ExitCode -ne 0) { throw "Managed pip bootstrap failed: $($pipBootstrap.Stderr.Trim())" }
        } finally {
            if (Test-Path -LiteralPath $archive) { Remove-Item -LiteralPath $archive -Force }
            if (Test-Path -LiteralPath $getPip) { Remove-Item -LiteralPath $getPip -Force }
        }
    }
    $resolved = Resolve-MusicRenamerManagedPython $runtimeFullPath
    $packageVersion = Get-MusicRenamerProjectVersion $coreFullPath
    $buildBackend = Invoke-MusicRenamerRawProcess -FileName $resolved.Executable -Arguments @(
        '-m', 'pip', 'install', '--disable-pip-version-check', '--no-input', 'setuptools>=69'
    ) -TimeoutSeconds $TimeoutSeconds
    if ($buildBackend.TimedOut) { throw 'Managed setuptools installation timed out and was terminated.' }
    if ($buildBackend.ExitCode -ne 0) { throw "Managed setuptools installation failed: $($buildBackend.Stderr.Trim())" }
    $pip = Invoke-MusicRenamerRawProcess -FileName $resolved.Executable -Arguments @(
        '-m', 'pip', 'install', '--disable-pip-version-check', '--no-input', '--editable', $coreFullPath
    ) -TimeoutSeconds $TimeoutSeconds
    if ($pip.TimedOut) { throw 'Music Renamer Core installation timed out and was terminated.' }
    if ($pip.ExitCode -ne 0) { throw "Music Renamer Core installation failed: $($pip.Stderr.Trim())" }
    $manifestPath = Write-MusicRenamerRuntimeManifest -RuntimeRoot $runtimeFullPath -CoreSourcePath $coreFullPath -CorePackageVersion $packageVersion -ExpectedGitCommit $ExpectedGitCommit
    return [pscustomobject]@{
        RuntimeRoot=$runtimeFullPath
        PythonExecutable=$resolved.Executable
        PythonVersion=$resolved.Version.ToString()
        ManifestPath=$manifestPath
        CorePackageVersion=$packageVersion
        CoreSourcePath=$coreFullPath
        CoreGitCommit=$ExpectedGitCommit
    }
}

function Invoke-MusicRenamerAdapterHealth {
    param(
        [string]$CorrelationId = [guid]::NewGuid().ToString('D'),
        [string]$Template = '{artist} - {title}',
        [bool]$WarningAcknowledged = $false,
        [AllowNull()][string]$FixturePath = $null,
        [string]$RuntimeRoot = $script:DefaultRuntimeRoot,
        [string]$AdapterPath = $script:DefaultAdapterPath,
        [string]$ManifestPath = (Join-Path $RuntimeRoot 'integration-manifest.json'),
        [ValidateRange(1, 300)][int]$TimeoutSeconds = 30
    )
    try { $resolved = Resolve-MusicRenamerManagedPython $RuntimeRoot }
    catch { return New-MusicRenamerFailure $CorrelationId 'runtime_unavailable' $_.Exception.Message }
    if (-not (Test-Path -LiteralPath $AdapterPath -PathType Leaf)) {
        return New-MusicRenamerFailure $CorrelationId 'adapter_unavailable' "Adapter is unavailable: $AdapterPath"
    }
    $request = [ordered]@{
        protocol_version = $script:ProtocolVersion
        correlation_id = $CorrelationId
        operation = 'health'
        config = [ordered]@{
            template = $Template
            warning_acknowledged = $WarningAcknowledged
            fixture_path = $FixturePath
        }
    }
    try {
        $raw = Invoke-MusicRenamerRawProcess -FileName $resolved.Executable -Arguments @($AdapterPath, '--manifest', $ManifestPath) -StandardInput ($request | ConvertTo-Json -Depth 6 -Compress) -TimeoutSeconds $TimeoutSeconds
    } catch {
        return New-MusicRenamerFailure $CorrelationId 'adapter_start_failed' $_.Exception.Message
    }
    if ($raw.TimedOut) {
        return New-MusicRenamerFailure $CorrelationId 'adapter_timeout' 'Adapter timed out and was terminated.' $raw.Stderr
    }
    $lines = @($raw.Stdout -split "`r?`n" | Where-Object { $_.Trim().Length -gt 0 })
    if ($lines.Count -ne 1) {
        return New-MusicRenamerFailure $CorrelationId 'malformed_transport' 'Adapter stdout must contain exactly one JSON document.' $raw.Stderr
    }
    try { $response = $lines[0] | ConvertFrom-Json }
    catch { return New-MusicRenamerFailure $CorrelationId 'malformed_transport' 'Adapter stdout is not valid JSON.' $raw.Stderr }
    if ($raw.ExitCode -ne 0) {
        return New-MusicRenamerFailure $CorrelationId 'adapter_nonzero_exit' "Adapter exited with code $($raw.ExitCode)." $raw.Stderr
    }
    foreach ($name in @('protocol_version', 'correlation_id', 'operation', 'adapter_status', 'runtime_health', 'core_health', 'error')) {
        if ($null -eq $response.PSObject.Properties[$name]) {
            return New-MusicRenamerFailure $CorrelationId 'malformed_transport' "Adapter response is missing '$name'." $raw.Stderr
        }
    }
    if ($response.protocol_version -ne $script:ProtocolVersion) {
        return New-MusicRenamerFailure $CorrelationId 'protocol_mismatch' 'Adapter response protocol does not match the request.' $raw.Stderr
    }
    if ($response.correlation_id -ne $CorrelationId) {
        return New-MusicRenamerFailure $CorrelationId 'correlation_mismatch' 'Adapter response correlation ID does not match the request.' $raw.Stderr
    }
    if ($response.operation -ne 'health') {
        return New-MusicRenamerFailure $CorrelationId 'invalid_response' 'Adapter response operation does not match the health request.' $raw.Stderr
    }
    if ($null -eq $response.runtime_health -or $null -eq $response.core_health) {
        return New-MusicRenamerFailure $CorrelationId 'malformed_transport' 'Adapter response health objects are missing.' $raw.Stderr
    }
    foreach ($name in @('status', 'python_executable')) {
        if ($null -eq $response.runtime_health.PSObject.Properties[$name]) {
            return New-MusicRenamerFailure $CorrelationId 'malformed_transport' "Adapter response is missing a runtime health field: $name." $raw.Stderr
        }
    }
    foreach ($name in @('status', 'package_name', 'package_version', 'source_path', 'pyside6_loaded')) {
        if ($null -eq $response.core_health.PSObject.Properties[$name]) {
            return New-MusicRenamerFailure $CorrelationId 'malformed_transport' "Adapter response is missing a Core health field: $name." $raw.Stderr
        }
    }
    if ($response.adapter_status -ne 'healthy' -or $response.runtime_health.status -ne 'healthy' -or $response.core_health.status -ne 'healthy') {
        return New-MusicRenamerFailure $CorrelationId 'unhealthy_response' 'Adapter did not report a healthy runtime and Core.' $raw.Stderr
    }
    if (-not [string]::Equals([System.IO.Path]::GetFullPath($response.runtime_health.python_executable), $resolved.Executable, [System.StringComparison]::OrdinalIgnoreCase)) {
        return New-MusicRenamerFailure $CorrelationId 'runtime_identity_mismatch' 'Adapter reported a different Python executable.' $raw.Stderr
    }
    if ($response.core_health.pyside6_loaded -ne $false) {
        return New-MusicRenamerFailure $CorrelationId 'gui_dependency_leak' 'Adapter did not prove that PySide6 remained unloaded.' $raw.Stderr
    }
    $response | Add-Member -NotePropertyName diagnostics -NotePropertyValue $raw.Stderr
    return $response
}

function Invoke-MusicRenamerAdapterRename {
    param(
        [Parameter(Mandatory=$true)][string]$SourcePath,
        [string]$Template = '{artist} - {title}',
        [bool]$WarningAcknowledged = $false,
        [object[]]$ArtistAliases = @(),
        [object[]]$TitleCleanupRules = @(),
        [bool]$EnableArtistQuotedTitle = $false,
        [bool]$EnableTitleSlashArtist = $false,
        [string]$CorrelationId = [guid]::NewGuid().ToString('D'),
        [string]$RuntimeRoot = $script:DefaultRuntimeRoot,
        [string]$AdapterPath = $script:DefaultAdapterPath,
        [string]$ManifestPath = (Join-Path $RuntimeRoot 'integration-manifest.json'),
        [ValidateRange(1, 300)][int]$TimeoutSeconds = 30,
        [string]$MutationGate = ('Local\YAD.Rename.' + [guid]::NewGuid().ToString('N')),
        [string]$CancelFile = '',
        [string]$JobCancelFile = ''
    )
    try { $resolved = Resolve-MusicRenamerManagedPython $RuntimeRoot }
    catch { return New-MusicRenamerFailure $CorrelationId 'runtime_unavailable' $_.Exception.Message }
    if (-not (Test-Path -LiteralPath $AdapterPath -PathType Leaf)) {
        return New-MusicRenamerFailure $CorrelationId 'adapter_unavailable' "Adapter is unavailable: $AdapterPath"
    }
    $request = [ordered]@{
        protocol_version = $script:ProtocolVersion
        correlation_id = $CorrelationId
        operation = 'rename'
        source_path = $SourcePath
        config = [ordered]@{
            template = $Template
            warning_acknowledged = $WarningAcknowledged
            artist_aliases = @($ArtistAliases)
            title_cleanup_rules = @($TitleCleanupRules)
            extraction = [ordered]@{
                artist_quoted_title = $EnableArtistQuotedTitle
                title_slash_artist = $EnableTitleSlashArtist
            }
        }
    }
    try {
        if (-not $CancelFile) { $CancelFile = Join-Path ([System.IO.Path]::GetTempPath()) ('yad-rename-' + [guid]::NewGuid().ToString('N') + '.tmp') }
        $adapterArguments=@($AdapterPath, '--manifest', $ManifestPath, '--mutation-gate', $MutationGate, '--cancel-file', $CancelFile)
        if ($JobCancelFile) { $adapterArguments += @('--job-cancel-file', $JobCancelFile) }
        $raw = Invoke-MusicRenamerRawProcess -FileName $resolved.Executable -Arguments $adapterArguments -StandardInput ($request | ConvertTo-Json -Depth 10 -Compress) -TimeoutSeconds $TimeoutSeconds -MutationGate $MutationGate -CancelFile $CancelFile
    } catch {
        return New-MusicRenamerFailure $CorrelationId 'adapter_start_failed' $_.Exception.Message
    } finally { if ($CancelFile -and (Test-Path -LiteralPath $CancelFile)) { Remove-Item -LiteralPath $CancelFile -Force } }
    if ($raw.TimedOut) {
        return New-MusicRenamerFailure $CorrelationId 'adapter_timeout' 'Adapter timed out and was terminated.' $raw.Stderr
    }
    $lines = @($raw.Stdout -split "`r?`n" | Where-Object { $_.Trim().Length -gt 0 })
    if ($lines.Count -ne 1) {
        return New-MusicRenamerFailure $CorrelationId 'malformed_transport' 'Adapter stdout must contain exactly one JSON document.' $raw.Stderr
    }
    try { $response = $lines[0] | ConvertFrom-Json }
    catch { return New-MusicRenamerFailure $CorrelationId 'malformed_transport' 'Adapter stdout is not valid JSON.' $raw.Stderr }
    if ($raw.ExitCode -ne 0) {
        return New-MusicRenamerFailure $CorrelationId 'adapter_nonzero_exit' "Adapter exited with code $($raw.ExitCode)." $raw.Stderr
    }
    foreach ($name in @('protocol_version', 'correlation_id', 'operation', 'adapter_status', 'classification', 'path', 'planning', 'preflight', 'execution', 'rejection_reason', 'error')) {
        if ($null -eq $response.PSObject.Properties[$name]) {
            return New-MusicRenamerFailure $CorrelationId 'malformed_transport' "Adapter rename response is missing '$name'." $raw.Stderr
        }
    }
    if ($response.protocol_version -ne $script:ProtocolVersion) {
        return New-MusicRenamerFailure $CorrelationId 'protocol_mismatch' 'Adapter response protocol does not match the request.' $raw.Stderr
    }
    if ($response.correlation_id -ne $CorrelationId) {
        return New-MusicRenamerFailure $CorrelationId 'correlation_mismatch' 'Adapter response correlation ID does not match the request.' $raw.Stderr
    }
    if ($response.operation -ne 'rename' -or $response.adapter_status -ne 'completed') {
        return New-MusicRenamerFailure $CorrelationId 'invalid_response' 'Adapter did not return a completed rename domain response.' $raw.Stderr
    }
    if ($response.classification -notin @('renamed', 'unchanged', 'rejected', 'failed', 'requires_attention', 'cancelled')) {
        return New-MusicRenamerFailure $CorrelationId 'invalid_response' 'Adapter returned an unknown rename classification.' $raw.Stderr
    }
    if ($null -ne $response.error) {
        return New-MusicRenamerFailure $CorrelationId 'invalid_response' 'Completed rename response must not contain an infrastructure error.' $raw.Stderr
    }
    if ($null -eq $response.path -or $null -eq $response.planning) {
        return New-MusicRenamerFailure $CorrelationId 'malformed_transport' 'Adapter rename response is missing path or planning projections.' $raw.Stderr
    }
    foreach ($name in @('original_path', 'destination_path', 'verified_final_path', 'final_location')) {
        if ($null -eq $response.path.PSObject.Properties[$name]) {
            return New-MusicRenamerFailure $CorrelationId 'malformed_transport' "Adapter path projection is missing '$name'." $raw.Stderr
        }
    }
    foreach ($name in @('status', 'destination_path', 'issue_codes', 'issues', 'warnings', 'errors', 'metadata')) {
        if ($null -eq $response.planning.PSObject.Properties[$name]) {
            return New-MusicRenamerFailure $CorrelationId 'malformed_transport' "Adapter planning projection is missing '$name'." $raw.Stderr
        }
    }
    if ($response.path.final_location -in @('missing', 'unknown') -and $null -ne $response.path.verified_final_path) {
        return New-MusicRenamerFailure $CorrelationId 'invalid_response' 'Unknown or missing final location must not claim a verified final path.' $raw.Stderr
    }
    if ($response.path.final_location -in @('missing', 'unknown') -and $response.classification -ne 'requires_attention') {
        return New-MusicRenamerFailure $CorrelationId 'invalid_response' 'Unknown or missing final location must require attention.' $raw.Stderr
    }
    if ($response.classification -notin @('rejected','cancelled') -and $null -eq $response.execution) {
        return New-MusicRenamerFailure $CorrelationId 'invalid_response' 'Non-rejected rename result must include a Core execution projection.' $raw.Stderr
    }
    if ($response.classification -eq 'cancelled' -and ($null -ne $response.execution -or
        $null -eq $response.PSObject.Properties['cancellation'] -or $response.cancellation.mutation_started -ne $false)) {
        return New-MusicRenamerFailure $CorrelationId 'invalid_response' 'Cancellation cannot conceal filesystem mutation.' $raw.Stderr
    }
    if ($null -ne $response.execution) {
        foreach ($name in @('transaction_id', 'plan_id', 'outcome', 'preflight_issues', 'operations')) {
            if ($null -eq $response.execution.PSObject.Properties[$name]) {
                return New-MusicRenamerFailure $CorrelationId 'malformed_transport' "Adapter execution projection is missing '$name'." $raw.Stderr
            }
        }
        if ($response.execution.outcome -eq 'failed_rollback_incomplete' -and $response.classification -ne 'requires_attention') {
            return New-MusicRenamerFailure $CorrelationId 'invalid_response' 'Incomplete recovery must require attention.' $raw.Stderr
        }
        $expectedClassification = switch ($response.execution.outcome) {
            'succeeded' { 'renamed' }
            'no_op' { 'unchanged' }
            'preflight_rejected' { 'rejected' }
            'failed_rolled_back' { 'failed' }
            'failed_rollback_incomplete' { 'requires_attention' }
            default { $null }
        }
        if ($null -eq $expectedClassification) {
            return New-MusicRenamerFailure $CorrelationId 'invalid_response' 'Adapter returned an unknown Core transaction outcome.' $raw.Stderr
        }
        if ($response.path.final_location -notin @('missing', 'unknown') -and $response.classification -ne $expectedClassification) {
            return New-MusicRenamerFailure $CorrelationId 'invalid_response' 'Rename classification does not match the Core transaction outcome.' $raw.Stderr
        }
    }
    $response | Add-Member -NotePropertyName diagnostics -NotePropertyValue $raw.Stderr
    return $response
}

function Invoke-MusicRenamerConfigValidation {
    param([Parameter(Mandatory=$true)][string]$Snapshot,
          [string]$RuntimeRoot=$script:DefaultRuntimeRoot,
          [string]$AdapterPath=$script:DefaultAdapterPath,
          [string]$ManifestPath=(Join-Path $RuntimeRoot 'integration-manifest.json'))
    $resolved = Resolve-MusicRenamerManagedPython $RuntimeRoot
    $id = [guid]::NewGuid().ToString('D')
    $request = [ordered]@{protocol_version=1; correlation_id=$id; operation='validate_config'; config=($Snapshot | ConvertFrom-Json)}
    $raw = Invoke-MusicRenamerRawProcess -FileName $resolved.Executable -Arguments @($AdapterPath,'--manifest',$ManifestPath) -StandardInput ($request | ConvertTo-Json -Depth 20 -Compress) -TimeoutSeconds 30
    if ($raw.TimedOut -or $raw.ExitCode -ne 0) { throw 'Music Renamer config validation transport failed; check the managed runtime/bootstrap.' }
    $lines = @($raw.Stdout -split "`r?`n" | Where-Object { $_.Trim().Length })
    if ($lines.Count -ne 1) { throw 'Invalid config validation stdout contract.' }
    $response = $lines[0] | ConvertFrom-Json
    foreach ($name in @('protocol_version','correlation_id','operation','adapter_status','valid','issues','error')) {
        if ($null -eq $response.PSObject.Properties[$name]) { throw 'Incomplete config validation response.' }
    }
    if ($response.protocol_version -ne 1 -or $response.correlation_id -ne $id -or
        $response.operation -ne 'validate_config' -or $response.adapter_status -ne 'completed' -or
        $response.valid -isnot [bool] -or $response.issues -isnot [array] -or $null -ne $response.error -or
        ($response.valid -and $response.issues.Count -ne 0) -or (-not $response.valid -and $response.issues.Count -eq 0)) {
        throw 'Invalid config validation response contract.'
    }
    return $response
}

function ConvertTo-MusicRenamerConfigSnapshot($Config) {
    # Validate only snapshot shape; Core/adapter owns all naming semantics.
    $required = @('template','warning_acknowledged','artist_aliases','title_cleanup_rules','extraction')
    if ($null -eq $Config -or @(Compare-Object ($required | Sort-Object) (@($Config.PSObject.Properties.Name) | Sort-Object)).Count) {
        throw 'Music Renamer config must contain exactly the documented snapshot fields.'
    }
    if ($Config.template -isnot [string] -or [string]::IsNullOrWhiteSpace($Config.template) -or
        $Config.warning_acknowledged -isnot [bool] -or $Config.artist_aliases -isnot [array] -or
        $Config.title_cleanup_rules -isnot [array]) { throw 'Invalid Music Renamer config snapshot types.' }
    if ($null -eq $Config.extraction -or
        @(Compare-Object @('artist_quoted_title','title_slash_artist') (@($Config.extraction.PSObject.Properties.Name) | Sort-Object)).Count -or
        $Config.extraction.artist_quoted_title -isnot [bool] -or $Config.extraction.title_slash_artist -isnot [bool]) {
        throw 'Invalid Music Renamer extraction snapshot.'
    }
    return $Config | ConvertTo-Json -Depth 20 -Compress
}

function New-MusicRenamerDownloadSnapshot {
    param([switch]$Enabled, [string]$ConfigPath = '')
    if (-not $Enabled) { return $null }
    if ($ConfigPath) {
        $config = [System.IO.File]::ReadAllText([System.IO.Path]::GetFullPath($ConfigPath)) | ConvertFrom-Json
    } else {
        $config = [pscustomobject]@{
            template='{artist} - {title} [{youtube_id}]'; warning_acknowledged=$false
            artist_aliases=@(); title_cleanup_rules=@()
            extraction=[pscustomobject]@{ artist_quoted_title=$false; title_slash_artist=$false }
        }
    }
    return ConvertTo-MusicRenamerConfigSnapshot $config
}

function Get-MusicRenamerPostprocessorArguments([string]$Snapshot) {
    if (-not [string]::IsNullOrWhiteSpace($Snapshot)) {
        return @('--use-postprocessor', 'MusicRenamer:when=after_move')
    }
}

Export-ModuleMember -Function @(
    'Get-MusicRenamerManagedPythonPath',
    'Resolve-MusicRenamerManagedPython',
    'Test-MusicRenamerPythonVersion',
    'Get-MusicRenamerProjectVersion',
    'Write-MusicRenamerRuntimeManifest',
    'Install-MusicRenamerManagedRuntime',
    'Invoke-MusicRenamerAdapterHealth',
    'Invoke-MusicRenamerAdapterRename',
    'Invoke-MusicRenamerConfigValidation',
    'ConvertTo-MusicRenamerConfigSnapshot',
    'New-MusicRenamerDownloadSnapshot',
    'Get-MusicRenamerPostprocessorArguments'
)

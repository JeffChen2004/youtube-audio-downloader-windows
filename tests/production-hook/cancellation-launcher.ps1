param([int]$TimeoutSeconds, [string]$MutationGate, [string]$CancelFile, [string]$JobCancelFile)
# Test-only injection via the existing launcher's explicit AdapterPath seam.
$repo=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
& (Join-Path $repo 'integrations/music-renamer/Invoke-MusicRenamerRename.ps1') @PSBoundParameters -AdapterPath (Join-Path $PSScriptRoot 'cancellation_adapter.py')
exit $LASTEXITCODE

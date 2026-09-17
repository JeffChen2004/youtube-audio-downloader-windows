$ErrorActionPreference = 'Stop'
$componentRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$source = Join-Path $componentRoot 'CookieBridge.cs'
$outputDirectory = Join-Path $componentRoot 'dist'
$output = Join-Path $outputDirectory 'cookie-bridge.exe'

New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
if (Test-Path -LiteralPath $output) { Remove-Item -LiteralPath $output -Force }

$frameworkRoot = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319'
$webExtensions = Join-Path $frameworkRoot 'System.Web.Extensions.dll'
if (-not (Test-Path -LiteralPath $webExtensions -PathType Leaf)) {
    throw '找不到 .NET Framework System.Web.Extensions.dll，無法編譯 Cookie Bridge。'
}

Add-Type -Path $source -ReferencedAssemblies @(
    'System.dll',
    'System.Core.dll',
    $webExtensions
) -OutputAssembly $output -OutputType ConsoleApplication

Write-Host "Built: $output"

#Requires -Version 5.1
<#
.SYNOPSIS
    Build the Windows port of thetoolbox.

.DESCRIPTION
    Restores NuGet packages and compiles the .NET 8 WinForms system-tray application.
    Feature parity with macOS is aspirational.
#>
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$project = Join-Path $root 'platform/windows/thetoolbox-windows.csproj'

Write-Host "Building thetoolbox for Windows ($Configuration)..." -ForegroundColor Cyan

if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    Write-Error @"
.NET SDK not found. Install .NET 8 from https://dotnet.microsoft.com/download
Then restart PowerShell and try again.
"@
}

Push-Location $root
try {
    dotnet restore $project
    dotnet build $project -c $Configuration --no-restore
    Write-Host ""
    Write-Host "Build succeeded." -ForegroundColor Green
    Write-Host "Run: dotnet run --project $project -c $Configuration"
}
finally {
    Pop-Location
}

# Build the WinUI 3 client for one architecture and stage the Python sidecar
# next to the exe, mirroring the macOS packaging scripts.
#
# Usage:
#   ./build.ps1 -Arch x64            # publish + stage runtime + backend
#   ./build.ps1 -Arch arm64 -Msix    # also produce an MSIX package
#
# Requires: .NET SDK 8, and for MSIX the Windows App SDK tooling on Windows.

param(
    [ValidateSet("x64", "arm64")]
    [string]$Arch = "x64",
    [switch]$Msix
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot                # clients/windows
$Proj = Join-Path $Root "OSTTracker\OSTTracker.csproj"
$Out = Join-Path $Root "out\app-$Arch"
$RuntimeDir = Join-Path $Root "runtime"                 # staging (gitignored)

# 1) Publish the self-contained WinUI 3 app (Windows App SDK bundled).
dotnet publish $Proj -c Release -r win-$Arch --self-contained true `
    -p:PublishReadyToRun=false -o $Out

# 2) Stage the embedded CPython runtime next to the exe, like 01_fetch_runtime.sh.
#    python-build-standalone publishes windows-msvc assets for both archs.
$Tag = "20260623"
$Asset = if ($Arch -eq "arm64") { "cpython-3.11.15+$Tag-aarch64-pc-windows-msvc-install_only.tar.gz" }
         else                    { "cpython-3.11.15+$Tag-x86_64-pc-windows-msvc-install_only.tar.gz" }
$Url = "https://github.com/astral-sh/python-build-standalone/releases/download/$Tag/$Asset"
$Archive = Join-Path $RuntimeDir $Asset
$RuntimeStaged = Join-Path $RuntimeDir "python-$Arch"

New-Item -ItemType Directory -Force -Path $RuntimeDir | Out-Null
if (-not (Test-Path $Archive)) {
    Write-Host "fetching $Asset"
    Invoke-WebRequest -Uri $Url -OutFile $Archive
}
if (-not (Test-Path $RuntimeStaged)) {
    tar -xzf $Archive -C $RuntimeDir
    Move-Item (Join-Path $RuntimeDir "python") $RuntimeStaged
}

$AppRuntime = Join-Path $Out "python-runtime"
Remove-Item -Recurse -Force $AppRuntime -ErrorAction SilentlyContinue
Copy-Item -Recurse $RuntimeStaged $AppRuntime

# 3) Ship backend/ + ost_tracker/ (the sidecar contract) next to the exe.
Copy-Item -Recurse (Join-Path $Root "..\..\backend") (Join-Path $Out "backend")
Copy-Item -Recurse (Join-Path $Root "..\..\ost_tracker") (Join-Path $Out "ost_tracker")

Write-Host "staged app at $Out"

# 4) Optional MSIX bundle. Needs the MSIX Packaging Tools / Windows SDK on
#    PATH (MakeAppx.exe) — run on a Windows box.
if ($Msix) {
    $MakeAppx = "MakeAppx.exe"
    if (Get-Command $MakeAppx -ErrorAction SilentlyContinue) {
        & $MakeAppx pack /d $Out /p (Join-Path $Root "out\OstTracker-$Arch.msix")
        Write-Host "msix at out\OstTracker-$Arch.msix"
    } else {
        Write-Host "MakeAppx.exe not found — skipped MSIX (install Windows SDK)"
    }
}

# 5) Optional NSIS installer (makensis on PATH).
$Makensis = "makensis.exe"
if (Get-Command $Makensis -ErrorAction SilentlyContinue) {
    & $Makensis /DARCH=$Arch /DOUT=$Out /DVERSION=0.1.0 (Join-Path $PSScriptRoot "installer.nsi")
}

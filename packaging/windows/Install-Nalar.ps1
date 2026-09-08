<#
.SYNOPSIS
  User-local setup for Nalar desktop (no admin, no Program Files).

.DESCRIPTION
  Copies nalar-desktop.exe + nalar.exe + runtime DLLs to
  %LOCALAPPDATA%\nalar\bin, the shipped webapp/ folder to
  %LOCALAPPDATA%\nalar\webapp (persistent -- the desktop serves it
  via --static-dir, no per-run temp extraction), and creates a
  per-user Start Menu shortcut
  (Nalar.lnk) so Win-key search finds it. Both exes ship together
  because the desktop auto-spawns the nalar service sitting next to
  itself (next-to-self lookup); a lone desktop exe cannot start its
  backend. Idempotent: re-running overwrites the previous install.

  Works from two layouts:
    - Release zip: script sits beside the exes/DLLs (default SourceDir).
    - Repo checkout: pass -SourceDir zig-out\bin (what
      `zig build install:windows:app` does).

.PARAMETER SourceDir
  Directory holding nalar-desktop.exe, nalar.exe, *.dll and the
  shipped webapp/ folder.
  Defaults to the script's own directory (release-zip layout).

.PARAMETER DesktopShortcut
  Also create Desktop\Nalar.lnk alongside the Start Menu entry.

.PARAMETER Uninstall
  Remove %LOCALAPPDATA%\nalar\bin, %LOCALAPPDATA%\nalar\webapp,
  the Start Menu shortcut and the
  Desktop shortcut (if present), then exit.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File Install-Nalar.ps1
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File Install-Nalar.ps1 -DesktopShortcut
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File Install-Nalar.ps1 -Uninstall
#>
param(
    [string]$SourceDir = "",
    [switch]$DesktopShortcut,
    [switch]$Uninstall
)

$ErrorActionPreference = "Stop"

function Get-NalarRoot {
    # Same priority as tools/install_tui.zig: LOCALAPPDATA first.
    if ($env:LOCALAPPDATA -ne $null -and $env:LOCALAPPDATA -ne "") {
        return (Join-Path $env:LOCALAPPDATA "nalar")
    }
    if ($env:APPDATA -ne $null -and $env:APPDATA -ne "") {
        return (Join-Path $env:APPDATA "nalar")
    }
    if ($env:USERPROFILE -ne $null -and $env:USERPROFILE -ne "") {
        return (Join-Path $env:USERPROFILE "nalar")
    }
    Write-Error "Cannot determine install destination - none of LOCALAPPDATA, APPDATA, USERPROFILE is set."
    exit 1
}

$nalarRoot = Get-NalarRoot
$binDir = Join-Path $nalarRoot "bin"
$webappDir = Join-Path $nalarRoot "webapp"
$startMenuDir = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs"
$startMenuLink = Join-Path $startMenuDir "Nalar.lnk"
$desktopLink = Join-Path ([Environment]::GetFolderPath("Desktop")) "Nalar.lnk"

if ($Uninstall) {
    if (Test-Path $binDir) { Remove-Item $binDir -Recurse -Force }
    if (Test-Path $webappDir) { Remove-Item $webappDir -Recurse -Force }
    foreach ($link in @($startMenuLink, $desktopLink)) {
        if (Test-Path $link) { Remove-Item $link -Force }
    }
    Write-Output "Uninstalled Nalar (removed $binDir, $webappDir and shortcuts)."
    exit 0
}

if ($SourceDir -eq "") { $SourceDir = $PSScriptRoot }
$desktopSrc = Join-Path $SourceDir "nalar-desktop.exe"
$serviceSrc = Join-Path $SourceDir "nalar.exe"
foreach ($req in @($desktopSrc, $serviceSrc)) {
    if (-not (Test-Path $req)) {
        Write-Error ("Required file missing: " + $req + " -- run 'zig build nalar-desktop' first or extract the full release zip.")
        exit 1
    }
}

New-Item -ItemType Directory -Force -Path $binDir | Out-Null
Copy-Item -Force $desktopSrc (Join-Path $binDir "nalar-desktop.exe")
Copy-Item -Force $serviceSrc (Join-Path $binDir "nalar.exe")
$dlls = Get-ChildItem (Join-Path $SourceDir "*.dll") -ErrorAction SilentlyContinue
foreach ($dll in $dlls) { Copy-Item -Force $dll.FullName $binDir }
if (-not (Test-Path (Join-Path $binDir "WebView2Loader.dll"))) {
    Write-Warning "WebView2Loader.dll not found in $SourceDir -- the desktop needs the WebView2 Runtime (preinstalled on Win 10+) and its loader beside the exe."
}

# Persistent webapp (Windows-only shipped static dir). The desktop
# prefers %LOCALAPPDATA%\nalar\webapp\index.html and serves it via
# --static-dir -- no per-run temp extraction, survives close/reopen
# and reboot. Missing webapp/ in SourceDir is a warning (not fatal):
# old zips and bare zig-out/bin runs fall back to embedded-asset
# temp extraction.
$webappSrc = Join-Path $SourceDir "webapp"
if (Test-Path (Join-Path $webappSrc "index.html")) {
    if (Test-Path $webappDir) { Remove-Item $webappDir -Recurse -Force }
    Copy-Item -Recurse -Force $webappSrc $webappDir
} else {
    Write-Warning "webapp/index.html not found in $SourceDir -- desktop falls back to embedded-asset temp extraction."
}

# Start Menu shortcut (per-user, no admin). WScript.Shell is inbox on
# every Windows since 2000; IconLocation points at the exe itself
# (no separate .ico shipped -- the exe carries the app icon).
$shell = New-Object -ComObject WScript.Shell
$lnk = $shell.CreateShortcut($startMenuLink)
$lnk.TargetPath = Join-Path $binDir "nalar-desktop.exe"
$lnk.WorkingDirectory = $binDir
$lnk.Description = "Nalar Desktop - agent workspace"
$lnk.IconLocation = (Join-Path $binDir "nalar-desktop.exe") + ",0"
$lnk.Save()

if ($DesktopShortcut) {
    $dlnk = $shell.CreateShortcut($desktopLink)
    $dlnk.TargetPath = Join-Path $binDir "nalar-desktop.exe"
    $dlnk.WorkingDirectory = $binDir
    $dlnk.Description = "Nalar Desktop - agent workspace"
    $dlnk.IconLocation = (Join-Path $binDir "nalar-desktop.exe") + ",0"
    $dlnk.Save()
}

Write-Output ("Installed Nalar to " + $binDir)
Write-Output "Press Win key and type 'Nalar' to launch it."
Write-Output "(WebView2 Runtime required; preinstalled on Windows 10+.)"

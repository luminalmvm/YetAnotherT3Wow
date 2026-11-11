<#
.SYNOPSIS
  Starts the T3Bridge companion (T3 Code <-> WoW). The companion starts the capture helper
  (T3Capture.exe, read-only window capture of WoW) itself and stops it when it exits.

.DESCRIPTION
  - Single instance: if a companion is already running (%LOCALAPPDATA%\T3Bridge\companion.lock),
    this script only reports it.
  - Default: runs hidden in the background. Stop it with scripts\stop-bridge.ps1.
  - -Console: runs in its own console window that shows the log. Ctrl+C or closing the window
    stops it cleanly.
  - On a clean stop the companion overwrites live.lua and Inbox.lua with an empty snapshot, so no
    conversation text stays in the WoW folder.
  - Autostart at logon is optional and separate: scripts\install-companion.ps1 -SkipBuild -NoLogin -Startup

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts\start-bridge.ps1
  powershell -ExecutionPolicy Bypass -File scripts\start-bridge.ps1 -Console
#>
[CmdletBinding()]
param(
  [switch]$Console,
  [switch]$Demo,
  [ValidateSet("debug", "info", "warn")][string]$LogLevel = "info"
)
$ErrorActionPreference = "Stop"
$Repo = Split-Path -Parent $PSScriptRoot
$Companion = Join-Path $Repo "companion"
$Main = Join-Path $Companion "dist\main.js"
$AppDir = Join-Path $env:LOCALAPPDATA "T3Bridge"
$Lock = Join-Path $AppDir "companion.lock"
$Log = Join-Path $AppDir "companion.log"

function Get-RunningCompanion {
  if (-not (Test-Path $Lock)) { return $null }
  $text = (Get-Content $Lock -Raw -ErrorAction SilentlyContinue)
  if (-not $text) { return $null }
  $procId = 0
  if (-not [int]::TryParse($text.Trim(), [ref]$procId)) { return $null }
  $p = Get-Process -Id $procId -ErrorAction SilentlyContinue
  if ($p -and $p.ProcessName -eq "node") { return $p }
  return $null
}

$node = Get-Command node -ErrorAction SilentlyContinue
if (-not $node) { throw "Node.js 22+ is required (https://nodejs.org)." }
if (-not (Test-Path $Main)) { throw "$Main is missing. Build first: scripts\install-companion.ps1 (or: cd companion; npm install; npm run build)" }

$running = Get-RunningCompanion
if ($running) {
  Write-Host "T3Bridge companion is already running (pid $($running.Id)). Stop it with scripts\stop-bridge.ps1." -ForegroundColor Yellow
  exit 0
}

$argList = @("`"$Main`"", "--log-level", $LogLevel)
if ($Demo) { $argList += "--demo" }
New-Item -ItemType Directory -Force -Path $AppDir | Out-Null
$logStart = 0
if (Test-Path $Log) { $logStart = (Get-Item $Log).Length }

if ($Console) {
  $p = Start-Process -FilePath $node.Source -ArgumentList $argList -WorkingDirectory $Companion -WindowStyle Normal -PassThru
  Write-Host "Started in a console window (pid $($p.Id)). Ctrl+C there (or scripts\stop-bridge.ps1) stops it."
} else {
  $p = Start-Process -FilePath $node.Source -ArgumentList $argList -WorkingDirectory $Companion -WindowStyle Hidden -PassThru
  Write-Host "Started in the background (pid $($p.Id)). Stop it with scripts\stop-bridge.ps1."
}

# Show the first log lines so problems are visible right away.
$deadline = (Get-Date).AddSeconds(8)
$seen = ""
while ((Get-Date) -lt $deadline) {
  Start-Sleep -Milliseconds 500
  if ($p.HasExited) { break }
  if (Test-Path $Log) {
    $fs = [System.IO.File]::Open($Log, 'Open', 'Read', 'ReadWrite')
    try {
      if ($fs.Length -lt $logStart) { $logStart = 0 }   # rotated
      $fs.Seek($logStart, 'Begin') | Out-Null
      $seen = (New-Object System.IO.StreamReader($fs)).ReadToEnd()
    } finally { $fs.Close() }
    if ($seen -match "writing .*live\.lua" -and ($seen -match "capture attached" -or $seen -match "capture helper" -or $seen -match "capture disabled")) { break }
  }
}
if ($seen) { Write-Host ""; Write-Host $seen.TrimEnd() }
if ($p.HasExited) {
  Write-Host "The companion exited (code $($p.ExitCode)). See $Log" -ForegroundColor Red
  exit 1
}
if ($seen -notmatch "capture attached") {
  Write-Host "(Capture not attached yet: that is normal while WoW is closed or still loading; it attaches by itself.)"
}
Write-Host "Log: $Log"

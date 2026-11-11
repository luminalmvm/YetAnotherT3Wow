<#
.SYNOPSIS
  Stops the T3Bridge companion cleanly and clears the live file.

.DESCRIPTION
  1. Asks the running companion to stop (creates %LOCALAPPDATA%\T3Bridge\stop.request). The
     companion then stops the capture helper and overwrites live.lua and Inbox.lua with an empty
     snapshot (no conversation text left in the WoW folder), and exits.
  2. If it has not exited after 10 s, it is terminated, and the files are cleared with
     `node companion\dist\main.js --clear`.
  -Clear also clears the files when no companion is running (for example after a crash).
  Never touches WoW itself, other addons, or SavedVariables.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts\stop-bridge.ps1
#>
[CmdletBinding()]
param([switch]$Clear)
$ErrorActionPreference = "Stop"
$Repo = Split-Path -Parent $PSScriptRoot
$Main = Join-Path $Repo "companion\dist\main.js"
$AppDir = Join-Path $env:LOCALAPPDATA "T3Bridge"
$Lock = Join-Path $AppDir "companion.lock"
$StopFile = Join-Path $AppDir "stop.request"

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

function Clear-LiveFiles {
  $node = Get-Command node -ErrorAction SilentlyContinue
  if ($node -and (Test-Path $Main)) { & $node.Source $Main --clear }
  else { Write-Warning "Cannot clear live.lua (node or $Main missing)." }
}

$p = Get-RunningCompanion
if (-not $p) {
  Write-Host "T3Bridge companion is not running."
  if ($Clear) { Clear-LiveFiles }
} else {
  Set-Content -Path $StopFile -Value "stop" -Encoding ASCII
  Write-Host "Asked the companion (pid $($p.Id)) to stop..."
  if ($p.WaitForExit(10000)) {
    Write-Host "Stopped. live.lua was cleared by the companion."
  } else {
    Write-Warning "No clean exit after 10 s: terminating pid $($p.Id)."
    Stop-Process -Id $p.Id -Force
    Clear-LiveFiles
  }
  Remove-Item $StopFile -Force -ErrorAction SilentlyContinue
}

# A capture helper left over from a crash (ours only: started from %LOCALAPPDATA%\T3Bridge\capture).
$helperDir = Join-Path $AppDir "capture"
Get-Process -Name T3Capture -ErrorAction SilentlyContinue | Where-Object {
  try { $_.Path -and $_.Path.StartsWith($helperDir, [StringComparison]::OrdinalIgnoreCase) } catch { $false }
} | ForEach-Object { Stop-Process -Id $_.Id -Force; Write-Host "Stopped leftover capture helper (pid $($_.Id))." }

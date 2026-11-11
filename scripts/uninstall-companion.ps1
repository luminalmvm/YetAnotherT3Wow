<#
.SYNOPSIS
  Removes the T3Bridge companion's Startup shortcut, stops it, and optionally deletes its data
  (config, DPAPI credential, logs) and revokes its T3 session. Never touches the WoW AddOns folder
  or any WoW screenshot/SavedVariables.
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts\uninstall-companion.ps1 -RemoveData
#>
[CmdletBinding()]
param([switch]$RemoveData)
$ErrorActionPreference = "Stop"
$AppDir = Join-Path $env:LOCALAPPDATA "T3Bridge"

$lnk = Join-Path ([Environment]::GetFolderPath("Startup")) "T3Bridge Companion.lnk"
if (Test-Path $lnk) { Remove-Item $lnk -Force; Write-Host "removed $lnk" }

# Clean stop first: the companion clears live.lua/Inbox.lua (no conversation text left behind).
& (Join-Path $PSScriptRoot "stop-bridge.ps1") -Clear
$lock = Join-Path $AppDir "companion.lock"
Remove-Item $lock -Force -ErrorAction SilentlyContinue

if ($RemoveData) {
  $meta = Join-Path $AppDir "auth-meta.json"
  if (Test-Path $meta) {
    $m = Get-Content $meta -Raw | ConvertFrom-Json
    $t3 = Join-Path $env:USERPROFILE ".t3\bin\t3.cmd"
    if ($m.sessionId -and (Test-Path $t3)) {
      & $t3 auth session revoke $m.sessionId | Out-Null
      if ($LASTEXITCODE -eq 0) { Write-Host "revoked T3 session $($m.sessionId)" } else { Write-Warning "could not revoke T3 session $($m.sessionId); revoke it in T3 Code > Connections" }
    }
  }
  if (Test-Path $AppDir) { Remove-Item $AppDir -Recurse -Force; Write-Host "removed $AppDir" }
}
Write-Host "done (the WoW addon is untouched; use scripts\uninstall-addon.ps1 for it)"

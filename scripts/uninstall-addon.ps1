<#
.SYNOPSIS
  Removes the T3Bridge addon folders: T3Bridge, T3Bridge_Live, T3Bridge_S####, T3Bridge_TA##, T3Bridge_TB##,
  T3Bridge_Img (image slots) and T3Bridge_ImgT.
.DESCRIPTION
  Refuses to run while WoW is running. Never touches other addons, WTF\ or SavedVariables.
  Your T3BridgeDB settings stay in WTF\Account\<account>\SavedVariables\T3Bridge.lua; delete that file
  yourself if you want them gone. Supports -WhatIf.
  The WoW folder is auto-detected the same way as install-addon.ps1; pass -WowPath if needed.
.EXAMPLE
  .\uninstall-addon.ps1 -WhatIf
  .\uninstall-addon.ps1 -WowPath "<drive>:\World of Warcraft\_forever_"
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [string]$WowPath,
  [string]$Flavor = "_forever_",
  [string]$AddOnsDir
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "lib\WowPath.ps1")
if (-not $AddOnsDir) {
  try { $AddOnsDir = Join-Path (Resolve-WowFlavorPath -WowPath $WowPath -Flavor $Flavor) "Interface\AddOns" }
  catch { Write-Host $_.Exception.Message -ForegroundColor Red; exit 1 }
}
$wow = Get-WowProcessFor $AddOnsDir
if ($wow -and -not $WhatIfPreference) { Write-Warning "WoW is running. Close it first; nothing was changed."; exit 1 }
if (-not (Test-Path -LiteralPath $AddOnsDir -PathType Container)) { Write-Error "AddOns folder not found: $AddOnsDir"; exit 1 }

$owned = Get-ChildItem -LiteralPath $AddOnsDir -Directory |
  Where-Object { $_.Name -match '^T3Bridge(_Live|_S\d{4}|_T[AB]\d{2}|_Img|_ImgT)?$' }
if (-not $owned) { Write-Host "Nothing to remove."; exit 0 }
if ($PSCmdlet.ShouldProcess($AddOnsDir, "Remove $($owned.Count) T3Bridge folders")) {
  $owned | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force }
  Write-Host "Removed $($owned.Count) folders."
}

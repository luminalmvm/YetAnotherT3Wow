<#
.SYNOPSIS
  Copies changed T3Bridge addon files into the installed addon so a /reload in game picks them up.
  Safe to run while WoW is running.

.DESCRIPTION
  Compares addon\T3Bridge\ (without test\ and the companion-owned Inbox.lua) with
  <AddOns>\T3Bridge\ by SHA-256 and copies ONLY files that already exist there and changed.

  While Wow.exe is running it refuses to copy:
    - new files (the client lists addon files at start-up; a file created later is not seen), and
    - .toc changes (the TOC is read at start-up),
  and lists them as "needs a full restart of WoW" instead. With WoW closed, those are copied too
  (scripts\install-addon.ps1 remains the full installer).

  Image slots (T3Bridge_Img, PROTOCOL rev 1.3): if the folder is missing (an install from before
  images), it is created with -ImageSlots slots while WoW is closed; while WoW runs it is reported
  as "needs a full restart". Existing image slots are left alone.

  It never deletes anything, never touches other addons, the T3Bridge_* link slot folders, live.lua,
  Inbox.lua, or SavedVariables.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts\sync-addon.ps1 -WhatIf
  powershell -ExecutionPolicy Bypass -File scripts\sync-addon.ps1
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [string]$WowPath,
  [string]$Flavor = "_forever_",
  [string]$AddOnsDir,
  [ValidateRange(0, 2000)][int]$ImageSlots = 100
)
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "lib\WowPath.ps1")
. (Join-Path $PSScriptRoot "lib\ImageSlots.ps1")
if (-not $AddOnsDir) {
  try { $AddOnsDir = Join-Path (Resolve-WowFlavorPath -WowPath $WowPath -Flavor $Flavor) "Interface\AddOns" }
  catch { Write-Host $_.Exception.Message -ForegroundColor Red; exit 1 }
}
$Repo = Split-Path -Parent $PSScriptRoot
$Source = Join-Path $Repo "addon\T3Bridge"
$Target = Join-Path $AddOnsDir "T3Bridge"

if (-not (Test-Path -LiteralPath $Target -PathType Container)) {
  Write-Host "Installed addon not found: $Target. Close WoW and run scripts\install-addon.ps1 first." -ForegroundColor Red
  exit 1
}
$Source = (Resolve-Path -LiteralPath $Source).Path
$Target = (Resolve-Path -LiteralPath $Target).Path
$wowRunning = [bool](Get-WowProcessFor $AddOnsDir)
Write-Host "Source: $Source"
Write-Host "Target: $Target"
Write-Host ("WoW is " + ($(if ($wowRunning) { "RUNNING: only changed existing files are copied" } else { "not running" })))

# SHA-256 via .NET (Get-FileHash honours -WhatIf and would return nothing in a dry run).
function Get-Sha256([string]$Path) {
  $s = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
  try { return [BitConverter]::ToString([System.Security.Cryptography.SHA256]::Create().ComputeHash($s)) } finally { $s.Close() }
}

$copied = @(); $restart = @(); $unchanged = 0
$files = Get-ChildItem -LiteralPath $Source -Recurse -File | Where-Object {
  $rel = $_.FullName.Substring($Source.Length + 1)
  $rel -notmatch '^test\\' -and $rel -ne 'Inbox.lua'
}
foreach ($f in $files) {
  $rel = $f.FullName.Substring($Source.Length + 1)
  $dest = Join-Path $Target $rel
  $exists = Test-Path -LiteralPath $dest -PathType Leaf
  if ($exists -and (Get-Sha256 $f.FullName) -eq (Get-Sha256 $dest)) {
    $unchanged++
    continue
  }
  $isToc = $rel -like '*.toc'
  if ($wowRunning -and (-not $exists -or $isToc)) {
    $restart += $(if ($exists) { "$rel (changed TOC)" } else { "$rel (new file)" })
    continue
  }
  if ($PSCmdlet.ShouldProcess($dest, "Copy $rel")) {
    $dir = Split-Path -Parent $dest
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    Copy-Item -LiteralPath $f.FullName -Destination $dest -Force
  }
  $copied += $rel
}

# Image slots (rev 1.3): a new folder of new files, so only with WoW closed.
$imgHave = Get-T3BImageSlotCount $AddOnsDir
$imgCreated = 0
if ($imgHave -eq 0 -and $ImageSlots -gt 0) {
  if ($wowRunning) {
    $restart += "T3Bridge_Img ($ImageSlots image slots, new folder)"
  } elseif ($PSCmdlet.ShouldProcess("$AddOnsDir\T3Bridge_Img", "Create $ImageSlots image slots")) {
    $tocLine = Select-String -LiteralPath (Join-Path $Source "T3Bridge.toc") -Pattern '^## Interface:\s*(\d+)' | Select-Object -First 1
    $iface = $(if ($tocLine) { $tocLine.Matches[0].Groups[1].Value } else { "16001" })
    $imgCreated = Install-T3BImageSlots -AddOnsDir $AddOnsDir -Count $ImageSlots -Interface $iface
  } else { $imgCreated = $ImageSlots }
}

# Files only in the installed copy are reported, never deleted.
$extra = Get-ChildItem -LiteralPath $Target -Recurse -File | ForEach-Object { $_.FullName.Substring($Target.Length + 1) } |
  Where-Object { $_ -ne 'Inbox.lua' -and -not (Test-Path -LiteralPath (Join-Path $Source $_)) }

Write-Host ""
$verb = $(if ($WhatIfPreference) { "Would copy" } else { "Copied" })
if ($copied.Count) { Write-Host "$verb ($($copied.Count)):" -ForegroundColor Green; $copied | ForEach-Object { Write-Host "  $_" } }
else { Write-Host "Nothing to copy." }
Write-Host "Unchanged: $unchanged"
if ($imgCreated -gt 0) { Write-Host ("$(if ($WhatIfPreference) { 'Would create' } else { 'Created' }) $imgCreated image slots in T3Bridge_Img (~" + [Math]::Round($imgCreated * 1048594 / 1MB) + " MB)") -ForegroundColor Green }
elseif ($imgHave -gt 0) { Write-Host "Image slots: $imgHave installed" }
if ($extra) { Write-Host "Only in the installed copy (left alone):"; $extra | ForEach-Object { Write-Host "  $_" } }
if ($restart.Count) {
  Write-Host ""
  Write-Host "Needs a full restart of WoW (not copied while WoW runs):" -ForegroundColor Yellow
  $restart | ForEach-Object { Write-Host "  $_" }
  Write-Host "  -> Exit WoW, run scripts\sync-addon.ps1 (or install-addon.ps1) again, then start WoW."
  Write-Host "     Then in game: /t3 spike img (checks the image slots)."
}
Write-Host ""
if ($copied.Count -and $wowRunning -and -not $WhatIfPreference) { Write-Host "In WoW, type  /reload  and press Enter to load the copied files." -ForegroundColor Cyan }

<#
.SYNOPSIS
  Installs the T3Bridge WoW addon, its load-on-demand link slots and the spike slots.

.DESCRIPTION
  Copies addon\T3Bridge into <WoW dir>\<flavour>\Interface\AddOns and creates:
    T3Bridge_Live\live.lua      shared snapshot file (padded to 524288 bytes), written by the companion
    T3Bridge_Live\spike.lua     small test file for /t3 spike s1 (rewritten by scripts\dev\set-live-file.ps1 -Spike)
    T3Bridge_S0001..S<N>        link slots, variant A (TOC points at ..\T3Bridge_Live\live.lua)
                                or variant B (each slot has live.lua = NTFS hard link to the shared file)
    T3Bridge_TA01..             spike slots, variant A  (used only by /t3 spike s1)
    T3Bridge_TB01..             spike slots, variant B  (used only by /t3 spike s1)
    T3Bridge_Img\i0001..i<M>.tga  image slots for pictures in chat (512x512 transparent TGAs, ~1 MB each)
                                plus s1..s3.tga swatches for /t3 spike img
    T3Bridge_ImgT\t1.tga        one spike swatch in a folder with a TOC

  The WoW folder is found automatically (see scripts\lib\WowPath.ps1: -WowPath, $env:T3B_WOW_PATH,
  the companion config, the Blizzard registry keys, Battle.net.config, then a search of common
  folders on every fixed drive). Pass -WowPath if it is not found.

  Refuses to change anything while WoW is running (WoW only sees new files when it starts).
  Only touches folders named T3Bridge, T3Bridge_Live, T3Bridge_S####, T3Bridge_TA##, T3Bridge_TB##,
  T3Bridge_Img and T3Bridge_ImgT.
  Never touches other addons, WTF\ or SavedVariables.
  T3Bridge\Inbox.lua and T3Bridge_Live\live.lua are kept if they already exist (the companion owns them).

.PARAMETER WowPath
  The WoW flavour folder (the one that contains Interface\AddOns, e.g. "<WoW dir>\_forever_"),
  or the World of Warcraft folder that contains it. Auto-detected when omitted.
.PARAMETER Flavor
  Flavour subfolder name. Default _forever_ (WoW Forever, the only tested client).
.PARAMETER AddOnsDir
  Advanced: install into this AddOns folder directly (skips detection).
.PARAMETER Interface
  Interface number written into the slot TOCs. Default: the value in addon\T3Bridge\T3Bridge.toc.
.PARAMETER ImageSlots
  Number of image slots (default 100, about 105 MB; 0 = no inline images, attachments still work).
  Each slot shows one image per WoW session; restarting WoW frees them all.
.PARAMETER ImageToc
  Also give T3Bridge_Img a TOC (only if /t3 spike img showed that textures need one).

.EXAMPLE
  .\install-addon.ps1 -WhatIf
  .\install-addon.ps1                                   # auto-detect, variant B, 500 slots
  .\install-addon.ps1 -WowPath "<drive>:\World of Warcraft\_forever_"
  .\install-addon.ps1 -Variant A -Slots 2000
  .\install-addon.ps1 -ImageSlots 200                   # more images per WoW session
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [string]$WowPath,
  [string]$Flavor = "_forever_",
  [string]$AddOnsDir,
  [ValidateSet("A", "B")][string]$Variant = "B",
  [ValidateRange(1, 2000)][int]$Slots = 500,
  [ValidateRange(0, 99)][int]$SpikeSlots = 24,
  [int]$LiveFileSize = 524288,
  [string]$Interface,
  [ValidateRange(0, 2000)][int]$ImageSlots = 100,
  [switch]$ImageToc
)

$ErrorActionPreference = "Stop"
$utf8 = New-Object System.Text.UTF8Encoding $false
$source = Join-Path $PSScriptRoot "..\addon\T3Bridge" | Resolve-Path | Select-Object -ExpandProperty Path
. (Join-Path $PSScriptRoot "lib\WowPath.ps1")
. (Join-Path $PSScriptRoot "lib\ImageSlots.ps1")
if (-not $Interface) {
  $tocLine = Select-String -LiteralPath (Join-Path $source "T3Bridge.toc") -Pattern '^## Interface:\s*(\d+)' | Select-Object -First 1
  $Interface = $(if ($tocLine) { $tocLine.Matches[0].Groups[1].Value } else { "16001" })
}

function Write-Text([string]$Path, [string]$Text) { [System.IO.File]::WriteAllText($Path, $Text, $utf8) }

# --- safety checks -----------------------------------------------------------------------------
if (-not $AddOnsDir) {
  try { $flavorDir = Resolve-WowFlavorPath -WowPath $WowPath -Flavor $Flavor }
  catch { Write-Host $_.Exception.Message -ForegroundColor Red; exit 1 }
  $AddOnsDir = Join-Path $flavorDir "Interface\AddOns"
  if (-not (Test-Path -LiteralPath $AddOnsDir -PathType Container)) {
    if ($PSCmdlet.ShouldProcess($AddOnsDir, "Create AddOns folder")) { New-Item -ItemType Directory -Path $AddOnsDir -Force | Out-Null }
  }
}
if (-not $WhatIfPreference -and -not (Test-Path -LiteralPath $AddOnsDir -PathType Container)) {
  Write-Error "AddOns folder not found: $AddOnsDir"
  exit 1
}
if (Test-Path -LiteralPath $AddOnsDir) { $AddOnsDir = (Resolve-Path -LiteralPath $AddOnsDir).Path }
# WoW only sees addon files that existed when it started, so never change a folder a running client uses.
$wow = Get-WowProcessFor $AddOnsDir
if ($wow) {
  if ($WhatIfPreference) {
    Write-Warning "WoW is running from this folder. A real install would refuse to run now (dry run continues)."
  } else {
    Write-Warning ("WoW is running (" + (($wow | ForEach-Object { $_.Name }) -join ", ") + "). Close it first; nothing was changed.")
    exit 1
  }
}
Write-Host "AddOns: $AddOnsDir"
Write-Host "Source: $source"
Write-Host "Variant $Variant, $Slots link slots, $SpikeSlots spike slots per variant, $ImageSlots image slots, interface $Interface"

# --- fast hard links ---------------------------------------------------------------------------
if (-not ("T3B.Native" -as [type])) {
  Add-Type -Namespace T3B -Name Native -MemberDefinition @"
[System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode, SetLastError = true)]
public static extern bool CreateHardLink(string lpFileName, string lpExistingFileName, System.IntPtr lpSecurityAttributes);
"@
}
function New-HardLink([string]$Link, [string]$Target) {
  if (-not [T3B.Native]::CreateHardLink($Link, $Target, [IntPtr]::Zero)) {
    New-Item -ItemType HardLink -Path $Link -Target $Target | Out-Null
  }
}

function Remove-OwnedFolders([string]$Pattern, [string]$Regex) {
  Get-ChildItem -LiteralPath $AddOnsDir -Directory -Filter $Pattern |
    Where-Object { $_.Name -match $Regex } |
    ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force }
}

function Slot-Toc([string]$Title, [int]$Number, [string]$FileLine) {
  return "## Interface: $Interface`r`n## Title: $Title`r`n## Notes: Link slot used by T3Bridge. Leave enabled.`r`n## LoadOnDemand: 1`r`n## Dependencies: T3Bridge`r`n## Group: T3Bridge`r`n## X-T3Bridge-Slot: $Number`r`n$FileLine`r`n"
}

# --- 1. main addon -----------------------------------------------------------------------------
$target = Join-Path $AddOnsDir "T3Bridge"
if ($PSCmdlet.ShouldProcess($target, "Install T3Bridge addon files (keeps an existing Inbox.lua)")) {
  $inbox = Join-Path $target "Inbox.lua"
  $keepInbox = $null
  if (Test-Path -LiteralPath $inbox) { $keepInbox = [System.IO.File]::ReadAllBytes($inbox) }
  if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
  New-Item -ItemType Directory -Path $target | Out-Null
  Get-ChildItem -LiteralPath $source -Recurse -File |
    Where-Object { $_.FullName -notmatch '\\test\\' } |
    ForEach-Object {
      $rel = $_.FullName.Substring($source.Length).TrimStart('\')
      $dest = Join-Path $target $rel
      $dir = Split-Path $dest -Parent
      if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
      Copy-Item -LiteralPath $_.FullName -Destination $dest
    }
  if ($keepInbox) { [System.IO.File]::WriteAllBytes($inbox, $keepInbox) }
  Write-Host "  installed T3Bridge"
}

# --- 2. shared live + spike files --------------------------------------------------------------
$liveDir = Join-Path $AddOnsDir "T3Bridge_Live"
$live = Join-Path $liveDir "live.lua"
$spike = Join-Path $liveDir "spike.lua"
if ($PSCmdlet.ShouldProcess($liveDir, "Create shared live.lua (if missing) and reset spike.lua")) {
  if (-not (Test-Path -LiteralPath $liveDir)) { New-Item -ItemType Directory -Path $liveDir | Out-Null }
  if (-not (Test-Path -LiteralPath $live)) {
    $head = "-- T3Bridge live snapshot. The companion rewrites this file in place (PROTOCOL.md section 2.3).`n"
    $bytes = New-Object byte[] $LiveFileSize
    for ($i = 0; $i -lt $bytes.Length; $i++) { $bytes[$i] = 0x20 }
    $hb = $utf8.GetBytes($head)
    [Array]::Copy($hb, $bytes, $hb.Length)
    [System.IO.File]::WriteAllBytes($live, $bytes)
    Write-Host "  created live.lua ($LiveFileSize bytes)"
  } else {
    Write-Host "  kept existing live.lua"
  }
  Write-Text $spike "-- T3Bridge spike file (set-live-file.ps1 -Spike rewrites it)`nT3B_SPIKE={seq=0,size=120}`nT3B_SPIKE_TAIL=0`n"
  Write-Host "  reset spike.lua (small on purpose: S1 checks that it can grow after login)"
}

# --- 3. link slots -----------------------------------------------------------------------------
if ($PSCmdlet.ShouldProcess("$AddOnsDir\T3Bridge_S0001..S$('{0:D4}' -f $Slots)", "Recreate $Slots link slots (variant $Variant)")) {
  Remove-OwnedFolders "T3Bridge_S*" '^T3Bridge_S\d{4}$'
  for ($n = 1; $n -le $Slots; $n++) {
    $name = "T3Bridge_S{0:D4}" -f $n
    $dir = Join-Path $AddOnsDir $name
    New-Item -ItemType Directory -Path $dir | Out-Null
    if ($Variant -eq "A") {
      Write-Text (Join-Path $dir "$name.toc") (Slot-Toc ("T3Bridge slot {0:D4}" -f $n) $n "..\T3Bridge_Live\live.lua")
    } else {
      Write-Text (Join-Path $dir "$name.toc") (Slot-Toc ("T3Bridge slot {0:D4}" -f $n) $n "live.lua")
      New-HardLink (Join-Path $dir "live.lua") $live
    }
  }
  Write-Host "  created $Slots link slots (variant $Variant)"
}

# --- 4. spike slots ----------------------------------------------------------------------------
if ($SpikeSlots -gt 0 -and $PSCmdlet.ShouldProcess("$AddOnsDir\T3Bridge_TA##, T3Bridge_TB##", "Recreate $SpikeSlots spike slots per variant")) {
  Remove-OwnedFolders "T3Bridge_T*" '^T3Bridge_T[AB]\d{2}$'
  for ($n = 1; $n -le $SpikeSlots; $n++) {
    $a = "T3Bridge_TA{0:D2}" -f $n
    $dirA = Join-Path $AddOnsDir $a
    New-Item -ItemType Directory -Path $dirA | Out-Null
    Write-Text (Join-Path $dirA "$a.toc") (Slot-Toc ("T3Bridge spike A{0:D2}" -f $n) $n "..\T3Bridge_Live\spike.lua")
    $b = "T3Bridge_TB{0:D2}" -f $n
    $dirB = Join-Path $AddOnsDir $b
    New-Item -ItemType Directory -Path $dirB | Out-Null
    Write-Text (Join-Path $dirB "$b.toc") (Slot-Toc ("T3Bridge spike B{0:D2}" -f $n) $n "spike.lua")
    New-HardLink (Join-Path $dirB "spike.lua") $spike
  }
  Write-Host "  created $SpikeSlots spike slots per variant"
}

# --- 5. image slots (PROTOCOL rev 1.3) ---------------------------------------------------------
$imgMb = [Math]::Round($ImageSlots * 1048594 / 1e6)
$imgWhat = $(if ($ImageSlots -gt 0) { "Recreate $ImageSlots transparent image slots (~$imgMb MB) and the spike swatches" } else { "Remove the image slot folders" })
if ($PSCmdlet.ShouldProcess("$AddOnsDir\T3Bridge_Img, T3Bridge_ImgT", $imgWhat)) {
  $n = Install-T3BImageSlots -AddOnsDir $AddOnsDir -Count $ImageSlots -Toc:$ImageToc -Interface $Interface
  if ($n -gt 0) { Write-Host "  created $n image slots (~$imgMb MB)$(if ($ImageToc) { ' with a TOC' })" } else { Write-Host "  no image slots (images show as text; attaching still works)" }
}

if (-not $WhatIfPreference) {
  # sanity check: a hard link and the shared file must be the same file
  if ($Variant -eq "B") {
    $probe = Join-Path $AddOnsDir "T3Bridge_S0001\live.lua"
    $same = (Get-Item -LiteralPath $probe).Length -eq (Get-Item -LiteralPath $live).Length
    Write-Host ("  hard link check: " + $(if ($same) { "ok" } else { "MISMATCH" }))
  }
  Write-Host "Done. Start WoW, log in, type /t3 demo (no companion needed). Then start the bridge: scripts\start-bridge.ps1"
  if ($ImageSlots -gt 0) { Write-Host "Images: in game run /t3 spike img once to check that image slots work on your client." }
}

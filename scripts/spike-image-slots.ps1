<#
.SYNOPSIS
  Writes test colours into the image slot swatches while WoW runs, for the in-game check /t3 spike img.

.DESCRIPTION
  Image slots (PROTOCOL rev 1.3) rely on one thing only the real client can answer: a texture file that
  existed when WoW started, overwritten in place after login and never loaded before, shows the NEW
  content when the addon loads it. This script and /t3 spike img check that, and a few related facts.

  In game, in this order:
    1. /t3 spike img           shows swatch s2 (loads it into the texture cache)
    2. this script             (WoW keeps running)  writes:
                                 s1 = RED      never loaded before -> must show RED (required)
                                 s2 = GREEN    already loaded      -> GREY means "cached" (expected)
                                 s3 = blue 256x128 with a white square top-left (orientation and crop)
                                 n1 = CYAN     a NEW file created now -> should stay empty
                                 t1 = RED      in T3Bridge_ImgT, a folder with a TOC
    3. /t3 spike img 2         shows all swatches with the colour each should have, and the load time
       then /t3 spike img ok   (s1 red) or /t3 spike img fail
  Optional /reload test:
    4. this script -Step 2     writes s1 and s2 YELLOW (both already loaded)
    5. /reload, then /t3 spike img 3: YELLOW = /reload frees cached textures
       then /t3 spike img reload yes|no

  Only touches the swatch files in T3Bridge_Img and T3Bridge_ImgT (overwritten in place at the same
  size) and creates T3Bridge_Img\n1.tga (on purpose: the "new file" test; the installer removes it).
  The image slots i0001.. are never touched.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts\spike-image-slots.ps1
  powershell -ExecutionPolicy Bypass -File scripts\spike-image-slots.ps1 -Step 2
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [ValidateSet(1, 2)][int]$Step = 1,
  [string]$WowPath,
  [string]$Flavor = "_forever_",
  [string]$AddOnsDir
)
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "lib\WowPath.ps1")
. (Join-Path $PSScriptRoot "lib\ImageSlots.ps1")
if (-not $AddOnsDir) {
  try { $AddOnsDir = Join-Path (Resolve-WowFlavorPath -WowPath $WowPath -Flavor $Flavor) "Interface\AddOns" }
  catch { Write-Host $_.Exception.Message -ForegroundColor Red; exit 1 }
}
$dir = Join-Path $AddOnsDir "T3Bridge_Img"
$tdir = Join-Path $AddOnsDir "T3Bridge_ImgT"
$swatches = @((Join-Path $dir "s1.tga"), (Join-Path $dir "s2.tga"), (Join-Path $dir "s3.tga"), (Join-Path $tdir "t1.tga"))
foreach ($f in $swatches) {
  if (-not (Test-Path -LiteralPath $f -PathType Leaf) -or (Get-Item -LiteralPath $f).Length -ne 1048594) {
    Write-Host "Swatch missing or wrong size: $f" -ForegroundColor Red
    Write-Host "Close WoW and run scripts\install-addon.ps1 (or scripts\sync-addon.ps1), then start WoW and try again."
    exit 1
  }
}
if (-not (Get-WowProcessFor $AddOnsDir)) {
  Write-Warning "WoW is not running from this folder. The test only means something while WoW runs (after /t3 spike img)."
}

$red = New-T3BSolidBytes 230 30 30
if ($Step -eq 1) {
  if ($PSCmdlet.ShouldProcess($dir, "Write s1 RED, s2 GREEN, s3 pattern, t1 RED (in place) and create n1.tga CYAN")) {
    Write-T3BInPlace (Join-Path $dir "s1.tga") $red
    Write-T3BInPlace (Join-Path $dir "s2.tga") (New-T3BSolidBytes 40 200 60)
    Write-T3BInPlace (Join-Path $dir "s3.tga") (New-T3BPatternBytes)
    Write-T3BInPlace (Join-Path $tdir "t1.tga") $red
    [System.IO.File]::WriteAllBytes((Join-Path $dir "n1.tga"), (New-T3BSolidBytes 30 220 230))
    Write-Host "Wrote the step 1 colours." -ForegroundColor Green
    Write-Host "In WoW type:  /t3 spike img 2" -ForegroundColor Cyan
  }
} else {
  if ($PSCmdlet.ShouldProcess($dir, "Write s1 and s2 YELLOW (in place)")) {
    $yellow = New-T3BSolidBytes 240 210 30
    Write-T3BInPlace (Join-Path $dir "s1.tga") $yellow
    Write-T3BInPlace (Join-Path $dir "s2.tga") $yellow
    Write-Host "Wrote the step 2 colours." -ForegroundColor Green
    Write-Host "In WoW type:  /reload   and then   /t3 spike img 3" -ForegroundColor Cyan
  }
}

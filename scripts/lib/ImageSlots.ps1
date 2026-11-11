# Image slot textures for in-game images (PROTOCOL rev 1.3, D16). Dot-source this file.
#
# <AddOns>\T3Bridge_Img\i0001.tga .. iNNNN.tga   slots the companion fills with images (transparent at install)
# <AddOns>\T3Bridge_Img\s1.tga .. s3.tga          swatches for /t3 spike img (grey at install)
# <AddOns>\T3Bridge_ImgT\t1.tga + TOC             one swatch in a folder WITH a TOC (does the client need one?)
#
# Every file is a 512x512, 32-bit uncompressed TGA with alpha and a bottom-left origin: 18 + 512*512*4 =
# 1,048,594 bytes (the same layout as the shipped icon.tga). WoW only sees files that existed when it started,
# so these are created with WoW closed and afterwards only ever overwritten in place at the same size.

$script:T3BImgCanvas = 512
$script:T3BImgBytes = 18 + 512 * 512 * 4

function Get-T3BTgaHeader {
  $h = New-Object byte[] 18
  $h[2] = 2                     # uncompressed true colour
  $h[12] = 0; $h[13] = 2        # width 512 (LE)
  $h[14] = 0; $h[15] = 2        # height 512 (LE)
  $h[16] = 32                   # bits per pixel
  $h[17] = 8                    # 8 alpha bits, bottom-left origin
  return ,$h
}

function New-T3BSlotBytes {
  # Transparent canvas (all pixel bytes 0).
  $b = New-Object byte[] $script:T3BImgBytes
  [Array]::Copy((Get-T3BTgaHeader), $b, 18)
  return ,$b
}

function Set-T3BFill([byte[]]$Buf, [int]$Offset, [int]$Count, [byte[]]$Pattern) {
  # Fills Buf[Offset .. Offset+Count) with Pattern repeated (Count is a multiple of the pattern length).
  if ($Count -le 0) { return }
  [Array]::Copy($Pattern, 0, $Buf, $Offset, [Math]::Min($Pattern.Length, $Count))
  $done = $Pattern.Length
  while ($done -lt $Count) {
    $n = [Math]::Min($done, $Count - $done)
    [Array]::Copy($Buf, $Offset, $Buf, $Offset + $done, $n)
    $done += $n
  }
}

function New-T3BSolidBytes([byte]$R, [byte]$G, [byte]$B, [byte]$A = 255) {
  $buf = New-T3BSlotBytes
  Set-T3BFill $buf 18 ($script:T3BImgBytes - 18) ([byte[]]@($B, $G, $R, $A))
  return ,$buf
}

function New-T3BPatternBytes {
  # Orientation/crop test (swatch s3): a 256x128 image in the TOP-LEFT of the canvas, blue with a white
  # 32x32 square in its own top-left corner; the rest of the canvas is transparent. The addon shows it
  # with SetTexCoord(0, 256/512, 0, 128/512): the white square must appear at the top-left.
  $buf = New-T3BSlotBytes
  $blue = [byte[]]@(200, 60, 20, 255)     # BGRA
  $white = [byte[]]@(255, 255, 255, 255)
  for ($y = 0; $y -lt 128; $y++) {
    $row = 18 + (511 - $y) * 512 * 4        # image row y is file row 511-y (bottom-up)
    Set-T3BFill $buf $row (256 * 4) $blue
    if ($y -lt 32) { Set-T3BFill $buf $row (32 * 4) $white }
  }
  return ,$buf
}

function Write-T3BInPlace([string]$Path, [byte[]]$Bytes) {
  # Overwrite an existing file at offset 0 without creating, truncating or renaming it.
  $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
  try { $fs.Write($Bytes, 0, $Bytes.Length) } finally { $fs.Close() }
}

function Get-T3BImageSlotCount([string]$AddOnsDir) {
  # Number of consecutive valid slots i0001.. (0 = not installed).
  $dir = Join-Path $AddOnsDir "T3Bridge_Img"
  if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return 0 }
  $n = 0
  while ($true) {
    $f = Join-Path $dir ("i{0:D4}.tga" -f ($n + 1))
    if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { break }
    if ((Get-Item -LiteralPath $f).Length -ne $script:T3BImgBytes) { break }
    $n++
  }
  return $n
}

function Install-T3BImageSlots {
  # Creates (or recreates) the image slot folder with WoW closed. Count 0 removes the folders.
  param([Parameter(Mandatory = $true)][string]$AddOnsDir, [int]$Count = 100, [switch]$Toc, [string]$Interface = "16001")
  $dir = Join-Path $AddOnsDir "T3Bridge_Img"
  $tdir = Join-Path $AddOnsDir "T3Bridge_ImgT"
  if ($Count -le 0) {
    foreach ($d in @($dir, $tdir)) { if (Test-Path -LiteralPath $d) { Remove-Item -LiteralPath $d -Recurse -Force } }
    return 0
  }
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
  # Slots beyond the requested count, and the spike's "new file" n1.tga, are removed.
  Get-ChildItem -LiteralPath $dir -File | Where-Object {
    ($_.Name -match '^i(\d{4})\.tga$' -and [int]$Matches[1] -gt $Count) -or $_.Name -eq 'n1.tga'
  } | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force }
  $blank = New-T3BSlotBytes
  for ($n = 1; $n -le $Count; $n++) {
    [System.IO.File]::WriteAllBytes((Join-Path $dir ("i{0:D4}.tga" -f $n)), $blank)
  }
  $grey = New-T3BSolidBytes 128 128 128
  foreach ($s in @("s1", "s2", "s3")) { [System.IO.File]::WriteAllBytes((Join-Path $dir "$s.tga"), $grey) }
  $tocPath = Join-Path $dir "T3Bridge_Img.toc"
  if ($Toc) {
    [System.IO.File]::WriteAllText($tocPath, "## Interface: $Interface`r`n## Title: T3Bridge images`r`n## Notes: Image textures for T3Bridge. Nothing to load.`r`n## LoadOnDemand: 1`r`n## Dependencies: T3Bridge`r`n## Group: T3Bridge`r`n")
  } elseif (Test-Path -LiteralPath $tocPath) { Remove-Item -LiteralPath $tocPath -Force }
  # A folder with a TOC, for the spike's comparison.
  if (-not (Test-Path -LiteralPath $tdir)) { New-Item -ItemType Directory -Path $tdir | Out-Null }
  [System.IO.File]::WriteAllBytes((Join-Path $tdir "t1.tga"), $grey)
  [System.IO.File]::WriteAllText((Join-Path $tdir "T3Bridge_ImgT.toc"), "## Interface: $Interface`r`n## Title: T3Bridge image test`r`n## Notes: One test texture for /t3 spike img. Nothing to load.`r`n## LoadOnDemand: 1`r`n## Dependencies: T3Bridge`r`n## Group: T3Bridge`r`n")
  return $Count
}

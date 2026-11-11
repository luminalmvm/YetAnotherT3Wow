<#
  Shared helper, dot-sourced by the T3Bridge scripts:  . (Join-Path $PSScriptRoot "lib\WowPath.ps1")

  Resolve-WowFlavorPath returns the folder of one WoW flavour (the folder that holds Interface\AddOns,
  for example "<WoW dir>\_forever_"). Order:
    1. -WowPath as given. It may be the flavour folder itself or the WoW root that contains it.
    2. $env:T3B_WOW_PATH
    3. "wowRoot" in the companion config (%LOCALAPPDATA%\T3Bridge\config.json), if it exists
    4. Blizzard registry keys (InstallPath / InstallLocation)
    5. Battle.net.config (DefaultInstallPath)
    6. A search for "World of Warcraft\.build.info" in common folders on every fixed drive
  It throws with a clear message when nothing is found.
#>

function Test-WowFlavorFolder([string]$Path) {
  if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Container)) { return $false }
  foreach ($probe in @("Interface", "WTF", ".flavor.info", "Wow.exe", "WowClassic.exe")) {
    if (Test-Path -LiteralPath (Join-Path $Path $probe)) { return $true }
  }
  return $false
}

function ConvertTo-WowFlavorPath([string]$Path, [string]$Flavor) {
  # Accepts the flavour folder, the WoW root, or a path inside a flavour folder (e.g. ...\_retail_\).
  if (-not $Path) { return $null }
  $Path = $Path.Trim().Trim('"').TrimEnd('\', '/')
  if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $null }
  $leaf = Split-Path -Leaf $Path
  if ($leaf -ieq $Flavor -and (Test-WowFlavorFolder $Path)) { return (Resolve-Path -LiteralPath $Path).Path }
  $child = Join-Path $Path $Flavor
  if (Test-WowFlavorFolder $child) { return (Resolve-Path -LiteralPath $child).Path }
  # A path to another flavour (e.g. the registry's ...\_retail_): try its sibling.
  if ($leaf -match '^_.+_$') {
    $sibling = Join-Path (Split-Path -Parent $Path) $Flavor
    if (Test-WowFlavorFolder $sibling) { return (Resolve-Path -LiteralPath $sibling).Path }
  }
  return $null
}

function Get-WowRootCandidates {
  $out = New-Object System.Collections.Generic.List[string]
  # Registry (64-bit and 32-bit views).
  $keys = @(
    "HKLM:\SOFTWARE\WOW6432Node\Blizzard Entertainment\World of Warcraft",
    "HKLM:\SOFTWARE\Blizzard Entertainment\World of Warcraft",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\World of Warcraft",
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\World of Warcraft"
  )
  foreach ($k in $keys) {
    try {
      $item = Get-ItemProperty -LiteralPath $k -ErrorAction Stop
      foreach ($name in @("InstallPath", "InstallLocation", "GamePath")) {
        $v = $item.$name
        if ($v) { $out.Add([string]$v) }
      }
    } catch { }
  }
  # Battle.net launcher config.
  $bnet = Join-Path $env:APPDATA "Battle.net\Battle.net.config"
  if (Test-Path -LiteralPath $bnet) {
    try {
      $j = Get-Content -LiteralPath $bnet -Raw | ConvertFrom-Json
      $def = $j.Client.Install.DefaultInstallPath
      if ($def) { $out.Add((Join-Path ($def -replace '/', '\') "World of Warcraft")) }
    } catch { }
  }
  # Common folders on every fixed drive.
  $drives = @()
  try { $drives = [System.IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady } | ForEach-Object { $_.RootDirectory.FullName } } catch { }
  foreach ($d in $drives) {
    foreach ($rel in @("World of Warcraft", "Program Files (x86)\World of Warcraft", "Program Files\World of Warcraft",
                       "Games\World of Warcraft", "Blizzard\World of Warcraft", "Battle.net\World of Warcraft")) {
      $root = Join-Path $d $rel
      if (Test-Path -LiteralPath (Join-Path $root ".build.info")) { $out.Add($root) }
    }
  }
  return $out
}

function Get-WowProcessFor([string]$AddOnsDir) {
  # Running WoW clients that use this AddOns folder. A process whose path cannot be read counts too.
  $flavor = $null
  try { $flavor = [System.IO.Path]::GetFullPath((Join-Path $AddOnsDir "..\..")).TrimEnd('\') } catch { }
  Get-Process -Name "Wow*" -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -notmatch "VoiceProxy" } | Where-Object {
    $exe = $null
    try { $exe = $_.Path } catch { }
    if (-not $exe -or -not $flavor) { return $true }
    return ((Split-Path -Parent $exe).TrimEnd('\') -ieq $flavor)
  }
}

function Resolve-WowFlavorPath {
  param([string]$WowPath, [string]$Flavor = "_forever_")
  if ($WowPath) {
    $r = ConvertTo-WowFlavorPath $WowPath $Flavor
    if ($r) { return $r }
    # An explicit flavour folder with another name (e.g. _classic_era_) is taken as given.
    $p = $WowPath.Trim().Trim('"').TrimEnd('\', '/')
    if ((Test-WowFlavorFolder $p) -and -not (Test-Path -LiteralPath (Join-Path $p ".build.info"))) { return (Resolve-Path -LiteralPath $p).Path }
    throw "WoW folder not found at -WowPath '$WowPath'. Pass the folder that contains Interface\AddOns (for example '<WoW dir>\$Flavor') or the World of Warcraft folder that contains '$Flavor'."
  }
  if ($env:T3B_WOW_PATH) {
    $r = ConvertTo-WowFlavorPath $env:T3B_WOW_PATH $Flavor
    if ($r) { return $r }
  }
  $cfg = Join-Path $env:LOCALAPPDATA "T3Bridge\config.json"
  if (Test-Path -LiteralPath $cfg) {
    try {
      $c = Get-Content -LiteralPath $cfg -Raw | ConvertFrom-Json
      if ($c.wowRoot) { $r = ConvertTo-WowFlavorPath $c.wowRoot $Flavor; if ($r) { return $r } }
    } catch { }
  }
  foreach ($cand in (Get-WowRootCandidates)) {
    $r = ConvertTo-WowFlavorPath $cand $Flavor
    if ($r) { return $r }
  }
  throw ("Could not find World of Warcraft ($Flavor). Pass it explicitly, for example:`n" +
         "  -WowPath `"<drive>:\World of Warcraft\$Flavor`"`n" +
         "(the folder that contains Interface\AddOns), or set the T3B_WOW_PATH environment variable.")
}

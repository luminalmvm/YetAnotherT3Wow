<#
.SYNOPSIS
  Builds and installs the T3Bridge companion. Does NOT touch the WoW AddOns folder
  (the addon and its live.lua/slot files are installed by scripts\install-addon.ps1).

.DESCRIPTION
  1. Checks Node >= 22 and the .NET SDK.
  2. Builds companion/ (npm install + tsc) and capture-helper/T3Capture (dotnet build -c Release),
     and copies the helper to %LOCALAPPDATA%\T3Bridge\capture\.
  3. Writes %LOCALAPPDATA%\T3Bridge\config.json (kept if it exists, unless -Force). The WoW folder
     comes from -WowPath or is auto-detected (scripts\lib\WowPath.ps1).
  4. Issues a scoped T3 credential (orchestration:read + orchestration:operate) via `t3 auth session issue`,
     stored DPAPI-protected in %LOCALAPPDATA%\T3Bridge\bearer.dat (skip with -NoLogin).
  5. Optional (-Startup): a Startup-folder shortcut that launches the companion hidden at logon.
     The companion itself enforces a single instance (%LOCALAPPDATA%\T3Bridge\companion.lock).

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts\install-companion.ps1 -Startup
#>
[CmdletBinding()]
param(
  [Alias("WowRoot")][string]$WowPath,
  [string]$Flavor = "_forever_",
  [ValidateSet("inplace", "rename")][string]$WriteMode = "inplace",
  [ValidateSet("wgc", "screenshot", "off")][string]$Capture = "wgc",
  [switch]$Startup,
  [switch]$NoLogin,
  [switch]$SkipBuild,
  [switch]$Force
)
$ErrorActionPreference = "Stop"
$Repo = Split-Path -Parent $PSScriptRoot
$Companion = Join-Path $Repo "companion"
$HelperProj = Join-Path $Repo "capture-helper\T3Capture"
$AppDir = Join-Path $env:LOCALAPPDATA "T3Bridge"
$HelperDir = Join-Path $AppDir "capture"
New-Item -ItemType Directory -Force -Path $AppDir | Out-Null
. (Join-Path $PSScriptRoot "lib\WowPath.ps1")

function Step($m) { Write-Host "==> $m" -ForegroundColor Cyan }

Step "Checking prerequisites"
$node = Get-Command node -ErrorAction SilentlyContinue
if (-not $node) { throw "Node.js 22+ is required (https://nodejs.org)." }
$nodeMajor = [int]((& node -v).TrimStart("v").Split(".")[0])
if ($nodeMajor -lt 22) { throw "Node.js 22+ is required (found $(& node -v))." }
$dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
if (-not $dotnet -and $Capture -eq "wgc") { throw "The .NET SDK (7 or newer) is required to build the capture helper." }

if (-not $SkipBuild) {
  Step "Building companion (npm install + tsc)"
  Push-Location $Companion
  try {
    & npm.cmd install --no-fund --no-audit | Out-Host   # npm.cmd: the npm.ps1 shim mangles args under PS 5.1
    if ($LASTEXITCODE -ne 0) { throw "npm install failed" }
    & npm.cmd run build | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "companion build failed" }
  } finally { Pop-Location }

  if ($Capture -eq "wgc") {
    Step "Building capture helper (Windows.Graphics.Capture)"
    & dotnet build $HelperProj -c Release --nologo -v q | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "capture helper build failed" }
    $out = Join-Path $HelperProj "bin\Release\net7.0-windows10.0.22621.0"
    New-Item -ItemType Directory -Force -Path $HelperDir | Out-Null
    # Stop a running helper so its files can be replaced.
    Get-Process -Name T3Capture -ErrorAction SilentlyContinue | Where-Object {
      try { $_.Path -and $_.Path.StartsWith($HelperDir, [StringComparison]::OrdinalIgnoreCase) } catch { $false }
    } | Stop-Process -Force -ErrorAction SilentlyContinue
    Copy-Item -Path (Join-Path $out "*") -Destination $HelperDir -Recurse -Force
  }
}

Step "Writing config"
$WowRoot = $null
try { $WowRoot = Resolve-WowFlavorPath -WowPath $WowPath -Flavor $Flavor; Write-Host "    WoW: $WowRoot" }
catch { Write-Warning ("  " + $_.Exception.Message) }
$cfgPath = Join-Path $AppDir "config.json"
if (-not $WowRoot) {
  Write-Warning "  Config not written: WoW was not found. Re-run with -WowPath, or set wowRoot in $cfgPath yourself."
} elseif ((Test-Path $cfgPath) -and -not $Force) {
  Write-Host "    keeping existing $cfgPath (use -Force to overwrite)"
} else {
  $cfg = [ordered]@{
    wowRoot   = $WowRoot
    writeMode = $WriteMode
    padBytes  = 524288
    capture   = [ordered]@{
      mode           = $Capture
      helperPath     = (Join-Path $HelperDir "T3Capture.exe")
      processName    = "Wow"
      regionWidth    = 1100
      regionHeight   = 200
      idleFps        = 10
      activeFps      = 30
      screenshotsDir = (Join-Path $WowRoot "Screenshots")
    }
  }
  $json = $cfg | ConvertTo-Json -Depth 5
  [System.IO.File]::WriteAllText($cfgPath, $json, (New-Object System.Text.UTF8Encoding($false)))
  Write-Host "    wrote $cfgPath"
}
$live = $(if ($WowRoot) { Join-Path $WowRoot "Interface\AddOns\T3Bridge_Live\live.lua" } else { $null })
if ($live -and -not (Test-Path $live)) {
  Write-Warning "  $live does not exist yet. Install the addon (scripts\install-addon.ps1) before starting WoW; the companion never creates it."
}

if (-not $NoLogin) {
  Step "Issuing a scoped T3 credential (stored DPAPI-protected; never printed)"
  & node (Join-Path $Companion "dist\main.js") --login
  if ($LASTEXITCODE -ne 0) { Write-Warning "  Login failed. Open T3 Code, then run: node `"$Companion\dist\main.js`" --login" }
}

$startupDir = [Environment]::GetFolderPath("Startup")
$lnk = Join-Path $startupDir "T3Bridge Companion.lnk"
$vbs = Join-Path $AppDir "start-companion.vbs"
if ($Startup) {
  Step "Creating hidden Startup shortcut"
  $nodeExe = $node.Source
  $mainJs = Join-Path $Companion "dist\main.js"
  # wscript + Run(..., 0) starts node without a console window.
  $vbsText = "Set sh = CreateObject(""WScript.Shell"")`r`nsh.CurrentDirectory = ""$Companion""`r`nsh.Run """"""$nodeExe"""" """"$mainJs"""""", 0, False`r`n"
  [System.IO.File]::WriteAllText($vbs, $vbsText, (New-Object System.Text.UTF8Encoding($false)))
  $ws = New-Object -ComObject WScript.Shell
  $sc = $ws.CreateShortcut($lnk)
  $sc.TargetPath = "$env:WINDIR\System32\wscript.exe"
  $sc.Arguments = "`"$vbs`""
  $sc.WorkingDirectory = $Companion
  $sc.Description = "T3Bridge companion (T3 Code <-> WoW)"
  $sc.Save()
  Write-Host "    $lnk"
}

Step "Done"
Write-Host "  Run now:        node `"$Companion\dist\main.js`""
Write-Host "  Demo (no T3):   node `"$Companion\dist\main.js`" --demo"
Write-Host "  Self-test:      node `"$Companion\dist\main.js`" --selftest"
Write-Host "  Status:         node `"$Companion\dist\main.js`" --status"
Write-Host "  Log:            $AppDir\companion.log"

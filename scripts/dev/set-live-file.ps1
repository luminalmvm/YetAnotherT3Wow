<#
.SYNOPSIS
  Writes test snapshots into the shared live file, standing in for the companion during spike tests.

.DESCRIPTION
  Every write is in place: the existing file is opened, overwritten, and its length set. It is never
  replaced or renamed, so variant B hard links keep working. The file must already exist (install-addon.ps1
  creates it before WoW starts): WoW does not see files created after it started.

  Live mode (default): writes protocol\fixtures\live.sample.lua with a new seq and current timestamps,
  padded to 524288 bytes. With -Loop it bumps seq every -IntervalSeconds, so the in-game link shows
  "Linked" and the thread timers run.

  Spike mode (-Spike): writes T3Bridge_Live\spike.lua for /t3 spike s1. With -Loop the file grows on
  each write (past 64 KB from the 4th write on), and every 4th write is deliberately torn (cut in half)
  to test that a corrupt file stays silent.

.EXAMPLE
  The WoW folder is auto-detected (scripts\lib\WowPath.ps1); pass -WowPath or -AddOnsDir to override.
  .\set-live-file.ps1 -Spike -Loop          # leave running, then type /t3 spike s1 in game
  .\set-live-file.ps1 -Loop                 # fake a live companion (snapshot from the fixture)
  .\set-live-file.ps1 -Inbox                # also write T3Bridge\Inbox.lua (seen after /reload)
#>
[CmdletBinding()]
param(
  [string]$WowPath,
  [string]$Flavor = "_forever_",
  [string]$AddOnsDir,
  [string]$Fixture = (Join-Path $PSScriptRoot "..\..\protocol\fixtures\live.sample.lua"),
  [switch]$Spike,
  [switch]$Loop,
  [switch]$Inbox,
  [double]$IntervalSeconds = 2,
  [int]$Count = 0,
  [string]$Sid = "k3f9",
  [int]$PadTo = 524288,
  [switch]$NoPad
)

$ErrorActionPreference = "Stop"
if (-not $AddOnsDir) {
  . (Join-Path (Split-Path -Parent $PSScriptRoot) "lib\WowPath.ps1")
  try { $AddOnsDir = Join-Path (Resolve-WowFlavorPath -WowPath $WowPath -Flavor $Flavor) "Interface\AddOns" }
  catch { Write-Host $_.Exception.Message -ForegroundColor Red; exit 1 }
}
$utf8 = New-Object System.Text.UTF8Encoding $false
$liveDir = Join-Path $AddOnsDir "T3Bridge_Live"
$target = if ($Spike) { Join-Path $liveDir "spike.lua" } else { Join-Path $liveDir "live.lua" }
$inboxPath = Join-Path $AddOnsDir "T3Bridge\Inbox.lua"

function Write-InPlace([string]$Path, [byte[]]$Bytes) {
  if (-not (Test-Path -LiteralPath $Path)) {
    throw "$Path does not exist. Run install-addon.ps1 (with WoW closed) first; WoW only sees files that existed when it started."
  }
  for ($try = 1; $try -le 10; $try++) {
    try {
      $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
      try {
        $fs.Write($Bytes, 0, $Bytes.Length)
        $fs.SetLength($Bytes.Length)
        $fs.Flush()
      } finally { $fs.Dispose() }
      return
    } catch [System.IO.IOException] {
      Start-Sleep -Milliseconds 50
    }
  }
  throw "Could not open $Path for writing (locked?)"
}

function Pad([string]$Text) {
  $b = $utf8.GetBytes($Text)
  if ($NoPad -or $b.Length -ge $PadTo) { return ,$b }
  $out = New-Object byte[] $PadTo
  [Array]::Copy($b, $out, $b.Length)
  for ($i = $b.Length; $i -lt $PadTo; $i++) { $out[$i] = 0x20 }
  return ,$out
}

$fixtureText = $null
$fixtureTs = 0
if (-not $Spike) {
  $fixtureText = [System.IO.File]::ReadAllText((Resolve-Path $Fixture).Path, $utf8)
  $m = [regex]::Match($fixtureText, 'T3B_IN=\{v=1,sid="[^"]*",seq=\d+,ts=(\d+)')
  if (-not $m.Success) { throw "Fixture does not look like a T3B_IN snapshot: $Fixture" }
  $fixtureTs = [long]$m.Groups[1].Value
}

function Live-Snapshot([long]$Seq) {
  $now = [long][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  $delta = $now - $fixtureTs
  # shift every timestamp so timers look live, then set sid/seq and the END marker
  $t = [regex]::Replace($fixtureText, '\b(ts|t0|t1)=(\d{10})\b', { param($mm) $mm.Groups[1].Value + "=" + ([long]$mm.Groups[2].Value + $delta) })
  $t = [regex]::Replace($t, 'T3B_IN=\{v=1,sid="[^"]*",seq=\d+', "T3B_IN={v=1,sid=""$Sid"",seq=$Seq")
  $t = [regex]::Replace($t, 'T3B_IN_END=\d+', "T3B_IN_END=$Seq")
  return $t
}

function Spike-Snapshot([long]$Seq) {
  $now = [long][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  $size = [Math]::Min(2048 + $Seq * 24576, 409600)
  $pad = "x" * [Math]::Max(0, $size - 120)
  $text = "T3B_SPIKE={seq=$Seq,ts=$now,size=$size,pad=""$pad""}`nT3B_SPIKE_TAIL=$Seq`n"
  if ($Seq % 4 -eq 0) {
    return @{ text = $text.Substring(0, [int]($text.Length * 0.6)); torn = $true }
  }
  return @{ text = $text; torn = $false }
}

# seq must grow within a companion sid: start from the clock so reruns never go backwards
$seq = [long]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - 1700000000)
if ($Spike) { $seq = 0 }
$n = 0
Write-Host ("Writing " + $target + $(if ($Loop) { " every $IntervalSeconds s (Ctrl+C to stop)" } else { "" }))
while ($true) {
  $seq++
  $n++
  if ($Spike) {
    $s = Spike-Snapshot $seq
    Write-InPlace $target ($utf8.GetBytes($s.text))
    Write-Host ("  spike seq {0}: {1} bytes{2}" -f $seq, $utf8.GetByteCount($s.text), $(if ($s.torn) { "  (torn on purpose)" } else { "" }))
  } else {
    $text = Live-Snapshot $seq
    Write-InPlace $target (Pad $text)
    if ($Inbox) { Write-InPlace $inboxPath ($utf8.GetBytes($text)) }
    Write-Host ("  live seq {0} ({1} bytes of Lua{2})" -f $seq, $utf8.GetByteCount($text), $(if ($Inbox) { ", Inbox.lua too" } else { "" }))
  }
  if (-not $Loop -or ($Count -gt 0 -and $n -ge $Count)) { break }
  Start-Sleep -Milliseconds ([int]($IntervalSeconds * 1000))
}

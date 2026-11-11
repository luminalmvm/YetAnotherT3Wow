# Troubleshooting

Start with two things: `/t3 status` in game, and the companion log at `%LOCALAPPDATA%\T3Bridge\companion.log`.

## Installing

**"Could not find World of Warcraft (_forever_)"**
Pass the folder that contains `Interface\AddOns`: `.\scripts\install-addon.ps1 -WowPath "<drive>:\World of Warcraft\_forever_"`. You can also set the `T3B_WOW_PATH` environment variable once.

**"WoW is running. Close it first"**
The client only sees addon files that existed when it started, so the installer refuses to run while WoW is open. Exit the game completely (not just to the character list). `-WhatIf` works while WoW runs.

**Scripts are blocked ("running scripts is disabled on this system")**
Run them as `powershell -ExecutionPolicy Bypass -File scripts\install-addon.ps1`, or allow local scripts for your user: `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`.

**The AddOns list shows hundreds of "T3Bridge slot" entries**
That is expected (500 slots plus 48 test slots). They must stay enabled. If your client supports `## Group`, they fold under T3Bridge.

## In game

**No minimap button, no `/t3` command**
T3Bridge is not loaded. Check that it is ticked in the AddOns list on the character screen and that "Load out of date AddOns" is on if the client asks.

**`/t3 status` says "Companion offline"**
The live file has not changed for 30 s. Start the bridge (`.\scripts\start-bridge.ps1`) and check the log for `writing … live.lua`. If the log says the live file does not exist, run the installer with WoW closed and start WoW again.

**"Companion not responding" after you send**
The companion did not acknowledge the command. Check in the log for `capture attached` and `addon -> …` lines.
- No `capture attached`: the capture helper was not found or cannot see WoW. Build it (`dotnet build -c Release capture-helper\T3Capture`) and keep WoW windowed or borderless; minimised windows deliver no frames.
- `capture attached` but no `addon ->` lines: try `/t3 cell 4`. Reset any custom render scale. `/t3 spike s2` reports the matrix geometry.
Your text is put back in the input box, so nothing is lost.

**"Link low: click to reload"**
Each poll uses one slot addon. Click the message or type `/reload`. For longer sessions reinstall with `-Slots 2000` (with WoW closed).

**The tracker is in the wrong place or missing**
`/t3 tracker auto` (default) places it under Questie, or above or beside it when there is no room. `/t3 tracker below|above|free` forces a side; in `free` mode Shift-drag the header. `/t3 tracker on` shows it again; `/t3 reset` resets all positions.

**The window shows "Loading thread…" for a long time**
The companion fetches the thread when you open it (usually under a second). If it stays, check the log for T3 errors; the addon asks again every 10 s.

**A new icon or texture does not show**
WoW caches textures. Restart the game completely; `/reload` is not enough.

**A red Lua error mentions T3Bridge**
Slash command errors are printed in chat as `Lua error in '/t3 …'`. Send that line and the output of `/t3 log` with your report.

## Companion and T3 Code

**`--login` fails with "T3 CLI not found"**
Open T3 Code once so it installs its CLI, or use a pairing token: `t3 pair --scope orchestration:read --scope orchestration:operate`, then `node companion\dist\main.js --pair` and paste the token.

**"another companion is already running"**
Only one instance runs at a time. `.\scripts\stop-bridge.ps1` stops it. After a crash the lock file is cleared on the next start.

**The companion keeps retrying T3**
T3 Code is not running, or its server moved to another port. The companion retries from 5 s up to every 60 s; start T3 Code and it connects by itself. `node companion\dist\main.js --status` shows what it found.

**After a T3 Code update nothing works**
The companion uses T3's undocumented local API (orchestration protocol 2). A T3 update can change it; the companion refuses to run against another protocol version. Check for an update to this repo.

**Clearing conversation text after a crash**
`.\scripts\stop-bridge.ps1 -Clear` overwrites `live.lua` and `Inbox.lua` with an empty snapshot.

## Reporting a bug

Include: the client version, `/t3 status` output, relevant `companion.log` lines and any `Lua error` lines. Check that they contain no private thread text before posting.

## Images

**Pictures show as `[image: name]` text**
Image slots are not installed or turned off. Close WoW, run `.\scripts\install-addon.ps1` (or `.\scripts\sync-addon.ps1`, which adds the missing `T3Bridge_Img` folder), start WoW and run `/t3 spike img`. If you answered `/t3 spike img fail` earlier, `/t3 spike img ok` turns them back on.

**"Loading image..." stays**
Check `companion.log` for `image tools unavailable`: rebuild the capture helper (`dotnet build -c Release capture-helper\T3Capture`). The companion skips an older helper copy in `%LOCALAPPDATA%\T3Bridge\capture` automatically; `install-companion.ps1` refreshes that copy.

**"No image slots left: restart WoW to free them"**
Each slot shows one picture per WoW session. Restart WoW, or reinstall with more slots (`-ImageSlots 200`, WoW closed). If `/t3 spike img 3` showed that `/reload` frees textures, set `"images": {"resetOnReload": true}` in `%LOCALAPPDATA%\T3Bridge\config.json` and restart the bridge; the hint then says `/reload`.

**Ctrl+V does nothing**
Copy an image first (Win+Shift+S, or Copy on an image or an image file). Ctrl+V works while the message box has focus; a text-only clipboard is ignored quietly. The Attach button next to Send does the same and says "No image on the clipboard" if there is none. "Attach latest WoW screenshot" needs a screenshot from the last 15 minutes.

**An image could not be sent**
T3 accepts PNG, JPEG, GIF and WebP up to 10 MB; other files are converted (TGA to PNG, the rest to JPEG). The status bar shows the error; staged images stay attached, so you can send again.

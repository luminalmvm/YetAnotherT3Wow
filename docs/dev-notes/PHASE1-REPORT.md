# T3Bridge Phase 1 report: bug fixes and live integration

> Historical development notes from building T3Bridge (2026-11). Kept for the measurements and the
> reasoning behind design decisions. Script paths were updated to the current repo layout and
> machine-specific paths were replaced with placeholders. For current usage see the main
> [README](../../README.md) and [docs](../).

Date: 2026-11-11. WoW was running the whole time (client 2560×1440). I never sent input to the game.
The only contact with the game was read-only window capture and copying changed addon files into its
AddOns folder.

**Current state:** the bridge is **running** in the background (started with `scripts\start-bridge.ps1`).
It writes your real T3 threads into `T3Bridge_Live\live.lua` and its capture helper is attached to WoW.
The addon fixes are copied in, but the game still runs the old code. **Next step: type `/reload` in WoW.**
A full restart is not needed: no new files and no TOC change.

---

## 1. Bugs fixed

### 1.1 `/t3 spike fonts` did nothing (root cause found and reproduced)
- **Root cause:** the fonts check built its probe text with `UIParent:CreateFontString(nil, "OVERLAY")`.
  That gives a font string with **no font at all**. On your client, `SetFont(mono.ttf)` did not load
  the bundled font, so the probe still had no font. The next `SetText()` then raised
  `FontString:SetText(): Font not set`. The error escaped the slash command. When a slash command
  errors, WoW's chat box stops its Enter handling halfway: the typed line stays in the box and
  nothing prints. Lua errors are hidden by default, so you saw nothing at all. Shortening the command
  by one letter went to the "usage" branch, which never touches fonts, so it worked.
- **Reproduced:** the WoW mock now behaves like the real client: a font string with no font raises
  on `SetText`, and fonts can fail to load. A new chat-line helper runs slash commands unprotected,
  the way WoW does. Against the old code the test failed with exactly
  `Spike.lua:229: FontString:SetText(): Font not set`.
- **Fix:**
  - Every probe font string starts from `GameFontNormal`, and every font call is protected.
  - The bundled font only counts if `GetFont()` really reports `mono.ttf` and the text measures as monospace.
  - Code blocks fall back to the chat font. The mono `SetFont` in `Messages.lua` is protected as well.
- **Every slash command** now runs inside `xpcall`. On an error it prints
  `Lua error in '/t3 …': <message>` plus "Details: /t3 log", and never fails silently again.
- **Every spike** now prints a `…: started` line and a final PASS/FAIL line (`S1 overall`,
  `S2 geometry`, `fonts …`, `templates …`, `S1 combat load`). Errors inside spike timers print as
  `FAIL <spike> (Lua error)`.
- **Regression tests:** `[legacy]` runs a client whose font fails to load and expects a FAIL line with
  no error. `[modern]` expects PASS (now) and PASS (after 2 s). A separate test checks that a slash
  error is caught and printed.
- **What your fonts result will probably say:** `FAIL fonts: bundled monospace font … not used`.
  That is harmless (code blocks use the normal chat font). Please send the `INFO fonts` line: it shows
  what `SetFont` returned on your client.

### 1.2 Two help-text bugs (seen in your screenshot)
- `/t3 hold … (now 2)` showed the cell size: a format-argument mix-up. It now shows `(now 200)`.
- `/t3 tracker on|offeset`: in WoW chat, `|r` is a colour code and swallows the `r`. All literal bars
  are now written `||`. A test checks every help line for stray escape codes.

### 1.3 Minimap button stuck between Questie and Spoken
- **Cause:** the default angle was 215°. On your minimap the Questie/Spoken buttons sit at roughly
  204°–225° (left of the map), so the T3 button landed right among them, at the same frame level (8)
  as LibDBIcon buttons. It could end up drawn under them, and they could catch its clicks and drags.
- **Fix (`UI/Minimap.lua`):**
  - Until you drag the button, it picks a free spot by itself. It looks at the other buttons around
    the minimap and takes the first clear angle near the top-right: 40°, 30°, 50°, … at least 26°
    from any other button. With your layout (an icon at about 58°) that is **30°**, the upper right
    of the ring. It checks 3 s and 12 s after login, because other addons create their buttons late.
  - Dragging works with either mouse button. The angle comes from the cursor while dragging and is
    saved in `T3BridgeDB.minimap.angle` with `moved = true`. The release after a drag does not
    toggle the chat window.
  - Frame level = minimap level + 10 (at least 8), raised further while dragging. Clamped to the screen.
  - Respects `GetMinimapShape()` (round, square, corners, using LibDBIcon's quadrant table). Round
    is the default when the client does not report a shape.
  - `/t3 minimap reset` forgets a dragged position and picks a free spot again. `/t3 reset` resets
    everything. Old installs that still have 215° saved are moved automatically, because they never
    set `moved`.

### 1.4 Tracker placement with a tall Questie tracker
- **Reading the old code:** it only went "above" Questie when Questie's bottom was below about 74 UI
  units. On your screen, Questie hangs right under the minimap, so "above" would have covered the
  minimap. Rows were capped by space on screen, so the tracker could not run off the bottom.
- **New modes (`/t3 tracker auto|below|above|free`, plus `on|off|reset`):**
  - **auto** (default): below Questie if 3 rows fit. Otherwise above it, but only up to the minimap
    when the minimap is right above. Otherwise beside it, to the left of Questie's top. Rows are
    always capped to what fits.
  - **below** and **above** force that side, rows capped (at least 1).
  - **free**: a saved position, moved by Shift-dragging the "T3 Code" header.
- **Your screen:** Questie ends near y≈820 of 1125, which leaves about 200 UI units below it, enough
  for all 8 rows. So auto puts the tracker **below Questie**. If your quest list grows to the bottom,
  it moves to the **left of Questie**.

### 1.5 Found and fixed during integration
- **Open chat stuck on "Loading thread…" after a companion restart.** The addon never asked again for
  the thread it was showing. Now it re-sends `focus` for the open thread, at most every 10 s
  (PROTOCOL D13). Tested.
- **Wrong default WoW path in `companion/src/config.ts`.** `"<WoW dir>\_forever_"` in JS
  loses its backslashes. Your `config.json` overrides it, so the bug never showed. Fixed anyway.
- **Real T3 ids like `thread-mcp…` gave look-alike tids** (`threadmc`, `threadmcp`, `threadmcpf`, …).
  Non-UUID ids now get 8-character hashes. Tested.
- **Companion log grew without limit.** It now rotates at 2 MB.
- **Companion exited if T3 Code was not running yet.** It now retries (5 s up to 60 s), which matters for autostart.
- **"(truncated — …)" used an em dash the WoW font may lack.** It is now ASCII.

---

## 2. Phase 1 integration

| Item | State |
|---|---|
| Real live file | Variant B: `<WoW dir>\_forever_\Interface\AddOns\T3Bridge_Live\live.lua`, the target of the 500 slot hard links (`fsutil hardlink list`: 501 names). Written in place, padded to exactly 524288 bytes. Checked after the real run: size 524288, still 501 links. Read through `T3Bridge_S0137\live.lua`, the file validates with the addon's own `State.Validate` under Lua 5.1. |
| Heartbeat / debounce | Heartbeat every 10 s (seq advanced on the real file), change writes debounced at 300 ms, at most 4 per second, acks written at once. |
| Thread selection | Up to 12: needs you → running → finished in the last 30 min → most recently updated. Never archived, deleted or subagent threads. The focused thread is always included. Only the focused thread's messages are written; other threads contribute their title, status, times, model and project only. Against your real T3: 12 threads, accepted by the addon. |
| `focus.older` | Companion writes it (true when the 40-message window leaves messages out, T3 has more pages, or size fitting dropped some). The addon uses it for "Earlier messages" and falls back to the old guess when it is missing. PROTOCOL D11. |
| PROTOCOL §2.3 | Rule 1 now reads "overwrite in place at offset 0, do not truncate first". Added D11 to D13 and the thread-selection rule. |
| Privacy | On a clean stop the companion writes an empty snapshot (`threads={}`, no focus, `ts=0`) to `live.lua` **and** `Inbox.lua` (D12). Verified on the real files with `stop-bridge.ps1`. After a crash, `stop-bridge.ps1 -Clear` (or `node companion\dist\main.js --clear`) does the same. The bearer token is still only stored DPAPI-encrypted in `%LOCALAPPDATA%\T3Bridge\bearer.dat`, and the logger redacts tokens. The log records command kinds, never message text. |
| Capture helper vs the real game | Read-only: `T3Capture.exe --process Wow` found `Wow.exe` ("World of Warcraft", client 2560×1440, origin 0,0, yellow border off). An 8-s capture got about 47 frames/s from WGC, processed 10/s (idle mode). Region readback 0.6–0.7 ms. CPU 0.05–0.3 % of the whole PC (1–5 % of one core). The captured crop showed the real top-left of your game. No matrix was on screen during this run, so no frame was decoded from the live game yet. Settings: cell 2 (addon default), hold 200 ms (addon default). Idle sampling every 100 ms catches a part 2+ times. |
| Start / stop | `scripts\start-bridge.ps1` starts hidden, single instance (checked: a second start only reports "already running"); `-Console` shows the log in a window. `scripts\stop-bridge.ps1` stops cleanly through a stop-request file (a hidden process gets no Ctrl+C). If the companion has not exited after 10 s, it terminates it and clears the files. Autostart stays the existing optional `scripts\install-companion.ps1 -Startup` (not enabled). |
| Deploy while WoW runs | `scripts\sync-addon.ps1` (supports `-WhatIf`) copies only changed **existing** files. While WoW runs it refuses new files and TOC changes and lists them as "needs a full restart". It never deletes anything and never touches `Inbox.lua`, the slots, other addons or SavedVariables. It ran for real and copied 8 files (Core, Slash, Spike, State, UI\ChatFrame, UI\Messages, UI\Minimap, UI\Tracker). → **`/reload` is enough.** |

## 3. Verified vs needs you

**Verified here (automated):**
- Lua (Lua 5.1 via lupa): **111/111** (was 97). New tests:
  - the fonts regression, in two variants
  - slash errors are printed
  - spike started/final lines
  - help text values and escapes
  - minimap: free-spot choice with your button layout, drag, the click after a drag, reset, square shape, crowded fallback
  - tracker below/side/above/free modes and row caps with your screen geometry
  - `focus.older`
  - focus re-send after a companion restart, throttled
- Companion (`npx vitest run`): **86/86** (was 75). New tests:
  - selection rules and the 12 cap
  - deleted/archived threads
  - hashed tids
  - `older` in its 3 cases, plus Lua output and size fitting
  - the empty exit snapshot
  - `Bridge.clear()` removes every title and message
  - the exit write also overwrites Inbox.lua
  - an **end-to-end** run of `dist/main.js` that is stopped through `stop.request` and leaves an empty file
- Decoder self-test PASS. 12/12 protocol vectors. 11/11 Lua↔companion encoder cross-check.

**Verified against the real system (read-only):**
- The real T3 server and credential. Real `--once` snapshot: 12 threads, accepted by the addon.
- Focusing a real thread (as the addon's `focus` command would): detail loaded in 62 ms, 17 messages,
  14 models, accepted by the addon. That scratch file was deleted afterwards.
- The real live-file write, heartbeat and hard links. Clean stop clears both files.
- The capture helper attached to the running WoW.

**Not verified (needs you in game):**
- That the reloaded addon shows the real threads.
- That the matrix from the real game decodes. This is the first real-game outbound test. S2 proved
  the pixel geometry, and the decoder handles that geometry, but it has not yet run on a live WoW frame.
- Your real minimap layout and the new tracker modes on your screen.
- The fonts verdict on your client.

No outbound frame from the game reached the companion during my session. The game still runs the
old addon code, and after a long session its link slots may be used up. A `/reload` fixes both.

## 4. In-game checklist (first time in WoW? start here)

To type a command: press **Enter** (a chat box opens bottom-left), type the command, press **Enter** again.

0. **Load the new addon code:** type `/reload`. The screen reloads for a few seconds.
   - Then type `/t3 spike fonts`. Now you always get `fonts: started` and a PASS or FAIL line (FAIL is fine).
   - Look at the minimap button: the round teal "T3" icon should sit at the upper right of the
     minimap ring, clear of the other buttons. You can drag it around the ring. `/t3 minimap reset`
     puts it back on a free spot.
1. **Running thread with a ticking timer:**
   - In the T3 Code app, give any thread a task that takes a minute or two.
   - Within about 15 s, a "T3 Code" list appears under the Questie quest list. It shows that thread
     with a yellow dot, its title, and a timer counting up (`0:12`, `0:13`, …).
   - If the list is somewhere awkward: `/t3 tracker below`, `above`, `free` or `auto`.
2. **Completed thread turns green:**
   - When T3 finishes, the row turns **green** with a tick and the timer stops.
   - Finished rows stay for 30 minutes, or until you open that thread in game.
3. **Clicking a row opens the chat:**
   - Left-click the row. The "T3 Code" window opens on that thread. You see "Loading thread..." for
     about a second, then the messages.
   - A tiny black-and-white bar flickers in the very top-left corner for a split second. That is the
     addon telling the companion which thread you opened. It is expected and only happens when you act.
4. **Sending a message from WoW:**
   - Click the text box at the bottom of the window, type `hello from WoW`, and press **Enter**.
   - The status line shows "Sending…", then the message appears in the window. In the T3 Code app,
     check that it arrived **in the same thread** (not another one).
   - If you see "Companion not responding", tell me (`/t3 status` output helps).
5. **Switching thread and model:**
   - The menu at the top-left of the window switches threads. The messages change after about a second.
   - The menu next to it switches the model, for real, on that T3 thread. Check in T3 Code that the
     thread's model changed, then switch it back.

Please send back:
- any red text or `Lua error` lines
- the `fonts` lines
- whether the minimap button and tracker sit well
- the output of `/t3 status` if something does not work

The companion log is `%LOCALAPPDATA%\T3Bridge\companion.log`. Look for lines like `addon -> hello` / `addon -> send`.

## 5. Lag and flashing: what would be cut first

What happens now:
- **Matrix flashes:**
  - only when you act (open a thread, send, answer, switch model, stop)
  - plus one `hello` per `/reload` or companion restart
  - plus at most one automatic `focus` re-send every 10 s while the companion lacks it
  - Each is a 512×16 px bar (512×64 for long text), visible about 230 ms.
- **Polling:** each poll loads a 512 KB file. Every 15 s when idle, 3 s while a thread runs, 1 s while
  the chat window is open and T3 is writing, or just after a send.

If you notice hitches or dislike the flashes, cut in this order:
1. **`/t3 hold 150`**: about 25 % shorter flashes, still about 2 capture samples per part at idle rate.
2. **Drop the 512 KB padding.** If your S1 run printed `PASS … file can grow after login`, the
   companion can write unpadded files of about 2–20 KB, so each poll reads a fraction of the data.
   This needs a small companion change (truncate in place instead of padding), not done yet.
   Please confirm the growth line first.
3. **Skip the `hello` frame.** The companion can learn the addon session from the first real command,
   saving one flash per reload. This is a small protocol change, not done.
4. **Slower polling while the chat is open:** 2 s instead of 1 s. Streaming text then updates in steps.
   Not done, but trivial (`State.Cadence`).
5. Longer sessions without "Link low: click to reload": reinstall with `-Slots 2000` next time WoW is
   closed. This does not affect lag.

## 6. Summary

**Key files changed or added**
- Addon:
  - `addon/T3Bridge/Slash.lua` (protected dispatcher, help, tracker/minimap commands)
  - `Spike.lua` (fonts fix, started/final lines, guarded callbacks)
  - `UI/Minimap.lua` (auto free spot, drag, shapes, reset)
  - `UI/Tracker.lua` (auto/below/above/free, side fallback)
  - `Core.lua` (defaults, focus re-send)
  - `State.lua` + `UI/ChatFrame.lua` (`focus.older`)
  - `UI/Messages.lua` (protected SetFont, ASCII text)
- Tests: `addon/T3Bridge/test/wow_mock.lua`, `test_smoke.lua`
- Companion:
  - `src/model/snapshot.ts` (selection, `older`, empty snapshot, hashed tids)
  - `src/bridge.ts` (`clear()`)
  - `src/main.ts` (clean shutdown, `stop.request`, `--clear`, T3 retry)
  - `src/wow/liveWriter.ts` (forced Inbox write)
  - `src/config.ts` (path fix)
  - `src/log.ts` (rotation)
  - `test/phase1.test.ts`
- Scripts:
  - `scripts/start-bridge.ps1`, `scripts/stop-bridge.ps1`
  - `scripts/sync-addon.ps1`
  - `scripts/uninstall-companion.ps1` (now stops cleanly)
- Docs: `protocol/PROTOCOL.md` (§2.2 threads/older, §2.3 rule 1, §2.6, D11–D13), `companion/README.md`, this report.

**Test results:** Lua 111/111 · companion 86/86 · selftest PASS · vectors 12/12 · Lua↔companion 11/11.

**Commands** (from `t3bridge\`):
```powershell
powershell -ExecutionPolicy Bypass -File scripts\start-bridge.ps1            # start (hidden, single instance)
powershell -ExecutionPolicy Bypass -File scripts\start-bridge.ps1 -Console   # start with a visible log window
powershell -ExecutionPolicy Bypass -File scripts\stop-bridge.ps1             # stop cleanly + clear live.lua
powershell -ExecutionPolicy Bypass -File scripts\sync-addon.ps1        # copy changed addon files (then /reload)
python addon\T3Bridge\test\run_tests.py                                      # Lua tests
cd companion; npx vitest run                                                 # companion tests
```

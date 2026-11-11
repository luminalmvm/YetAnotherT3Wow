# T3Bridge Phase 0: Track B report (WoW addon side)

> Historical development notes from building T3Bridge (2026-11). Kept for the measurements and the
> reasoning behind design decisions. Script paths were updated to the current repo layout and
> machine-specific paths were replaced with placeholders. For current usage see the main
> [README](../../README.md) and [docs](../).

Status: the addon, protocol contract, test vectors, scripts and tests are written. Everything that
can run outside the game passes. Everything that depends on the real WoW client is **not verified
yet**: it needs the in-game checklist below (about 15 minutes).

The addon was installed into `<WoW dir>\_forever_\Interface\AddOns\` with WoW closed:
variant B, 500 link slots, 24 spike slots per variant.

---

## 1. Verified here (by running code)

| What | How | Result |
|---|---|---|
| Every addon `.lua` file parses as **Lua 5.1** (WoW's version) | `run_tests.py`, compile suite (lupa `lua51`) | 23/23 |
| CRC-32 (pure-Lua path and a signed-result `bit` library path), frame layout, 206/207-byte split, 5-part 4000-byte message, MSB-first packing, sync row, white-run rendering, UTF-8 cutting | unit suite (`test_codec.lua`) | pass |
| Snapshot validation: fixture loads in a Lua 5.1 sandbox; torn file (syntax error); table without matching `T3B_IN_END`; stale `seq`; `sid` change resets; wrong version; malformed fields dropped without raising; 12-thread cap | unit suite (`test_state.lua`) | pass |
| Tracker rules (ordering, `m:ss`/`h:mm:ss`, frozen durations, seen-hiding, 30-min TTL, summary text), dropdown groups, poll cadence, status-line priority, history-page merge | unit suite | pass |
| Outbound stop-and-wait: ack, foreign-session ack ignored, 3 retransmits with flag bit then failure, ack arriving mid-transmission, `err` counts as done, focus/model coalescing, `hello` jumps the queue, seq wrap rotates the session id | unit suite | pass |
| **Whole addon end to end against a WoW API mock**, run twice: "modern" (all templates) and "legacy" (no modern templates, no `C_XMLUtil`, no `GetPhysicalScreenSize`, no `BackdropTemplate`). Covers: TOC load order, login events, Inbox fallback, slot discovery, disabled slot re-enabled, polling, torn file swallowed (no error reaches the default handler), Questie anchoring (late frame, hide → fallback, bottom-of-screen → above, narrow → min width), chat rendering with UI-code escaping, approval button → `ans`, Enter / Shift+Enter (both newline behaviours), 4000-byte send, retransmit → "Companion not responding" with the text put back, offline after 30 s, "Link low" → click → `ReloadUI`, exhaustion stops polling, full `/t3 demo`, every `/t3 spike` command, minimap left/right click, SavedVariables free of message text. **The drawn matrix is read back from the mock's textures and decoded**: hello, ans, send and the 5-part message all decode to the exact payload. | smoke suite (`test_smoke.lua`) | pass |
| Test vectors cross-checked by a second, separate implementation (bitwise JS CRC, its own packing) | `node scripts/dev/gen-vectors.js --check --png` | 12/12 vectors, 16 frames |
| `install-addon.ps1`: fresh install, reinstall keeps companion-owned `Inbox.lua`/`live.lua`, switch B → A → B, ignores other addons, skips `test/`, refuses while WoW runs | run against a fake AddOns folder in the scratchpad, plus `-WhatIf` and a real install | pass; 501 hard links on `live.lua`, 25 on `spike.lua` (`fsutil hardlink list`) |
| `set-live-file.ps1`: in-place writes go through hard links; padded live file (524288 bytes) and `Inbox.lua` validate under Lua 5.1; spike file grows (26 → 51 → 75 KB) and the 4th write is torn on purpose; refuses to create a missing file | fake AddOns folder + Lua 5.1 check | pass |

Commands (from the repo root `t3bridge\`):

```powershell
pip install lupa                                   # once
python addon\T3Bridge\test\run_tests.py            # -> TOTAL: 97 passed, 0 failed
python addon\T3Bridge\test\run_tests.py --write-vectors   # regenerate protocol\vectors\*.json
node scripts\dev\gen-vectors.js --check --png    # -> 12/12 vectors match
node scripts\dev\make-fixture.js                 # regenerate fixture + Demo.lua
```

## 2. Not verified (needs the real client)

The mock catches Lua errors and logic bugs. It **cannot** tell what this client really does. Open questions:

1. **S1 (the core risk):** does `LoadAddOn` on a fresh load-on-demand slot re-read `live.lua` from
   disk after login? Does variant A's `..\T3Bridge_Live\live.lua` TOC path work? Do variant B's hard
   links work? Can the file grow past its login-time size? Does loading work in combat?
2. Whether a syntax error inside a load-on-demand file really goes through `seterrorhandler`, so our
   handler swallows it (expected: no red error window).
3. **S2:** that the matrix lands exactly on physical pixel (0,0) at 1:1 scale, and that Track A's capture helper decodes it.
4. That the bundled DejaVu Sans Mono font loads (`/t3 spike fonts`).
5. Real template behaviour: `PortraitFrameTemplate` looks, `WowStyle1DropdownTemplate` radio menus,
   `InputScrollFrameTemplate` (does Enter put a newline in before `OnEnterPressed`? both cases are
   handled), `ScrollFrameTemplate` scroll bar position.
6. How the window, tracker and minimap button look next to Questie. Text wrapping heights.
7. Whether `## Group: T3Bridge` folds the 548 slot addons into one entry in the AddOns list.

---

## 3. In-game checklist (first-time friendly)

You type each `/t3 …` command into the normal WoW chat: press **Enter**, type the command, press
**Enter** again. Results print in the chat window in colour: **PASS** green, **FAIL** red, **INFO**
yellow. Scroll the chat with the mouse wheel if lines go by. Please send back every PASS/FAIL/INFO line.

**Before you start:** the addon is already installed. If you ever need to reinstall: close WoW, then
in PowerShell, in the `t3bridge` folder, run `.\scripts\install-addon.ps1`.

### Step 1: start the game with the addon on
1. Start WoW and wait for the character list.
2. Click **AddOns** (bottom-left of the character list). Check that **T3Bridge** is ticked. The slot
   addons ("T3Bridge slot 0001" and so on, maybe folded under T3Bridge) must be ticked too: they are
   on by default. Close the list and click **Enter World**.
3. Expected: a round **T3 icon** (teal with "T3") on the edge of the minimap. Nothing else shows yet:
   the tracker stays hidden until there is data.

### Step 2: templates and APIs
Type `/t3 spike templates`.
- Expected: a yes/no list, then `PASS templates: every UI element has a usable template`.

### Step 3: font
Type `/t3 spike fonts`.
- Expected: `PASS fonts: bundled monospace font loads (now)`, then about 2 s later `… (after 2 s)`.
  A FAIL here is not serious: code blocks then use the normal chat font.

### Step 4: look at the UI (demo, no companion needed)
Type `/t3 demo`.
- Expected: the chat window "T3 Code" opens in the middle of the screen. It shows a thread called
  "Fix flaky login test…" with about 40 messages, code blocks on dark backgrounds, and an orange
  "Approval needed" box with **Allow / Always allow / Deny** buttons. A small "T3 Code" list appears
  under the Questie quest tracker (or top-right if Questie shows nothing). It has orange (pulsing),
  yellow, green and red rows.
- Try: click **Allow**. A reply types itself out. Click the input box at the bottom, type `hello`,
  press **Enter**. Press **Shift+Enter** for a new line. Use the thread menu (top-left of the window)
  to switch threads. Hover a message and click the small note icon to copy it. Drag the bottom-right
  corner to resize. Click the minimap icon (left or right click) to close and open the window.
- Type `/t3 demo` again to leave demo mode.
- Please tell us anything that looks broken or un-WoW-like (screenshots are fine).

### Step 5: S1, the live-file link (most important)
1. In PowerShell, in the `t3bridge` folder, run:
   `.\scripts\dev\set-live-file.ps1 -Spike -Loop`
   Leave it running. It prints a line every 2 s.
2. In WoW type `/t3 spike s1` and wait about 20 seconds.
3. Expected, for **A** and **B** separately:
   - `PASS S1-A load works …` and `PASS S1-B load works …`
   - `PASS S1-A edits after login are picked up  seq x -> y` (same for B)
   - `PASS S1-A file can grow after login  read a … KB file` (same for B)
   - `PASS S1 torn/corrupt file handled silently …`, or `INFO S1 torn file … run again`
4. A red Lua error window must **not** appear. If one does, say so (and copy its first line).
5. Write down which of A and B passed. One working variant is enough.

### Step 6: S1 in combat
1. Leave the PowerShell loop running. Type `/t3 spike s1 combat`.
2. Start a fight: right-click any monster with a red or yellow name near you (or a training dummy
   in a city). The addon does nothing to your character. You fight as usual.
3. Expected: `PASS S1 combat load  variant … loaded in combat (lockdown=true …)`.
4. Press **Ctrl+C** in PowerShell to stop the loop.
   (If S1 says slots are used up, type `/reload` and try again.)

### Step 7: S2, the outbound pixel matrix
1. If Track A's capture helper is ready, start it first (see `docs\` from Track A). If it is not
   ready, do this step anyway: the geometry check still works without it.
2. Type `/t3 spike s2`. Over about 15 s, four small black-and-white bars appear one after another in
   the very top-left corner, each for 3 s (it only looks like this during the test; real sends last about 0.2 s).
3. Expected: `PASS S2 hello_c1 … 1 unit = 1.0000 px; left=0.00 top=…`, the same for `focus_c2`,
   `intr_c4`, `boundary_207_c2`, then `PASS S2 geometry (all sizes)`.
4. If the capture helper ran, it should report decoding `hello_c1, focus_c2, intr_c4, boundary_207_c2`.

### Step 8: live link without the companion (optional)
1. In PowerShell: `.\scripts\dev\set-live-file.ps1 -Loop`
2. Within about 15 s: the tracker shows six threads, with the summary
   `1 running · 2 needs you · 1 done · 1 failed`. Timers count up. `/t3 status` shows `Link: Linked · 1s`.
3. Click a tracker row: the chat opens on that thread. Expected here, because no companion is
   running to answer: a tiny bar flickers in the top-left corner a few times (the addon saying
   `hello`), and after about 12 s the status reads "Companion not responding". Sending anything does the same.
4. Ctrl+C the loop. About 30 s later the status changes to "Companion offline".

### What to send back
All PASS/FAIL/INFO lines, which S1 variant passed, whether any red error window appeared, and anything that looked wrong in step 4.

Switching variant later: close WoW, then run `.\scripts\install-addon.ps1 -Variant A` (or `B`).
For more slots: `-Slots 2000`. To remove everything: `.\scripts\uninstall-addon.ps1`.

---

## 4. Known risks

| Risk | Impact | Mitigation |
|---|---|---|
| The client caches LoD file contents or the directory listing (an earlier experiment showed that files **created** after login are invisible) | Inbound link dead | S1 tests exactly this. The design only ever **rewrites existing files in place**. If S1 fails for both variants, fall back to `Inbox.lua` (refresh on `/reload`), which already works. |
| File size cached at login | Truncated reads | S1 growth test. The companion pads to a fixed 524288 bytes (PROTOCOL D6) either way. |
| Torn reads | One poll wasted | `T3B_IN_END` check, swallowed error, retry after 0.5 s. |
| Error handler not swallowing load errors (for example if BugGrabber is installed later: it locks `seterrorhandler`) | Error noise on a torn file | None of the installed addons override it (checked). Torn reads are rare (the companion writes in about 1 ms). |
| Slot budget: each poll uses one slot. 500 slots ≈ 8 min of 1 s polling, 25 min at 3 s, 2 h idle | "Link low: click to reload" | Adaptive cadence. Use `-Slots 2000` for longer sessions. A reload takes a few seconds and only happens on the user's click. |
| `Inbox.lua` is listed in the TOC, so a torn `Inbox.lua` at login shows one Lua error | Cosmetic, rare | The companion writes it rarely (≤ every 5 s) and quickly. |
| Matrix not pixel-exact (render scale, DPI, windowed borders) | Decode fails | 1:1 scale via `SetIgnoreParentScale` + `768/physicalHeight`. Cell size 2 by default (`/t3 cell 4` if needed). The decoder searches for the sync row. S2 reports the geometry. |
| Copy dialog: pipes are shown escaped (`||`). Whether Ctrl+C copies `|` or `||` is untested | Minor | Verify in step 4 with the message that contains `|cffff0000`. |
| 548 entries in the AddOns list if `## Group` is not supported | Cosmetic | Harmless. |
| Account safety | n/a | The addon only draws UI. It never moves, targets, casts or injects input. Commands only go to the companion when you click or press Enter. `Screenshot()` is never called. |

## 5. Changes from the brief

- **Protocol additions** (top of `protocol/PROTOCOL.md`, D1–D10). The most important is `T3B_IN.asid`:
  the ack must name the addon session, or an old ack would confirm new commands after a `/reload`.
  Others: an optional `err` field, defined part numbering, flags and endianness, write-in-place and
  padding rules, the `hist` window, and Lua-5.1-only string escapes.
- **Spike slots** `T3Bridge_TA##`/`T3Bridge_TB##` reading `T3Bridge_Live\spike.lua`. Both variants
  can be tested in one session without using up production slots. Production slots are exactly as
  specified (`T3Bridge_S%04d`).
- **Extra files** beyond the list: `Core.lua` (settings, event bus, sending), `Demo.lua` (generated
  copy of the fixture), `DemoMode.lua`, `Spike.lua`, `UI/Templates.xml` (input template keys),
  `Media/mono.ttf` (DejaVu Sans Mono, license in `Media/mono-LICENSE.txt`).
- The tracker hides itself when there is nothing to show (no data and not in demo mode).
- When Questie's tracker sits at the bottom of the screen, the T3 tracker anchors **above** it, so it cannot run off-screen.

## 6. File map

```
protocol/PROTOCOL.md                 contract (both directions) + change list D1-D10
protocol/fixtures/live.sample.lua    7 threads, 40-message focus, pending approval
protocol/fixtures/live.empty.lua     minimal valid snapshot
protocol/fixtures/live.torn.lua      truncated snapshot (syntax error)
protocol/vectors/*.json, *.png       outbound frames: bytes -> cells -> pixels
addon/T3Bridge/                      the addon (TOC Interface 16001, SavedVariables T3BridgeDB)
  Compat.lua Codec.lua State.lua Core.lua Inbound.lua Outbound.lua Inbox.lua
  Demo.lua DemoMode.lua Spike.lua Slash.lua Bindings.xml
  UI/Tracker.lua ChatFrame.lua Messages.lua Prompt.lua Minimap.lua CopyDialog.lua Templates.xml
  Media/icon.tga mono.ttf
  test/run_tests.py harness.lua test_codec.lua test_state.lua test_smoke.lua wow_mock.lua vectors_spec.lua
scripts/install-addon.ps1      install addon + slots (refuses while WoW runs; -WhatIf)
scripts/uninstall-addon.ps1
scripts/dev/set-live-file.ps1      fake companion writes (live / -Spike / -Loop / -Inbox)
scripts/dev/gen-vectors.js         independent encoder; checks vectors, renders PNGs
scripts/dev/make-fixture.js        fixture + Demo.lua generator (reference Lua 5.1 escaper)
```

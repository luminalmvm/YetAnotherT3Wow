# T3Bridge Phase 2 notes: effort picker, open-thread tracker, chat polish

> Historical development notes from building T3Bridge (2026-11). Kept for the measurements and the
> reasoning behind design decisions. Script paths were updated to the current repo layout and
> machine-specific paths were replaced with placeholders. For current usage see the main
> [README](../../README.md) and [docs](../).

Date: 2026-11-11. WoW was running the whole time. I never sent input to the game. The only contact
was copying changed addon files with `scripts\sync-addon.ps1` (9 existing files, no new files,
no TOC change) and restarting the bridge.

**Current state:**
- The bridge runs the new companion (restarted 18:58, attached to WoW).
- `live.lua` now holds your 14 open threads, and the addon's own validator accepts it.
- The game still runs the old addon code. **Next step: `/reload` in WoW** (no restart needed).

---

## 1. What changed

### 1.1 Effort picker (requested)
- **Chat window:** a third dropdown right of the model dropdown shows the thread's reasoning effort
  (`Low`, `Medium`, `High`, `X-High`, `Max`, `Ultrathink`). It uses the same style as the other
  dropdowns: `WowStyle1DropdownTemplate`, with the old `UIDropDownMenu` as fallback.
- **Choices per model:** it lists only the values the selected model offers (from T3's model list).
  It is **hidden** for models without an effort option (Claude Haiku 4.5 has only a "thinking" switch).
- **Picking an effort** sends one command: the current model plus the new effort.
- **Switching model** sends the model and the effort in the **same** command, so there is one matrix
  flash. It keeps the current effort if the new model offers it, otherwise it uses that model's
  default. Example: X-High → Opus 4.5 becomes High.
- **Button text:** the model button shows short names (`Sonnet 5.5`, without `Claude `).
- **Narrow windows:** the top bar shrinks the dropdowns (thread first, then model, then effort) down to
  minimum widths, so they never overlap the status text. At the minimum window width (420) the status
  text is cut short as a last resort. Dropdown text truncates with "...".
- **Companion:**
  - Reads each model's effort option from T3 (`server.getConfig`).
  - Reports the thread's current effort the way T3 resolves it.
  - Maps `model <tid> <model> [effort]` to T3's `thread.model-selection.set`. It replaces only the
    `effort` entry and keeps `fastMode`, `ultracode`, `contextWindow`, and so on as they were.
- **`Ultrathink`:** a real stored value in T3. The run uses the model's default effort, and T3 starts
  each of your prompts with "Ultrathink:".

### 1.2 Tracker: every open thread until you settle it in T3 (your revised requirement)
- **"Settled" is a real T3 concept.** The `thread.settle` and `thread.auto-settle` commands set
  `settledAt` (auto-settle follows your "auto-settle after N days" setting); `thread.unsettle`
  clears it. I verified this in the T3 server bundle and the live thread list.
- **Rule now:** the bridge lists every thread that is **not settled**, not archived, not deleted and
  not a subagent. The thread open in WoW is always included, even if settled.
  - Live right now: 14 open threads, matching the 14 unsettled threads in T3.
- **Cap:** raised from 12 to **30**. 30 long-titled threads cost under 16 KB of the 480 KB budget.
- **Order:** needs you, running, then the rest by most recent update.
- **No 30-minute cutoff,** and **opening a row never hides it**.
  - Both the addon's "seen" rule and the 30-minute TTL are deleted.
  - The companion never dropped opened threads. It already always included the focused thread.
  - Gap fixed: a focused thread missing from T3's thread list (which omits older settled threads)
    is now added from the thread's own data.
- **Per-row collapse:**
  - The small **+/−** button at a row's left, or **right-click** a row, toggles it.
  - Collapsed rows are a compact grey line: small icon, title cut to ~34 characters, no timer unless
    the thread needs attention. They sort after the expanded rows.
  - The header shows e.g. `1 running · 3 collapsed`.
  - Header control: the **[-]/[+]** button in the header, or **right-click the header**, collapses or
    expands all. A plain left-click on the header still hides or shows the whole list.
- **Auto-expand:** a collapsed row expands by itself when its thread starts needing approval or input,
  or fails. You can collapse it again; it then stays collapsed until the next new attention state.
- **Saved data:** collapse state lives in `T3BridgeDB.tracker.rows` as `thread id → true` or a short
  state key such as `"approval"` or `"failed:<time>"`. No titles, no text. Old entries are pruned.
- **Fitting the screen:** rows fit the vertical space where the tracker sits; collapsed rows are
  smaller, so more fit. When rows are left over, a **"N more..."** line opens the chat window with its
  thread menu, which lists every thread (it scrolls, where the client supports it).
- **Zero threads:** the tracker now **always shows its header**, with "no open threads" on one line.
  It used to hide completely.

### 1.3 Chat polish
- **(a) Clipped "Assistant 16:28" header:**
  - **What I found:** the scroll area's geometry was not wrong. The latest message was taller than
    the view, so with the view stuck to the bottom its header was scrolled half out of the top edge.
  - **Fix:** a **sticky header strip**. When the message at the top edge has its header scrolled
    away, a dark strip at the top shows that message's role, time and "(continued)", instead of a
    half-cut line. It disappears when the real header is visible.
- **(b) Light markdown in user and assistant messages:**
  - `**bold**` → gold highlight
  - `` `code` `` → pale blue
  - `# headings` → gold, on their own line
  - `- ` / `* ` / `1. ` lists → bullet (`·`) or number with a hanging indent; nested levels are indented
  - The companion now keeps these marks for user and assistant text only; tool and system text is unchanged.
  - **Safety:** all text is escaped before colour codes are added, so `|c…`/`|T…` in messages stay
    literal (tested). Unmatched `**` or `` ` `` stay as typed. The 2000-character FontString split
    still applies.
- **(c) Why you saw no T3 tracker:**
  - **Reproduced with your screenshot geometry** in the fake-WoW harness (Questie top ~580 units,
    bottom ~208, minimap above). The placement logic chose **below Questie**, with room for 12+ rows,
    which is a visible spot.
  - **Real cause:** the old code **hid the whole tracker when it had zero rows**. Your only recent
    thread had completed, and opening it in game marked it "seen", so zero rows → nothing visible.
  - **Now:** the header always shows, and threads no longer disappear when opened or after 30 minutes.

### 1.4 Protocol (PROTOCOL.md revision 1.2, backward compatible, wire version still 1)
- **D14:**
  - `focus.effort`
  - `focus.models[i].opts = {{id="effort", vals={...}, def="..."}}`
  - optional 4th field on `model`
  - markdown marks in user/assistant `p` segments
- **D15:** open-thread selection, cap 30, new order, no 30-minute rule, collapse is addon-only.
- **New test vector:** `model_effort_c2` (Lua) / `model-effort` (companion), `model\ta1b2c3d4\tclaude-opus-5-5\txhigh`.
- **Fixture:** `live.sample.lua` and `/t3 demo` (`Demo.lua`) now carry effort choices (Opus 5.5,
  Sonnet 5.5, Opus 4.5, Haiku 4.5 without effort) and a markdown-rich message.
- **Compatibility with older versions:**
  - An old addon ignores the new fields and shows its first 12 threads. It would show `**` literally.
  - An old companion ignores the effort field.

## 2. Test results
- **Lua (5.1 via lupa): 127/127** (was 111).
  - Effort parsing, including malformed input.
  - The effort picker end to end in both client configurations. The decoded matrix payloads are
    `…\tlow`, the fallback `claude-opus-4-5\thigh`, no effort field for Haiku 4.5, and the picker hidden.
  - The top bar at 420 px.
  - Markdown styling and injection safety.
  - The sticky header.
  - Tracker:
    - zero threads with your screenshot geometry
    - opened and 3-day-old rows staying
    - right-click and +/− collapse, collapse all
    - auto-expand on needs-you and on failure, re-collapse
    - "N more..." opening a thread menu that lists all 30
    - SavedVariables holding ids only
- **Companion (vitest): 100/100** (was 86).
  - Effort descriptors and resolution.
  - Model-selection payloads: effort only, kept, fallback, none stored, no-effort model.
  - The `model` command with effort against the fake T3.
  - Open-thread selection: old finished threads kept, settled/archived/subagents dropped, cap 30,
    focused thread always included even when settled, opening never removes a thread.
  - Size budget.
  - Markdown marks.
- **Encoders:** JS reference 13/13 vectors · Lua↔companion encoder cross-check 12/12.

## 3. Verified vs needs you
**Verified against the real T3 (throwaway thread "T3Bridge effort test (safe to delete)", created and deleted by my script):**
- The companion's real `setModel` path with effort. Each change appeared in T3 after ~420 ms:
  - low
  - ultrathink
  - switch to Opus 4.5 gave High (fallback)
  - xhigh
  - switch to Haiku 4.5 left the options alone and the snapshot had no effort
  - Sonnet 5.5 with Max
- The thread was then gone from T3's list.
- None of your real threads' settings were changed.

**Verified (read-only):**
- Your real thread list: 14 unsettled of 41 recent threads.
- The new `live.lua`: 14 threads, 524288 bytes, accepted by the addon validator.
- The running (old) addon sent `hello` to the new companion.

**Needs you in game (not verifiable here):**
- **Dropdown look and truncation:** how the effort dropdown looks, and how the dropdown text
  truncates on your client at small window sizes.
- **Menu helpers:** whether your client has the menu helpers used by "N more..." and the thread
  list. Both are guarded:
  - `DropdownButton:OpenMenu` opens the thread menu automatically. If it is missing, the chat window
    still opens and you click the menu yourself.
  - The menu's scroll mode keeps the thread list on screen. If it is missing, the list is not limited.
- **Glyphs:** that the `·` bullet glyph renders (it is the same character the status bar already
  shows correctly).
- **Overall feel:** of collapsed rows, the sticky header and the markdown colours.

## 4. In-game checklist
1. **Load the new code:** type `/reload`. Under the Questie list you should see **T3 Code** with
   your open threads (now including finished ones), or "no open threads". Click a row: the chat
   opens, and **the row stays**.
2. **Effort:** in T3 Code, make a throwaway thread (e.g. "say hi"). In WoW, pick it in the chat
   window's thread menu. The new dropdown right of the model shows its effort (e.g. `High`). Pick
   `Low`, then check in the T3 app that the thread's reasoning level changed to Low. Switch the model
   to Opus 4.5 while on X-High and see it fall back to High. **Switch the effort (and model) back
   afterwards**, or delete the throwaway thread.
3. **Collapse:** right-click a tracker row, or click its small −, and it becomes a grey compact line
   at the bottom (the header says "1 collapsed"). Click + to expand it. The [-] in the header
   collapses everything; [+] expands everything.
4. **Chat:** shrink the window to its smallest size. The three dropdowns get narrower and do not
   cover the status text. Scroll inside a long reply: a dark strip with "Assistant hh:mm (continued)"
   stays at the top. Bold text is gold, `code` is pale blue, lists have bullets.
5. Send any `Lua error` lines, or a screenshot if something looks off (`/t3 status` helps too).

To dismiss a thread from the tracker for good, **settle it in T3 Code**. It disappears within a few seconds.

## 5. Files changed
- **Addon:**
  - `State.lua` (cap 30, effort parsing, tracker rules, collapse/auto-expand; "seen"/TTL removed)
  - `Core.lua` (no mark-as-seen on open; `tracker.rows` default)
  - `UI/ChatFrame.lua` (effort dropdown, top-bar fitting, short model names, `OpenThreadMenu`, scrolling thread menu)
  - `UI/Messages.lua` (markdown styling, sticky header)
  - `UI/Tracker.lua` (all open threads, per-row/all collapse, "N more...", header always shown)
  - `UI/Minimap.lua` (tooltip summary)
  - `Slash.lua` (help text)
  - `DemoMode.lua` (effort in demo)
  - `Demo.lua` (regenerated)
  - Tests: `test/test_state.lua`, `test/test_smoke.lua`, `test/wow_mock.lua`, `test/vectors_spec.lua`
- **Companion:**
  - `src/t3/types.ts`, `src/t3/project.ts` (effort descriptors, resolution, options helpers)
  - `src/t3/client.ts` (`buildModelSelection`, `setModel(…, effort)`, focused thread kept in `threads()`)
  - `src/t3/fakeClient.ts`
  - `src/model/snapshot.ts` (open-thread selection, cap 30, `opts`/`effort`, markdown marks for u/a)
  - `src/model/markdown.ts` (`keepMarks`)
  - `src/wow/frameCodec.ts`, `src/actions.ts`, `src/config.ts`
  - Tests: `test/phase2.test.ts` (new), `test/phase1.test.ts`, `test/snapshot.test.ts`, `test/vectors.test.ts`, `test/vectors/model-effort.json`
- **Protocol/docs:**
  - `protocol/PROTOCOL.md` (rev 1.2, D14, D15)
  - `protocol/fixtures/*` (regenerated)
  - `protocol/vectors/model_effort_c2.*`
  - `protocol/vectors/README.md`
  - `scripts/dev/make-fixture.js`
  - `docs/t3-api-notes.md` §9
  - this file

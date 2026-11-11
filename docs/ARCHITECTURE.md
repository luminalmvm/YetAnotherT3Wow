# Architecture

T3Bridge has three parts that run on one Windows PC:

| Part | Language | Job |
|---|---|---|
| `addon/T3Bridge` | Lua 5.1 + XML (WoW addon API) | Tracker, chat window, minimap button; reads the live file, draws outbound frames |
| `companion` | TypeScript on Node 22 (no runtime dependencies) | Talks to the local T3 Code server, writes the live file and image slots, decodes outbound frames, runs commands |
| `capture-helper/T3Capture` | C# / .NET 7+ | Read-only window capture of WoW's top-left strip (Windows.Graphics.Capture); one-shot clipboard and image-decoding tools |

The wire format in both directions is specified in [protocol/PROTOCOL.md](../protocol/PROTOCOL.md). If code and that file disagree, the file wins.

## T3 Code side

The companion finds the server through `%USERPROFILE%\.t3\userdata\server-runtime.json` and always connects to `127.0.0.1:<port>`, even though the server binds all interfaces. It authenticates with a scoped bearer token (`orchestration:read` + `orchestration:operate`) issued by T3's own CLI, stored DPAPI-encrypted in `%LOCALAPPDATA%\T3Bridge\bearer.dat`.

- Reads: one WebSocket (`/ws`, Effect-RPC JSON) with `orchestration.subscribeShell` (thread list) and `orchestration.subscribeThread` (the thread open in game). REST is used for history pages.
- Writes: `orchestration.dispatchCommand` with `message.dispatch` (send), `thread.model-selection.set` (model and effort), `thread.stop` and `runtime-request.respond` (approvals and answers).
- Command ids are derived from the addon's message id (`t3bridge:<thread>:<clientMsgId>`). T3 treats a repeated command id as a no-op, so a retransmitted or replayed send can never post twice.

Everything T3-specific sits behind the `T3Client` interface (`companion/src/t3/client.ts`, `project.ts`). The API is undocumented and nightly; see [t3-api-notes.md](t3-api-notes.md) for every call, with redacted samples in [fixtures/](fixtures/).

## Inbound: companion to addon (the live file)

WoW addons cannot open files or sockets. They can only load files that existed when the client started. T3Bridge uses that:

1. `install-addon.ps1` creates `Interface\AddOns\T3Bridge_Live\live.lua`, padded to exactly 524288 bytes, and 500 load-on-demand "slot" addons `T3Bridge_S0001` to `T3Bridge_S0500`.
   - **Variant B** (default): each slot holds `live.lua` as an NTFS hard link to the shared file.
   - **Variant A**: each slot's TOC lists `..\T3Bridge_Live\live.lua`.
2. The companion rewrites `live.lua` **in place** (offset 0, no truncate, never rename) so every hard link sees the new content. Writes are debounced (300 ms, at most 4 per second) with a heartbeat every 10 s; acks are written at once.
3. To poll, the addon calls `LoadAddOn` on the next unused slot. The client reads the file from disk again, the file sets the global `T3B_IN`, and the addon validates it (`T3B_IN_END` must match `seq`, otherwise it was a torn read and is retried).
4. Each slot can load only once per session, so **one poll uses one slot**. The cadence adapts: every 15 s idle, 3 s while a thread runs, 1 s while the chat window is open and T3 is writing. When slots run low the addon offers a `/reload`, which frees them all.

The snapshot holds up to 30 open top-level threads (not settled, archived, deleted or subagent threads; the thread open in game is always included), ordered needs-you, running, then most recent. Only the open thread's messages are included (a 40-message window, 8000 bytes per message, 480 KiB in total). On a clean stop the companion overwrites `live.lua` and `T3Bridge\Inbox.lua` with an empty snapshot.

### Subagent threads (PROTOCOL rev 1.4)

T3 gives every subagent its own thread (delegated tasks and provider-native subagents such as Claude's `Agent` tool), linked to its parent by `lineage` ([t3-api-notes.md §11](t3-api-notes.md#11-subagents-2026-11-11-protocol-rev-14)). The filtered shell subscription omits idle and finished subagents, so the companion also fetches each listed thread's family with `orchestration.getThreadFamily` (one call per family, again at most every 4 s when a subagent in it changes) and merges it with the live shell rows (the newer row wins). Top-level rows get `kids`/`kidsRunning`/`kidsNeed`; up to 8 subagents per row (40 in total) go into `subs`; the focused thread gets `focus.parent`, `focus.kids` (20) and `focus.path` (breadcrumb, 4 entries). A focused subagent is listed with `parent=` even when finished. Messages that refer to a child thread (T3's 'Delegated task "X" finished' line, a subagent in a tool run, a `t3-thread://` link) carry `{"tl", label, id=}` segments. In game, the chat window shows an Up arrow and a clickable breadcrumb for a subagent and a collapsible Subagents strip for a parent; the tracker shows a badge (`+3`, `1 running`, `1 needs you`) that lists the subagents under their row; the thread menu indents them under their parent. No new outbound command: `focus <tid>` opens a subagent like any thread.

`Inbox.lua` is a fallback listed in the addon's TOC: it is read only at login or `/reload`.

## Outbound: addon to companion (the pixel matrix)

When you send, switch thread, change model or answer a prompt, the addon draws a matrix of black and white cells at the top-left corner of the screen:

- 256 columns × 8 rows for short commands, 32 rows for long text; row 0 is the sync pattern `1010…`.
- A frame carries a header (magic `T3`, version, flags, addon session id, sequence, part numbers), up to 974 payload bytes and a CRC-32. Long messages split into parts.
- Default cell size 2 physical pixels (a 512×16 px strip), shown for about 200 ms. The addon pixel-snaps the strip to physical pixel (0,0) regardless of UI scale.
- Stop-and-wait: the addon waits for the companion's `ack` in the live file and retransmits a few times (about 12 s in total) before it reports "Companion not responding".

`T3Capture` attaches to the WoW window with Windows.Graphics.Capture (cursor capture off, yellow border off where allowed), copies only the top-left 1100×200 px region from GPU to CPU, and passes crops that contain a sync row to the companion over stdout. The companion's decoder fits the cell pitch by least squares over the sync row, tries every sync candidate and lets the CRC decide.

### Measured reliability (from the development notes)

- Synthetic frames: cells of 2 and 4 px decode 100 % under every tested scaling (1.25× to 2×, nearest and bilinear); 1 px only when pixels are exact.
- Live capture of a D3D11 flip-model test window: 0 decode failures in every run; lost parts were only frames the compositor never delivered.
- Against the running game: helper CPU about 1–5 % of one core, region readback 0.6–0.7 ms.
- Exclusive fullscreen and real 60 Hz latency were not measured.

Full numbers: [dev-notes/PHASE0-REPORT-A.md](dev-notes/PHASE0-REPORT-A.md).

## Images (PROTOCOL rev 1.3)

The same "only files that existed at start-up" rule applies to textures, so images use **image slots**:

1. `install-addon.ps1 -ImageSlots 100` creates `Interface\AddOns\T3Bridge_Img\i0001.tga … i0100.tga`, each a fixed 512×512 32-bit TGA (1,048,594 bytes), fully transparent.
2. For a picture in the focused thread (a T3 `user_message` attachment), the companion fetches the bytes from T3 (`assets.createUrl`), decodes and fits them into 512×512 with the capture helper's `decode` tool (TGA in TypeScript), and overwrites a free slot **in place** with the picture in its top-left corner. Only then does the snapshot name the slot: `{"img","[image: name]",s=12,w=320,h=180,…}`.
3. The addon shows the slot texture cropped with `SetTexCoord(0, w/512, 0, h/512)` (at most 240×160 inline, up to 512 in the viewer), and sets the texture only once the image scrolls into view.
4. WoW caches a texture the first time it is used, so each slot shows one picture per WoW session. The companion tracks used slots per WoW process (pid + start time, `imgslots.json`); a WoW restart frees all of them. At most 8 new pictures per snapshot, only for the newest 40 messages. On a clean stop every used slot is blanked again.

Sending pictures: Ctrl+V in the message box or the Attach button sends `clip` (the helper's `clipboard` tool reads the Windows clipboard) or `shot` (newest WoW screenshot). The companion keeps the staged files in `%LOCALAPPDATA%\T3Bridge\tmp`, shows thumbnails in their own slots, and on `send` uploads them to T3 (`attachments.createUploadUrl` + a signed POST) and attaches them to `message.dispatch`. `/t3 spike img` (with `scripts\spike-image-slots.ps1`) checks on the real client that an overwritten, never-loaded slot shows the new picture; `/t3 spike img fail` makes images fall back to `[image: name]` text.

## Addon layout

| File | Role |
|---|---|
| `Compat.lua` | Client feature detection, escaping |
| `Codec.lua` | Frame building, CRC-32, cell rendering |
| `State.lua` | Snapshot validation, tracker rules, cadence, link status |
| `Core.lua` | Settings (`T3BridgeDB`), events, sending |
| `Inbound.lua` / `Outbound.lua` | Slot polling / matrix drawing and retransmits |
| `UI/*.lua` | Tracker, chat window (attach menu, staged images), messages (light markdown, inline images), image viewer, prompts, minimap button, copy dialog |
| `Demo.lua`, `DemoMode.lua` | `/t3 demo` data (generated from `protocol/fixtures/live.sample.lua`) |
| `Spike.lua` | In-game self-tests (`/t3 spike …`) |
| `Slash.lua` | `/t3` commands, each run in a protected call |

SavedVariables (`T3BridgeDB`) store only positions, settings, per-thread collapse state and opened subagent lists keyed by thread id, and the image spike result (`img.works`, `img.reloadFrees`). They never contain titles, message text or images.

## Development history

The addon and companion were built in phases; the reports with every measurement and decision are in [dev-notes/](dev-notes/).

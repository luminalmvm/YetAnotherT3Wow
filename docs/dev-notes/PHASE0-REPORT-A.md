# Phase 0 report: Track A (T3 API spike S3, companion, live-capture outbound)

> Historical development notes from building T3Bridge (2026-11). Kept for the measurements and the
> reasoning behind design decisions. Script paths were updated to the current repo layout and
> machine-specific paths were replaced with placeholders. For current usage see the main
> [README](../../README.md) and [docs](../).

Date: 2026-11-11. Machine: Windows 11 Pro 10.0.26300, Node 22.18, .NET SDK 7.0.304, two monitors
(2560×1440 primary at 100 % scaling, 96 DPI; a 1920-wide secondary). T3 Code Nightly 0.1.8.
WoW was not running.

**Most important caveat:** nobody had touched the PC for ~14.5 h during these tests (displays almost
certainly asleep). In that state DWM composites at **~3.7 frames/s system-wide**. I measured this for
window capture, monitor capture, and a 280 fps D3D flip-model window alike. Every live-capture number
below was taken under that throttle, so it is a **worst case** for timing. It does not affect decode
correctness. I did not wake the displays (that changes machine state while you are away). To re-measure
at the real rate, run `bash scripts/dev/run-e2e-matrix.sh 200 120 awake` while you are at the PC.

---

## 1. Verdict

| Item | Status |
|---|---|
| T3 server discovery, auth (scoped bearer, DPAPI), list/read threads, live subscribe | **VERIFIED** |
| Send message, set model (+ model list), interrupt, approve/deny, answer user input | **VERIFIED** on throwaway threads (created and deleted by the spike) |
| Thread deep link `t3code://threads/<env>/<thread>` | INFERRED from the bundle (not fired: it would navigate your open T3 window) |
| `live.lua` writer (in-place padded and rename modes, debounce, heartbeat, seq/END) | Implemented, unit-tested (fake timers, hard link, reader holding the file open). Not yet run against the real `live.lua` (Track B may be testing with it). |
| Outbound decoder (sync search, threshold, CRC, multi-part, dedupe) | Implemented. Self-test and 75 unit tests pass. Cross-checked both ways with Track B's Lua codec. |
| Live capture helper (Windows.Graphics.Capture, .NET 7) | **Works**: real WGC capture of a D3D11 flip-model window decodes 100 % of the frames it receives. |
| **Full loop on real T3**: pixels → WGC → decoder → bridge → `message.dispatch` → agent reply → ack in `live.lua` | **VERIFIED** (cell 2 and cell 1) |
| WoW windowed / borderless / exclusive fullscreen | **Not tested**: WoW was not running (§5) |
| Screenshot-file fallback | Implemented as secondary (PNG/TGA/BMP decoders + watcher), unit-tested with synthetic files |

**Recommendation:** make live window capture (WGC) the outbound channel and keep screenshots only as a
manual fallback. Default **cell = 2 px**, R = 8/32 as in PROTOCOL.md, and **hold ≥ 200 ms** (§4). Details in §6.

## 2. T3 API (spike S3)

Full write-up: [`t3-api-notes.md`](../t3-api-notes.md) with [`fixtures/`](../fixtures/). Summary:
- **Auth:** `t3 auth session issue --scope orchestration:read --scope orchestration:operate --json` gives a
  revocable bearer, so the user does nothing. The token is stored DPAPI-protected in
  `%LOCALAPPDATA%\T3Bridge\bearer.dat`. The pairing path (`t3 pair` → `POST /oauth/token` token exchange) is
  verified too and available as `--pair`.
- **Reads:** REST `/api/orchestration/shell?omitOlderSettled=1&omitIdleSubagents=1` (header
  `x-t3-orchestration-protocol: 2`) and `/threads/:id/bounded|history|transcript`. Live: WebSocket `/ws`
  (Effect RPC JSON, `wsTicket` from `POST /api/auth/websocket-ticket/rpc`) with `orchestration.subscribeShell`
  and `orchestration.subscribeThread`.
- **Writes:** all through `orchestration.dispatchCommand`: `message.dispatch` (send),
  `thread.model-selection.set`, `thread.stop`, and `runtime-request.respond` with either `decision` or `answers`.
  Models come from `server.getConfig → providers[].models[]`.
- Surprises that affect the design:
  1. `thread.turn.start` does not exist in protocol 2. Sending is `message.dispatch` with `dispatchMode: queue_after_active`.
  2. **Command ids are global and permanent.** Replaying one on the same thread is a silent no-op, which gives free
     idempotency (the companion uses `t3bridge:<thread>:<clientMsgId>`). Replaying on another thread is an error.
  3. Runtime request ids are about 400 characters long and contain `%`, so the companion maps them to short `rid`s.
  4. `visibleTurnItems[].position` is relative to the window. The stable message index comes from `item.ordinal`.
  5. Shell stream snapshots that carry `resolvedRepositoryIdentityRoots` are partial and must be merged, not replaced.
  6. In `approval-required` mode, read-only commands (`echo`) run without asking. `mkdir` asked.
- Measured: `dispatchCommand` round trip 14–57 ms; send → Haiku reply ≈ 3 s; model change visible in 110–125 ms;
  stop → `interrupted` ≈ 1 s; filtered shell 115 ms / 221 KB (unfiltered 3.5 MB).

## 3. Companion (built and tested)

`companion/` (TypeScript, Node 22, no runtime dependencies: built-in `fetch`/`WebSocket`, `zlib`, and
DPAPI through PowerShell). Modules: `t3/discovery`, `t3/auth` (+`dpapi`), `t3/wsRpc`, `t3/client` (the
`T3Client` interface and its WS/REST implementation), `t3/project` (wire → domain), `t3/fakeClient` (demo),
`model/snapshot` (caps, truncation, id maps), `model/markdown` (segments + transliteration),
`wow/luaEscape`, `wow/liveWriter`, `wow/frameCodec`, `wow/frameDecoder`, `wow/captureClient`,
`wow/screenshotWatcher` + `imageDecode`, `actions`, `bridge`, `selftest`, `main`.
Config: `%LOCALAPPDATA%\T3Bridge\config.json`.

Tests (`npx vitest run`): **75 tests in 9 files, all passing.** They cover Lua escaping (every byte
round-trips; forbidden escape forms never appear), parsing the generated `live.lua` with a strict Lua-subset
parser (Track B's `live.sample.lua` parses with it too), the 8000 B per-message cap that keeps the tail and
re-opens a cut code fence, the 480 KiB fit, thread ordering and status mapping, tid/rid maps, the in-place
writer (never creates the file, fixed size, hard link stays live, a concurrent reader does not block it), the
rename writer, debounce / 4 writes per second / heartbeat with fake timers, projections built from the
**live-captured fixtures** (approval and AskUserQuestion), bridge command handling with the fake T3 (send
idempotency under retransmit, multi-part reassembly, ack/asid/err rules, new addon session), the decoder,
the reassembler, the capture record parser, PNG/TGA/BMP decoding, and the screenshot watcher (only new
files, never deletes).

`--demo` writes a realistic snapshot without T3 and reacts to addon commands (send streams a canned reply;
model, stop and answers change state). `--once` against the live T3 wrote 12 threads in 1.8 KB of Lua
(padded to 524288 B), to a scratch file and not into WoW.

## 4. Outbound: live capture measurements

### 4.1 How it was measured
`capture-helper/T3TestWindow` stands in for WoW. It renders through a **D3D11 FLIP_DISCARD swapchain with
vsync Present every frame** (CPU-composed frames, 250–325 presents/s). That is the same path WGC sees from
WoW's D3D12 flip-model swapchain. It draws frames from the reference encoder at its top-left and logs
show/hide timestamps. `T3Capture` attaches to it by HWND (client-area origin; title bar 31 px, border 1 px
removed automatically). The Node harness (`dist/testing/e2eCapture.js`) decodes, reassembles and compares.
Each run: 10 messages / 16 parts (hello, focus, send of 40–4000 bytes incl. UTF-8 and tabs, model, ans,
intr, hist). Scale factors > 1 draw cell edges at `round(k·cell·scale)`, i.e. a UI scale that does not map
cells to whole pixels.

### 4.2 Decode reliability: real WGC capture (compositor throttled to ~3.7 fps)
Hold 700 ms / gap 350 ms (so every part gets ≥ 2 captured frames):

| cell \ scale | 1.0 | 1.25 | 1.5 |
|---|---|---|---|
| 1 px | 10/10 msgs, 16/16 parts | 10/10, 16/16 | 10/10, 16/16 |
| 2 px | 10/10, 16/16 | 10/10, 16/16 | 7/10, 13/16 ¹ |
| 4 px | 10/10, 16/16 | 10/10, 16/16 | 10/10, 16/16 |

Hold 200 ms / gap 120 ms (PROTOCOL default) under the same throttle: 44–88 % of parts captured
(e.g. c2 ×1.0: 13/16, c4 ×1.5: 13/16, c1 ×1.25: 7/16; one c4 ×1.0 run got 0/16 because the helper failed to attach once, and the re-run got 12/16). **Decode failures in every live run: 0.** All losses
are frames the throttled compositor never delivered (one frame every ~270 ms against a ~230 ms window).
The addon's 4 retransmits would recover them, at the cost of up to ~3 s per lost part.
¹ No decode errors; the parts were never delivered by the throttled compositor.

### 4.3 Decode reliability: synthetic images (`node dist/main.js --selftest`), 18 decodes per cell
(6 messages × 3 backgrounds: game-like, white, noise; offsets 1–3 px and a 31 px title bar)

| cell | exact | ×1.25 near / bilin | ×1.5 | ×1.75 | ×2.0 |
|---|---|---|---|---|---|
| 1 px | 18/18 | 18/18 / **5/18** | 18/18 / 18/18 | 18/18 / **10/18** | 18/18 / 18/18 |
| 2 px | 18/18 | 18/18 / 18/18 | 18/18 / 18/18 | 18/18 / 18/18 | 18/18 / 18/18 |
| 4 px | 18/18 | 18/18 / 18/18 | 18/18 / 18/18 | 18/18 / 18/18 | 18/18 / 18/18 |

Robustness on exact pixels: noise ±40 (c2) 6/6; dim/gamma tone curves (30..170, γ 1.8; HDR-like γ 0.5) 6/6
at c1 and c2; **3×3 box blur breaks c ≤ 2 (0/6)**, c4 6/6. WGC copies pixels exactly, so blur only matters if
something rescales the frame.

**About "DPI scaling":** the monitor runs at 100 % (96 DPI), so I could not trigger real DWM bitmap scaling
of a DPI-unaware window. The scale factors above emulate it (and an addon UI scale that does not map cells to
whole pixels). The test window supports `--dpi unaware` for a re-run on a scaled monitor. WoW is DPI-aware and
the addon pixel-snaps (PROTOCOL §3.3), so in practice cells should be exact.

### 4.4 Latency
- Live, throttled (~3.7 fps): part shown → decoded **p50 87–199 ms, p95 ≈ 190–265 ms** (426 ms in one run).
  This is almost entirely the wait for the next composited frame.
- Real-T3 loop: `send` drawn → **visible as a user message in the T3 thread after 252 ms** (cell 2; 1.3 s at
  cell 1, where the first pass was missed and the retransmit caught it).
- Pipeline cost per captured frame: helper GPU→CPU readback of the region **0.3–3 ms**; Node decode
  **p50 0.3–1 ms** (p95 < 2 ms).
- Expected with displays awake (60 Hz, helper active mode 30 fps): about one capture interval plus < 5 ms,
  i.e. **≈ 20–50 ms** from show to decode. Not measured.

### 4.5 CPU / resources (helper)
At the throttled rate: 0–3 % of one core steady (6–10 % in the first interval, which includes start-up),
working set 86–88 MB (the .NET runtime). Region readback means it never copies a full frame to the CPU.
At a real 60–144 Hz, every frame raises an event; frames over the throttle are dropped right after
`TryGetNextFrame` (no GPU copy). Still to measure with WoW running. If it is too high, the next step is
`GraphicsCaptureSession.MinUpdateInterval` (present on this OS per `ApiInformation`, but not in the
22621 projection available to .NET 7; it would need raw COM).

### 4.6 Bugs found and fixed during the spike (worth knowing)
1. **Frame-pool starvation:** not disposing `frame.Surface` keeps the pool's buffers busy, so WGC stalls until the GC runs.
2. **One-frame lag:** `TryGetNextFrame` returns the **oldest** queued frame. The helper now drains the queue and keeps the newest.
3. **Look-alike background:** game scenery next to the matrix can mimic `1010…`, shifting the start by an even number of cells
   (2/18 exact-pixel cases failed). The decoder now tries every sync candidate and lets the CRC decide.
4. **Sub-pixel phase:** taking x0 from one edge gave half-pixel errors at non-integer pitch (c1 ×1.25/×1.5 failed in live capture).
   A least-squares fit over the 255 cell boundaries fixed it (c1 ×1.25 then went to 10/10 live).
5. GDI-painted windows produce very few WGC frames. Only the D3D/flip test window is representative.

## 5. Window modes (honest status)
WoW was not running, so none of the WoW modes was tested. What is known:
- **Windowed and "Windowed (Fullscreen)" (borderless):** WoW's D3D12 swapchain is a normal DWM-composited
  flip-model window. The same path worked here with the D3D11 flip test window (title bar and border offsets
  handled). Your `Config.wtf` has `GxMaximize "1"` (a maximized window), which is this case. **Expected to work.**
- **Exclusive "Fullscreen":** WGC window capture of a DXGI exclusive-fullscreen swapchain usually works on
  Windows 10 1903+ because Fullscreen Optimizations turn it into a flip/independent-flip window. With FSO
  disabled, or true exclusive mode, it can return black or stale frames. **Untested: verify in game.**
- Minimized: WGC delivers nothing (the companion keeps waiting; the addon retransmits, then reports "Companion not responding").
- Occlusion: window capture does not need WoW to be visible on top; capture continues behind other windows.
- The yellow capture border is disabled (`IsBorderRequired = false`, granted for unpackaged apps on this
  build) and cursor capture is off, so the cursor cannot cover the matrix.

In-game check (5 minutes): start the companion, run `/t3 spike s2` (Track B) in each display mode, and
watch `%LOCALAPPDATA%\T3Bridge\companion.log` (`capture attached …` and `addon -> hello`). For raw
diagnostics: `T3Capture.exe --process Wow --keep-alive --emit-all` (stats on stderr).

## 6. Recommendation for the outbound channel
1. **Primary: WGC live capture** (`T3Capture`). It is read-only, has no screen flash and no game hitch, works
   behind other windows, decodes 100 % of delivered frames, and is cheap (region readback).
2. **Cell = 2 px default.** It survives every scaling and filtering case tested. 1 px only decodes reliably when
   pixels are exact (bilinear scaling at 1.25×/1.75× fails often); 4 px is the safe choice for unusual setups.
   R = 8 for commands and 32 for text (as specified). That means 512×16 px (commands) or 512×64 px (text) for
   about 230 ms per part.
3. **Hold:** keep 200 ms with displays awake (≈ 6 captures at 30 fps active mode). Consider 300 ms for the
   first part after a long idle period, because idle polling is 10 fps. Measure with `run-e2e-matrix.sh` while you are at the PC.
4. **Screenshot fallback:** keep it only as an opt-in for systems where WGC fails (for example exclusive fullscreen
   without FSO). It needs `screenshotFormat` png or tga (JPEG destroys the cells), and it hitches and flashes.

## 7. Open questions
1. WoW in exclusive fullscreen (§5), and helper CPU at the game's real frame rate.
2. Real latency and loss at 60 Hz (re-run the matrix with displays awake).
3. PROTOCOL suggestions for Track B ([companion-protocol-notes.md](../companion-protocol-notes.md)): reword "truncate"
   in §2.3 rule 1 as "overwrite in place"; add an optional `focus.older` flag because `i` is sparse.
4. Should completed threads stay in the tracker list longer than PROTOCOL's 30 min? The companion sends the 12 most relevant.
5. `afterSequence` resume for subscriptions (fewer full snapshots after reconnects) is not implemented yet.

## 8. How to reproduce
```
cd companion && npm install && npm run build
npx vitest run                                   # 75 unit tests
node dist/main.js --selftest                     # decoder matrix (+ all vectors, incl. protocol/vectors)
dotnet build -c Release ..\capture-helper\T3Capture
dotnet build -c Release ..\capture-helper\T3TestWindow
node dist/testing/e2eCapture.js --cell 2 --hold-ms 200      # one live-capture run (JSON result)
bash ../scripts/dev/run-e2e-matrix.sh 200 120 awake            # 9-run matrix -> companion/test-results/
node dist/testing/e2eLoop.js --cell 2                        # full loop on real T3 (throwaway thread, deleted after)
python ../scripts/dev/crosscheck-lua-vectors.py ..               # Track B Codec.lua vs companion vectors (needs lupa)
```
Raw results from these runs are not shipped in this repo; `run-e2e-matrix.sh` writes new ones to
`companion/test-results/` (git-ignored).

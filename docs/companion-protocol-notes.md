# Companion side of protocol/PROTOCOL.md: implementation notes for the addon side

`protocol/PROTOCOL.md` is the contract. The companion follows it. This file covers how the
companion fills in the parts the contract leaves open, a few deviations where I think the companion's
behaviour is safer, and suggestions. Code paths are under `companion/src/`.

## Inbound (`live.lua`)

| Topic | Companion behaviour |
|---|---|
| File | `<AddOns>\T3Bridge_Live\live.lua`. **Never created** by the companion: if it is missing, the companion logs "run the addon installer and restart WoW" and keeps retrying (`wow/liveWriter.ts`). `--demo --out <file>` and tests are the only places it creates a file. |
| Write mode | Default `inplace`: open the existing file, write the full image at offset 0, **no truncate**, never rename or delete. Image = UTF-8 Lua + ASCII spaces up to exactly 524288 B (or the current file size, if that is larger). Optional `rename` mode for variant A. |
| ⚠ Deviation | §2.3 rule 1 says "truncate, write". Because the size is fixed at 524288, overwriting without truncating ends in the same file state and avoids a short-file window, so the companion does not truncate. Suggest rewording rule 1 to "overwrite in place at offset 0". |
| Retry | EBUSY/EPERM/EACCES: 10 tries, 50 ms apart. Unit test: a reader holding the file open does not block the write. |
| Rate | Debounce 300 ms, at most 4 writes/s (250 ms gap), a write is never delayed more than 1.2 s under continuous change, heartbeat every 10 s, ack writes immediate. `seq` +1 per write (heartbeats included); `T3B_IN_END` is always the last statement and equals `seq` (unit-tested by parsing the output). |
| Size | ≤ 480 KiB of Lua before padding: the oldest focus messages are halved, then dropped, until it fits (`model/snapshot.ts: fitSnapshot`). Per message ≤ 8000 B: **the tail is kept** with a `(...earlier text cut...)` marker, a cut code fence is re-opened, and `more=true`. |
| Encoding | Raw UTF-8 (§2.3 rule 3). Only `\\ \" \n \r \t` and `\ddd` (3 digits) for other bytes < 0x20 and 0x7F. Config `asciiOnly: true` writes every byte ≥ 0x80 as `\ddd`; this yields identical Lua strings, only larger. |
| `\|` | **Not escaped**. The addon escapes `\|` (`Compat.Escape`), which matches the reference fixture. |
| Transliteration | On by default (`transliterate`): characters the enUS WoW fonts lack become ASCII: smart quotes → `"` `'`, dashes → `-`/`--`, `…` → `...`, arrows → `->`, ✓/✅ → `[ok]`, box drawing → `-`/`\|`/`+`, zero-width characters dropped, other emoji dropped, CJK → `?`. Latin-1 and Latin Extended-A letters (åäöéñ…) are kept. This changes display text only; it applies to titles, names and messages. |
| `threads` | ≤ 12, ordered needs-you, running, then most recent. Subagent and archived threads are excluded. The focused thread is always included. `title` ≤ 120 B, `model` = display name ("Claude Opus 5.5") ≤ 64 B, `proj` = project title ≤ 64 B. `t1` is omitted while running. |
| `st` | `preparing/queued/starting/running/waiting` → `running`. `completed`, `failed`. `interrupted/cancelled/rolled_back` → `stopped`. `idle` and anything unknown → `idle`. |
| `need` | Pending runtime request kind `user_input` → `input`; any other kind (`command`, `file-change`, `permission`, …) → `approval`. |
| `focus` | Omitted until the focused thread's detail has loaded (normally < 0.5 s after `focus`). `focus.model` = model **slug** (e.g. `claude-opus-5-5`). `models` = the models of the thread's provider instance. |
| `pending` | `rid` = `"r"` + 12 hex chars of SHA-1 of T3's request id (T3's ids are ~400 chars with `%`, outside the §1 charset). Approval option ids are T3 decisions: `accept`, `acceptForSession`, `acceptAlways`, `decline`, `cancel`. Input option ids are `o1..oN`; options are only offered for single-question requests. |
| `ack`/`asid`/`err` | `ack` is set when the message is fully reassembled. The snapshot carrying it is written as soon as the command has run, and **at most 1 s** after receipt, so `ack` and `err` usually arrive together. `err` is cleared only by a later (`seq` > `err.seq`) success. A new `asid` resets `ack` to 0 before applying. |
| `Inbox.lua` | Written in place with the same content, at most every 5 s, only if the file exists. |

### Message index `i` (please read)
T3 gives every turn item a stable ordinal (`runOrdinal × 10⁶ + itemInRun`). The companion uses
`i = (runOrdinal − 1) × 100000 + itemInRun`. Properties:
- stable and never reused; a streaming message keeps its `i`; the first item of a thread is `i = 1`;
- **sparse**: tool items are merged into one `t` message and hidden items (checkpoints, reasoning) leave gaps,
  so consecutive messages can differ by 1 to 100000+;
- values stay below 2³¹ for threads with fewer than ~21,000 turns (WoW's Lua 5.1 `%d` is 32-bit on Windows).

Consequences for the addon:
1. `msgs[1].i > 1` almost always means older history exists, but it can be a false positive (for example when the
   thread's first item is a hidden notification). A `hist` then returns nothing new, which is harmless.
2. `hist <tid> <beforeIndex>`: the companion pages T3 history until it has 40 messages with `i < beforeIndex`,
   then sets the window start to the `i` of the 40th one (not `beforeIndex − 40`). The 120-message cap is enforced.

**Suggestion (additive, no version bump):** add `focus.older = true|false` (whether older history exists)
so the addon does not have to infer it from `i`. The companion has the information (`hasMoreHistory`)
and can write it (now done: PROTOCOL D11).

## Outbound (pixel matrix)

| Topic | Companion behaviour |
|---|---|
| Capture | `capture-helper/T3Capture` (Windows.Graphics.Capture, read-only, cursor capture off, yellow border off where the OS allows) crops the **client-area** origin of the WoW window (it removes the title bar/border offset using DWM extended frame bounds and `ClientToScreen`) and copies only the region (default 1100×200) from GPU to CPU. It pre-detects the sync row in C#, emits only crops that contain a matrix, and skips duplicates (same 1-bit hash within 2 s). |
| Decoder | `wow/frameDecoder.ts`: searches sync-row starts at x ≤ 96, y ≤ 200 (§3.3 asks for ≥ 64×32). It fits the cell pitch and phase over all 255 cell boundaries by least squares, so non-integer pitch from 0.75 to 12 px works. The threshold is the midpoint of the sync row's white and black means, which handles dim, HDR or gamma-shifted captures. Every sync candidate is tried (the background can mimic `1010`) and the **CRC decides**. |
| Cell size | Exact-pixel c = 1, 2, 4 all decode. Under display scaling (nearest or bilinear, 1.25–2×), **c = 2 and 4 decode 100%**; c = 1 decodes 100% with nearest scaling but only 28–56% with bilinear at 1.25× and 1.75×. Recommend keeping **c = 2 as the default** and offering c = 1 only for "pixel-exact" setups. See [dev-notes/PHASE0-REPORT-A.md](dev-notes/PHASE0-REPORT-A.md). |
| Reassembly | Per §3.6: dedupe on (sid, seq, part), join raw bytes before UTF-8 decoding, execute once per (sid, seq); retransmits only refresh the ack; a new sid drops old partials; partials expire after 30 s. |
| Commands | `send` → T3 `message.dispatch` with `commandId = "t3bridge:<threadId>:<clientMsgId>"`; T3 itself deduplicates command ids, so even a companion restart cannot double-send. `ans` free text on an **approval** = `decline` + feedback text for the agent. `ans` on a multi-question input = one answer per line (option number, option id, or text). `model` is validated against the thread's provider models. `intr` → `thread.stop`. `open [tid]` → `t3code://threads/<env>/<thread>` (reserved; the addon does not send it). |
| `hello` | Optional fields are logged (`proto`, `addonVersion`, `cell`, `rows`). |

## Test vectors
- Companion vectors: `companion/test/vectors/*.json` (camelCase: `sidHex`, `seq`, `flags`, `messageUtf8`,
  `messageHex`, `frames[] = {part, parts, rows, hex, crc32, cells[]}`). They include the 206/207-byte boundary,
  a retransmit flag, UTF-8/tab/newline payloads and a 5-part 4026-byte `send`. Regenerate with `UPDATE_VECTORS=1 npx vitest run test/vectors.test.ts`.
- **Cross-check done:**
  - The addon's `addon/T3Bridge/Codec.lua`, run under real Lua 5.1 (lupa), produces byte-identical frames and
    cell strings for all 11 companion vectors (`scripts/dev/crosscheck-lua-vectors.py`, "pure" bit mode).
  - The companion decodes all of the addon's `protocol/vectors/*.json` (snake_case is read by an adapter) and
    all their rendered `.png` images through the screenshot+matrix decoder (`test/vectors.test.ts`).

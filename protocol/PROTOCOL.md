# T3Bridge wire protocol, v1 (revision 1.2)

> **Revision 1.2 (Phase 2, 2026-11-11), backward compatible, wire version stays `1`:** D14 adds the
> reasoning-effort picker (`focus.effort`, `focus.models[i].opts`, an optional 4th field on `model`)
> and light markdown marks in user/assistant `p` segments. D15 changes thread selection to "every open
> (unsettled) thread", raises the cap from 12 to 30 and drops the 30-minute tracker rule. Older addons
> ignore the new fields, show at most their first 12 threads, and show `**`/`# ` marks literally.
> Older companions ignore the 4th `model` field.

This file is the contract between the **WoW addon** (`addon/T3Bridge`) and the **Windows
companion** (`companion/`). If the code and this file disagree, this file wins. Change it
first, then the code.

- Inbound (companion → addon): a Lua snapshot file that the addon loads through load-on-demand "slot" addons.
- Outbound (addon → companion): a black-and-white pixel matrix drawn at the top-left of the game
  screen for a few frames. The companion reads it with Windows.Graphics.Capture, which only reads.

Test data:
- `protocol/fixtures/live.sample.lua`: a full snapshot (6 threads, a focused thread with 40 messages and a pending approval).
- `protocol/vectors/*.json` (+ `.png`): outbound frames, from bytes to cells to pixels.
  `scripts/dev/gen-vectors.js --check` recomputes every vector with its own JavaScript CRC32 and
  bit packing, separate from the Lua encoder.

---

## 0. What changed from the design brief (read this first)

The brief's formats are kept. Everything below is an addition or a clarification. Each item names the gap it closes.

| # | Change | Why |
|---|--------|-----|
| D1 | **New field `T3B_IN.asid`** (8 lowercase hex chars): the addon session id that `ack` refers to. The addon only takes `ack` when `asid` matches its own session. | The addon restarts `seq` at 1 after every `/reload`. Without `asid`, an `ack=17` left from the previous session would falsely confirm new commands 1..17. |
| D2 | The 4-byte `sid` in the outbound frame is the **addon session id**: random at addon load, and regenerated when `seq` would pass 65535. `seq` is per message, starts at 1, never 0. | The brief left open whose `sid` this is. The companion de-duplicates on `(sid, seq)`. |
| D3 | `part` counts from 1 (`1..parts`). All parts of one message share `seq`. `ack` confirms a whole message. | The brief left this undefined. The status line shows "Sending 2/3". |
| D4 | `flags` bit 0 = retransmission. Other bits are 0, and the decoder ignores them. Every multi-byte field is big-endian. The CRC covers bytes 0 .. end of payload. | The brief left this undefined. |
| D5 | **New optional field `T3B_IN.err = {seq=, text=}`**: the companion could not carry out command `seq` (for example, an unknown thread). | Without it, the addon cannot show anything for a command that arrived but failed. |
| D6 | Live-file write rules (§2.3): write in place (truncate and write the same file, never rename), UTF-8, only Lua 5.1 string escapes, and **pad to a fixed size of 524288 bytes** with trailing spaces until spike S1 shows that growth works. Heartbeat rewrite at least every 10 s. | Hard links (variant B) break on rename. An earlier experiment found that files created after login are not visible. The S1 "growth" test checks whether the client caches file size from login; padding avoids that risk either way. |
| D7 | Segment kinds are defined (`p` text, `c` code; anything else renders as `p`). The per-message `more=true` means the companion **cut this message short**. Older history is implied by `msgs[1].i > 1`. | The brief left this undefined. |
| D8 | `hello` may carry optional trailing fields: `hello\t<proto>\t<addonVersion>\t<cell>\t<rows>`. Receivers ignore unknown trailing fields on every command. | Lets the companion log the addon version and geometry. Older parsers that split on tab still work. |
| D9 | `focus.msgs` is a window of at most 120 messages. `hist` widens it toward older messages (§2.6). | The brief left `hist` behaviour undefined. |
| D10 | Addon-side only: spike slots `T3Bridge_TA01..` (variant A) and `T3Bridge_TB01..` (variant B) load `T3Bridge_Live\spike.lua`. Only `/t3 spike s1` uses them. The companion never writes `spike.lua`. | Lets one game session test both variants without using up production slots. |
| D11 | **New optional field `focus.older`** (bool): T3 holds messages older than `msgs[1]`. When present the addon uses it for the "Earlier messages" button instead of guessing from `msgs[1].i > 1` (message indexes are sparse). (Phase 1) | Suggested by the companion side: `i` gaps made the guess wrong. |
| D12 | **Exit snapshot**: a companion that stops cleanly writes one last snapshot with `threads={}`, no `focus` and `ts=0`, to `live.lua` and `Inbox.lua`. The addon then shows "Companion offline" at once and no conversation text stays on disk. `node dist/main.js --clear` writes the same snapshot (with a new `sid`). (Phase 1) | Privacy: the live file holds the focused thread's text in plain text. |
| D13 | Addon: while the chat window shows thread X and a fresh snapshot has no `focus` for X (companion restarted, or the first `focus` was lost), the addon sends `focus X` again, at most once every 10 s. (Phase 1) | Otherwise an open chat stayed on "Loading thread..." after a companion restart. |
| D14 | **Reasoning effort** (Phase 2). `focus.effort` = the effort the focused thread runs with (T3 option `effort`, resolved like T3 does: the stored value if the model offers it, legacy `ultracode` as `xhigh`, else the model's default). `focus.models[i].opts = {{id="effort", vals={...}, def="..."}}` lists the model's effort ids in menu order and its default; models without an effort option have no `opts`. Outbound `model <tid> <modelId> [effort]`: with the 4th field the companion sets model and effort in one T3 `thread.model-selection.set`, keeping every other option (`fastMode`, `ultracode`, `contextWindow`, ...). Without it, the stored effort is kept, or replaced by the new model's default if the new model does not offer it. An effort the model does not offer becomes its default. `ultrathink` is a real stored value in T3 0.1.8 (T3 sends the model's default API effort and prefixes each prompt with "Ultrathink:"). **Markdown marks:** user (`u`) and assistant (`a`) `p` segments keep `**bold**` (`__x__` becomes `**x**`) and headings as a line `# text` (any level); inline `` `code` `` and `- ` / `1. ` list items were already kept. The addon styles them; tool/system text is unchanged. | The user asked for an effort picker next to the model picker; one command means one matrix flash for "switch model + fall back effort". |
| D15 | **Open threads** (Phase 2). `threads` = every open thread, at most **30** (was 12): not settled in T3 (`settledAt` null; T3's `thread.settle` / `thread.auto-settle` set it, `thread.unsettle` clears it), not archived or deleted, not a subagent. Order: needs you, running, then the rest by most recent update. The focused thread is always included, even when settled. The addon lists every thread in the tracker until it is settled. No 30-minute rule, and opening a row never hides it. Rows can be collapsed per thread (addon-only state, stored as thread ids in SavedVariables). | The user wants all open threads visible and to dismiss them only by settling them in T3. |

---

## 1. Shared identifiers and limits

| Item | Rule |
|------|------|
| Thread id `tid` | `[A-Za-z0-9_-]{1,40}`. The companion maps T3 ids to these, for example the first 8 hex digits of the UUID, lengthened on collision. Never contains a tab or newline. |
| Request id `rid`, option id, model id | `[A-Za-z0-9_.:/-]{1,64}`. No tab, no newline. |
| Companion session `sid` (inbound) | 4 to 8 chars `[a-z0-9]`. A new value every time the companion starts. |
| Addon session `asid` | 4 random bytes, written as 8 lowercase hex chars inbound. |
| Text encoding | UTF-8 everywhere. |
| Outbound input cap | The user's text is at most **4000 bytes** of UTF-8. The addon enforces this. |
| Threads in snapshot | ≤ 30 (D15; was 12) |
| Messages in snapshot | ≤ 120 (default window 40) |
| Message body | ≤ 8000 bytes per message in the snapshot. Longer bodies are cut, with `more=true`. |
| Snapshot size | ≤ 480 KiB of Lua before padding. Padded file = 524288 bytes. |
| Titles | ≤ 120 bytes. Project and model names ≤ 64 bytes. |

Times are Unix epoch seconds (integers) from the same PC's clock. The addon compares them with WoW's `time()`.

---

## 2. Inbound: snapshot file

### 2.1 Delivery mechanism

WoW cannot read arbitrary files at runtime. The addon can only **load an addon**, and a
load-on-demand (LoD) addon can only be loaded once per UI session. The installer therefore creates
N stub addons, `T3Bridge_S0001` … `T3Bridge_SNNNN` (default 500, at most 2000). Each folder holds only a TOC:

```
## Interface: 16001
## Title: T3Bridge slot 0001
## LoadOnDemand: 1
## Dependencies: T3Bridge
## Group: T3Bridge
## X-T3Bridge-Slot: 1
live.lua                         <- variant B (NTFS hard link to the shared file)
..\T3Bridge_Live\live.lua        <- variant A (shared path)
```

Each poll calls `C_AddOns.LoadAddOn("T3Bridge_S%04d")` on the next unused slot, which runs
`live.lua` as it currently is on disk. A `/reload` resets every slot.

- **Variant A**: every slot TOC points at the one file `Interface\AddOns\T3Bridge_Live\live.lua`.
- **Variant B**: every slot folder has its own `live.lua`, each an NTFS hard link to
  `T3Bridge_Live\live.lua`. Because they are hard links, an in-place write through any of those paths changes all of them.

The companion writes the same canonical path in both variants:
`<AddOns>\T3Bridge_Live\live.lua`. Variant B **requires in-place writes**: renaming a new file into place breaks every hard link.

**Fallback floor**: the companion also rewrites `<AddOns>\T3Bridge\Inbox.lua`, in the same format and
in place. The main addon's TOC loads it once at startup, so it only refreshes on `/reload`. It is
fine to write it less often, for example at most every 5 s.

### 2.2 File format

The file holds exactly two assignment statements and nothing else (no function calls):

```lua
T3B_IN={v=1,sid="k3f9",seq=4812,ts=1794393000,ack=17,asid="9f3a01c2",
 err=nil,
 threads={
  {id="a1b2c3d4",title="Fix flaky login test",st="running",need=nil,t0=1794392000,t1=nil,model="claude-opus-5-5",proj="t3code"},
 },
 focus={id="a1b2c3d4",model="claude-opus-5-5",
  models={{id="claude-opus-5-5",name="Opus 5.5"},{id="claude-sonnet-5-5",name="Sonnet 5.5"}},
  streaming=true,
  pending={kind="approval",rid="req-77",text="Run `npm test`?",options={{id="allow",label="Allow"},{id="deny",label="Deny"}}},
  msgs={
   {i=131,r="a",ts=1794392990,segs={{"p","Here is the fix:"},{"c","local x = 1"}},more=false},
  }}}
T3B_IN_END=4812
```

`T3B_IN_END` must be the **last statement** and must equal `T3B_IN.seq`.

#### Top level

| Field | Type | Req | Meaning |
|-------|------|-----|---------|
| `v` | int | yes | Protocol version, `1`. The addon ignores snapshots with any other `v`. |
| `sid` | string | yes | Companion session id. A change means the companion restarted: the addon resets its inbound state. |
| `seq` | int | yes | Snapshot counter, 1..2^53. Goes up with every write in a companion session. |
| `ts` | int | yes | When this file was written (epoch seconds). Rewritten at least every 10 s, even with no changes (heartbeat). |
| `ack` | int | yes | The highest addon message `seq` fully received from addon session `asid`. 0 = nothing yet. |
| `asid` | string | yes* | The addon session `ack` refers to. 8 hex chars, or `""` before any frame has arrived. *Old writers may leave it out; the addon then takes no acks. |
| `err` | table/nil | no | `{seq=<addon seq>, text="<short human message>"}` for the most recent failed command from `asid`. Stays until a later command succeeds or fails. |
| `threads` | array | yes | ≤ 30 thread summaries of the user's open (unsettled) threads (D15), ordered: needs you (approval/input), running, then most recently updated. Never settled, archived, deleted or subagent threads, except that the focused thread is always included. Summaries only: message text appears only under `focus`, for the focused thread. |
| `focus` | table/nil | no | Detail for the thread named by the last `focus` command, or `nil`. |

#### Thread summary

| Field | Type | Meaning |
|-------|------|---------|
| `id` | string | tid |
| `title` | string | Thread title, ≤ 120 bytes. |
| `st` | string | `running` \| `completed` \| `failed` \| `stopped` \| `idle`. Unknown values show as `idle`. |
| `need` | string/nil | `approval` \| `input` while the thread is waiting on the user (any `st`), else nil. |
| `t0` | int/nil | Start of the current or latest run. |
| `t1` | int/nil | End of the latest run (nil while running). |
| `model` | string/nil | Model display name. |
| `proj` | string/nil | Project name. |

How the addon shows a thread: `need ~= nil` → "needs you" (orange, pulsing). Otherwise it follows `st`.
Phase 2 (D15): every listed thread has a tracker row, `idle` included, until the thread is settled in T3
(the companion then stops sending it). Opening a thread does not hide its row. Collapsed rows (addon
setting) are compact and sorted after the expanded ones. They expand again when the thread needs you or fails.

#### Focus

| Field | Type | Meaning |
|-------|------|---------|
| `id` | string | tid. The addon shows messages only when this equals the thread the user selected. |
| `model` | string/nil | Current model **id**. |
| `effort` | string/nil | Optional (D14). The thread's reasoning effort id (e.g. `"high"`). nil when the current model has no effort option. |
| `models` | array | `{id=, name=, opts=}` choices for the model dropdown. Empty or nil hides the dropdown. `opts` (optional, D14) = `{{id="effort", vals={"low","medium",...}, def="medium"}}`; only the effort option is sent. |
| `streaming` | bool | The assistant is producing output right now. |
| `pending` | table/nil | `{kind="approval"\|"input", rid=, text=, options={{id=,label=},...}}`. `options` may be empty for `input`. |
| `older` | bool/nil | Optional (D11). `true` = older messages exist before `msgs[1]` (send `hist` to get them); `false` = `msgs[1]` is the thread's oldest shown message. Absent: the addon guesses from `msgs[1].i > 1`. |
| `msgs` | array | Oldest first, ≤ 120. |

#### Message

| Field | Type | Meaning |
|-------|------|---------|
| `i` | int | Message index in the thread, starting at 1. Never reused. A message whose body changes (streaming) keeps its `i`. |
| `r` | string | Role: `u` user, `a` assistant, `t` tool, `s` system. |
| `ts` | int | Creation time. |
| `segs` | array | Ordered segments `{kind, text}`. `kind` `"p"` = text paragraph(s), `"c"` = code block (the text carries no backtick fences). Unknown kinds render as `"p"`. In `u`/`a` messages, `p` text may carry the D14 marks: `**bold**`, `` `code` ``, `# heading` lines, `- ` / `1. ` list items (2 spaces per nesting level). |
| `more` | bool | `true` = the companion cut this message to the size limit. The addon shows "(truncated — full text in T3 Code)". |

### 2.3 Writing rules (companion)

1. **Overwrite in place.** Open the existing file with share mode read/write and write the whole
   padded image at offset 0, then close. Do not truncate first: the file has a fixed size (rule 2),
   so overwriting leaves it in the same final state without a short-file window. Never delete it,
   rename it, or replace it with a new file. If the open fails because WoW has the file open, retry
   after 50 ms, up to 10 times.
2. **Pad** the file to exactly 524288 bytes with trailing ASCII spaces (`0x20`) after the final
   newline. If the Lua text alone is over 480 KiB, cut the oldest message bodies further until it fits. Padding may be dropped later if `/t3 spike s1` reports `growth PASS` on the user's client.
3. **Encoding.** UTF-8 without a BOM. Strings use double quotes and only the **Lua 5.1** escapes
   `\\ \" \n \r \t` and `\ddd` (decimal, exactly 3 digits for any other byte below 0x20 and for
   0x7F). **Never `\x..`, `\u{..}`, `\z`**, or long brackets `[[ ]]`. Raw UTF-8 bytes ≥ 0x80 go into strings unchanged.
4. Only table constructors, strings, integers, `true`, `false`, `nil`. No function calls, operators, or extra statements.
5. Rate: write when state changes, at most 4 times per second, plus a heartbeat at least every 10 s.
6. `seq` goes up by 1 with every write, heartbeats included.
7. The installer creates `T3Bridge_Live\live.lua` (and the hard links) before WoW starts. The
   companion must never create the file itself if it is missing: a file created after the game started is not visible to it. Report "run the installer and restart WoW" instead.

### 2.4 Acceptance (addon)

Before each load the addon sets `T3B_IN=nil` and `T3B_IN_END=nil`. It then calls `LoadAddOn`
inside a swallowing error handler: it saves `geterrorhandler()`, installs a handler that only
records the error, and restores the saved one afterwards. Then:

```
if type(T3B_IN) ~= "table"            -> reject "missing"     (torn file / syntax error / missing)
if T3B_IN.v ~= 1                       -> reject "version"
if T3B_IN_END ~= T3B_IN.seq            -> reject "torn"
if T3B_IN.sid ~= lastSid               -> RESET (forget lastSeq, message cache, completed-seen set), accept
elif T3B_IN.seq <= lastSeq             -> reject "stale"       (nothing new; not an error)
accept: lastSeq = seq; build model
companion offline  <=> no accepted snapshot, or time() - T3B_IN.ts > 30
```

A rejected snapshot never changes the UI. After a "torn" or "missing" reject, the next poll comes
after 0.5 s instead of the usual interval (once only, then normal cadence). The addon also checks every field's type and drops anything malformed, without raising an error.

### 2.5 Poll cadence (addon) and slot budget

| Condition (first match wins) | Interval |
|---|---|
| No slots left | stop polling, show "Link exhausted: click to reload" |
| Within 10 s of an outbound send, or waiting for an ack | 1 s |
| Chat window open and `focus.streaming` | 1 s |
| Any thread running or needing you | 3 s |
| Otherwise (idle, offline, no snapshot yet) | 15 s |

Every poll uses up one slot. When fewer than 10 % of slots are left, the status bar and tracker
show "Link low: click to reload". `ReloadUI()` runs **only** when the user clicks that. The addon never reloads on its own.

### 2.6 Focus window and history

- After `focus <tid>`, the companion sets `focus` to that thread with its newest ≤ 40 messages.
- `hist <tid> <beforeIndex>` asks for the up-to-40 messages before `beforeIndex`. The companion
  widens the window start to `max(1, beforeIndex-40)` and keeps it until the next `focus`. The window holds at most 120 messages. Above that cap, the companion drops `hist`.
- The companion sets `focus.older` (D11) so the addon knows whether to offer "Earlier messages".
- After a companion restart the addon re-sends `focus` for the thread open in its chat window (D13).
- The addon keeps an in-memory cache, by `i`, of the focused thread's messages, so earlier pages stay visible even if the window shrinks. It clears the cache on focus change or companion `sid` change.

---

## 3. Outbound: pixel matrix

### 3.1 Commands (payload)

UTF-8. Fields are separated by a single TAB (`0x09`). No trailing newline. The **last** field of
`send` and `ans` may contain tabs and newlines: split at most 3 times. Receivers ignore extra trailing fields on the other commands.

| Command | Fields | Meaning |
|---------|--------|---------|
| `hello` | `[proto] [addonVersion] [cell] [rows]` | Sent once per addon session, at the first fresh snapshot whose `asid` is not ours. |
| `focus` | `<tid>` | Make `tid` the focused thread (§2.6). |
| `send` | `<tid> <clientMsgId> <text>` | Send a user message. `clientMsgId` = `<asid>-<seq>`, the idempotency key. |
| `model` | `<tid> <modelId> [effort]` | Change the thread's model; the optional 3rd argument also sets its reasoning effort (D14). The effort-only picker sends the current model id with the new effort. |
| `intr` | `<tid>` | Stop or interrupt the running turn. |
| `ans` | `<tid> <rid> <optionId\|text>` | Answer a pending request. If the field exactly equals one of the pending request's option ids, it is that option. Otherwise it is free text. |
| `hist` | `<tid> <beforeIndex>` | Ask for older messages. |
| `open` | `[tid]` | Bring the T3 Code app to the front. **Reserved; the addon never sends it** (the user's choice). |

### 3.2 Frame layout (bytes)

All multi-byte integers are big-endian.

| Offset | Size | Field | Value |
|---|---|---|---|
| 0 | 2 | magic | `0x54 0x33` ("T3") |
| 2 | 1 | ver | `0x01` |
| 3 | 1 | flags | bit0 = retransmission; other bits 0 |
| 4 | 4 | sid | addon session id (raw bytes) |
| 8 | 2 | seq | message seq, 1..65535 |
| 10 | 1 | part | 1..parts |
| 11 | 1 | parts | 1..255 |
| 12 | 2 | len | payload bytes in **this** frame |
| 14 | len | payload | slice `[(part-1)*cap, ...)` of the message bytes |
| 14+len | 4 | crc32 | CRC-32/ISO-HDLC (zlib `crc32`: reflected, poly 0xEDB88320, init and xorout 0xFFFFFFFF) of bytes `0 .. 13+len` |

Frame overhead = 18 bytes. Check value: `crc32("123456789") = 0xCBF43926`.

### 3.3 Matrix geometry

- **Width** 256 cells. Each cell is `c × c` physical pixels, `c ∈ {1, 2, 4}` (default **2**; the user can change it with `/t3 cell`).
- **Rows** `R` = 8 (command frames) or 32 (text frames). Row 0 is the sync row; rows 1..R-1 carry data.
  Capacity is `(R-1) × 32` bytes, so payload per frame is ≤ **206** bytes (R=8) or ≤ **974** bytes (R=32).
- **Colours**: white `(1,1,1)` = bit 1, black `(0,0,0)` = bit 0, drawn on an opaque black backing of exactly `256c × Rc` pixels.
- **Sync row** (row 0): cell `x` is white when `x` is even (`1010…`, 128 white cells). The decoder
  can find the matrix and work out `c` from this row alone.
- **Data**: frame byte `k` sits in row `1 + floor(k/32)`, cells `8·(k mod 32) .. +7`, MSB first.
  Cells after the last frame byte are 0 (black).
- **Placement**: the top-left cell sits at physical pixel (0,0) of the game's render surface. In
  windowed mode, WGC may include the window border or title bar, so **the decoder must search** the
  top-left region (at least 64 px down, 32 px right) for the sync row rather than assuming (0,0).
- **Pixel exactness**: the addon uses a top-level frame with `SetIgnoreParentScale(true)` and
  `SetScale(768 / physicalHeight)`, so one UI unit is one physical pixel. Decoders should still
  sample each cell's centre, with a 50 % luma threshold.

How the addon picks frames for a message `M` (`#M` bytes):
- `#M ≤ 206`: one frame, R=8.
- otherwise: R=32, `parts = ceil(#M / 974)`. Every part except the last carries exactly 974 bytes.
  The split may fall inside a UTF-8 character: the companion joins the raw bytes before decoding.
- Largest message: `send` + tid + clientMsgId + 4000-byte text ≈ 4070 bytes → 5 parts.

### 3.4 Timing

For each part:
1. Show the matrix. Wait until **2 frames have rendered** (2 `OnUpdate` calls after `Show`).
2. Keep it visible for `hold` ms more (default 200, range 100–500, `/t3 hold`).
3. Hide it. Leave it hidden for at least 2 rendered frames and 50 ms before the next part.

At 30 fps, a 200 ms hold means about 6 capture frames see each part. The decoder takes a part the
first time it sees it with a valid CRC, and ignores repeats with the same `(sid, seq, part)`.

### 3.5 Sender state machine (stop-and-wait)

```
IDLE --enqueue--> SENDING(part 1..n) --last part hidden--> WAIT_ACK(deadline = now+3s)
WAIT_ACK --T3B_IN.asid==sid and T3B_IN.ack>=seq--> DONE -> next message
WAIT_ACK --deadline, attempts<4--> SENDING (all parts again, flags.bit0=1, attempts+1)
WAIT_ACK --deadline, attempts==4--> FAILED: status "Companion not responding"; drop the message;
          if it was a `send`, put its text back into an empty input box; the queue continues
```

- One message in flight at a time. Waiting `focus` and `model` commands coalesce (a newer one replaces an older queued one for the same kind).
- While waiting for an ack, polling runs at 1 s (§2.5).
- `T3B_IN.err.seq == seq` also ends WAIT_ACK (as DONE). The addon shows `err.text`.
- When `seq` would pass 65535, the addon makes a new `sid`, restarts at 1, and queues a new `hello`.

### 3.6 Receiver rules (companion)

1. Find the sync row, work out `c`, read row 1. Check for `"T3"`, `ver==1`, and that `len` fits the visible rows, then check the CRC. Drop the frame on any failure.
2. Store the part under `(sid, seq, part)`. When all `parts` parts are present, join them, decode as UTF-8, and carry out the command **once** per `(sid, seq)`. Retransmits of a completed message only refresh the ack.
3. Set `asid = hex(sid)` and `ack = seq` in the next snapshot (write it right away, without waiting for the 250 ms rate limit).
4. A new `sid` (addon reload) replaces the old one. There is only one addon instance.
5. Partial parts older than 30 s are thrown away.

---

## 4. Error cases (summary)

| Case | Addon behaviour |
|------|-----------------|
| Slot addons missing or disabled | It tries `EnableAddOn` once per slot. With no usable slot it falls back to `Inbox.lua` only and says "No link slots — run install-addon.ps1". |
| File torn or syntax error | Error swallowed silently, snapshot rejected, retry after 0.5 s. |
| `T3B_IN_END` mismatch | Rejected as torn. |
| Stale `seq` | Ignored (normal when nothing changed). |
| `ts` older than 30 s | "Companion offline". Last data stays visible, dimmed. |
| `sid` changed | Message cache and seen-set reset, `hello` re-armed. |
| No ack after 3 tries | "Companion not responding". |
| Slots < 10 % | "Link low: click to reload". |
| Slots = 0 | Polling stops, "Link exhausted: click to reload". |

## 5. Versioning

- `v` in the snapshot and `ver` in the frame are both `1`. A breaking change bumps both.
- Additive optional fields do not bump the version. Readers must ignore unknown fields.

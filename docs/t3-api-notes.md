# T3 Code local API: notes for the T3Bridge companion

Target: **T3 Code Nightly 0.1.8** (`serverVersion 0.1.8-nightly.20261109.4433`, orchestration protocol **2**), Windows.
Sources: the live local server (read-only calls, plus write calls **only on throwaway threads created and
deleted by the spike**), and the shipped bundles (`resources/server.asar`, `resources/app.asar`), which I
extracted to my scratchpad and only read.

Labels: **VERIFIED** means I observed it against the live server. **INFERRED** means I read it from the
bundle and did not run it. Redacted samples are in [`docs/fixtures/`](fixtures/). The implementation
lives in `companion/src/t3/` (`discovery.ts`, `auth.ts`, `wsRpc.ts`, `client.ts`, `project.ts`).

> Security: the server binds `0.0.0.0` (`server-runtime.json: host`). The companion always connects to
> `127.0.0.1:<port>`. No token, ticket or pairing code appears in logs, docs or fixtures.

---

## 1. Discovery (VERIFIED)

`%USERPROFILE%\.t3\userdata\server-runtime.json`:

```json
{"version":1,"pid":12345,"host":"0.0.0.0","port":3773,"origin":"http://127.0.0.1:3773",
 "startedAt":"…","serverVersion":"0.1.8-nightly.20261109.4433","managedPolicy":null,"ownerId":"…"}
```

- Use `port` and build `http://127.0.0.1:<port>` yourself. Do not use `host`.
- `pid` liveness check: `process.kill(pid, 0)`.
- Probe without auth: `GET /.well-known/t3/environment` returns
  `{environmentId, label, platform, serverVersion, orchestrationProtocolVersion: 2, capabilities{…}}`
  ([fixture](fixtures/descriptor.json)). The companion refuses to run if the protocol is not `2`.
  `capabilities.threadStop: true` matters for interrupts (§6.3).

## 2. Authentication

### 2.1 What the server accepts (VERIFIED)
`GET /api/auth/session` without credentials returns `authenticated:false` plus a descriptor
([fixture](fixtures/auth-session.unauthenticated.json)):
`bootstrapMethods: ["desktop-bootstrap","one-time-token"]`,
`sessionMethods: ["browser-session-cookie","bearer-access-token","dpop-access-token"]`.
Protected routes return `401 {"_tag":"EnvironmentAuthInvalidError","reason":"missing_credential"}`.

Scopes: `orchestration:read` + `orchestration:operate` are enough for everything the bridge does
(list, read, send, model, stop, respond). The CLI's default set is much broader (settings, terminal,
filesystem…), so the companion always asks for these two explicitly.

### 2.2 Primary: scoped bearer session from the local CLI (VERIFIED, used by the companion)
```
t3 auth session issue --scope orchestration:read --scope orchestration:operate \
    --ttl 90d --label "T3Bridge companion" --json
```
stdout: `{"sessionId","token","method":"bearer-access-token","scopes":[…],"subject","client","expiresAt"}`.
This is T3's documented headless/remote client path. It runs against the local auth control plane
(the user's own data dir), so the user does not need to do anything. The companion
(`auth.ts: issueViaCli`):
- runs it through `cmd.exe` with fixed arguments and parses stdout in memory (never logged),
- validates the token with `GET /api/auth/session` (expects `authenticated:true` and both scopes),
- stores `{token, sessionId, expiresAt, scopes}` **DPAPI-protected (CurrentUser, extra entropy)** in
  `%LOCALAPPDATA%\T3Bridge\bearer.dat`, and non-secret metadata in `auth-meta.json`,
- re-validates on start and after disconnects, and re-issues if the token was revoked or expired.

List or revoke: `t3 auth session list --json` (no tokens shown), `t3 auth session revoke <sessionId>`
(VERIFIED: a revoked token immediately gets `authenticated:false`). `scripts/uninstall-companion.ps1 -RemoveData` revokes it.

### 2.3 Alternative: one-time pairing token, then OAuth token exchange (VERIFIED)
1. `t3 pair --scope orchestration:read --scope orchestration:operate --label T3Bridge` (prints a QR code
   and a link) or `t3 auth pairing create … --json` (`{id, credential, label?, expiresAt}`). TTL defaults to 5 minutes.
2. `POST /oauth/token`, `content-type: application/x-www-form-urlencoded`:
   ```
   grant_type=urn:ietf:params:oauth:grant-type:token-exchange
   subject_token=<credential>
   subject_token_type=urn:t3:params:oauth:token-type:environment-bootstrap
   requested_token_type=urn:ietf:params:oauth:token-type:access_token
   scope=orchestration:read orchestration:operate
   client_label=T3Bridge companion&client_device_type=desktop&client_os=windows
   ```
   Response: `{access_token, issued_token_type, token_type:"Bearer"|"DPoP", expires_in, scope}`.
   Replaying the same credential returns `401 invalid_credential` (VERIFIED: it is single-use).
   Companion: `node dist/main.js --pair` reads the token from stdin. I verified this with a 5-minute
   read-only pairing credential and revoked the resulting session afterwards.

Not used: `POST /api/auth/browser-session {credential}` (cookie sessions), DPoP-bound tokens, and the
`/mcp` + `/oauth/mcp/*` flow (a separate credential type, per the brief).

### 2.4 Request headers (VERIFIED)
- `Authorization: Bearer <token>` on every protected HTTP route.
- `x-t3-orchestration-protocol: 2` is **required** on `/api/orchestration/*`. Without it you get `400`.

## 3. Listing threads (VERIFIED)

### REST
`GET /api/orchestration/shell?omitOlderSettled=1&omitIdleSubagents=1`. The values must be the string `"1"`;
`true` is ignored. With these filters: 60 threads / 221 KB / ~115 ms on this machine. Without them: all
1374 threads / 3.5 MB / 0.6–1 s.

Response: `{schemaVersion:2, snapshotSequence, threads[], archivedThreads[], projects[], olderSettled{before, asOfSequence, counts}}`.
Per-thread fields used by the bridge ([fixture](fixtures/shell-snapshot.sample.json)):

| Need | Field |
|---|---|
| id | `id` (UUID) |
| title | `title` |
| status | `status`: `idle` \| run status (`preparing`, `queued`, `starting`, `running`, `waiting`, `completed`, `interrupted`, `failed`, `cancelled`, `rolled_back`). Seen live: idle, preparing, queued, starting, running, completed, failed, cancelled, interrupted. |
| needs you | `pendingRuntimeRequest: {id, kind, createdAt, blocking?}` or `null` (kind: `command`, `file-read`, `file-change`, `mcp-elicitation`, `permission`, `dynamic_tool_call`, `user_input`, `auth_refresh`) |
| start / end | `latestRunStartedAt` (or `latestRunRequestedAt`), `latestRunCompletedAt` (ISO strings) |
| model | `modelSelection: {instanceId, model, options:[{id,value}]}`, `providerInstanceId` |
| project | `projectId` → `projects[].title` |
| subagents | `lineage.relationshipToParent === "subagent"`. The bridge hides these. |
| hidden | `archivedAt`, `deletedAt`, `settledAt` |

The bridge maps the status to the protocol's `st` (PROTOCOL.md §2.2) like this: active statuses → `running`,
`completed` → `completed`, `failed` → `failed`, `interrupted`/`cancelled`/`rolled_back` → `stopped`,
everything else → `idle`. `need` is `input` when the pending kind is `user_input`, and `approval` for any other pending kind.

Also available: `GET /api/projects` returns `{projects, updatedAt}`.

### Live (WebSocket, preferred)
`orchestration.subscribeShell` with `{omitIdleSubagents:true, omitOlderSettled:true}`. It first sends one full
`snapshot`, then deltas: `thread.updated {sequence, location:"active"|"archive", thread}`,
`thread.removed`, `project.updated`, `project.removed` ([fixture](fixtures/shell-stream-items.sample.json)).
**Gotcha (VERIFIED):** later `snapshot` items that carry `resolvedRepositoryIdentityRoots` hold
`threads: []` and only a subset of projects. These are enrichment refreshes, so merge them and do not
replace your state (`client.ts: onShellItem`). Optional fields: `afterSequence` (resume) and `requestCompletionMarker`.

## 4. Reading a thread (VERIFIED)

| Call | Use |
|---|---|
| `GET /api/orchestration/threads/:id/bounded` | Latest window: `{snapshotSequence, projection{…18 keys}, historyCursor, hasMoreHistory, latestLocalTurnOrdinal}`. Optional query: `deferWork`, `compactTurnItems`, `dedupeBodies`, `compactIds`. 44–660 ms. |
| `GET …/threads/:id/history?cursor=<historyCursor>&view=conversation` | Older page: `{snapshotSequence, items[], nextCursor, hasMoreHistory}` (`view`: `conversation` \| `activity` \| `work`) |
| `GET …/threads/:id` | Full projection (one 2,540-item thread: 524 KB, 115 ms). |
| `GET …/threads/:id/transcript` | `{threadId, title, updatedAt, items[]}` |
| WS `orchestration.subscribeThread {threadId, acceptBoundedSnapshot:true}` | `snapshot` (same as bounded), then `event` items (below). Used by the bridge for the focused thread. |

`projection.visibleTurnItems[] = {position, visibility, sourceThreadId, sourceItemId, item}`. `position` is
relative to the window (0..n-1), so it is **not** a stable index. `item.ordinal = runOrdinal × 10⁶ + itemIndexInRun`
is stable and monotonic across the whole thread. The companion turns it into the protocol's
message index `i = (run−1)·100000 + itemIndexInRun`, so the first item of a thread is `i=1`.

Turn-item `type`s (bundle schema; ✓ = seen live): `user_message`✓ `{text, attachments, inputIntent}`,
`assistant_message`✓ `{text, streaming}`, `reasoning`✓ `{text, streaming}`, `command_execution`✓
`{input, output?, outputOmitted?, exitCode?}`, `dynamic_tool`✓ `{toolName, title(object), input}`,
`file_change` `{fileName, additions, deletions, diffStr?}`, `file_search`, `web_search`, `subagent`✓
`{prompt, result}`, `approval_request`✓, `user_input_request`✓, `todo_list`, `proposed_plan`
`{markdown}`, `checkpoint`✓, `notification`✓ `{summary}`, `run_interrupt_request`✓/`run_interrupt_result`✓ `{message}`,
`system_notice`, `error {failure{message}}`, `compaction`, `handoff`, `fork`, `thread_created`,
`secret_request`, `link_request`. The bridge renders user, assistant and plan items as text. It folds consecutive tool items into
one `t` message, shows requests, errors and interrupts as `s`, and hides reasoning, checkpoints and internal items.

Thread stream `event.type`s seen live: `turn-item.updated` (payload = the **whole** item, so streaming text
grows in place; on a long-running thread this came about every 1–3 s while thinking), `run.updated`,
`run-attempt.updated`, `node.updated`, `message.updated`, `provider-turn.updated`, `provider-thread.updated`,
`provider-session.attached/updated`, `checkpoint-scope.created`, `checkpoint.captured`, and
`runtime-request.updated` (approval/input spike). The bundle lists more (`run.created`, `plan.updated`,
`subagent.updated`, …). The bridge uses `turn-item.updated`, `runtime-request.updated` and `run.created/updated`,
and ignores the rest. See the [fixture](fixtures/thread-stream-items.sample.json).

### Requests (approvals and user input) (VERIFIED)
- Pending state: `projection.runtimeRequests[]`: `{id, kind, status:"pending"|"resolved"|"expired"|"cancelled", responseCapability, decision?, answers?}`.
  `id` is ~400 characters with `%` escapes, so the companion maps it to a short protocol `rid` (`r` + 12 hex chars).
- Details live in the matching turn item (`item.requestId === request.id`):
  - `approval_request {requestKind, prompt?, reason?, options?: [{decision, label, warning?}]}` ([fixture](fixtures/approval-request.pending.json))
  - `user_input_request {questions: [{id, header, question, options:[{label, description, value?}], multiSelect?, allowCustomAnswer?}]}` ([fixture](fixtures/user-input-request.pending.json)). The question `id` was the question text in the live sample.
- Observed: in runtime mode `approval-required`, a read-only command (`echo`) ran without asking, while
  `mkdir` raised a `command` approval.

## 5. WebSocket RPC (VERIFIED)

1. `POST /api/auth/websocket-ticket/rpc` (Bearer) returns `{ticket, expiresAt}` (short-lived; the `rpc` audience).
2. Connect `ws://127.0.0.1:<port>/ws?orchestrationProtocol=2&wsTicket=<ticket>`. Without
   `orchestrationProtocol=2` you get `426 orchestration_protocol_incompatible`. Node 22's built-in `WebSocket` is enough.
3. Messages are Effect-RPC JSON ([verbatim frames](fixtures/ws-frames.sample.json)):
   ```
   → {"_tag":"Request","id":"1","tag":"orchestration.dispatchCommand","payload":{…},"headers":[]}
   ← {"_tag":"Exit","requestId":"1","exit":{"_tag":"Success","value":{"sequence":1673370}}}
   → {"_tag":"Request","id":"2","tag":"orchestration.subscribeThread","payload":{"threadId":"…","acceptBoundedSnapshot":true},"headers":[]}
   ← {"_tag":"Chunk","requestId":"2","values":[{…},…]}      → {"_tag":"Ack","requestId":"2"}   (ack every chunk)
   → {"_tag":"Interrupt","requestId":"2","interruptors":[]}  (cancel a stream)
   → {"_tag":"Ping"}  ← {"_tag":"Pong"}
   ```
   Failures come back as `exit: {_tag:"Failure", cause:…}` with tagged errors (for example `OrchestrationV2DispatchCommandError`).
4. Methods used: `server.getConfig`, `orchestration.subscribeShell`, `orchestration.subscribeThread`, `attachments.createUploadUrl`, `assets.createUrl` (§10),
   `orchestration.dispatchCommand`, and `orchestration.launchThread` (only for the throwaway-thread spike).
   Other methods in the bundle: `getThreadProjection`, `getTurnItem` (full output of omitted items), `searchThread(s)`,
   `getThreadFamily`, `forceStopThread`, `subscribeCommandOutput`, … (INFERRED).

**Subscribe or poll?** Subscribe. One socket carries live shell and thread deltas as the server emits them
(no polling delay). Polling the filtered shell costs ~220 KB per call. The companion reconnects with
exponential backoff (1 s → 30 s) and mints a new ticket each time.

## 6. Write calls: exact formats

All writes are `orchestration.dispatchCommand` with an `OrchestrationV2Command`. The result is `{sequence}`.
**Command ids are global and permanent (VERIFIED).** Re-sending a `commandId` for the same thread
is a silent no-op that still returns success, which makes it a free idempotency key. Re-using it for
another thread fails with `"Command … was already handled for thread X and cannot be replayed for Y"`.
The companion derives `commandId = messageId = "t3bridge:<threadId>:<clientMsgId>"`.

### 6.1 Send a message / start a turn (VERIFIED)
```json
{"type":"message.dispatch","commandId":"t3bridge:<tid>:<clientMsgId>","threadId":"<uuid>",
 "messageId":"t3bridge:<tid>:<clientMsgId>","text":"…","attachments":[],
 "createdBy":"user","creationSource":"web","dispatchMode":{"type":"queue_after_active"}}
```
- `queue_after_active` starts at once on an idle thread and queues behind a running turn, like `t3 thread send`.
  Other modes (INFERRED): `start_immediately`, `steer_active{targetRunId}`, `restart_active{targetRunId}`,
  `defer_start`. Optional: `modelSelection`, `context`, `freshContext`.
- Measured: dispatch ack 14 ms, reply visible (Haiku, "reply PONG2") 3.3 s. Sending the same `commandId` again
  did not create a second message.
- `thread.turn.start` (named in the brief) does not exist in protocol 2. `message.dispatch` replaces it.

### 6.2 Set the thread's model (VERIFIED) and list selectable models (VERIFIED)
```json
{"type":"thread.model-selection.set","commandId":"<uuid>","threadId":"<uuid>",
 "modelSelection":{"instanceId":"claudeAgent_2","model":"claude-haiku-5-5","options":[{"id":"effort","value":"high"}]}}
```
The shell showed the new `modelSelection` after 110–125 ms. Selectable models come from
`server.getConfig → providers[]`: `{instanceId, displayName, enabled, status, models:[{slug, name, isDefault, capabilities.optionDescriptors}]}`
([fixture](fixtures/server-config.providers.json)). The bridge offers the models of the thread's own
`instanceId` (14 for `claudeAgent_2`). Cross-provider switching is a separate `provider.switch` command (INFERRED, not used).

### 6.3 Interrupt (VERIFIED)
```json
{"type":"thread.stop","commandId":"<uuid>","threadId":"<uuid>"}
```
This is what the web client sends when `capabilities.threadStop` is true. A streaming run reached
`interrupted` in ~0.96 s, and a `run_interrupt_result` "Stopped by user" item appeared. Fallback for older servers (INFERRED):
`{"type":"run.interrupt","commandId","threadId","runId":"<active run>","holdQueue":true}`.

### 6.4 Respond to an approval (VERIFIED)
```json
{"type":"runtime-request.respond","commandId":"<uuid>","threadId":"<uuid>","requestId":"<runtimeRequests[].id>",
 "decision":"decline","feedback":"optional text for the agent"}
```
`decision` ∈ `accept` | `acceptForSession` | `acceptAlways` | `decline` | `cancel`. These are also the option ids the
bridge sends to the addon. Verified with `decline`: the command did not run, the agent replied "DENIED",
and the request became `resolved` ([fixture](fixtures/approval-request.resolved.json)).

### 6.5 Answer a user-input request (VERIFIED)
```json
{"type":"runtime-request.respond","commandId":"<uuid>","threadId":"<uuid>","requestId":"<id>",
 "answers":{"<question.id>":"<option label or free text>"}}
```
Verified: answering "Blue" to an AskUserQuestion made the agent reply "Blue". Dismissing without an answer
(INFERRED): `{"type":"thread.user-input.dismiss","commandId","threadId","requestId"}`.

### 6.6 Thread deep link (INFERRED, not executed, because it would navigate the user's open T3 window)
Desktop `promptLinkAppPath()` accepts `t3code://threads/<environmentId>/<threadId>`, which opens app route
`/<environmentId>/<threadId>`, and `t3code://new?…`. `environmentId` comes from `/.well-known/t3/environment`.
The `t3code` scheme is registered to `T3 Code (Nightly).exe "%1"` (VERIFIED in HKCU). `t3code://app` does not match a
route, so the second-instance handler just brings the main window to the front. The companion's `open [tid]` uses
these through `cmd /c start "" <url>`. The addon never sends `open`.

### 6.7 Create / delete a thread (VERIFIED, spike only)
`orchestration.launchThread {commandId, threadId?, projectId, title, modelSelection, runtimeMode, interactionMode:"default",
workspaceStrategy:{type:"root"}, initialMessage:{messageId, text, attachments:[]}}` returns `{threadId, projection, resumed, sequence}`.
`{"type":"thread.delete","commandId","threadId"}` removes it. The bridge never creates or deletes threads.

## 7. Timings measured (this PC, server 0.1.8-nightly)

| Operation | Time |
|---|---|
| filtered shell REST / full shell REST | ~115 ms / 0.6–1.0 s |
| WS connect + first shell snapshot | 0.2–0.5 s |
| `dispatchCommand` round trip | 14–57 ms |
| send → Haiku reply visible | ~3 s |
| model change visible in shell | 110–125 ms |
| `thread.stop` → `interrupted` | ~1 s |

## 8. Open points
- The protocol header value `2` and all field names are nightly-internal (Effect schemas). Everything sits behind
  `T3Client` (`client.ts`) so a schema change only touches `client.ts` and `project.ts`.
- Bearer TTL: the companion asks for 90 days and re-issues automatically, but only while the T3 CLI exists. If the user removes
  `~/.t3/bin/t3.cmd`, use `--pair`.
- History paging uses REST cursors; `afterSequence` resume for subscriptions is not implemented (after a reconnect the bridge simply takes a fresh snapshot).

## 9. Phase 2 additions (2026-11-11)

### 9.1 Model options and the reasoning effort (VERIFIED live on a throwaway thread, then deleted)
- `server.getConfig → providers[].models[].capabilities.optionDescriptors[]`: `{id, label, type:"select", options:[{id,label,isDefault?}], currentValue?, promptInjectedValues?}` or `{id, label, type:"boolean", currentValue?}`.
  Claude models (T3 0.1.8): `effort` select with `low, medium, high, xhigh, max, ultrathink` (Opus 4.5: `low, medium, high, max`; Opus 4.6 / Sonnet 4.6: no `xhigh`); defaults differ per model (Opus 5.5 `medium`, Sonnet 5.5 `high`, Opus 4.7 `xhigh`, ...). Other options: `ultracode`, `fastMode` (booleans), `contextWindow` (select). **Haiku 4.5 has no effort**, only a `thinking` boolean.
- A thread's `modelSelection.options` is an array `[{id, value}]` (older data: an `{id: value}` object). The server stores `thread.model-selection.set`'s `modelSelection` **verbatim** (bundle: `case "thread.model-selection.set": return {...thread, modelSelection: command.modelSelection}`). The web client is responsible for normalising, so the companion keeps every other option and only replaces `effort`.
- Effective effort (bundle `resolveDescriptorChoiceValue`): stored value if offered; otherwise `currentValue ?? isDefault`. Legacy `effort:"ultracode"` maps to `xhigh` + `ultracode:true`.
- `ultrathink` is listed in `promptInjectedValues`: a stored `effort:"ultrathink"` is valid. The run uses the model's default API effort, and every prompt gets an `Ultrathink:` prefix (`applyClaudePromptEffortPrefix`).
- Live sequence (throwaway thread, `claudeAgent_2`), each change visible in the shell after ~420 ms:
  `haiku-5-5 {}` → `(haiku-5-5, low)` → `(opus-5-5, ultrathink)` → `(opus-4-5, keep)` gave `effort:high` (ultrathink not offered there) → `(opus-5-5, xhigh)` → `(haiku-4-5, keep)` left the options untouched (no effort option; `focus.effort` absent) → `(sonnet-5-5, max)`. The thread was then deleted (gone from the shell).

### 9.2 "Settled" threads (VERIFIED in the bundle and the live shell)
- Real T3 concept: commands `thread.settle`, `thread.auto-settle` (sidebar setting `sidebarAutoSettleAfterDays`, `sidebarAutoSettleOnMerge`) and `thread.unsettle`; events `thread.settled` / `thread.unsettled`. Thread fields `settledAt`, `settledOverride` (`"settled"` / `"active"` / null), `unsettledAt`. Settling clears pins; unsettling sets `settledAt:null`.
- The shell (`omitOlderSettled=1`) still contains recently settled threads (with `settledAt` set); older ones are only counted in `olderSettled`.
- Live (2026-11-11): 41 non-subagent, non-archived threads in the filtered shell, **14 with `settledAt == null`** (identical with the unfiltered shell: 355 / 14). `snoozedUntil`/`pinnedAt` were unused.
- The bridge's "open thread" = `settledAt == null && archivedAt == null && deletedAt == null && not subagent` (PROTOCOL D15). Snoozed threads count as open.

## 10. Images (2026-11-11, PROTOCOL rev 1.3)

Verified live on two throwaway threads ("T3Bridge image test / image e2e (safe to delete)", Haiku 4.5,
"No project"), created and deleted by scripts in my scratchpad; both were gone from the full shell afterwards.
None of the user's threads were touched. Redacted shapes: [fixture](fixtures/image-attachments.json).

### 10.1 Images in thread history (VERIFIED)
- `user_message` turn items carry `attachments: [{type:"image", id, name, mimeType, sizeBytes}]` (empty array when
  there are none). The same objects come through `subscribeThread` (snapshot and `turn-item.updated`) and through
  `GET …/threads/:id/bounded` (`projection.visibleTurnItems[].item.attachments`).
- After sending, the attachment id is final: `<threadId>-<uuid>` (the upload's `pending-<uuid>` id is replaced when
  the server "claims" the upload for the thread).
- Schema (bundle, INFERRED beyond the fields above): `ChatAttachment = ChatImageAttachment | ChatFileAttachment |
  ChatUnknownAttachment`; image `mimeType` must match `^image/`, `sizeBytes` ≤ 10 MiB
  (`PROVIDER_SEND_TURN_MAX_IMAGE_BYTES`); an optional `source` describes snapshots taken by T3's own snap tool.
  Images inside tool output use another resource type (`tool-output-image {threadId, itemId, index}`); the bridge
  does not show those (not verified).

### 10.2 Fetching attachment bytes (VERIFIED)
1. WS `assets.createUrl {resource: {_tag:"attachment", attachmentId}}` (scope `orchestration:read`) returns
   `{relativeUrl:"/api/assets/<signed token>", expiresAt (+1 h), imageDimensions?:{width,height}}`. Optional resource
   fields `fileName`, `mimeType`, `disposition:"inline"|"attachment"` made no difference to the bytes.
2. `GET <origin><relativeUrl>`: 200, `content-type: image/png`, the original bytes (SHA-256 identical). The URL is
  signed, so no `Authorization` header is needed. The companion still only ever talks to `127.0.0.1`.

### 10.3 Uploading and sending an image (VERIFIED)
1. WS `attachments.createUploadUrl {type:"image", name, mimeType, sizeBytes}` (scope `orchestration:operate`;
   `mimeType` ∈ `image/png|jpeg|gif|webp`, `sizeBytes` 1..10 MiB) returns
   `{attachmentId:"pending-<uuid>", relativeUrl:"/api/attachments/upload/<signed token>", expiresAt (+10 min)}`.
2. `POST <origin><relativeUrl>` with exactly `sizeBytes` bytes (a different `Content-Length` is refused) returns
   `204`. No bearer needed (signed URL).
3. `message.dispatch` with `attachments:[{type:"image", id:"pending-…", name, mimeType, sizeBytes}]`. The model
   received the image: Haiku answered "Red blue." for a red/blue test PNG, and described a second one correctly.
   **`text: ""` with an image is accepted** (the bridge allows image-only messages).
4. `attachments.delete {attachmentId}` removes an unsent pending upload (only `pending-…` ids; others are ignored).
   Unclaimed uploads are swept by the server after a while (bundle: `sweepStalePendingAttachments`, INFERRED).

### 10.4 How the bridge uses it
- Inline images: `user_message` attachments of the focused thread's newest 40 messages are fetched (10.2), decoded,
  fitted to 512×512 and written into an image slot texture (PROTOCOL D16). At most 8 new images per snapshot.
- Sending: images staged in game (`clip` / `shot`) are uploaded (10.3) when the user sends; formats T3 does not
  accept (TGA, BMP) or files over 10 MiB are converted first (TGA → PNG, others → JPEG).
- The T3 Code MCP tools `t3_attachment_prepare_upload` / `t3_thread_send_attachments` are the same flow behind
  T3's own MCP server (bundle: "POST the file's exact bytes to `relativeUrl` … then send with the returned
  `attachmentId`"); the bridge uses the WebSocket methods directly.

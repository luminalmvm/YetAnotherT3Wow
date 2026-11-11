// T3Client: the only thing the rest of the companion knows about T3 Code.
// Implementation: WebSocket RPC (/ws, orchestration protocol 2) for live state and commands,
// plus REST (/api/orchestration/...) for history pages. See docs/t3-api-notes.md.
import { randomUUID } from "node:crypto";
import { EventEmitter } from "node:events";
import { log } from "../log.js";
import { buildPending, isActiveStatus, itemsToMessages, lineageOf, providersFromConfig, resolveEffort, selectionOptions, shellThreadToSummary, subagentRefs, withEffort } from "./project.js";
import type { AttachmentInput, ImageRef, ModelChoice, PendingRequest, ProjectSummary, ProviderSummary, ThreadDetail, ThreadSummary } from "./types.js";
import { RpcSocket } from "./wsRpc.js";

export interface T3Client {
  readonly connected: boolean;
  start(): Promise<void>;
  stop(): void;
  threads(): ThreadSummary[];
  projects(): Map<string, ProjectSummary>;
  providers(): ProviderSummary[];
  models(providerInstanceId: string): ModelChoice[];
  /** Start watching one thread live (replaces the previous focus). */
  focus(threadId: string | null): Promise<void>;
  focusedThreadId(): string | null;
  /** Detail for the focused thread, or null if not loaded yet. */
  focusDetail(): ThreadDetail | null;
  /** Loads older history for the focused thread until `count` more messages before index `beforeIndex` exist (or none remain). */
  loadOlder(threadId: string, beforeIndex: number, count: number): Promise<void>;
  sendMessage(threadId: string, text: string, idempotencyKey?: string, attachments?: AttachmentInput[]): Promise<void>;
  /**
   * Uploads an image for a later message.dispatch (VERIFIED live, T3 0.1.8): WS `attachments.createUploadUrl`
   * {type:"image", name, mimeType, sizeBytes} -> {attachmentId:"pending-<uuid>", relativeUrl, expiresAt (10 min)},
   * then POST the exact bytes to <origin><relativeUrl> (a signed URL; no bearer needed) -> 204.
   */
  uploadImage(bytes: Buffer, name: string, mimeType: string): Promise<AttachmentInput>;
  /**
   * Bytes of a message attachment (VERIFIED live): WS `assets.createUrl` {resource:{_tag:"attachment", attachmentId}}
   * -> {relativeUrl (signed, 1 h), imageDimensions?}, then GET <origin><relativeUrl>.
   */
  fetchAttachment(ref: ImageRef): Promise<Buffer>;
  /**
   * Set the thread's model (and optionally its reasoning effort), keeping every other model option.
   * If the effort (given, or the thread's current one) is not offered by the model, the model's default is used.
   */
  setModel(threadId: string, modelId: string, effort?: string): Promise<void>;
  interrupt(threadId: string): Promise<void>;
  respondApproval(threadId: string, requestId: string, decision: string, feedback?: string): Promise<void>;
  answerUserInput(threadId: string, requestId: string, answers: Record<string, unknown>): Promise<void>;
  /**
   * Every thread of one family (root + all subagent descendants), as last fetched, or null when not
   * loaded yet (rev 1.4). VERIFIED live: WS `orchestration.getThreadFamily {threadId}` -> {snapshotSequence,
   * threads[]} with shell rows of every thread sharing the root (idle and finished subagents included, which
   * the filtered shell omits).
   */
  family(rootId: string): ThreadSummary[] | null;
  /** The families the snapshot needs; the client fetches missing or changed ones and emits "change". */
  wantFamilies(rootIds: string[]): void;
  /** Shell rows plus cached family rows (optional; used to resolve a tid after a companion restart). */
  knownThreads?(): ThreadSummary[];
  /** "change" whenever threads/focus/pending changed; "connection" on (dis)connect. */
  on(ev: "change" | "connection", fn: (...a: any[]) => void): this;
}

interface FamilyEntry { threads: ThreadSummary[]; sig: string; fetchedAt: number; dirty: boolean }

/** Minimum time between two fetches of the same family (a running subagent updates the shell every few s). */
export const FAMILY_REFRESH_MS = 4000;
/** At most this many families are kept (the snapshot lists <= 30 top-level threads + the focused root). */
const MAX_FAMILIES = 40;

interface FocusState {
  threadId: string;
  items: Map<string, any>;
  runtimeRequests: Map<string, any>;
  runs: Map<string, any>;
  thread: any;
  hasMoreHistory: boolean;
  historyCursor: string | null;
  loaded: boolean;
  cancel?: () => void;
}

export interface RpcT3ClientOptions {
  origin: string;
  getBearer: () => Promise<string>;
  /** Re-read server config (providers/models) every N ms. */
  configRefreshMs?: number;
  includeReasoning?: boolean;
}

/**
 * Deterministic command id from (thread, idempotency key) so a retransmitted `send` is not sent twice.
 * VERIFIED: T3 command ids are global and permanent; replaying one is a no-op for the same thread and an
 * error ("already handled for thread X and cannot be replayed") for another thread.
 */
export function commandIdFor(threadId: string, key: string | undefined): string {
  return key ? `t3bridge:${threadId}:${key}` : randomUUID();
}

/**
 * The `thread.model-selection.set` payload (VERIFIED: T3 stores modelSelection verbatim; options are
 * [{id, value}]). Every option except effort is kept as it was. Effort: the requested value, else the
 * thread's current one; replaced by the model's default when the model does not offer it. Models without
 * an effort option leave the options untouched.
 */
export function buildModelSelection(sel: any, instanceId: string, modelId: string, effort: string | undefined, models: ModelChoice[]): { instanceId: string; model: string; options?: { id: string; value: unknown }[] } {
  const model = models.find((m) => m.id === modelId);
  if (models.length && !model) throw new Error(`model ${modelId} is not offered by ${instanceId}`);
  let options = selectionOptions(sel?.options);
  const choice = model?.effort;
  if (choice) {
    const stored = options.find((o) => o.id === "effort")?.value;
    if (effort !== undefined) {
      options = withEffort(options, choice.values.includes(effort) ? effort : choice.def);
    } else if (stored !== undefined && resolveEffort(choice, options) !== stored) {
      // The stored effort is not offered by the new model: fall back to its default (resolveEffort
      // also maps the legacy "ultracode" to "xhigh").
      options = withEffort(options, resolveEffort(choice, options)!);
    }
  }
  return { instanceId, model: modelId, ...(options.length ? { options } : {}) };
}

export class RpcT3Client extends EventEmitter implements T3Client {
  private sock?: RpcSocket;
  private shellCancel?: () => void;
  private threadMap = new Map<string, ThreadSummary>();
  private rawThreads = new Map<string, any>();
  private projectMap = new Map<string, ProjectSummary>();
  private providerList: ProviderSummary[] = [];
  private focusState: FocusState | null = null;
  private stopped = false;
  private reconnectDelay = 1000;
  private reconnectTimer?: NodeJS.Timeout;
  private configTimer?: NodeJS.Timeout;
  private sentKeys = new Map<string, number>();
  private families = new Map<string, FamilyEntry>();
  private wanted: string[] = [];
  private familyBusy = false;
  private familyTimer?: NodeJS.Timeout;

  constructor(private readonly o: RpcT3ClientOptions) { super(); }

  get connected(): boolean { return !!this.sock?.isOpen; }

  async start(): Promise<void> {
    this.stopped = false;
    await this.connectOnce();
    this.configTimer = setInterval(() => { void this.refreshConfig(); }, this.o.configRefreshMs ?? 120_000);
  }

  stop(): void {
    this.stopped = true;
    if (this.reconnectTimer) clearTimeout(this.reconnectTimer);
    if (this.configTimer) clearInterval(this.configTimer);
    if (this.familyTimer) clearTimeout(this.familyTimer);
    this.focusState?.cancel?.();
    this.shellCancel?.();
    this.sock?.close();
  }

  private async connectOnce(): Promise<void> {
    const sock = new RpcSocket({ origin: this.o.origin, getBearer: this.o.getBearer });
    await sock.connect();
    this.sock = sock;
    this.reconnectDelay = 1000;
    sock.onClose((reason) => {
      log.warn(`T3 connection lost (${reason})`);
      this.emit("connection", false);
      this.scheduleReconnect();
    });
    this.emit("connection", true);
    await this.refreshConfig();
    for (const f of this.families.values()) f.dirty = true;
    this.subscribeShell();
    if (this.focusState) this.subscribeFocus(this.focusState.threadId);
  }

  private scheduleReconnect(): void {
    if (this.stopped || this.reconnectTimer) return;
    const d = this.reconnectDelay;
    this.reconnectDelay = Math.min(this.reconnectDelay * 2, 30_000);
    this.reconnectTimer = setTimeout(async () => {
      this.reconnectTimer = undefined;
      try { await this.connectOnce(); log.info("T3 connection restored"); }
      catch (e) { log.warn(`T3 reconnect failed: ${(e as Error).message}`); this.scheduleReconnect(); }
    }, d);
  }

  private async refreshConfig(): Promise<void> {
    if (!this.sock?.isOpen) return;
    try {
      this.providerList = providersFromConfig(await this.sock.request("server.getConfig", {}));
      this.emit("change", "config");
    } catch (e) { log.warn(`server.getConfig failed: ${(e as Error).message}`); }
  }

  private subscribeShell(): void {
    this.shellCancel?.();
    const s = this.sock!.stream("orchestration.subscribeShell", { omitIdleSubagents: true, omitOlderSettled: true }, (item) => this.onShellItem(item), (err) => {
      if (err && !this.stopped) log.warn(`shell subscription ended: ${err.message}`);
    });
    this.shellCancel = s.cancel;
  }

  private onShellItem(item: any): void {
    switch (item?.kind) {
      case "snapshot": {
        const snap = item.snapshot ?? {};
        const enrichmentOnly = item.resolvedRepositoryIdentityRoots !== undefined && !(snap.threads?.length) && !(snap.archivedThreads?.length);
        if (!enrichmentOnly) { this.threadMap.clear(); this.rawThreads.clear(); for (const f of this.families.values()) f.dirty = true; this.pumpFamilies(); }
        for (const p of snap.projects ?? []) this.projectMap.set(String(p.id), { id: String(p.id), title: String(p.title ?? "") });
        for (const t of snap.threads ?? []) this.upsertThread(t);
        break;
      }
      case "thread.updated":
        if (item.location === "archive") { this.threadMap.delete(String(item.thread.id)); this.rawThreads.delete(String(item.thread.id)); }
        else this.upsertThread(item.thread);
        this.touchFamily(item.thread);
        break;
      case "thread.removed": {
        const raw = this.rawThreads.get(String(item.threadId));
        if (raw) this.touchFamily(raw);
        this.threadMap.delete(String(item.threadId)); this.rawThreads.delete(String(item.threadId));
        break;
      }
      case "project.updated": this.projectMap.set(String(item.project.id), { id: String(item.project.id), title: String(item.project.title ?? "") }); break;
      case "project.removed": this.projectMap.delete(String(item.projectId)); break;
      default: return;
    }
    this.emit("change", "shell");
  }

  private upsertThread(t: any): void {
    const s = shellThreadToSummary(t);
    if (s.archived) { this.threadMap.delete(s.id); this.rawThreads.delete(s.id); return; }
    this.threadMap.set(s.id, s);
    this.rawThreads.set(s.id, t);
    if (this.focusState?.threadId === s.id) this.focusState.thread = { ...this.focusState.thread, ...t };
  }

  threads(): ThreadSummary[] {
    const out = [...this.threadMap.values()];
    // The focused thread must always reach the snapshot. The shell subscription omits "older settled"
    // threads, so fall back to the focused thread's own projection when the shell lacks it.
    const st = this.focusState;
    if (st && !this.threadMap.has(st.threadId) && st.thread && st.thread.id === st.threadId) {
      const s = shellThreadToSummary(st.thread);
      if (!s.archived) out.push({ ...s, partial: true });
    }
    return out;
  }

  /** Shell rows plus every cached family row (resolving a subagent tid the snapshot has not named yet). */
  knownThreads(): ThreadSummary[] {
    const out = this.threads();
    for (const f of this.families.values()) out.push(...f.threads);
    return out;
  }
  /** A subagent changed (created, ran, finished): its family must be fetched again. */
  private touchFamily(t: any): void {
    if (t?.lineage?.relationshipToParent !== "subagent") return;
    const root = lineageOf(t).rootId;
    const f = root ? this.families.get(root) : undefined;
    if (f && !f.dirty) { f.dirty = true; this.pumpFamilies(); }
  }

  family(rootId: string): ThreadSummary[] | null { return this.families.get(rootId)?.threads ?? null; }

  wantFamilies(rootIds: string[]): void {
    const next = [...new Set(rootIds.filter(Boolean))].slice(0, MAX_FAMILIES);
    if (next.join("\n") === this.wanted.join("\n")) { this.pumpFamilies(); return; }
    this.wanted = next;
    for (const k of [...this.families.keys()]) if (!next.includes(k)) this.families.delete(k);
    this.pumpFamilies();
  }

  /** Fetches one missing or dirty family at a time (throttled per family); emits "change" when one changed. */
  private pumpFamilies(): void {
    if (this.familyBusy || this.stopped || !this.sock?.isOpen) return;
    const now = Date.now();
    let wait = Infinity;
    const root = this.wanted.find((r) => {
      const f = this.families.get(r);
      if (!f) return true;
      if (!f.dirty) return false;
      const left = f.fetchedAt + FAMILY_REFRESH_MS - now;
      if (left <= 0) return true;
      wait = Math.min(wait, left);
      return false;
    });
    if (!root) {
      if (wait !== Infinity && !this.familyTimer) this.familyTimer = setTimeout(() => { this.familyTimer = undefined; this.pumpFamilies(); }, wait);
      return;
    }
    this.familyBusy = true;
    const sock = this.sock;
    sock.request("orchestration.getThreadFamily", { threadId: root }, 15000).then((r: any) => {
      const list: any[] = Array.isArray(r?.threads) ? r.threads : [];
      const threads = list.map(shellThreadToSummary).filter((t) => !t.archived);
      const sig = threads.map((t) => `${t.id}|${t.status}|${t.activity}|${t.updatedAt}|${t.pending?.id ?? ""}|${t.title}`).join("\n");
      const prev = this.families.get(root);
      if (this.wanted.includes(root)) this.families.set(root, { threads, sig, fetchedAt: Date.now(), dirty: false });
      if (!prev || prev.sig !== sig) this.emit("change", "family");
    }).catch((e) => {
      log.warn(`getThreadFamily failed: ${(e as Error).message}`);
      // Keep what we had; try again after the throttle interval.
      const prev = this.families.get(root);
      this.families.set(root, { threads: prev?.threads ?? [], sig: prev?.sig ?? "", fetchedAt: Date.now(), dirty: true });
    }).finally(() => {
      this.familyBusy = false;
      this.pumpFamilies();
    });
  }

  projects(): Map<string, ProjectSummary> { return this.projectMap; }
  providers(): ProviderSummary[] { return this.providerList; }
  models(providerInstanceId: string): ModelChoice[] {
    return this.providerList.find((p) => p.instanceId === providerInstanceId)?.models ?? [];
  }
  focusedThreadId(): string | null { return this.focusState?.threadId ?? null; }

  async focus(threadId: string | null): Promise<void> {
    if (this.focusState?.threadId === threadId) return;
    this.focusState?.cancel?.();
    this.focusState = null;
    if (!threadId) { this.emit("change", "focus"); return; }
    this.focusState = { threadId, items: new Map(), runtimeRequests: new Map(), runs: new Map(), thread: this.rawThreads.get(threadId) ?? {}, hasMoreHistory: false, historyCursor: null, loaded: false };
    if (this.sock?.isOpen) this.subscribeFocus(threadId);
    this.emit("change", "focus");
  }

  private subscribeFocus(threadId: string): void {
    const st = this.focusState;
    if (!st || st.threadId !== threadId || !this.sock?.isOpen) return;
    st.cancel?.();
    const s = this.sock.stream("orchestration.subscribeThread", { threadId, acceptBoundedSnapshot: true }, (item) => this.onThreadItem(threadId, item), (err) => {
      if (err && !this.stopped) log.warn(`thread subscription ended: ${err.message}`);
    });
    st.cancel = s.cancel;
  }

  private onThreadItem(threadId: string, item: any): void {
    const st = this.focusState;
    if (!st || st.threadId !== threadId) return;
    if (item?.kind === "snapshot") {
      const p = item.projection ?? {};
      const older = [...st.items.values()].filter((x) => x.__older);
      st.items.clear();
      for (const x of older) st.items.set(x.id, x);
      for (const v of p.visibleTurnItems ?? []) if (v?.item?.id) st.items.set(v.item.id, v.item);
      st.runtimeRequests = new Map((p.runtimeRequests ?? []).map((r: any) => [r.id, r]));
      st.runs = new Map((p.runs ?? []).map((r: any) => [r.id, r]));
      st.thread = { ...st.thread, ...(p.thread ?? {}) };
      if (!older.length) { st.hasMoreHistory = !!item.hasMoreHistory; st.historyCursor = item.historyCursor ?? null; }
      st.loaded = true;
    } else if (item?.kind === "event") {
      const e = item.event ?? {};
      const p = e.payload;
      switch (e.type) {
        case "turn-item.updated":
          if (p?.id && (p.parentItemId == null)) st.items.set(p.id, p);
          break;
        case "runtime-request.updated": if (p?.id) st.runtimeRequests.set(p.id, p); break;
        case "run.created":
        case "run.updated": if (p?.id) st.runs.set(p.id, p); break;
        default: return;
      }
    } else return;
    this.emit("change", "focus");
  }

  focusDetail(): ThreadDetail | null {
    const st = this.focusState;
    if (!st || !st.loaded) return null;
    const shell = this.threadMap.get(st.threadId);
    const items = [...st.items.values()];
    const runs = [...st.runs.values()].sort((a, b) => (a.ordinal ?? 0) - (b.ordinal ?? 0));
    const active = [...runs].reverse().find((r) => isActiveStatus(String(r.status)));
    const pending: PendingRequest | null = buildPending([...st.runtimeRequests.values()], items);
    const sel = st.thread?.modelSelection ?? {};
    const lineage = st.thread?.lineage ? lineageOf({ ...st.thread, id: st.threadId }) : { parentId: shell?.parentId ?? null, rootId: shell?.rootId ?? null };
    return {
      id: st.threadId,
      title: shell?.title ?? String(st.thread?.title ?? ""),
      providerInstanceId: String(sel.instanceId ?? st.thread?.providerInstanceId ?? shell?.providerInstanceId ?? ""),
      modelSlug: String(sel.model ?? shell?.modelSlug ?? ""),
      modelOptions: sel.options,
      streaming: !!active && ["running", "starting"].includes(String(active.status)),
      activeRunId: active?.id ?? null,
      pending,
      messages: itemsToMessages(items, { includeReasoning: this.o.includeReasoning }),
      hasOlder: st.hasMoreHistory,
      subagents: subagentRefs(items),
      parentId: lineage.parentId,
      rootId: lineage.rootId,
    };
  }

  async loadOlder(threadId: string, beforeIndex: number, count: number): Promise<void> {
    const st = this.focusState;
    if (!st || st.threadId !== threadId) return;
    for (let page = 0; page < 5; page++) {
      const have = itemsToMessages([...st.items.values()]).filter((m) => m.i < beforeIndex).length;
      if (have >= count || !st.hasMoreHistory || !st.historyCursor) return;
      const u = new URL(`/api/orchestration/threads/${encodeURIComponent(threadId)}/history`, this.o.origin);
      u.searchParams.set("cursor", st.historyCursor);
      u.searchParams.set("view", "conversation");
      const res = await fetch(u, { headers: { authorization: `Bearer ${await this.o.getBearer()}`, "x-t3-orchestration-protocol": "2" }, signal: AbortSignal.timeout(15000) });
      if (!res.ok) throw new Error(`history page: HTTP ${res.status}`);
      const j: any = await res.json();
      if (this.focusState !== st) return;
      for (const v of j.items ?? []) if (v?.item?.id && !st.items.has(v.item.id)) st.items.set(v.item.id, { ...v.item, __older: true });
      st.hasMoreHistory = !!j.hasMoreHistory;
      st.historyCursor = j.nextCursor ?? null;
      this.emit("change", "focus");
    }
  }

  private async dispatch(command: Record<string, unknown>): Promise<number> {
    if (!this.sock?.isOpen) throw new Error("not connected to T3");
    const r: any = await this.sock.request("orchestration.dispatchCommand", command, 20000);
    return Number(r?.sequence ?? 0);
  }

  async sendMessage(threadId: string, text: string, idempotencyKey?: string, attachments: AttachmentInput[] = []): Promise<void> {
    if (idempotencyKey) {
      const now = Date.now();
      for (const [k, t] of this.sentKeys) if (now - t > 3_600_000) this.sentKeys.delete(k);
      if (this.sentKeys.has(`${threadId}:${idempotencyKey}`)) { log.info(`send ${idempotencyKey} already dispatched; skipping duplicate`); return; }
    }
    const commandId = commandIdFor(threadId, idempotencyKey);
    await this.dispatch({
      type: "message.dispatch",
      commandId,
      threadId,
      messageId: commandId,
      text,
      attachments: attachments.map((a) => ({ type: "image", id: a.id, name: a.name, mimeType: a.mimeType, sizeBytes: a.sizeBytes })),
      createdBy: "user",
      creationSource: "web",
      dispatchMode: { type: "queue_after_active" },
    });
    if (idempotencyKey) this.sentKeys.set(`${threadId}:${idempotencyKey}`, Date.now());
  }

  async uploadImage(bytes: Buffer, name: string, mimeType: string): Promise<AttachmentInput> {
    if (!this.sock?.isOpen) throw new Error("not connected to T3");
    const r: any = await this.sock.request("attachments.createUploadUrl", { type: "image", name, mimeType, sizeBytes: bytes.length }, 15000);
    const id = String(r?.attachmentId ?? "");
    const rel = String(r?.relativeUrl ?? "");
    if (!id || !rel.startsWith("/api/attachments/upload/")) throw new Error("unexpected upload URL from T3");
    const res = await fetch(new URL(rel, this.o.origin), { method: "POST", body: new Uint8Array(bytes), headers: { "content-type": mimeType }, signal: AbortSignal.timeout(30000) });
    if (res.status !== 204 && !res.ok) throw new Error(`image upload: HTTP ${res.status}`);
    return { type: "image", id, name, mimeType, sizeBytes: bytes.length };
  }

  async fetchAttachment(ref: ImageRef): Promise<Buffer> {
    if (!this.sock?.isOpen) throw new Error("not connected to T3");
    const r: any = await this.sock.request("assets.createUrl", { resource: { _tag: "attachment", attachmentId: ref.id } }, 15000);
    const rel = String(r?.relativeUrl ?? "");
    if (!rel.startsWith("/api/assets/")) throw new Error("unexpected asset URL from T3");
    const res = await fetch(new URL(rel, this.o.origin), { signal: AbortSignal.timeout(30000) });
    if (!res.ok) throw new Error(`attachment: HTTP ${res.status}`);
    const len = Number(res.headers.get("content-length") ?? 0);
    if (len > 20 * 1024 * 1024) throw new Error("attachment too large");
    return Buffer.from(await res.arrayBuffer());
  }

  async setModel(threadId: string, modelId: string, effort?: string): Promise<void> {
    const raw = this.focusState?.threadId === threadId ? this.focusState.thread : this.rawThreads.get(threadId);
    const sel = raw?.modelSelection ?? {};
    const instanceId = String(sel.instanceId ?? raw?.providerInstanceId ?? "");
    if (!instanceId) throw new Error("unknown provider instance for thread");
    const modelSelection = buildModelSelection(sel, instanceId, modelId, effort, this.models(instanceId));
    await this.dispatch({ type: "thread.model-selection.set", commandId: randomUUID(), threadId, modelSelection });
  }

  async interrupt(threadId: string): Promise<void> {
    await this.dispatch({ type: "thread.stop", commandId: randomUUID(), threadId });
  }

  async respondApproval(threadId: string, requestId: string, decision: string, feedback?: string): Promise<void> {
    await this.dispatch({ type: "runtime-request.respond", commandId: randomUUID(), threadId, requestId, decision, ...(feedback ? { feedback } : {}) });
  }

  async answerUserInput(threadId: string, requestId: string, answers: Record<string, unknown>): Promise<void> {
    await this.dispatch({ type: "runtime-request.respond", commandId: randomUUID(), threadId, requestId, answers });
  }

  /** Test helper used by the API spike: launch a throwaway thread. Not used by the bridge. */
  async launchThread(input: { projectId: string; title: string; text: string; instanceId: string; model: string; runtimeMode: string }): Promise<string> {
    const commandId = randomUUID();
    const threadId = randomUUID();
    const r: any = await this.sock!.request("orchestration.launchThread", {
      commandId,
      creationSource: "web",
      threadId,
      projectId: input.projectId,
      title: input.title,
      modelSelection: { instanceId: input.instanceId, model: input.model },
      runtimeMode: input.runtimeMode,
      interactionMode: "default",
      workspaceStrategy: { type: "root" },
      initialMessage: { messageId: randomUUID(), text: input.text, attachments: [] },
    }, 30000);
    return String(r?.threadId ?? r?.thread?.id ?? threadId);
  }

  /** Spike helper: delete a thread this companion created. */
  async deleteThread(threadId: string): Promise<void> {
    await this.dispatch({ type: "thread.delete", commandId: randomUUID(), threadId });
  }
}

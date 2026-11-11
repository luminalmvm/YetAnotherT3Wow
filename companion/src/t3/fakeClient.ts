// In-memory T3Client with realistic demo data. Used by --demo and tests. It reacts to commands
// (send -> streamed canned reply, model, interrupt, approvals, input) so the whole addon loop can be
// exercised without T3 Code.
import { EventEmitter } from "node:events";
import { buildModelSelection, type T3Client } from "./client.js";
import type { AttachmentInput, ChatMessage, ImageRef, ModelChoice, PendingRequest, ProjectSummary, ProviderSummary, SubagentRef, ThreadDetail, ThreadSummary } from "./types.js";

interface FakeThread { summary: ThreadSummary; messages: ChatMessage[]; pending: PendingRequest | null; streaming: boolean; nextRun: number; options?: { id: string; value: unknown }[] }

// Effort choices as T3 0.1.8 reports them (server.getConfig, VERIFIED live 2026-11-11).
const EFFORT_ALL = ["low", "medium", "high", "xhigh", "max", "ultrathink"];
const MODELS: ModelChoice[] = [
  { id: "claude-opus-5-5", name: "Claude Opus 5.5", effort: { values: EFFORT_ALL, def: "medium" } },
  { id: "claude-sonnet-5-5", name: "Claude Sonnet 5.5", effort: { values: EFFORT_ALL, def: "high" } },
  { id: "claude-haiku-5-5", name: "Claude Haiku 5.5", effort: { values: EFFORT_ALL, def: "medium" } },
  { id: "claude-fable-5-2", name: "Claude Fable 5.2", effort: { values: EFFORT_ALL, def: "medium" } },
  { id: "claude-opus-4-5", name: "Claude Opus 4.5", effort: { values: ["low", "medium", "high", "max"], def: "high" } },
  { id: "claude-haiku-4-5", name: "Claude Haiku 4.5" },
];

const LONG_REPLY = [
  "I found the flaky part. The login test races the session cookie write:",
  "",
  "```ts",
  "await page.click('#login');",
  "// the cookie is written asynchronously; wait for it",
  "await expect.poll(() => context.cookies()).toContainEqual(expect.objectContaining({ name: 'sid' }));",
  "```",
  "",
  "With that change the suite passed **50/50** runs locally. Next steps:",
  "- run it in CI with `--repeat-each=20`",
  "- remove the `retry: 2` workaround in `playwright.config.ts`",
  "",
  "Smart quotes “like these”, an ellipsis… and an arrow → are transliterated for WoW fonts; pipes | stay raw.",
].join("\n");

/** Fake subagent thread ids (shaped like T3's delegated-task and provider-native ids). */
export const FAKE_KIDS = {
  css: "thread:delegated-task:command%3Amcp%3Afa4e0101-0000-4000-8000-000000000101%3Adelegate-task%3Afa4e0102-0000-4000-8000-000000000102",
  shot: "thread:delegated-task:command%3Amcp%3Afa4e0101-0000-4000-8000-000000000101%3Adelegate-task%3Afa4e0103-0000-4000-8000-000000000103",
  tokens: "thread:provider:claudeAgent:native-thread:provider-thread%3Afake%3Aa0000000000000001",
  vars: "thread:provider:claudeAgent:native-thread:provider-thread%3Afake%3Aa0000000000000002",
};

export class FakeT3Client extends EventEmitter implements T3Client {
  private map = new Map<string, FakeThread>();
  private focusId: string | null = null;
  private projectMap = new Map<string, ProjectSummary>([
    ["p-web", { id: "p-web", title: "t3code-web" }],
    ["p-infra", { id: "p-infra", title: "infra" }],
    ["p-docs", { id: "p-docs", title: "docs" }],
  ]);
  private timers = new Set<NodeJS.Timeout>();
  readonly calls: { method: string; args: unknown[] }[] = [];
  connected = true;
  /** Delay between streamed chunks (ms); 0 = synchronous (tests). */
  streamDelayMs = 120;

  constructor(now = Date.now()) {
    super();
    const mk = (id: string, title: string, status: string, project: string, model: string, ageMin: number, durMin: number | null, pending: ThreadSummary["pending"] = null): ThreadSummary => ({
      id, title, status, pending, projectId: project, providerInstanceId: "claudeAgent", modelSlug: model,
      startedAt: now - ageMin * 60_000, completedAt: durMin === null ? null : now - (ageMin - durMin) * 60_000,
      updatedAt: now - (durMin === null ? 0 : (ageMin - durMin)) * 60_000, isSubagent: false, createdBy: "user", archived: false, settled: false,
    });
    const threads: ThreadSummary[] = [
      mk("a1b2c3d4-0000-4000-8000-000000000001", "Fix flaky login test in auth.spec.ts", "waiting", "p-web", "claude-opus-5-5", 12, null, { id: "req-approval-1", kind: "command", blocking: true }),
      mk("b2c3d4e5-0000-4000-8000-000000000002", "Add dark mode toggle to the settings page", "running", "p-web", "claude-sonnet-5-5", 3, null),
      mk("c3d4e5f6-0000-4000-8000-000000000003", "Migrate CI from Travis to GitHub Actions", "waiting", "p-infra", "claude-opus-5-5", 40, null, { id: "req-input-1", kind: "user_input", blocking: true }),
      mk("d4e5f6a7-0000-4000-8000-000000000004", "Write release notes for v2.3 — “Aurora”", "completed", "p-docs", "claude-haiku-5-5", 30, 18),
      mk("e5f6a7b8-0000-4000-8000-000000000005", "Upgrade to React 19 and fix type errors | strict mode", "failed", "p-web", "claude-sonnet-5-5", 50, 25),
      mk("f6a7b8c9-0000-4000-8000-000000000006", "Profile the slow dashboard query (Postgres EXPLAIN)", "interrupted", "p-infra", "claude-opus-5-5", 90, 65),
      mk("a7b8c9d0-0000-4000-8000-000000000007", "Refactor auth middleware into its own package", "idle", "p-web", "claude-opus-5-5", 1500, 1400),
    ];
    // Subagents of "Add dark mode toggle" (rev 1.4; ids shaped like T3's, all fake): two delegated tasks and
    // two provider-native subagents (one nested under a delegated task). Native subagents stay "idle" like in T3.
    const PARENT = "b2c3d4e5-0000-4000-8000-000000000002";
    const sub = (id: string, title: string, status: string, parent: string, ageMin: number, durMin: number | null, native: boolean): ThreadSummary => ({
      ...mk(id, title, status, "p-web", "claude-sonnet-5-5", ageMin, durMin),
      isSubagent: true, createdBy: "agent", parentId: parent, rootId: PARENT, native,
      ...(native ? { startedAt: null, completedAt: null, createdAt: now - ageMin * 60_000 } : {}),
    });
    const kids: ThreadSummary[] = [
      sub(FAKE_KIDS.css, "Write the dark mode stylesheet", "running", PARENT, 2, null, false),
      sub(FAKE_KIDS.tokens, "Map the colour tokens", "idle", PARENT, 3, 1, true),
      sub(FAKE_KIDS.shot, "Screenshot test for dark mode", "completed", PARENT, 3, 2, false),
      sub(FAKE_KIDS.vars, "Find hard-coded colours", "idle", FAKE_KIDS.css, 2, 1, true),
    ];
    threads.push(...kids);
    for (const s of threads) {
      const msgs: ChatMessage[] = [];
      const base = Math.floor((s.startedAt ?? now) / 1000);
      let i = 1;
      msgs.push({ i: i++, role: "u", ts: base, text: s.title + ". Please keep the change small.", streaming: false });
      for (let k = 0; k < 18; k++) {
        msgs.push({ i: i++, role: "t", ts: base + 10 + k * 20, text: `$ npm test -- auth.spec.ts (exit ${k % 3 === 0 ? 1 : 0})\nedit src/auth/session.ts (+${k + 2} -${k})`, streaming: false });
        msgs.push({ i: i++, role: "a", ts: base + 20 + k * 20, text: k === 17 ? LONG_REPLY : `Step ${k + 1}: looked at \`session.ts\` line ${40 + k}. The retry loop masks a real race.`, streaming: false });
      }
      const fake: FakeThread = { summary: s, messages: msgs, pending: null, streaming: s.status === "running", nextRun: 2 };
      if (s.pending?.kind === "command") fake.pending = { kind: "approval", requestId: s.pending.id, t3Kind: "command", text: "Approval needed (command): npm test -- --repeat-each=20", options: [{ id: "accept", label: "Allow" }, { id: "acceptForSession", label: "Allow for session" }, { id: "decline", label: "Deny" }] };
      if (s.pending?.kind === "user_input") fake.pending = { kind: "input", requestId: s.pending.id, t3Kind: "user_input", text: "CI: Which runner image should the workflow use?\n  1. ubuntu-latest\n  2. windows-latest", options: [{ id: "o1", label: "ubuntu-latest" }, { id: "o2", label: "windows-latest" }], questions: [{ id: "Which runner image should the workflow use?", header: "CI", question: "Which runner image should the workflow use?", multiSelect: false, options: [{ id: "o1", label: "ubuntu-latest", value: "ubuntu-latest" }, { id: "o2", label: "windows-latest", value: "windows-latest" }] }] };
      this.map.set(s.id, fake);
    }
    // The parent's history refers to its subagents: a tool run with subagent links and the
    // 'Delegated task "..." finished' notification (both VERIFIED shapes, rev 1.4).
    const parent = this.map.get(PARENT)!;
    const last = parent.messages[parent.messages.length - 1];
    const ts = last.ts + 10;
    parent.messages.push({ i: last.i + 1, role: "t", ts, streaming: false,
      text: "Subagent: Map the colour tokens (done)\nSubagent: Write the dark mode stylesheet (running)\nSubagent: Screenshot test for dark mode (done)",
      parts: [
        { kind: "link", threadId: FAKE_KIDS.tokens, label: "Subagent: Map the colour tokens (done)" },
        { kind: "link", threadId: FAKE_KIDS.css, label: "Subagent: Write the dark mode stylesheet (running)" },
        { kind: "link", threadId: FAKE_KIDS.shot, label: "Subagent: Screenshot test for dark mode (done)" },
      ] });
    parent.messages.push({ i: last.i + 2, role: "s", ts: ts + 60, streaming: false, text: 'Delegated task "Screenshot test for dark mode" finished',
      parts: [{ kind: "link", threadId: FAKE_KIDS.shot, label: 'Delegated task "Screenshot test for dark mode" finished' }] });
  }

  async start(): Promise<void> { this.emit("connection", true); }
  stop(): void { for (const t of this.timers) clearTimeout(t); this.timers.clear(); }
  threads(): ThreadSummary[] { return [...this.map.values()].map((t) => t.summary); }
  family(rootId: string): ThreadSummary[] | null {
    const out = this.threads().filter((t) => t.id === rootId || t.rootId === rootId);
    return out.length ? out : null;
  }
  /** Roots the last render asked for (tests). */
  wantedRoots: string[] = [];
  wantFamilies(rootIds: string[]): void { this.wantedRoots = rootIds; }
  projects(): Map<string, ProjectSummary> { return this.projectMap; }
  providers(): ProviderSummary[] { return [{ instanceId: "claudeAgent", displayName: "Claude", enabled: true, models: MODELS }]; }
  models(id: string): ModelChoice[] { return id === "claudeAgent" ? MODELS : []; }
  focusedThreadId(): string | null { return this.focusId; }

  async focus(threadId: string | null): Promise<void> {
    this.calls.push({ method: "focus", args: [threadId] });
    this.focusId = threadId;
    this.emit("change", "focus");
  }

  focusDetail(): ThreadDetail | null {
    const t = this.focusId ? this.map.get(this.focusId) : undefined;
    if (!t) return null;
    return {
      id: t.summary.id, title: t.summary.title, providerInstanceId: t.summary.providerInstanceId, modelSlug: t.summary.modelSlug, modelOptions: t.options ?? [{ id: "effort", value: "high" }],
      streaming: t.streaming, activeRunId: t.streaming ? "run" : null, pending: t.pending, messages: t.messages, hasOlder: false,
      subagents: this.threads().filter((k) => k.parentId === t.summary.id).map((k): SubagentRef => ({
        childThreadId: k.id, status: k.native ? "completed" : String(k.status), title: k.title, startedAt: k.startedAt ?? k.createdAt ?? null, completedAt: k.completedAt ?? (k.native ? k.updatedAt : null),
      })),
      parentId: t.summary.parentId ?? null, rootId: t.summary.rootId ?? t.summary.id,
    };
  }

  async loadOlder(): Promise<void> { this.calls.push({ method: "loadOlder", args: [] }); }

  private get(threadId: string): FakeThread {
    const t = this.map.get(threadId);
    if (!t) throw new Error("thread not found");
    return t;
  }

  private later(ms: number, fn: () => void): void {
    if (this.streamDelayMs === 0) { fn(); return; }
    const h = setTimeout(() => { this.timers.delete(h); fn(); }, ms);
    this.timers.add(h);
  }

  /** Uploaded images (id -> bytes); fetchAttachment serves these and `attachmentBytes`. */
  readonly uploads = new Map<string, Buffer>();
  readonly attachmentBytes = new Map<string, Buffer>();
  private uploadCounter = 0;

  async uploadImage(bytes: Buffer, name: string, mimeType: string): Promise<AttachmentInput> {
    this.calls.push({ method: "uploadImage", args: [name, mimeType, bytes.length] });
    const id = `pending-${String(++this.uploadCounter).padStart(8, "0")}-0000-4000-8000-000000000000`;
    this.uploads.set(id, Buffer.from(bytes));
    return { type: "image", id, name, mimeType, sizeBytes: bytes.length };
  }

  async fetchAttachment(ref: ImageRef): Promise<Buffer> {
    this.calls.push({ method: "fetchAttachment", args: [ref.id] });
    const b = this.attachmentBytes.get(ref.id) ?? this.uploads.get(ref.id);
    if (!b) throw new Error("attachment not found");
    return b;
  }

  async sendMessage(threadId: string, text: string, key?: string, attachments: AttachmentInput[] = []): Promise<void> {
    this.calls.push({ method: "sendMessage", args: attachments.length ? [threadId, text, key, attachments] : [threadId, text, key] });
    const t = this.get(threadId);
    const now = Math.floor(Date.now() / 1000);
    const run = t.nextRun++;
    // Like T3, a claimed upload gets a final id; the fake keeps serving the same bytes under it.
    const images: ImageRef[] = attachments.map((a, k) => {
      const id = `${threadId.replace(/[^A-Za-z0-9_-]/g, "")}-${String(run).padStart(4, "0")}${k}`;
      const b = this.uploads.get(a.id);
      if (b) this.attachmentBytes.set(id, b);
      return { id, name: a.name, mimeType: a.mimeType, sizeBytes: a.sizeBytes };
    });
    t.messages.push({ i: (run - 1) * 100_000 + 1, role: "u", ts: now, text, streaming: false, ...(images.length ? { images } : {}) });
    const reply: ChatMessage = { i: (run - 1) * 100_000 + 2, role: "a", ts: now, text: "", streaming: true };
    t.messages.push(reply);
    t.streaming = true;
    t.summary = { ...t.summary, status: "running", startedAt: Date.now(), completedAt: null, updatedAt: Date.now() };
    this.emit("change", "send");
    const words = `(demo) You said: "${text.slice(0, 200)}". Here is a canned streamed reply so you can watch streaming in WoW.`.split(" ");
    let k = 0;
    const step = () => {
      if (!t.streaming) return;
      reply.text += (k ? " " : "") + words[k++];
      this.emit("change", "stream");
      if (k < words.length) this.later(this.streamDelayMs, step);
      else { reply.streaming = false; t.streaming = false; t.summary = { ...t.summary, status: "completed", completedAt: Date.now(), updatedAt: Date.now() }; this.emit("change", "done"); }
    };
    this.later(this.streamDelayMs, step);
  }

  async setModel(threadId: string, modelId: string, effort?: string): Promise<void> {
    this.calls.push({ method: "setModel", args: effort === undefined ? [threadId, modelId] : [threadId, modelId, effort] });
    if (!MODELS.some((m) => m.id === modelId)) throw new Error(`model ${modelId} is not offered`);
    const t = this.get(threadId);
    const sel = buildModelSelection({ model: t.summary.modelSlug, options: t.options ?? [{ id: "effort", value: "high" }] }, t.summary.providerInstanceId, modelId, effort, MODELS);
    t.options = sel.options;
    t.summary = { ...t.summary, modelSlug: modelId };
    this.emit("change", "model");
  }

  async interrupt(threadId: string): Promise<void> {
    this.calls.push({ method: "interrupt", args: [threadId] });
    const t = this.get(threadId);
    t.streaming = false;
    for (const m of t.messages) m.streaming = false;
    t.messages.push({ i: t.messages.at(-1)!.i + 1, role: "s", ts: Math.floor(Date.now() / 1000), text: "Stopped by user", streaming: false });
    t.summary = { ...t.summary, status: "interrupted", completedAt: Date.now() };
    this.emit("change", "interrupt");
  }

  private resolvePending(t: FakeThread, note: string): void {
    t.pending = null;
    t.summary = { ...t.summary, pending: null, status: "running" };
    t.messages.push({ i: t.messages.at(-1)!.i + 1, role: "s", ts: Math.floor(Date.now() / 1000), text: note, streaming: false });
    this.emit("change", "pending");
  }

  async respondApproval(threadId: string, requestId: string, decision: string, feedback?: string): Promise<void> {
    this.calls.push({ method: "respondApproval", args: [threadId, requestId, decision, feedback] });
    const t = this.get(threadId);
    if (t.pending?.requestId !== requestId) throw new Error("request not pending");
    this.resolvePending(t, `Approval: ${decision}${feedback ? ` (${feedback})` : ""}`);
  }

  async answerUserInput(threadId: string, requestId: string, answers: Record<string, unknown>): Promise<void> {
    this.calls.push({ method: "answerUserInput", args: [threadId, requestId, answers] });
    const t = this.get(threadId);
    if (t.pending?.requestId !== requestId) throw new Error("request not pending");
    this.resolvePending(t, `Answered: ${Object.values(answers).join(", ")}`);
  }
}

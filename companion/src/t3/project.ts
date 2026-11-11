// Pure projections from T3 wire objects (orchestration protocol 2) to companion domain types.
import type { ChatMessage, EffortChoice, ImageRef, MsgPart, PendingRequest, ProviderSummary, SubagentRef, ThreadSummary } from "./types.js";

const toMs = (s: unknown): number | null => {
  if (typeof s !== "string") return null;
  const n = Date.parse(s);
  return Number.isFinite(n) ? n : null;
};

export function shellThreadToSummary(t: any): ThreadSummary {
  return {
    id: String(t.id),
    title: String(t.title ?? ""),
    status: String(t.status ?? "idle"),
    pending: t.pendingRuntimeRequest ? { id: String(t.pendingRuntimeRequest.id), kind: String(t.pendingRuntimeRequest.kind), blocking: t.pendingRuntimeRequest.blocking } : null,
    startedAt: toMs(t.latestRunStartedAt) ?? toMs(t.latestRunRequestedAt),
    completedAt: toMs(t.latestRunCompletedAt),
    updatedAt: toMs(t.updatedAt) ?? 0,
    providerInstanceId: String(t.providerInstanceId ?? t.modelSelection?.instanceId ?? ""),
    modelSlug: String(t.modelSelection?.model ?? ""),
    projectId: String(t.projectId ?? ""),
    isSubagent: t.lineage?.relationshipToParent === "subagent",
    createdBy: String(t.createdBy ?? ""),
    archived: t.archivedAt != null || t.deletedAt != null,
    settled: t.settledAt != null,
    ...lineageOf(t),
    native: typeof t.id === "string" && t.id.startsWith("thread:provider:"),
    activity: typeof t.activityRunStatus === "string" ? t.activityRunStatus : null,
    createdAt: toMs(t.createdAt),
  };
}

/**
 * Parent/root of a thread (VERIFIED live, T3 0.1.8): `lineage = {parentThreadId, relationshipToParent, rootThreadId}`.
 * Top-level threads: parent null, root = their own id. Subagents (delegated tasks and provider-native
 * subagents) point at their parent; forks also have a parent but are listed as top-level threads, so only
 * `relationshipToParent === "subagent"` yields a parentId here (and a fork is its own root).
 */
export function lineageOf(t: any): { parentId: string | null; rootId: string | null } {
  const l = t?.lineage;
  const own = t?.id != null ? String(t.id) : null;
  if (l?.relationshipToParent !== "subagent") return { parentId: null, rootId: own };
  const parentId = typeof l?.parentThreadId === "string" ? l.parentThreadId : null;
  const rootId = typeof l?.rootThreadId === "string" ? l.rootThreadId : parentId;
  return { parentId, rootId };
}

export function providersFromConfig(cfg: any): ProviderSummary[] {
  const list: any[] = Array.isArray(cfg?.providers) ? cfg.providers : [];
  return list.map((p) => ({
    instanceId: String(p.instanceId),
    displayName: String(p.displayName ?? p.instanceId),
    enabled: !!p.enabled && p.status !== "disabled",
    models: (Array.isArray(p.models) ? p.models : []).map((m: any) => {
      const effort = effortFromDescriptors(m?.capabilities?.optionDescriptors);
      return { id: String(m.slug), name: String(m.name ?? m.slug), ...(effort ? { effort } : {}) };
    }),
  }));
}

const OPTION_ID = /^[A-Za-z0-9_.:-]{1,32}$/;

/**
 * The "effort" select descriptor of a model (server.getConfig -> models[].capabilities.optionDescriptors),
 * VERIFIED live: {id:"effort", type:"select", options:[{id,label,isDefault?}], currentValue?, promptInjectedValues?}.
 * Default = currentValue, else the option marked isDefault, else the first option (the order of T3's own
 * resolveDescriptorChoiceValue; Claude models only set isDefault).
 */
export function effortFromDescriptors(descs: unknown): EffortChoice | undefined {
  if (!Array.isArray(descs)) return undefined;
  const d: any = descs.find((x: any) => x && x.id === "effort" && x.type === "select");
  if (!d || !Array.isArray(d.options)) return undefined;
  const values: string[] = [];
  for (const o of d.options) {
    const id = typeof o?.id === "string" ? o.id.trim() : "";
    if (OPTION_ID.test(id) && !values.includes(id) && values.length < 12) values.push(id);
  }
  if (!values.length) return undefined;
  const marked = d.options.find((o: any) => o?.isDefault && values.includes(o.id))?.id;
  const cur = typeof d.currentValue === "string" && values.includes(d.currentValue) ? d.currentValue : undefined;
  return { values, def: cur ?? marked ?? values[0] };
}

/** Options of a model selection as an [{id,value}] array (T3 also accepted a legacy {id: value} object). */
export function selectionOptions(raw: unknown): { id: string; value: unknown }[] {
  if (Array.isArray(raw)) return raw.filter((o: any) => o && typeof o.id === "string").map((o: any) => ({ id: o.id, value: o.value }));
  if (raw && typeof raw === "object") return Object.entries(raw as Record<string, unknown>).map(([id, value]) => ({ id, value }));
  return [];
}

/**
 * The effort a thread really runs with, as T3 resolves it: the stored option if the model offers it,
 * the legacy value "ultracode" as "xhigh", otherwise the model's default. undefined = model has no effort option.
 */
export function resolveEffort(choice: EffortChoice | undefined, options: unknown): string | undefined {
  if (!choice) return undefined;
  const raw = selectionOptions(options).find((o) => o.id === "effort")?.value;
  const v = typeof raw === "string" ? raw.trim() : "";
  if (v && choice.values.includes(v)) return v;
  if (v === "ultracode" && choice.values.includes("xhigh")) return "xhigh";
  return choice.def;
}

/** New options array with effort set (or appended), every other option kept in place. */
export function withEffort(options: unknown, effort: string): { id: string; value: unknown }[] {
  const list = selectionOptions(options);
  const k = list.findIndex((o) => o.id === "effort");
  if (k >= 0) list[k] = { id: "effort", value: effort };
  else list.unshift({ id: "effort", value: effort });
  return list;
}

/** Stable message index from a T3 turn-item ordinal (runOrdinal * 1e6 + itemWithinRun). Starts at 1. */
export function ordinalToIndex(ordinal: number): number {
  if (!Number.isFinite(ordinal) || ordinal <= 0) return 0;
  const run = Math.floor(ordinal / 1_000_000);
  const within = Math.min(ordinal % 1_000_000, 99_999);
  return run <= 0 ? within : (run - 1) * 100_000 + within;
}

const TOOL_TYPES = new Set(["command_execution", "dynamic_tool", "file_change", "file_search", "web_search", "subagent"]);

function firstLine(s: unknown, max = 160): string {
  const t = String(s ?? "").replace(/\r/g, "").split("\n").find((l) => l.trim().length > 0) ?? "";
  return t.length > max ? t.slice(0, max - 3) + "..." : t;
}

function toolLine(it: any): string {
  switch (it.type) {
    case "command_execution": {
      const code = typeof it.exitCode === "number" ? ` (exit ${it.exitCode})` : it.status === "running" ? " (running)" : "";
      return `$ ${firstLine(it.input, 140)}${code}`;
    }
    case "dynamic_tool": return `[${it.toolName ?? "tool"}] ${firstLine(typeof it.title === "string" ? it.title : typeof it.input === "string" ? it.input : "", 120)}`.trim();
    case "file_change": {
      const d = [typeof it.additions === "number" ? `+${it.additions}` : "", typeof it.deletions === "number" ? `-${it.deletions}` : ""].filter(Boolean).join(" ");
      return `edit ${it.fileName}${d ? ` (${d})` : ""}`;
    }
    case "file_search": return `search ${firstLine(it.pattern ?? "", 120)}`;
    case "web_search": return `web ${firstLine((it.patterns ?? []).join(", "), 120)}`;
    case "subagent": return `task: ${firstLine(it.prompt, 120)}${it.result ? " -> done" : ""}`;
    default: return it.type;
  }
}

function approvalText(it: any): string {
  const kind = String(it.requestKind ?? "permission");
  const body = it.prompt || it.reason || it.title || kind;
  return `Approval needed (${kind}): ${String(body)}`;
}

function inputText(it: any): string {
  const qs: any[] = Array.isArray(it.questions) ? it.questions : [];
  return qs.map((q) => `${q.header ? q.header + ": " : ""}${q.question}${(q.options ?? []).length ? "\n" + q.options.map((o: any, k: number) => `  ${k + 1}. ${o.label}${o.description ? " - " + o.description : ""}`).join("\n") : ""}`).join("\n\n") || "Input requested";
}

/**
 * Image attachments of a user_message item (VERIFIED live, T3 0.1.8): attachments[] =
 * {type:"image", id:"<threadId>-<uuid>", name, mimeType, sizeBytes}. Other attachment types are ignored.
 */
export function imageAttachments(raw: unknown): ImageRef[] {
  if (!Array.isArray(raw)) return [];
  const out: ImageRef[] = [];
  for (const a of raw) {
    if (!a || a.type !== "image" || typeof a.id !== "string" || !/^[A-Za-z0-9_-]{1,128}$/.test(a.id)) continue;
    out.push({ id: a.id, name: String(a.name ?? "image"), mimeType: String(a.mimeType ?? ""), sizeBytes: Number(a.sizeBytes ?? 0) });
    if (out.length >= 16) break;
  }
  return out;
}

/**
 * Links to other T3 threads in message text (VERIFIED live): assistant markdown such as
 * `[label](t3-thread://v2/<environmentId>/<threadId>)`; the thread id is the last path segment, as is
 * (child ids keep their `%3A` escapes: `thread:delegated-task:command%3Amcp%3A...`). Returns the text with
 * bare links replaced by "(linked thread)" (markdown links keep their label) and up to `max` distinct links.
 */
export function extractThreadLinks(text: string, max = 6): { text: string; links: { threadId: string; label: string }[] } {
  const links: { threadId: string; label: string }[] = [];
  const add = (id: string, label: string) => {
    if (!/^[A-Za-z0-9%:._~-]{1,600}$/.test(id) || links.some((l) => l.threadId === id) || links.length >= max) return;
    links.push({ threadId: id, label });
  };
  const idOf = (url: string) => url.replace(/[?#].*$/, "").split("/").filter(Boolean).pop() ?? "";
  let out = text.replace(/\[([^\]\n]+)\]\((t3-thread:\/\/[^)\s]+)\)/g, (m, label: string, url: string) => {
    add(idOf(url.slice("t3-thread://".length)), label.replace(/[`*_]/g, "").trim() || "Linked thread");
    return m;
  });
  out = out.replace(/(^|[^(])(t3-thread:\/\/[A-Za-z0-9%:._~\/-]+)/g, (_m, pre: string, url: string) => {
    add(idOf(url.slice("t3-thread://".length)), "Linked thread");
    return pre + "(linked thread)";
  });
  return { text: out, links };
}

/** The `subagent` turn items of a thread: child thread id and the run state the parent shows for it. */
export function subagentRefs(items: any[]): SubagentRef[] {
  const out: SubagentRef[] = [];
  for (const it of items) {
    if (!it || it.type !== "subagent" || typeof it.childThreadId !== "string" || !it.childThreadId) continue;
    out.push({ childThreadId: it.childThreadId, status: String(it.status ?? ""), title: String(it.title ?? ""), startedAt: toMs(it.startedAt), completedAt: toMs(it.completedAt) });
  }
  return out;
}

/** Label of a subagent tool line that links to the child thread. */
function subagentLabel(it: any): string {
  const name = firstLine(it.title || it.prompt, 100) || "subagent";
  const st = String(it.status ?? "");
  const suffix = st === "running" || st === "starting" || st === "queued" ? " (running)" : st === "failed" ? " (failed)" : st === "completed" ? " (done)" : st ? ` (${st})` : "";
  return `Subagent: ${name}${suffix}`;
}

export interface ItemsToMessagesOptions {
  includeReasoning?: boolean;
  maxToolLines?: number;
}

/**
 * Turn items (any order) -> chat messages (oldest first). Consecutive tool items are merged into one
 * `t` message keyed by the first item's index, so streaming tool activity keeps a stable `i`.
 */
export function itemsToMessages(items: any[], o: ItemsToMessagesOptions = {}): ChatMessage[] {
  const maxTool = o.maxToolLines ?? 8;
  const sorted = [...items].filter((x) => x && typeof x.ordinal === "number").sort((a, b) => a.ordinal - b.ordinal);
  const out: ChatMessage[] = [];
  // Tool runs: plain lines, except subagent items with a child thread, which become links (rev 1.4)
  // and do not count toward the line cap (at most 8 links per run).
  let toolRun: { msg: ChatMessage; lines: string[]; parts: MsgPart[]; pending: string[]; links: number; extra: number } | null = null;
  const flushTool = () => {
    if (!toolRun) return;
    const { msg, lines, parts, pending, links, extra } = toolRun;
    const more = extra > 0 ? `(+${extra} more)` : "";
    msg.text = lines.join("\n") + (more ? `\n${more}` : "");
    if (links > 0) {
      const tail = [...pending, ...(more ? [more] : [])];
      if (tail.length) parts.push({ kind: "text", text: tail.join("\n") });
      msg.parts = parts;
    }
    out.push(msg);
    toolRun = null;
  };
  for (const it of sorted) {
    const i = ordinalToIndex(it.ordinal);
    const ts = Math.floor((toMs(it.startedAt) ?? toMs(it.updatedAt) ?? Date.now()) / 1000);
    const streaming = it.streaming === true || it.status === "running";
    if (TOOL_TYPES.has(it.type)) {
      if (!toolRun) toolRun = { msg: { i, role: "t", ts, text: "", streaming }, lines: [], parts: [], pending: [], links: 0, extra: 0 };
      const isLink = it.type === "subagent" && typeof it.childThreadId === "string" && it.childThreadId !== "" && toolRun.links < 8;
      if (isLink) {
        const label = subagentLabel(it);
        toolRun.lines.push(label);
        if (toolRun.pending.length) { toolRun.parts.push({ kind: "text", text: toolRun.pending.join("\n") }); toolRun.pending = []; }
        toolRun.parts.push({ kind: "link", threadId: it.childThreadId, label });
        toolRun.links++;
      } else if (toolRun.lines.length - toolRun.links < maxTool) {
        const line = toolLine(it);
        toolRun.lines.push(line);
        toolRun.pending.push(line);
      } else toolRun.extra++;
      toolRun.msg.streaming = toolRun.msg.streaming || streaming;
      continue;
    }
    let msg: ChatMessage | null = null;
    switch (it.type) {
      case "user_message": {
        msg = withLinks({ i, role: "u", ts, text: String(it.text ?? ""), streaming: false });
        const images = imageAttachments(it.attachments);
        if (images.length) msg.images = images;
        break;
      }
      case "assistant_message": msg = withLinks({ i, role: "a", ts, text: String(it.text ?? ""), streaming }); break;
      case "proposed_plan": msg = withLinks({ i, role: "a", ts, text: String(it.markdown ?? ""), streaming }); break;
      case "reasoning": if (o.includeReasoning) msg = { i, role: "s", ts, text: `(thinking) ${firstLine(it.text, 300)}`, streaming }; break;
      case "todo_list": msg = { i, role: "s", ts, text: (it.steps ?? []).map((s: any) => `[${s.status === "completed" ? "x" : s.status === "in_progress" ? ">" : " "}] ${s.step ?? s.text ?? ""}`).join("\n"), streaming: false }; break;
      case "approval_request": msg = { i, role: "s", ts, text: approvalText(it), streaming: false }; break;
      case "user_input_request": msg = { i, role: "s", ts, text: inputText(it), streaming: false }; break;
      case "error": msg = { i, role: "s", ts, text: `Error: ${it.failure?.message ?? "run failed"}`, streaming: false }; break;
      case "run_interrupt_request":
      case "run_interrupt_result":
      case "system_notice": msg = { i, role: "s", ts, text: String(it.message ?? it.type), streaming: false }; break;
      case "compaction": msg = { i, role: "s", ts, text: "(context compacted)", streaming: false }; break;
      case "notification": {
        if (!it.summary) break;
        const text = String(it.summary);
        msg = { i, role: "s", ts, text, streaming: false };
        // 'Delegated task "X" finished' / 'Subagent "X" failed' (VERIFIED live): source.childThreadId names the child.
        const child = it.source?.childThreadId;
        if (typeof child === "string" && child) msg.parts = [{ kind: "link", threadId: child, label: text }];
        break;
      }
      default: break; // checkpoint, handoff, fork, thread_created, secret/link requests: not shown
    }
    if (msg) { flushTool(); out.push(msg); }
  }
  flushTool();
  return out;
}

/** Adds link parts for t3-thread links in a user/assistant message (rev 1.4); text keeps the labels. */
function withLinks(m: ChatMessage): ChatMessage {
  if (!m.text.includes("t3-thread://")) return m;
  const { text, links } = extractThreadLinks(m.text);
  m.text = text;
  if (links.length) m.parts = [{ kind: "text", text }, ...links.map((l): MsgPart => ({ kind: "link", threadId: l.threadId, label: l.label }))];
  return m;
}

/** Builds the pending request (approval or input) from runtime requests + their turn items. */
export function buildPending(runtimeRequests: any[], items: any[]): PendingRequest | null {
  const pending = (runtimeRequests ?? []).filter((r) => r?.status === "pending").sort((a, b) => String(a.createdAt).localeCompare(String(b.createdAt)));
  for (const r of pending) {
    const item = (items ?? []).find((it) => it && it.requestId === r.id && (it.type === "approval_request" || it.type === "user_input_request"));
    if (r.kind === "user_input" || item?.type === "user_input_request") {
      const qs: any[] = Array.isArray(item?.questions) ? item.questions : [];
      const questions = qs.map((q) => ({
        id: String(q.id),
        header: String(q.header ?? ""),
        question: String(q.question ?? ""),
        multiSelect: !!q.multiSelect,
        options: (q.options ?? []).map((o: any, k: number) => ({ id: `o${k + 1}`, label: String(o.label), value: String(o.value ?? o.label) })),
      }));
      // Option buttons are offered only for single-question requests; otherwise the user answers in text.
      const options = questions.length === 1 ? questions[0].options.map((o: { id: string; label: string }) => ({ id: o.id, label: o.label })) : [];
      return { kind: "input", requestId: String(r.id), text: item ? inputText(item) : "Input requested (open T3 Code for details)", options, questions, t3Kind: String(r.kind) };
    }
    if (r.kind === "auth_refresh") {
      return { kind: "approval", requestId: String(r.id), text: "A provider sign-in refresh is needed. Open T3 Code.", options: [], t3Kind: "auth_refresh" };
    }
    const opts: any[] = Array.isArray(item?.options) && item.options.length ? item.options : [
      { decision: "accept", label: "Allow" },
      { decision: "acceptForSession", label: "Allow for session" },
      { decision: "decline", label: "Deny" },
    ];
    return {
      kind: "approval",
      requestId: String(r.id),
      text: item ? approvalText(item) : `Approval needed (${r.kind})`,
      options: opts.map((o) => ({ id: String(o.decision), label: String(o.label) })),
      t3Kind: String(r.kind),
    };
  }
  return null;
}

const ACTIVE = new Set(["preparing", "queued", "starting", "running", "waiting"]);
export function isActiveStatus(s: string): boolean { return ACTIVE.has(s); }

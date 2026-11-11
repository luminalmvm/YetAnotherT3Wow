// T3 state -> compact inbound snapshot (PROTOCOL.md section 2.2) with all caps applied.
import { createHash } from "node:crypto";
import type { ImageRef, ModelChoice, PendingRequest, ProjectSummary, ProviderSummary, ThreadDetail, ThreadSummary } from "../t3/types.js";
import { isActiveStatus, resolveEffort } from "../t3/project.js";
import { LuaFields, toLua, type LuaOptions } from "../wow/luaEscape.js";
import { markdownToSegs, transliterate, truncateMarkdownTail, utf8Head, utf8Len, type Seg } from "./markdown.js";

export type SnapSt = "running" | "completed" | "failed" | "stopped" | "idle";

export interface SnapThread { id: string; title: string; st: SnapSt; need?: "approval" | "input"; t0?: number; t1?: number; model?: string; proj?: string }
/**
 * Image segment (PROTOCOL rev 1.3, D16): Lua `{"img","[image: name]",s=<slot or 0>,w=,h=,alt=,aid=,st=}`.
 * The 2nd element is a text fallback, so a 1.2 addon (which renders unknown kinds as "p") shows "[image: name]".
 * st (only with s=0): load | full | off | err | old.
 */
export interface ImgFields { s: number; w?: number; h?: number; alt: string; aid: string; st?: string }
export type ImgSeg = [kind: "img", text: string, fields: LuaFields];
export type SnapSeg = Seg | ImgSeg;
export const isImgSeg = (s: SnapSeg): s is ImgSeg => s[0] === "img";

export function imgSeg(f: ImgFields): ImgSeg {
  return ["img", `[image: ${f.alt}]`, new LuaFields({ s: f.s, w: f.w, h: f.h, alt: f.alt, aid: f.aid, st: f.st })];
}

/** Short stable id for an image (8 hex chars of the SHA-1 of the T3 attachment id). */
export function shortAid(id: string): string { return createHash("sha1").update(id).digest("hex").slice(0, 8); }

/** Slot information for an image (from ImageManager.resolve). */
export interface ImgInfo { s: number; w?: number; h?: number; st?: string }
export type ImageResolver = (ref: ImageRef) => ImgInfo;

/** A staged attachment (focus.staged, D17). */
export interface SnapStaged { aid: string; s: number; w?: number; h?: number; name: string }

export interface SnapMsg { i: number; r: "u" | "a" | "t" | "s"; ts: number; segs: SnapSeg[]; more: boolean }
export interface SnapPending { kind: "approval" | "input"; rid: string; text: string; options: { id: string; label: string }[] }
/** A selectable model option (PROTOCOL 2.2, D14): only the reasoning effort ("effort") is sent. */
export interface SnapOpt { id: "effort"; vals: string[]; def: string }
export interface SnapModel { id: string; name: string; opts?: SnapOpt[] }
/** older: T3 holds messages older than msgs[1] (PROTOCOL 2.2, optional). effort: the thread's effort (D14). */
/** staged/notice/nid: PROTOCOL rev 1.3 (D17, D18). */
export interface SnapFocus { id: string; model?: string; effort?: string; models?: SnapModel[]; streaming: boolean; pending?: SnapPending; older?: boolean; staged?: SnapStaged[]; notice?: string; nid?: number; msgs: SnapMsg[] }
export interface SnapshotDoc {
  v: 1; sid: string; seq: number; ts: number; ack: number; asid: string;
  err?: { seq: number; text: string };
  /** Image slots left/total and what frees them (PROTOCOL rev 1.3, D16). */
  imgslots?: { left: number; total: number; reset: "reload" | "restart" };
  threads: SnapThread[];
  focus?: SnapFocus;
}

export interface Caps {
  maxThreads: number;
  focusWindow: number;
  maxFocusWindow: number;
  maxMessageBytes: number;
  maxSnapshotBytes: number;
  maxTitleBytes: number;
  maxNameBytes: number;
  maxPendingTextBytes: number;
  transliterate: boolean;
}

export const DEFAULT_CAPS: Caps = {
  maxThreads: 30, focusWindow: 40, maxFocusWindow: 120, maxMessageBytes: 8000, maxSnapshotBytes: 480 * 1024,
  maxTitleBytes: 120, maxNameBytes: 64, maxPendingTextBytes: 2000, transliterate: true,
};

// ---------------------------------------------------------------------------------------------
// Id maps
// ---------------------------------------------------------------------------------------------

/** T3 thread id <-> protocol tid (`[A-Za-z0-9_-]{1,40}`): first 8 hex/alnum chars, lengthened on collision. */
export class TidMap {
  private toShort = new Map<string, string>();
  private toLong = new Map<string, string>();
  tid(t3Id: string): string {
    const have = this.toShort.get(t3Id);
    if (have) return have;
    // UUIDs: their first 8 hex digits. Other ids (seen live: "thread-mcp...", which share long
    // prefixes): a SHA-1 hex digest, so tids stay short and distinct.
    const clean = /^[0-9a-f]{8}-[0-9a-f]{4}-/i.test(t3Id) ? t3Id.replace(/[^A-Za-z0-9_-]/g, "") : createHash("sha1").update(t3Id).digest("hex");
    for (let len = 8; len <= 40; len++) {
      const cand = clean.length >= len ? clean.slice(0, len) : clean + createHash("sha1").update(t3Id).digest("hex").slice(0, len - clean.length);
      const owner = this.toLong.get(cand);
      if (!owner || owner === t3Id) { this.toShort.set(t3Id, cand); this.toLong.set(cand, t3Id); return cand; }
    }
    throw new Error("tid space exhausted");
  }
  resolve(tid: string): string | undefined { return this.toLong.get(tid); }
}

/** T3 runtime request ids are ~400 chars with '%' (VERIFIED) -> protocol rid `r` + 12 hex chars. */
export class RidMap {
  private toLong = new Map<string, string>();
  rid(requestId: string): string {
    const r = "r" + createHash("sha1").update(requestId).digest("hex").slice(0, 12);
    this.toLong.set(r, requestId);
    return r;
  }
  resolve(rid: string): string | undefined { return this.toLong.get(rid); }
}

// ---------------------------------------------------------------------------------------------
// Mapping
// ---------------------------------------------------------------------------------------------

export function mapStatus(s: string): SnapSt {
  if (isActiveStatus(s)) return "running";
  switch (s) {
    case "completed": return "completed";
    case "failed": return "failed";
    case "interrupted": case "cancelled": case "rolled_back": return "stopped";
    default: return "idle";
  }
}

export function mapNeed(kind: string | undefined): "approval" | "input" | undefined {
  if (!kind) return undefined;
  return kind === "user_input" ? "input" : "approval";
}

const sec = (ms: number | null | undefined) => (ms ? Math.floor(ms / 1000) : undefined);

function clip(s: string, maxBytes: number, tr: boolean): string {
  const t = (tr ? transliterate(s) : s).replace(/[\r\n\t]+/g, " ").trim();
  return utf8Head(t, maxBytes);
}

export function modelName(providers: ProviderSummary[], instanceId: string, slug: string): string {
  const p = providers.find((x) => x.instanceId === instanceId) ?? providers.find((x) => x.models.some((m) => m.id === slug));
  return p?.models.find((m) => m.id === slug)?.name ?? slug;
}

export interface SelectOptions { maxThreads: number; focusId?: string | null; now?: number }

/**
 * Up to maxThreads of the user's OPEN threads (Phase 2: no 30-minute cutoff), ordered:
 *   0 waiting for you (approval/input), 1 running, 2 everything else, most recently updated first.
 * Open = not settled in T3 (`settledAt` is null: T3's thread.settle / thread.auto-settle set it,
 * thread.unsettle clears it), not archived or deleted, not a subagent. The focused thread is always
 * included, even when settled. Only summaries (title, status, times, model, project) go into the
 * snapshot: message text is sent for the focused thread only.
 */
export function selectThreads(all: ThreadSummary[], o: SelectOptions): ThreadSummary[] {
  const rank = (t: ThreadSummary) => {
    if (t.pending) return 0;
    if (isActiveStatus(t.status)) return 1;
    return 2;
  };
  const recency = (t: ThreadSummary) => Math.max(t.updatedAt || 0, t.completedAt || 0, t.startedAt || 0);
  const live = all.filter((t) => !t.isSubagent && !t.archived);
  const cands = live.filter((t) => !t.settled);
  cands.sort((a, b) => rank(a) - rank(b) || recency(b) - recency(a));
  const out = cands.slice(0, o.maxThreads);
  if (o.focusId && !out.some((t) => t.id === o.focusId)) {
    const f = live.find((t) => t.id === o.focusId);
    if (f) { if (out.length >= o.maxThreads) out.pop(); out.push(f); }
  }
  return out;
}

export function threadToSnap(t: ThreadSummary, tids: TidMap, projects: Map<string, ProjectSummary>, providers: ProviderSummary[], caps: Caps): SnapThread {
  const st = mapStatus(t.status);
  const out: SnapThread = { id: tids.tid(t.id), title: clip(t.title || "(untitled)", caps.maxTitleBytes, caps.transliterate), st };
  const need = mapNeed(t.pending?.kind);
  if (need) out.need = need;
  const t0 = sec(t.startedAt);
  if (t0) out.t0 = t0;
  const t1 = st === "running" ? undefined : sec(t.completedAt);
  if (t1) out.t1 = t1;
  if (t.modelSlug) out.model = clip(modelName(providers, t.providerInstanceId, t.modelSlug), caps.maxNameBytes, caps.transliterate);
  const proj = projects.get(t.projectId)?.title;
  if (proj) out.proj = clip(proj, caps.maxNameBytes, caps.transliterate);
  return out;
}

export function pendingToSnap(p: PendingRequest, rids: RidMap, caps: Caps): SnapPending {
  return {
    kind: p.kind,
    rid: rids.rid(p.requestId),
    text: utf8Head(caps.transliterate ? transliterate(p.text) : p.text, caps.maxPendingTextBytes),
    options: p.options.slice(0, 8).map((o) => ({ id: o.id, label: clip(o.label, 48, caps.transliterate) })),
  };
}

export function messageToSnap(m: { i: number; role: SnapMsg["r"]; ts: number; text: string; images?: ImageRef[] }, maxBytes: number, caps: Caps, resolveImage?: ImageResolver): SnapMsg {
  const [text, cut] = truncateMarkdownTail(m.text, maxBytes);
  let segs: Seg[] = markdownToSegs(text, { transliterate: caps.transliterate, keepMarks: keepMarksFor(m.role) });
  // Segment conversion can grow text slightly (transliteration); enforce the byte cap on the result.
  let total = segs.reduce((n, s) => n + utf8Len(s[1]), 0);
  let more = cut;
  while (total > maxBytes && segs.length) {
    const first = segs[0];
    const over = total - maxBytes;
    if (utf8Len(first[1]) <= over) { segs = segs.slice(1); }
    else segs[0] = [first[0], utf8Head(first[1], utf8Len(first[1]) - over - 3) + "..."];
    total = segs.reduce((n, s) => n + utf8Len(s[1]), 0);
    more = true;
  }
  const imgs: ImgSeg[] = (m.images ?? []).slice(0, 8).map((ref) => {
    const info = resolveImage ? resolveImage(ref) : { s: 0, st: "off" };
    const alt = clip(ref.name || "image", 64, caps.transliterate);
    return imgSeg({ s: info.s, w: info.w, h: info.h, alt, aid: shortAid(ref.id), st: info.s ? undefined : info.st });
  });
  const out: SnapSeg[] = [...segs.filter((s) => imgs.length === 0 || s[1] !== ""), ...imgs];
  return { i: m.i, r: m.role, ts: m.ts, segs: out.length ? out : [["p", ""]], more };
}

/** User and assistant text keeps light markdown marks for the addon to style (PROTOCOL D14). */
export function keepMarksFor(role: SnapMsg["r"]): boolean { return role === "a" || role === "u"; }

export interface FocusInput {
  detail: ThreadDetail;
  /** null = newest focusWindow messages; else messages with i >= windowStart (from `hist`). */
  windowStart: number | null;
  /** Image slots for message attachments; only the newest `imageWindow` messages get slots (others: st="old"). */
  resolveImage?: ImageResolver;
  imageWindow?: number;
  staged?: SnapStaged[];
  notice?: { text: string; nid: number };
}

export function focusToSnap(f: FocusInput, tids: TidMap, rids: RidMap, providers: ProviderSummary[], caps: Caps): SnapFocus {
  const d = f.detail;
  let msgs = d.messages;
  if (f.windowStart != null) msgs = msgs.filter((m) => m.i >= f.windowStart!);
  else msgs = msgs.slice(-caps.focusWindow);
  msgs = msgs.slice(-caps.maxFocusWindow);
  const models = providers.find((p) => p.instanceId === d.providerInstanceId)?.models ?? [];
  // Older history exists if the window left loaded messages out, or T3 has unloaded pages.
  const leftOut = msgs.length > 0 && d.messages.length > 0 && d.messages[0].i < msgs[0].i;
  const out: SnapFocus = {
    id: tids.tid(d.id),
    streaming: d.streaming,
    older: leftOut || !!d.hasOlder,
    msgs: [],
  };
  const imageFrom = msgs.length - (f.imageWindow ?? 40);
  const oldImage: ImageResolver = () => ({ s: 0, st: "old" });
  out.msgs = msgs.map((m, k) => messageToSnap(m, caps.maxMessageBytes, caps, f.resolveImage ? (k >= imageFrom ? f.resolveImage : oldImage) : undefined));
  if (f.staged?.length) out.staged = f.staged.slice(0, 4).map((s) => ({ ...s, name: clip(s.name, 64, caps.transliterate) }));
  if (f.notice) { out.notice = clip(f.notice.text, 120, caps.transliterate); out.nid = f.notice.nid; }
  if (d.modelSlug) out.model = d.modelSlug;
  const effort = resolveEffort(models.find((m) => m.id === d.modelSlug)?.effort, d.modelOptions);
  if (effort) out.effort = effort;
  if (models.length) out.models = models.map((m): SnapModel => ({
    id: m.id,
    name: clip(m.name, caps.maxNameBytes, caps.transliterate),
    ...(m.effort ? { opts: [{ id: "effort", vals: m.effort.values, def: m.effort.def }] } : {}),
  }));
  if (d.pending) out.pending = pendingToSnap(d.pending, rids, caps);
  return out;
}

// ---------------------------------------------------------------------------------------------
// Serialization with size enforcement
// ---------------------------------------------------------------------------------------------

export function serializeSnapshot(doc: SnapshotDoc, o: LuaOptions = {}): string {
  const head = `T3B_IN={v=1,sid=${toLua(doc.sid, o)},seq=${doc.seq},ts=${doc.ts},ack=${doc.ack},asid=${toLua(doc.asid, o)},`;
  const err = (doc.err ? `\n err=${toLua(doc.err, o)},` : "\n err=nil,") + (doc.imgslots ? `\n imgslots=${toLua(doc.imgslots, o)},` : "");
  const threads = "\n threads={" + doc.threads.map((t) => "\n  " + toLua(t, o)).join(",") + "}";
  let focus = "";
  if (doc.focus) {
    const { msgs, ...rest } = doc.focus;
    const restLua = toLua(rest, o);
    focus = ",\n focus=" + restLua.slice(0, -1) + (restLua.length > 2 ? "," : "") + "\n  msgs={" + msgs.map((m) => "\n   " + toLua(m, o)).join(",") + "}}";
  }
  return `${head}${err}${threads}${focus}}\nT3B_IN_END=${doc.seq}\n`;
}

/**
 * The snapshot written when the companion exits (and by `--clear`): no threads, no focus, so no
 * conversation text stays on disk. ts=0 makes the addon show "Companion offline" at once.
 */
export function emptySnapshotLua(sid: string, seq: number, ack = 0, asid = ""): string {
  return serializeSnapshot({ v: 1, sid, seq, ts: 0, ack, asid, threads: [] });
}

/** Shrinks the focus messages (oldest first) until the serialized snapshot fits maxBytes (UTF-8). */
export function fitSnapshot(doc: SnapshotDoc, maxBytes: number, o: LuaOptions = {}): { lua: string; shrunk: number } {
  let lua = serializeSnapshot(doc, o);
  let shrunk = 0;
  while (Buffer.byteLength(lua, "utf8") > maxBytes && doc.focus && doc.focus.msgs.length) {
    const msgs = doc.focus.msgs;
    const idx = msgs.findIndex((m) => m.segs.reduce((n, s) => n + utf8Len(s[1]), 0) > 512);
    if (idx >= 0) {
      const m = msgs[idx];
      const textSegs = m.segs.filter((s): s is Seg => !isImgSeg(s));
      const half = Math.floor(textSegs.reduce((n, s) => n + utf8Len(s[1]), 0) / 2);
      const text = textSegs.map((s) => (s[0] === "c" ? "```\n" + s[1] + "\n```" : s[1])).join("\n\n");
      const [t] = truncateMarkdownTail(text, half);
      msgs[idx] = { ...m, segs: [...markdownToSegs(t, { transliterate: false, keepMarks: keepMarksFor(m.r) }), ...m.segs.filter(isImgSeg)], more: true };
    } else { msgs.shift(); doc.focus.older = true; }
    shrunk++;
    lua = serializeSnapshot(doc, o);
  }
  return { lua, shrunk };
}

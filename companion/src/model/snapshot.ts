// T3 state -> compact inbound snapshot (PROTOCOL.md section 2.2) with all caps applied.
import { createHash } from "node:crypto";
import type { ImageRef, ModelChoice, MsgPart, PendingRequest, ProjectSummary, ProviderSummary, SubagentRef, ThreadDetail, ThreadSummary } from "../t3/types.js";
import { isActiveStatus, resolveEffort } from "../t3/project.js";
import { LuaFields, toLua, type LuaOptions } from "../wow/luaEscape.js";
import { markdownToSegs, transliterate, truncateMarkdownTail, utf8Head, utf8Len, type Seg } from "./markdown.js";

export type SnapSt = "running" | "completed" | "failed" | "stopped" | "idle";

/**
 * Thread summary. rev 1.4: `parent` = tid of the parent thread (subagent threads only); `kids` = number of
 * subagent threads, `kidsRunning` = how many of them run, `kidsNeed` = how many need you (any depth).
 */
export interface SnapThread { id: string; title: string; st: SnapSt; need?: "approval" | "input"; t0?: number; t1?: number; model?: string; proj?: string; parent?: string; kids?: number; kidsRunning?: number; kidsNeed?: number }
/** A subagent of the focused thread (focus.kids, rev 1.4). */
export interface SnapKid { id: string; title: string; st: SnapSt; need?: "approval" | "input"; t0?: number; t1?: number; kids?: number }
export interface SnapRef { id: string; title: string }
/**
 * Image segment (PROTOCOL rev 1.3, D16): Lua `{"img","[image: name]",s=<slot or 0>,w=,h=,alt=,aid=,st=}`.
 * The 2nd element is a text fallback, so a 1.2 addon (which renders unknown kinds as "p") shows "[image: name]".
 * st (only with s=0): load | full | off | err | old.
 */
export interface ImgFields { s: number; w?: number; h?: number; alt: string; aid: string; st?: string }
export type ImgSeg = [kind: "img", text: string, fields: LuaFields];
/**
 * Thread link segment (rev 1.4): Lua `{"tl","<label>",id="<tid>"}`. The 2nd element is the visible text, so a
 * 1.3 addon (unknown kinds render as "p") shows the label as plain text.
 */
export type LinkSeg = [kind: "tl", text: string, fields: LuaFields];
export type SnapSeg = Seg | ImgSeg | LinkSeg;
export const isImgSeg = (s: SnapSeg): s is ImgSeg => s[0] === "img";
export const isLinkSeg = (s: SnapSeg): s is LinkSeg => s[0] === "tl";
export function linkSeg(label: string, tid: string): LinkSeg { return ["tl", label, new LuaFields({ id: tid })]; }

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
/** rev 1.4: parent (when the focused thread is a subagent), kids (<= 20) + nkids (total), path (root -> focused, <= 4). */
export interface SnapFocus { id: string; model?: string; effort?: string; models?: SnapModel[]; streaming: boolean; pending?: SnapPending; older?: boolean; staged?: SnapStaged[]; notice?: string; nid?: number; parent?: SnapRef; kids?: SnapKid[]; nkids?: number; path?: SnapRef[]; msgs: SnapMsg[] }
export interface SnapshotDoc {
  v: 1; sid: string; seq: number; ts: number; ack: number; asid: string;
  err?: { seq: number; text: string };
  /** Image slots left/total and what frees them (PROTOCOL rev 1.3, D16). */
  imgslots?: { left: number; total: number; reset: "reload" | "restart" };
  threads: SnapThread[];
  /** Subagent rows for the tracker / thread menu (rev 1.4): children of listed threads, each with `parent`. */
  subs?: SnapThread[];
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
  /** rev 1.4: subagent rows per listed thread / in total (`subs`), focus.kids, breadcrumb entries. */
  maxSubsPerThread: number;
  maxSubs: number;
  maxFocusKids: number;
  maxPath: number;
}

export const DEFAULT_CAPS: Caps = {
  maxThreads: 30, focusWindow: 40, maxFocusWindow: 120, maxMessageBytes: 8000, maxSnapshotBytes: 480 * 1024,
  maxTitleBytes: 120, maxNameBytes: 64, maxPendingTextBytes: 2000, transliterate: true,
  maxSubsPerThread: 8, maxSubs: 40, maxFocusKids: 20, maxPath: 4,
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
    // rev 1.4: a focused subagent is included too (buildThreadTree lists it with its parent).
    const f = live.find((t) => t.id === o.focusId) ?? all.find((t) => t.id === o.focusId && !t.archived);
    if (f && !f.isSubagent) { if (out.length >= o.maxThreads) out.pop(); out.push(f); }
    else if (f) out.push(f);
  }
  return out;
}

/**
 * Run state of a thread as the bridge shows it. Subagent threads (rev 1.4): the parent's `subagent` item
 * (VERIFIED: status running/completed/failed, startedAt/completedAt) is used when the thread's own status is idle. Provider-native
 * subagent threads keep `status: "idle"` and have no runs (VERIFIED); `activityRunStatus` is set while they
 * run (T3's isLiveSubagentShell, INFERRED from the bundle), and an idle native subagent counts as finished.
 */
export function runState(t: ThreadSummary, ref?: SubagentRef): { st: SnapSt; t0?: number; t1?: number } {
  // The parent's view only matters when the thread's own status says nothing (native subagents stay
  // "idle"); a delegated task's own status (e.g. "cancelled") is more precise (VERIFIED live).
  if (ref && (t.native || mapStatus(t.status) === "idle") && !t.activity) {
    const st = ref.status === "completed" ? "completed" : ref.status === "failed" ? "failed" : isActiveStatus(ref.status) ? "running"
      : ref.status === "cancelled" || ref.status === "interrupted" ? "stopped" : mapStatus(t.status);
    return { st, t0: sec(ref.startedAt ?? t.startedAt ?? t.createdAt), t1: st === "running" ? undefined : sec(ref.completedAt ?? t.completedAt ?? t.updatedAt) };
  }
  let st = mapStatus(t.status);
  if (st === "idle" && t.activity) st = isActiveStatus(t.activity) ? "running" : mapStatus(t.activity);
  if (st === "idle" && t.isSubagent && t.native) st = "completed";
  const nativeTimes = t.native && !t.startedAt;
  const t0 = sec(t.startedAt ?? (nativeTimes ? t.createdAt : null));
  const t1 = st === "running" ? undefined : sec(t.completedAt ?? (nativeTimes ? t.updatedAt : null));
  return { st, t0, t1 };
}

export interface ThreadSnapExtra { parent?: string; ref?: SubagentRef; kids?: { kids: number; running: number; need: number } }

export function threadToSnap(t: ThreadSummary, tids: TidMap, projects: Map<string, ProjectSummary>, providers: ProviderSummary[], caps: Caps, extra: ThreadSnapExtra = {}): SnapThread {
  const { st, t0, t1 } = runState(t, extra.ref);
  const out: SnapThread = { id: tids.tid(t.id), title: clip(t.title || "(untitled)", caps.maxTitleBytes, caps.transliterate), st };
  const need = mapNeed(t.pending?.kind);
  if (need) out.need = need;
  if (t0) out.t0 = t0;
  if (t1) out.t1 = t1;
  if (t.modelSlug) out.model = clip(modelName(providers, t.providerInstanceId, t.modelSlug), caps.maxNameBytes, caps.transliterate);
  const proj = projects.get(t.projectId)?.title;
  if (proj) out.proj = clip(proj, caps.maxNameBytes, caps.transliterate);
  if (extra.parent) out.parent = extra.parent;
  if (extra.kids && extra.kids.kids > 0) {
    out.kids = extra.kids.kids;
    if (extra.kids.running) out.kidsRunning = extra.kids.running;
    if (extra.kids.need) out.kidsNeed = extra.kids.need;
  }
  return out;
}

// ---------------------------------------------------------------------------------------------
// Subagent tree (rev 1.4)
// ---------------------------------------------------------------------------------------------

export interface TreeInput {
  /** t3.threads(): the live (filtered) shell plus the focused thread's own row. */
  shell: ThreadSummary[];
  /** Cached families by root id (t3.family), null = not loaded yet. */
  familyOf: (rootId: string) => ThreadSummary[] | null;
  focusId: string | null;
  /** The focused thread's `subagent` items (its children's run state as the parent shows it). */
  focusSubagents?: SubagentRef[];
  /** Lineage of the focused thread from its projection (used when no shell/family row has it yet). */
  focusLineage?: { parentId?: string | null; rootId?: string | null };
  focusTitle?: string;
}

export interface TreeResult {
  threads: SnapThread[];
  subs: SnapThread[];
  focus: { parent?: SnapRef; kids?: SnapKid[]; nkids?: number; path?: SnapRef[] };
  /** Families the next render needs (listed threads' roots and the focused thread's root). */
  wantRoots: string[];
}

const recencyOf = (t: ThreadSummary) => Math.max(t.updatedAt || 0, t.completedAt || 0, t.startedAt || 0, t.createdAt || 0);

/**
 * Builds the thread list with subagents (rev 1.4):
 * - `threads`: the open top-level threads (selectThreads, unchanged), each with kids/kidsRunning/kidsNeed, plus
 *   the focused thread and its ancestors below the root when the focused thread is a subagent (with `parent`),
 *   even when settled or finished.
 * - `subs`: up to maxSubsPerThread children per listed top-level thread (needs you, running, then most recent),
 *   at most maxSubs in total, each with `parent`.
 * - focus extras: parent, kids (<= maxFocusKids) + nkids, path (root -> focused, <= maxPath entries).
 * Rows come from the live shell and the fetched families; for one id the newer row (updatedAt) wins, the shell
 * on a tie (a finished subagent drops out of the filtered shell without a final update).
 */
export function buildThreadTree(inp: TreeInput, tids: TidMap, projects: Map<string, ProjectSummary>, providers: ProviderSummary[], caps: Caps): TreeResult {
  const byId = new Map<string, ThreadSummary>();
  const put = (t: ThreadSummary, preferNew: boolean) => {
    const have = byId.get(t.id);
    if (have && t.partial && !have.partial) return; // a projection-derived row never hides a real one
    if (!have || (have.partial && !t.partial) || (preferNew ? t.updatedAt >= have.updatedAt : t.updatedAt > have.updatedAt)) byId.set(t.id, t);
  };
  const tops = selectThreads(inp.shell, { maxThreads: caps.maxThreads, focusId: inp.focusId });
  const focusRow = inp.focusId ? inp.shell.find((t) => t.id === inp.focusId) : undefined;
  const lineage = { parentId: focusRow?.parentId ?? inp.focusLineage?.parentId ?? null, rootId: focusRow?.rootId ?? inp.focusLineage?.rootId ?? null };
  const roots: string[] = [];
  for (const t of tops) roots.push(t.rootId || t.id);
  if (inp.focusId) roots.push(lineage.rootId || inp.focusId);
  const wantRoots = [...new Set(roots)];
  for (const r of wantRoots) for (const t of inp.familyOf(r) ?? []) put(t, false);
  for (const t of inp.shell) put(t, true);
  // A focused subagent whose rows are not loaded yet still gets its lineage from its projection.
  if (inp.focusId && !byId.has(inp.focusId) && focusRow) byId.set(inp.focusId, focusRow);
  const focus = inp.focusId ? byId.get(inp.focusId) : undefined;
  const focusParent = focus?.parentId ?? lineage.parentId;

  const kidsOf = new Map<string, ThreadSummary[]>();
  for (const t of byId.values()) {
    if (!t.isSubagent || !t.parentId || t.archived) continue;
    const list = kidsOf.get(t.parentId);
    if (list) list.push(t); else kidsOf.set(t.parentId, [t]);
  }
  const refs = new Map((inp.focusSubagents ?? []).map((r) => [r.childThreadId, r]));
  const refFor = (t: ThreadSummary) => (inp.focusId && t.parentId === inp.focusId ? refs.get(t.id) : undefined);
  const stateOf = (t: ThreadSummary) => runState(t, refFor(t)).st;
  const needsAny = (t: ThreadSummary, depth: number): boolean =>
    !!t.pending || (depth < 4 && (kidsOf.get(t.id) ?? []).some((k) => needsAny(k, depth + 1)));
  const kidStats = (id: string) => {
    const kids = kidsOf.get(id) ?? [];
    let running = 0, need = 0;
    for (const k of kids) {
      if (needsAny(k, 1)) need++;
      else if (stateOf(k) === "running") running++;
    }
    return { kids: kids.length, running, need };
  };
  const sortKids = (list: ThreadSummary[]) => {
    const rank = (t: ThreadSummary) => (needsAny(t, 1) ? 0 : stateOf(t) === "running" ? 1 : 2);
    return [...list].sort((a, b) => rank(a) - rank(b) || recencyOf(b) - recencyOf(a) || (a.id < b.id ? -1 : 1));
  };
  const title = (t: ThreadSummary | undefined, fallback = "(untitled)") => clip((t?.title || fallback), caps.maxTitleBytes, caps.transliterate);
  const snap = (t: ThreadSummary, parent?: string) =>
    threadToSnap(t, tids, projects, providers, caps, { parent, ref: refFor(t), kids: kidStats(t.id) });

  // threads: top-level rows (+ the focused subagent and its ancestors below the root)
  const threads: SnapThread[] = [];
  const listed = new Set<string>();
  for (const t of tops) {
    if (t.isSubagent) continue; // the focused subagent is added below with its ancestors
    threads.push(snap(t));
    listed.add(t.id);
  }
  const path: ThreadSummary[] = [];
  if (focus) {
    let cur: ThreadSummary | undefined = focus;
    const seen = new Set<string>();
    while (cur && !seen.has(cur.id) && path.length < 12) {
      seen.add(cur.id);
      path.unshift(cur);
      cur = cur.parentId ? byId.get(cur.parentId) : undefined;
    }
    if (focus.isSubagent) {
      for (const t of path) {
        if (listed.has(t.id) || !t.isSubagent) continue;
        threads.push(snap(t, t.parentId ? tids.tid(t.parentId) : undefined));
        listed.add(t.id);
      }
    }
  } else if (inp.focusId && focusParent) {
    // Focused subagent whose row is unknown (not loaded yet): the snapshot still names its parent.
    const p = byId.get(focusParent);
    if (p) path.push(p);
  }

  // subs: children of the listed top-level threads
  const subs: SnapThread[] = [];
  for (const t of tops) {
    if (t.isSubagent || subs.length >= caps.maxSubs) continue;
    for (const k of sortKids(kidsOf.get(t.id) ?? []).slice(0, caps.maxSubsPerThread)) {
      if (subs.length >= caps.maxSubs) break;
      if (listed.has(k.id)) continue;
      subs.push(snap(k, tids.tid(t.id)));
    }
  }

  // focus extras
  const fx: TreeResult["focus"] = {};
  if (inp.focusId) {
    if (focusParent) {
      const p = byId.get(focusParent);
      fx.parent = { id: tids.tid(focusParent), title: title(p, "Parent thread") };
    }
    const kids = sortKids(kidsOf.get(inp.focusId) ?? []);
    if (kids.length) {
      fx.nkids = kids.length;
      fx.kids = kids.slice(0, caps.maxFocusKids).map((k): SnapKid => {
        const s = snap(k);
        const out: SnapKid = { id: s.id, title: s.title, st: s.st };
        if (s.need) out.need = s.need;
        else if (needsAny(k, 1)) out.need = "input";
        if (s.t0) out.t0 = s.t0;
        if (s.t1) out.t1 = s.t1;
        if (s.kids) out.kids = s.kids;
        return out;
      });
    }
    if (focusParent || (focus && focus.isSubagent)) {
      let refsPath: SnapRef[] = path.map((t) => ({ id: tids.tid(t.id), title: title(t) }));
      if (!focus) refsPath.push({ id: tids.tid(inp.focusId), title: clip(inp.focusTitle || "(untitled)", caps.maxTitleBytes, caps.transliterate) });
      if (refsPath.length > caps.maxPath) refsPath = [refsPath[0], ...refsPath.slice(refsPath.length - (caps.maxPath - 1))];
      if (refsPath.length > 1) fx.path = refsPath;
    }
  }
  return { threads, subs, focus: fx, wantRoots };
}

export function pendingToSnap(p: PendingRequest, rids: RidMap, caps: Caps): SnapPending {
  return {
    kind: p.kind,
    rid: rids.rid(p.requestId),
    text: utf8Head(caps.transliterate ? transliterate(p.text) : p.text, caps.maxPendingTextBytes),
    options: p.options.slice(0, 8).map((o) => ({ id: o.id, label: clip(o.label, 48, caps.transliterate) })),
  };
}

/** Maps a T3 thread id to its protocol tid (for `tl` link segments). */
export type LinkTid = (threadId: string) => string;

export function messageToSnap(m: { i: number; role: SnapMsg["r"]; ts: number; text: string; images?: ImageRef[]; parts?: MsgPart[] }, maxBytes: number, caps: Caps, resolveImage?: ImageResolver, linkTid?: LinkTid): SnapMsg {
  if (m.parts?.some((p) => p.kind === "link") && linkTid) return partsToSnap(m, m.parts, maxBytes, caps, linkTid);
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

/**
 * A message with thread links (rev 1.4): text parts become p/c segments, link parts `tl` segments, in order.
 * The byte cap applies to the text parts (links are short labels, at most 8 per message).
 */
function partsToSnap(m: { i: number; role: SnapMsg["r"]; ts: number; images?: ImageRef[] }, parts: MsgPart[], maxBytes: number, caps: Caps, linkTid: LinkTid): SnapMsg {
  const segs: SnapSeg[] = [];
  let budget = maxBytes, more = false, links = 0;
  for (const p of parts) {
    if (p.kind === "link") {
      if (links >= 8) continue;
      links++;
      segs.push(linkSeg(clip(p.label || "Linked thread", caps.maxTitleBytes, caps.transliterate), linkTid(p.threadId)));
      continue;
    }
    if (budget <= 0) { more = more || p.text.trim() !== ""; continue; }
    const [text, cut] = truncateMarkdownTail(p.text, budget);
    for (const s of markdownToSegs(text, { transliterate: caps.transliterate, keepMarks: keepMarksFor(m.role) })) {
      segs.push(s);
      budget -= utf8Len(s[1]);
    }
    more = more || cut;
  }
  return { i: m.i, r: m.role, ts: m.ts, segs: segs.length ? segs : [["p", ""]], more };
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
  /** rev 1.4: parent / kids / nkids / path of the focused thread (from buildThreadTree). */
  tree?: TreeResult["focus"];
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
  const linkTid: LinkTid = (id) => tids.tid(id);
  out.msgs = msgs.map((m, k) => messageToSnap(m, caps.maxMessageBytes, caps, f.resolveImage ? (k >= imageFrom ? f.resolveImage : oldImage) : undefined, linkTid));
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
  const tr = f.tree;
  if (tr?.parent) out.parent = tr.parent;
  if (tr?.kids?.length) { out.kids = tr.kids; out.nkids = tr.nkids ?? tr.kids.length; }
  if (tr?.path?.length) out.path = tr.path;
  return out;
}

// ---------------------------------------------------------------------------------------------
// Serialization with size enforcement
// ---------------------------------------------------------------------------------------------

export function serializeSnapshot(doc: SnapshotDoc, o: LuaOptions = {}): string {
  const head = `T3B_IN={v=1,sid=${toLua(doc.sid, o)},seq=${doc.seq},ts=${doc.ts},ack=${doc.ack},asid=${toLua(doc.asid, o)},`;
  const err = (doc.err ? `\n err=${toLua(doc.err, o)},` : "\n err=nil,") + (doc.imgslots ? `\n imgslots=${toLua(doc.imgslots, o)},` : "");
  const threads = "\n threads={" + doc.threads.map((t) => "\n  " + toLua(t, o)).join(",") + "}"
    + (doc.subs?.length ? ",\n subs={" + doc.subs.map((t) => "\n  " + toLua(t, o)).join(",") + "}" : "");
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
    const idx = msgs.findIndex((m) => m.segs.reduce((n, s) => n + (isImgSeg(s) || isLinkSeg(s) ? 0 : utf8Len(s[1])), 0) > 512);
    if (idx >= 0) {
      const m = msgs[idx];
      const textSegs = m.segs.filter((s): s is Seg => !isImgSeg(s) && !isLinkSeg(s));
      const half = Math.floor(textSegs.reduce((n, s) => n + utf8Len(s[1]), 0) / 2);
      const text = textSegs.map((s) => (s[0] === "c" ? "```\n" + s[1] + "\n```" : s[1])).join("\n\n");
      const [t] = truncateMarkdownTail(text, half);
      msgs[idx] = { ...m, segs: [...markdownToSegs(t, { transliterate: false, keepMarks: keepMarksFor(m.r) }), ...m.segs.filter((s) => isImgSeg(s) || isLinkSeg(s))], more: true };
    } else { msgs.shift(); doc.focus.older = true; }
    shrunk++;
    lua = serializeSnapshot(doc, o);
  }
  return { lua, shrunk };
}

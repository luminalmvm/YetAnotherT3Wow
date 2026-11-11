// Outbound command -> T3 call. Pure orchestration over the T3Client interface (testable with a fake).
import { spawn } from "node:child_process";
import type { Command } from "./wow/frameCodec.js";
import type { T3Client } from "./t3/client.js";
import type { RidMap, TidMap } from "./model/snapshot.js";
import type { ThreadDetail } from "./t3/types.js";
import type { ImageManager } from "./images/manager.js";
import { log } from "./log.js";

export class ActionError extends Error {}

export interface ActionContext {
  t3: T3Client;
  tids: TidMap;
  rids: RidMap;
  /** Focus window state (PROTOCOL 2.6). */
  focus: { tid: string | null; windowStart: number | null };
  caps: { focusWindow: number; maxFocusWindow: number };
  environmentId?: string;
  /** Override for tests. */
  openUrl?: (url: string) => void;
  onHello?: (c: Extract<Command, { kind: "hello" }>) => void;
  /** Image support (PROTOCOL rev 1.3); absent = images unavailable. */
  images?: ImageManager;
}

function threadIdFor(ctx: ActionContext, tid: string): string {
  const id = ctx.tids.resolve(tid);
  if (!id) throw new ActionError(`Unknown thread ${tid}`);
  return id;
}

export function defaultOpenUrl(url: string): void {
  // Only fixed scheme + validated ids reach here.
  if (!/^t3code:\/\/[A-Za-z0-9/_.:-]*$/.test(url)) throw new ActionError("refusing to open unexpected URL");
  const child = spawn("cmd.exe", ["/d", "/c", "start", "", url], { detached: true, stdio: "ignore", windowsHide: true });
  child.unref();
}

/** Resolves an `ans` answer against the pending request of the focused thread. */
export function resolveAnswer(detail: ThreadDetail | null, requestId: string, answer: string):
  | { type: "approval"; decision: string; feedback?: string }
  | { type: "input"; answers: Record<string, unknown> } {
  const p = detail?.pending;
  if (!p || p.requestId !== requestId) {
    // Not loaded (thread not focused): only exact decision ids can be honoured safely.
    if (["accept", "acceptForSession", "acceptAlways", "decline", "cancel"].includes(answer)) return { type: "approval", decision: answer };
    throw new ActionError("That request is no longer pending");
  }
  if (p.kind === "approval") {
    if (p.options.some((o) => o.id === answer)) return { type: "approval", decision: answer };
    // Free text on an approval = deny with feedback for the agent.
    return { type: "approval", decision: "decline", feedback: answer };
  }
  const qs = p.questions ?? [];
  if (!qs.length) throw new ActionError("Input request has no questions; answer it in T3 Code");
  const answers: Record<string, unknown> = {};
  if (qs.length === 1) {
    const opt = qs[0].options.find((o) => o.id === answer);
    answers[qs[0].id] = opt ? opt.label : answer;
  } else {
    // Several questions: one answer per line in order, option numbers or ids allowed.
    const lines = answer.split(/\r?\n/);
    qs.forEach((q, k) => {
      const v = (lines[k] ?? "").trim();
      const byId = q.options.find((o) => o.id === v);
      const byNum = /^\d+$/.test(v) ? q.options[Number(v) - 1] : undefined;
      answers[q.id] = (byId ?? byNum)?.label ?? v;
    });
  }
  return { type: "input", answers };
}

/** Executes one command. Throws ActionError with a short user-facing message on failure. */
export async function executeCommand(ctx: ActionContext, cmd: Command): Promise<void> {
  switch (cmd.kind) {
    case "hello":
      ctx.onHello?.(cmd);
      return;
    case "focus": {
      const id = threadIdFor(ctx, cmd.tid);
      ctx.focus.tid = cmd.tid;
      ctx.focus.windowStart = null;
      await ctx.t3.focus(id);
      return;
    }
    case "send": {
      const id = threadIdFor(ctx, cmd.tid);
      // Staged images (D17) go with this message; a message may then have no text.
      const staged = ctx.images?.stagedFor(cmd.tid).length ?? 0;
      if (!cmd.text.trim() && !staged) throw new ActionError("Empty message");
      if (!staged) { await ctx.t3.sendMessage(id, cmd.text, cmd.clientMsgId); return; }
      let prepared;
      try { prepared = await ctx.images!.prepareSend(cmd.tid, id); }
      catch (e) { throw new ActionError(`Image upload failed: ${(e as Error).message}`.slice(0, 120)); }
      await ctx.t3.sendMessage(id, cmd.text, cmd.clientMsgId, prepared.attachments);
      prepared.commit();
      return;
    }
    case "model": {
      const id = threadIdFor(ctx, cmd.tid);
      await ctx.t3.setModel(id, cmd.modelId, cmd.effort);
      return;
    }
    case "intr": {
      const id = threadIdFor(ctx, cmd.tid);
      await ctx.t3.interrupt(id);
      return;
    }
    case "ans": {
      const id = threadIdFor(ctx, cmd.tid);
      const requestId = ctx.rids.resolve(cmd.rid);
      if (!requestId) throw new ActionError("Unknown request");
      const detail = ctx.t3.focusedThreadId() === id ? ctx.t3.focusDetail() : null;
      const r = resolveAnswer(detail, requestId, cmd.answer);
      if (r.type === "approval") await ctx.t3.respondApproval(id, requestId, r.decision, r.feedback);
      else await ctx.t3.answerUserInput(id, requestId, r.answers);
      return;
    }
    case "hist": {
      const id = threadIdFor(ctx, cmd.tid);
      if (ctx.focus.tid !== cmd.tid || ctx.t3.focusedThreadId() !== id) throw new ActionError("Focus the thread first");
      await ctx.t3.loadOlder(id, cmd.beforeIndex, ctx.caps.focusWindow);
      const msgs = ctx.t3.focusDetail()?.messages ?? [];
      const before = msgs.filter((m) => m.i < cmd.beforeIndex);
      if (!before.length) return;
      const start = before[Math.max(0, before.length - ctx.caps.focusWindow)].i;
      const windowCount = msgs.filter((m) => m.i >= start).length;
      if (windowCount > ctx.caps.maxFocusWindow) { log.info("hist ignored: focus window at its 120-message cap"); return; }
      ctx.focus.windowStart = start;
      return;
    }
    case "clip": {
      threadIdFor(ctx, cmd.tid);
      if (!ctx.images) { if (!cmd.quiet) throw new ActionError("Images are not available"); return; }
      await ctx.images.clip(cmd.tid, cmd.quiet);
      return;
    }
    case "shot": {
      threadIdFor(ctx, cmd.tid);
      if (!ctx.images) throw new ActionError("Images are not available");
      await ctx.images.shot(cmd.tid);
      return;
    }
    case "unstage": {
      ctx.images?.unstage(cmd.tid, cmd.aid);
      return;
    }
    case "open": {
      const open = ctx.openUrl ?? defaultOpenUrl;
      if (cmd.tid && ctx.environmentId) {
        const id = threadIdFor(ctx, cmd.tid);
        open(`t3code://threads/${ctx.environmentId}/${id}`);
      } else open("t3code://app");
      return;
    }
  }
}

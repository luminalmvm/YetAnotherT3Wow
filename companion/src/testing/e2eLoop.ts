// Full outbound loop against the REAL T3 server, on a throwaway thread created and deleted here:
//   addon-style frames (focus, send) -> T3TestWindow pixels -> T3Capture (WGC) -> decoder -> Bridge -> T3 dispatch
//   -> agent reply observed via the T3 client; ack/asid verified in the written live.lua.
// Usage: node dist/testing/e2eLoop.js [--hold-ms 700] [--cell 2]
import { spawn } from "node:child_process";
import { randomBytes } from "node:crypto";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { Bridge } from "../bridge.js";
import { appDataDir, defaultConfig } from "../config.js";
import { configureLog } from "../log.js";
import { ensureAuth, TokenStore } from "../t3/auth.js";
import { RpcT3Client } from "../t3/client.js";
import { discover } from "../t3/discovery.js";
import { CaptureHelper, defaultHelperPath, unixUsNow } from "../wow/captureClient.js";
import { cellStrings } from "../wow/frameCodec.js";
import { decodeImage } from "../wow/frameDecoder.js";
import { LiveWriter } from "../wow/liveWriter.js";
import { encodeMessage } from "./frameEncoder.js";

const NO_PROJECT_TITLE = "No project";
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
async function waitFor<T>(fn: () => T | undefined | null | false, ms: number, what: string): Promise<T> {
  const t0 = Date.now();
  for (;;) { const v = fn(); if (v) return v; if (Date.now() - t0 > ms) throw new Error(`timeout: ${what}`); await sleep(100); }
}

async function main() {
  configureLog({ level: "info" });
  const a = process.argv.slice(2);
  const get = (k: string, d: string) => { const i = a.indexOf(k); return i >= 0 ? a[i + 1] : d; };
  const holdMs = Number(get("--hold-ms", "700")), cell = Number(get("--cell", "2"));
  const cfg = defaultConfig();
  const srv = await discover(cfg.t3.runtimeFile);
  const auth = await ensureAuth({ origin: srv.origin, store: new TokenStore(appDataDir()), cliPath: cfg.t3.cliPath, ttl: cfg.t3.tokenTtl, allowIssue: false });
  const t3 = new RpcT3Client({ origin: srv.origin, getBearer: async () => auth.token });
  await t3.start();
  await waitFor(() => t3.threads().length > 0 && t3.projects().size > 0, 10000, "shell");
  const project = [...t3.projects().values()].find((p) => p.title === NO_PROJECT_TITLE);
  if (!project) throw new Error("no 'No project' project to host a throwaway thread");
  const threadId = await t3.launchThread({ projectId: project.id, title: "T3Bridge loop test (safe to delete)", text: "Automated T3Bridge loop test. Reply with exactly: READY. No tools.", instanceId: "claudeAgent_2", model: "claude-haiku-4-5", runtimeMode: "approval-required" });
  const result: any = { threadId: threadId.slice(0, 8) + "..." };
  const helperExe = defaultHelperPath()!;
  let helper: CaptureHelper | undefined;
  let win: ReturnType<typeof spawn> | undefined;
  try {
    await waitFor(() => t3.threads().find((t) => t.id === threadId && t.status === "completed"), 120000, "initial reply");
    const live = join(tmpdir(), "t3bridge-e2e", `loop-live-${process.pid}.lua`);
    mkdirSync(dirname(live), { recursive: true });
    let writer: LiveWriter;
    const bridge = new Bridge({ t3, environmentId: srv.descriptor?.environmentId, onDirty: () => writer?.markDirty(), onAck: () => writer?.writeNow("ack") });
    writer = new LiveWriter({ file: live, mode: "inplace", padBytes: 524288, debounceMs: 300, minIntervalMs: 250, heartbeatMs: 10000, render: (s, ts) => bridge.render(s, ts), allowCreate: true });
    writer.start();
    // Watch the thread directly (independent of whether the addon's focus frame is captured).
    await t3.focus(threadId);
    const tid = bridge.tids.tid(threadId);
    const asid = randomBytes(4);
    const asidHex = asid.toString("hex");
    const cmds = [`hello\t1\te2e-loop\t${cell}\t8`, `focus\t${tid}`, `send\t${tid}\t${asidHex}-3\tLoop test via pixels: reply with exactly LOOP-OK and nothing else.`];
    const frames = cmds.flatMap((m, k) => { const e = encodeMessage(asid, k + 1, m); return e.frames.map((f, p) => ({ label: `${k + 1}:${p + 1}`, rows: e.rows, cells: cellStrings(f, e.rows) })); });
    const framesFile = join(tmpdir(), "t3bridge-e2e", `loop-frames-${process.pid}.json`);
    writeFileSync(framesFile, JSON.stringify(frames));
    const here = dirname(fileURLToPath(import.meta.url));
    const windowExe = resolve(here, "..", "..", "..", "capture-helper", "T3TestWindow", "bin", "Release", "net7.0-windows", "T3TestWindow.exe");
    win = spawn(windowExe, ["--frames", framesFile, "--cell", String(cell), "--hold-ms", String(holdMs), "--gap-ms", "350", "--start-delay-ms", "6000", "--repeat", "2", "--size", "720x200", "--exit-delay-ms", "500"], { stdio: ["ignore", "pipe", "ignore"] });
    const shown = new Map<string, number>();
    let ready: any;
    let buf = "";
    win.stdout!.on("data", (d) => { buf += d; let nl; while ((nl = buf.indexOf("\n")) >= 0) { const ev = JSON.parse(buf.slice(0, nl)); buf = buf.slice(nl + 1); if (ev.ev === "ready") ready = ev; if (ev.ev === "shown" && !shown.has(ev.label)) shown.set(ev.label, ev.unixUs); } });
    await waitFor(() => ready, 15000, "test window");
    helper = new CaptureHelper({ exe: helperExe, args: ["--hwnd", ready.hwnd, "--region", "600x140"] });
    const decodedAt = new Map<number, number>();
    (globalThis as any).__bridge = bridge; (globalThis as any).__decoded = []; (globalThis as any).__statuses = [];
    helper.on("status", (st) => { if (st.ev !== "stats") (globalThis as any).__statuses.push(JSON.stringify(st).slice(0, 200)); else (globalThis as any).__statuses.push(`stats arr=${st.arrivedFps} sync=${st.syncFrames} emitted=${st.emitted}`); });
    helper.on("record", (r) => { const res = decodeImage(r.image); (globalThis as any).__decoded.push(res.ok ? `ok seq=${res.frame.seq}` : `fail ${res.reason}`); if (res.ok) { if (!decodedAt.has(res.frame.seq)) decodedAt.set(res.frame.seq, unixUsNow()); bridge.onFrame(res.frame); } });
    helper.start();
    const sendSeen = await waitFor(() => (t3.focusDetail()?.messages ?? []).find((m) => m.role === "u" && m.text.includes("Loop test via pixels")), 60000, "user message from pixels in T3");
    const tUser = unixUsNow();
    const reply = await waitFor(() => (t3.focusDetail()?.messages ?? []).find((m) => m.role === "a" && m.text.includes("LOOP-OK")), 120000, "agent reply");
    await sleep(800);
    const liveText = readFileSync(live, "utf8");
    result.ok = true;
    result.ackInLive = /ack=3,asid="([0-9a-f]{8})"/.exec(liveText)?.[1] === asidHex;
    result.focusInLive = liveText.includes(`focus={id="${tid}"`);
    result.replyInLive = liveText.includes("LOOP-OK");
    result.sendShownToDecodedMs = decodedAt.get(3) && shown.get("3:1") ? (decodedAt.get(3)! - shown.get("3:1")!) / 1000 : null;
    result.sendShownToVisibleInT3Ms = shown.get("3:1") ? (tUser - shown.get("3:1")!) / 1000 : null;
    result.userText = sendSeen.text;
    result.replyText = reply.text.slice(0, 40);
    result.bridgeEvents = bridge.events.map((e) => ({ kind: e.kind, seq: e.seq, cmd: e.cmd, ms: e.ms }));
    writer.stop();
  } catch (e) {
    result.ok = false;
    result.error = (e as Error).message;
    result.debug = { decoded: [...(globalThis as any).__decoded ?? []], statuses: (globalThis as any).__statuses ?? [], events: (globalThis as any).__bridge?.events, focus: (globalThis as any).__bridge?.focus, focusDetailMsgs: t3.focusDetail()?.messages.slice(-4).map((m) => ({ r: m.role, t: m.text.slice(0, 60) })), focusedId: t3.focusedThreadId()?.slice(0, 8) };
  } finally {
    helper?.stop();
    try { win?.kill(); } catch { /* ignore */ }
    try { await t3.deleteThread(threadId); result.deleted = true; } catch (e) { result.deleteError = (e as Error).message; }
    t3.stop();
    console.log(JSON.stringify(result, null, 1));
    setTimeout(() => process.exit(result.ok ? 0 : 1), 300);
  }
}
main().catch((e) => { console.error(e); process.exit(2); });

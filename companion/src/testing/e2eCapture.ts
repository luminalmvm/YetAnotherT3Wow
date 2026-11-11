// End-to-end outbound test without WoW:
//   reference encoder -> T3TestWindow (paints frames, logs show times) -> T3Capture (WGC) -> frameDecoder -> Reassembler.
// Usage: node dist/testing/e2eCapture.js [--cell 2] [--scale 1.0] [--dpi permonitor|unaware] [--hold-ms 200]
//          [--gap-ms 120] [--idle-fps 10] [--active-fps 30] [--repeat 1] [--pos 40,40] [--json out.json]
import { spawn } from "node:child_process";
import { randomBytes } from "node:crypto";
import { mkdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { cellStrings } from "../wow/frameCodec.js";
import { decodeImage, decodeUtf8, Reassembler } from "../wow/frameDecoder.js";
import { CaptureHelper, defaultHelperPath, unixUsNow, type CaptureRecord } from "../wow/captureClient.js";
import { encodeMessage } from "./frameEncoder.js";

export interface E2EOptions {
  cell: number; scale: number; dpi: "permonitor" | "unaware"; holdMs: number; gapMs: number;
  idleFps: number; activeFps: number; repeat: number; pos: string; background: string; animateFps?: number; topmost?: boolean; renderer?: "d3d" | "gdi"; messages?: string[];
}

export function sampleMessages(): string[] {
  const long = (n: number) => {
    const words = "the quick brown fox jumps over the lazy dog while T3Bridge carries text through pixels".split(" ");
    let s = ""; let k = 0;
    while (Buffer.byteLength(s) < n) s += (s ? " " : "") + words[k++ % words.length] + (k % 17 === 0 ? " — åäö ✓\n\t" : "");
    return Buffer.from(s).subarray(0, n).toString("utf8").replace(/�+$/, "");
  };
  return [
    "hello\t1\t0.1.0\t2\t8",
    "focus\ta1b2c3d4",
    "send\ta1b2c3d4\t9f3a01c2-3\tHi from Azeroth! Can you run the tests again?",
    "model\ta1b2c3d4\tclaude-sonnet-5-5",
    "ans\ta1b2c3d4\tr0123456789ab\taccept",
    `send\ta1b2c3d4\t9f3a01c2-6\t${long(600)}`,
    `send\ta1b2c3d4\t9f3a01c2-7\t${long(2500)}`,
    "intr\ta1b2c3d4",
    `send\ta1b2c3d4\t9f3a01c2-9\t${long(4000)}`,
    "hist\ta1b2c3d4\t131",
  ];
}

function pct(a: number[], p: number): number {
  if (!a.length) return NaN;
  const s = [...a].sort((x, y) => x - y);
  return s[Math.min(s.length - 1, Math.floor((p / 100) * s.length))];
}

export async function runE2E(o: E2EOptions): Promise<any> {
  const here = dirname(fileURLToPath(import.meta.url));
  const root = resolve(here, "..", "..", "..");
  const windowExe = join(root, "capture-helper", "T3TestWindow", "bin", "Release", "net7.0-windows", "T3TestWindow.exe");
  const helperExe = defaultHelperPath();
  if (!helperExe) throw new Error("T3Capture.exe not built");
  const sid = randomBytes(4);
  const msgs = o.messages ?? sampleMessages();
  const frames: { label: string; rows: number; cells: string[] }[] = [];
  const expected = new Map<number, string>();
  msgs.forEach((m, k) => {
    const seq = k + 1;
    expected.set(seq, m);
    const enc = encodeMessage(sid, seq, m);
    enc.frames.forEach((f, p) => frames.push({ label: `${seq}:${p + 1}/${enc.frames.length}`, rows: enc.rows, cells: cellStrings(f, enc.rows) }));
  });
  const dir = join(tmpdir(), "t3bridge-e2e");
  mkdirSync(dir, { recursive: true });
  const framesFile = join(dir, `frames-${process.pid}.json`);
  writeFileSync(framesFile, JSON.stringify(frames));

  const pitch = o.cell * o.scale;
  const regionW = Math.ceil(256 * pitch) + 64, regionH = Math.ceil(32 * pitch) + 64;
  const win = spawn(windowExe, ["--frames", framesFile, "--cell", String(o.cell), "--scale", String(o.scale), "--dpi", o.dpi, "--hold-ms", String(o.holdMs),
    "--gap-ms", String(o.gapMs), "--repeat", String(o.repeat), "--pos", o.pos, "--background", o.background, "--size", `${Math.max(640, regionW + 80)}x${Math.max(240, regionH + 80)}`,
    "--start-delay-ms", "2500", "--animate-fps", String(o.animateFps ?? 0), "--topmost", o.topmost ? "1" : "0", "--renderer", o.renderer ?? "d3d"], { stdio: ["ignore", "pipe", "pipe"] });
  const shown = new Map<string, number>();
  let ready: any = null;
  let doneAt = 0;
  let wbuf = "";
  win.stdout!.on("data", (d: Buffer) => {
    wbuf += d.toString();
    let nl: number;
    while ((nl = wbuf.indexOf("\n")) >= 0) {
      const line = wbuf.slice(0, nl).trim(); wbuf = wbuf.slice(nl + 1);
      if (!line) continue;
      const ev = JSON.parse(line);
      if (ev.ev === "ready") ready = ev;
      if (ev.ev === "shown" && !shown.has(`${ev.rep}|${ev.label}`)) shown.set(`${ev.rep}|${ev.label}`, ev.unixUs);
      if (process.env.T3B_E2E_TRACE && (ev.ev === "shown" || ev.ev === "hidden" || ev.ev === "paints")) console.error(`win ${ev.ev} ${ev.label ?? ev.perSec}`);
      if (ev.ev === "done") doneAt = Date.now();
    }
  });
  const t0 = Date.now();
  while (!ready && Date.now() - t0 < 15000) await new Promise((r) => setTimeout(r, 50));
  if (!ready) { win.kill(); throw new Error("test window did not start"); }

  const extra = process.env.T3B_E2E_EMIT_ALL ? ["--emit-all", "--no-dedupe"] : [];
  const helper = new CaptureHelper({ exe: helperExe, args: [...extra, "--hwnd", ready.hwnd, "--region", `${regionW}x${regionH}`, "--idle-fps", String(o.idleFps), "--active-fps", String(o.activeFps), "--stats-ms", "2000"] });
  const statuses: any[] = [];
  helper.on("status", (s) => { statuses.push(s); if (process.env.T3B_E2E_TRACE) console.error("helper " + JSON.stringify(s).slice(0, 300)); });
  const re = new Reassembler();
  const firstDecode = new Map<string, { at: number; frameUs: number; readyUs: number }>();
  const complete = new Map<number, { text: string; at: number }>();
  const fail: Record<string, number> = {};
  let records = 0, okFrames = 0;
  let rep = 0; let lastSeq = 0;
  const decodeMs: number[] = [];
  helper.on("record", (r: CaptureRecord) => {
    records++;
    const d0 = performance.now();
    const res = decodeImage(r.image, { maxX: 96, maxY: 120 });
    decodeMs.push(performance.now() - d0);
    if (!res.ok) {
      fail[res.reason] = (fail[res.reason] ?? 0) + 1;
      if (process.env.T3B_E2E_DUMP) {
        const pgm = Buffer.concat([Buffer.from(`P5 ${r.image.width} ${r.image.height} 255
`), Buffer.from(r.image.data)]);
        writeFileSync(join(process.env.T3B_E2E_DUMP, `fail-${r.seq}-${res.reason}.pgm`), pgm);
      }
      return;
    }
    okFrames++;
    const f = res.frame;
    if (f.seq < lastSeq) rep++;
    lastSeq = f.seq;
    const key = `${rep}|${f.seq}:${f.part}/${f.parts}`;
    if (process.env.T3B_E2E_TRACE) console.error(`rec ${r.seq} -> ${key}`);
    if (!firstDecode.has(key)) firstDecode.set(key, { at: unixUsNow(), frameUs: r.frameUnixUs, readyUs: r.readyUnixUs });
    const pr = re.push(f);
    if (pr.kind === "complete") complete.set(pr.msg.seq, { text: decodeUtf8(pr.msg.payload), at: unixUsNow() });
  });
  helper.start();
  while (!doneAt && Date.now() - t0 < 120000) await new Promise((r) => setTimeout(r, 100));
  await new Promise((r) => setTimeout(r, 1200));
  helper.stop();
  try { win.kill(); } catch { /* ignore */ }

  // Latency per part (first repetition only)
  const lat: number[] = [], capLat: number[] = [], pipe: number[] = [];
  let partsSeen = 0;
  for (const [k, sh] of shown) {
    const d = firstDecode.get(k);
    if (!d) continue;
    partsSeen++;
    lat.push((d.at - sh) / 1000);
    capLat.push((d.frameUs - sh) / 1000);
    pipe.push((d.at - d.frameUs) / 1000);
  }
  let matched = 0;
  for (const [seq, text] of expected) if (complete.get(seq)?.text === text) matched++;
  const stats = statuses.filter((s) => s.ev === "stats" && s.processedFps > 0);
  const attached = statuses.find((s) => s.ev === "attached");
  return {
    config: { ...o, regionW, regionH, framesTotal: frames.length * o.repeat, messages: msgs.length, monitorDpi: ready.dpi, windowDpiMode: ready.dpiMode, renderer: ready.renderer },
    attached: attached ? { borderOff: attached.borderOff, originX: attached.originX, originY: attached.originY, dpi: attached.dpi, itemW: attached.itemW, itemH: attached.itemH } : null,
    result: {
      messagesComplete: complete.size, messagesMatched: matched, messagesExpected: msgs.length,
      partsShown: shown.size, partsDecoded: partsSeen, records, okFrames, decodeFailures: fail,
      latencyMs: { p50: +pct(lat, 50).toFixed(1), p95: +pct(lat, 95).toFixed(1), max: +Math.max(...lat).toFixed(1) },
      showToFrameMs: { p50: +pct(capLat, 50).toFixed(1), p95: +pct(capLat, 95).toFixed(1) },
      frameToDecodeMs: { p50: +pct(pipe, 50).toFixed(1), p95: +pct(pipe, 95).toFixed(1) },
      decodeCpuMs: { p50: +pct(decodeMs, 50).toFixed(2), p95: +pct(decodeMs, 95).toFixed(2) },
      helper: stats.length ? { processedFps: stats.map((s) => s.processedFps), arrivedFps: stats.map((s) => s.arrivedFps), cpuPctOneCore: stats.map((s) => s.cpuPctOneCore), avgReadbackMs: stats.map((s) => s.avgReadbackMs) } : null,
    },
  };
}

const isMain = process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (isMain) {
  const a = process.argv.slice(2);
  const get = (k: string, d: string) => { const i = a.indexOf(k); return i >= 0 ? a[i + 1] : d; };
  const opts: E2EOptions = {
    cell: Number(get("--cell", "2")), scale: Number(get("--scale", "1")), dpi: get("--dpi", "permonitor") as any,
    holdMs: Number(get("--hold-ms", "200")), gapMs: Number(get("--gap-ms", "120")), idleFps: Number(get("--idle-fps", "10")),
    activeFps: Number(get("--active-fps", "30")), repeat: Number(get("--repeat", "1")), pos: get("--pos", "40,40"), background: get("--background", "game"),
    animateFps: Number(get("--animate-fps", "0")), topmost: a.includes("--topmost"), renderer: get("--renderer", "d3d") as any,
  };
  runE2E(opts).then((r) => {
    const out = JSON.stringify(r, null, 1);
    const jf = get("--json", "");
    if (jf) writeFileSync(jf, out);
    console.log(out);
    process.exit(r.result.messagesMatched === r.result.messagesExpected ? 0 : 1);
  }).catch((e) => { console.error(e); process.exit(2); });
}

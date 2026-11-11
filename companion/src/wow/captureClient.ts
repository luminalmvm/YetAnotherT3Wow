// Spawns capture-helper (T3Capture.exe, Windows.Graphics.Capture) and parses its binary stdout records.
// Record: "T3CF"(4) ver(1) kind(1) w(u16) h(u16) cropX(u16) cropY(u16) seq(u32) frameUnixUs(i64) readyUnixUs(i64) pitchMilli(u32) + w*h luma.
import { spawn, type ChildProcess } from "node:child_process";
import { EventEmitter } from "node:events";
import { existsSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { log } from "../log.js";
import type { LumaImage } from "./frameDecoder.js";

export const RECORD_HEADER = 38;

export interface CaptureRecord {
  image: LumaImage;
  cropX: number;
  cropY: number;
  seq: number;
  /** When DWM produced the frame (unix µs, from the frame's SystemRelativeTime). */
  frameUnixUs: number;
  /** When the helper finished the readback (unix µs). */
  readyUnixUs: number;
  /** When Node received the record (unix µs). */
  receivedUnixUs: number;
  pitch: number;
}

export function unixUsNow(): number { return Math.round((performance.timeOrigin + performance.now()) * 1000); }

/** Incremental parser for the helper's stdout. */
export class RecordParser {
  private buf: Buffer = Buffer.alloc(0);
  resyncs = 0;
  push(chunk: Buffer, onRecord: (r: CaptureRecord) => void): void {
    this.buf = this.buf.length ? Buffer.concat([this.buf, chunk]) : Buffer.from(chunk);
    for (;;) {
      if (this.buf.length < RECORD_HEADER) return;
      if (this.buf.toString("latin1", 0, 4) !== "T3CF") {
        const at = this.buf.indexOf("T3CF", 1, "latin1");
        this.resyncs++;
        this.buf = at < 0 ? this.buf.subarray(Math.max(0, this.buf.length - 3)) : this.buf.subarray(at);
        continue;
      }
      const w = this.buf.readUInt16LE(6), h = this.buf.readUInt16LE(8);
      const need = RECORD_HEADER + w * h;
      if (this.buf.length < need) return;
      const rec: CaptureRecord = {
        image: { width: w, height: h, data: new Uint8Array(this.buf.subarray(RECORD_HEADER, need)) },
        cropX: this.buf.readUInt16LE(10),
        cropY: this.buf.readUInt16LE(12),
        seq: this.buf.readUInt32LE(14),
        frameUnixUs: Number(this.buf.readBigInt64LE(18)),
        readyUnixUs: Number(this.buf.readBigInt64LE(26)),
        pitch: this.buf.readUInt32LE(34) / 1000,
        receivedUnixUs: unixUsNow(),
      };
      this.buf = this.buf.subarray(need);
      onRecord(rec);
    }
  }
}

export function defaultHelperPath(): string | null {
  const here = dirname(fileURLToPath(import.meta.url));
  const cands = [
    process.env.T3B_CAPTURE_HELPER,
    join(process.env.LOCALAPPDATA ?? "", "T3Bridge", "capture", "T3Capture.exe"),
    resolve(here, "..", "..", "..", "capture-helper", "T3Capture", "bin", "Release", "net7.0-windows10.0.22621.0", "T3Capture.exe"),
  ].filter(Boolean) as string[];
  return cands.find((p) => existsSync(p)) ?? null;
}

export interface CaptureHelperOptions {
  exe: string;
  args: string[];
  restartOnExit?: boolean;
}

export class CaptureHelper extends EventEmitter {
  private child?: ChildProcess;
  private parser = new RecordParser();
  private stopped = false;
  private restartTimer?: NodeJS.Timeout;
  lastStats: any = null;

  constructor(private readonly o: CaptureHelperOptions) { super(); }

  start(): void {
    this.stopped = false;
    const child = spawn(this.o.exe, this.o.args, { stdio: ["pipe", "pipe", "pipe"], windowsHide: true });
    this.child = child;
    child.stdout!.on("data", (d: Buffer) => this.parser.push(d, (r) => this.emit("record", r)));
    let errBuf = "";
    child.stderr!.on("data", (d: Buffer) => {
      errBuf += d.toString("utf8");
      let nl: number;
      while ((nl = errBuf.indexOf("\n")) >= 0) {
        const line = errBuf.slice(0, nl).trim();
        errBuf = errBuf.slice(nl + 1);
        if (!line) continue;
        let ev: any;
        try { ev = JSON.parse(line); } catch { log.debug(`capture-helper: ${line}`); continue; }
        if (ev.ev === "stats") this.lastStats = ev;
        this.emit("status", ev);
      }
    });
    child.on("exit", (code) => {
      this.emit("exit", code);
      if (!this.stopped && this.o.restartOnExit) {
        log.warn(`capture-helper exited (${code}); restarting in 3 s`);
        this.restartTimer = setTimeout(() => this.start(), 3000);
      }
    });
    child.on("error", (e) => log.error(`capture-helper failed to start: ${e.message}`));
  }

  stop(): void {
    this.stopped = true;
    if (this.restartTimer) clearTimeout(this.restartTimer);
    try { this.child?.stdin?.end(); } catch { /* ignore */ }
    const c = this.child;
    if (c) setTimeout(() => { try { c.kill(); } catch { /* ignore */ } }, 1500).unref();
  }
}

export function helperArgs(c: { processName: string; regionWidth: number; regionHeight: number; idleFps: number; activeFps: number; activeHoldMs: number }): string[] {
  return ["--process", c.processName, "--region", `${c.regionWidth}x${c.regionHeight}`, "--idle-fps", String(c.idleFps), "--active-fps", String(c.activeFps), "--active-hold-ms", String(c.activeHoldMs)];
}

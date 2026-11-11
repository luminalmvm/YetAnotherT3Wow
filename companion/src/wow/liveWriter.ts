// Writes the inbound snapshot file (PROTOCOL.md 2.1/2.3).
//
// Modes:
//  - "inplace" (default, required for hard-link slots): open the EXISTING file, write the padded
//    snapshot at offset 0, never truncate, never rename, never create.
//  - "rename": write <file>.t3b-tmp next to it, then rename over the target (variant A only; breaks hard links).
// Rate: debounced writes on change (>= minIntervalMs apart), immediate writes for acks, heartbeat every heartbeatMs.
// seq increases by 1 with every write (heartbeats included) and T3B_IN_END always equals it.
import { closeSync, existsSync, fstatSync, openSync, renameSync, unlinkSync, writeSync } from "node:fs";
import { log } from "../log.js";

export type WriteMode = "inplace" | "rename";

export interface LiveWriterOptions {
  file: string;
  mode: WriteMode;
  /** Pad to exactly this many bytes (PROTOCOL D6: 524288). 0 = pad only up to the previous size. */
  padBytes: number;
  debounceMs: number;
  minIntervalMs: number;
  heartbeatMs: number;
  /** Returns the full Lua text for this seq/ts. */
  render: (seq: number, ts: number) => string;
  /** Optional secondary file (Inbox.lua fallback), written in place at most every `secondaryIntervalMs`. */
  secondaryFile?: string;
  secondaryIntervalMs?: number;
  /** Allow creating the file if missing (demo/test only; PROTOCOL 2.3 rule 7 forbids it for the real file). */
  allowCreate?: boolean;
  /** Starting seq (default 0 -> first write is 1). */
  startSeq?: number;
  now?: () => number;
  onWrite?: (info: WriteInfo) => void;
}

export interface WriteInfo { seq: number; bytes: number; contentBytes: number; ms: number; reason: string; file: string }

export class MissingLiveFileError extends Error {
  constructor(readonly file: string) {
    super(`${file} does not exist. Run the addon installer (scripts\\install-addon.ps1) and restart WoW; the companion never creates it.`);
  }
}

const sleepSync = (ms: number) => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);

function withRetry<T>(fn: () => T, what: string): T {
  let last: unknown;
  for (let k = 0; k < 10; k++) {
    try { return fn(); } catch (e: any) {
      last = e;
      if (!["EBUSY", "EPERM", "EACCES"].includes(e?.code)) throw e;
      sleepSync(50);
    }
  }
  throw new Error(`${what} failed after 10 retries: ${(last as Error)?.message}`);
}

/** Builds the padded byte image of the file. */
export function padContent(lua: string, padBytes: number, prevSize: number): Buffer {
  const body = Buffer.from(lua, "utf8");
  const target = Math.max(padBytes, padBytes > 0 ? 0 : prevSize, body.length);
  if (padBytes > 0 && body.length > padBytes) throw new Error(`snapshot ${body.length} B exceeds pad size ${padBytes} B`);
  // never shrink an existing file in place
  const size = Math.max(target, prevSize);
  if (size === body.length) return body;
  const out = Buffer.alloc(size, 0x20);
  body.copy(out, 0);
  return out;
}

/** In-place write at offset 0 (no truncate). Returns bytes written. */
export function writeInPlace(file: string, lua: string, padBytes: number, allowCreate = false): { bytes: number; contentBytes: number } {
  if (!existsSync(file) && !allowCreate) throw new MissingLiveFileError(file);
  return withRetry(() => {
    const fd = openSync(file, existsSync(file) ? "r+" : "w+");
    try {
      const prev = fstatSync(fd).size;
      const buf = padContent(lua, padBytes, prev);
      let off = 0;
      while (off < buf.length) off += writeSync(fd, buf, off, buf.length - off, off);
      return { bytes: buf.length, contentBytes: Buffer.byteLength(lua, "utf8") };
    } finally { closeSync(fd); }
  }, `write ${file}`);
}

/** Rename-based atomic replace. */
export function writeRename(file: string, lua: string, padBytes: number, allowCreate = false): { bytes: number; contentBytes: number } {
  if (!existsSync(file) && !allowCreate) throw new MissingLiveFileError(file);
  const tmp = file + ".t3b-tmp";
  const buf = padContent(lua, padBytes, 0);
  const fd = openSync(tmp, "w");
  try { let off = 0; while (off < buf.length) off += writeSync(fd, buf, off, buf.length - off, off); } finally { closeSync(fd); }
  try { withRetry(() => renameSync(tmp, file), `rename ${tmp}`); }
  catch (e) { try { unlinkSync(tmp); } catch { /* ignore */ } throw e; }
  return { bytes: buf.length, contentBytes: Buffer.byteLength(lua, "utf8") };
}

export class LiveWriter {
  private seq: number;
  private lastWriteAt = 0;
  private lastSecondaryAt = 0;
  private debounceTimer?: NodeJS.Timeout;
  private heartbeatTimer?: NodeJS.Timeout;
  private dirtySince = 0;
  private stopped = true;
  lastError: Error | null = null;
  writes = 0;

  constructor(private readonly o: LiveWriterOptions) {
    this.seq = o.startSeq ?? 0;
  }

  private now(): number { return this.o.now ? this.o.now() : Date.now(); }

  get currentSeq(): number { return this.seq; }

  start(): void {
    this.stopped = false;
    this.writeNow("start");
    this.heartbeatTimer = setInterval(() => {
      if (this.now() - this.lastWriteAt >= this.o.heartbeatMs - 50) this.writeNow("heartbeat");
    }, Math.max(250, Math.min(1000, this.o.heartbeatMs / 4)));
  }

  stop(): void {
    this.stopped = true;
    if (this.debounceTimer) clearTimeout(this.debounceTimer);
    if (this.heartbeatTimer) clearInterval(this.heartbeatTimer);
    this.debounceTimer = this.heartbeatTimer = undefined;
  }

  /** State changed: write after the debounce, but no more often than minIntervalMs. */
  markDirty(): void {
    if (this.stopped) return;
    if (!this.dirtySince) this.dirtySince = this.now();
    if (this.debounceTimer) clearTimeout(this.debounceTimer);
    const sinceWrite = this.now() - this.lastWriteAt;
    // Debounce, but never delay a pending change by more than 4x the debounce (steady streaming).
    const waited = this.now() - this.dirtySince;
    let delay = Math.max(this.o.debounceMs - Math.min(waited, this.o.debounceMs), this.o.minIntervalMs - sinceWrite, 0);
    if (waited >= this.o.debounceMs * 4) delay = Math.max(0, this.o.minIntervalMs - sinceWrite);
    this.debounceTimer = setTimeout(() => { this.debounceTimer = undefined; this.writeNow("change"); }, delay);
  }

  /** Immediate write (used for acks, PROTOCOL 3.6 rule 3). */
  writeNow(reason = "now", forceSecondary = false): WriteInfo | null {
    if (forceSecondary) this.lastSecondaryAt = -Infinity;
    if (this.debounceTimer) { clearTimeout(this.debounceTimer); this.debounceTimer = undefined; }
    this.dirtySince = 0;
    const t0 = performance.now();
    const seq = this.seq + 1;
    const ts = Math.floor(this.now() / 1000);
    try {
      const lua = this.o.render(seq, ts);
      const fn = this.o.mode === "rename" ? writeRename : writeInPlace;
      const r = fn(this.o.file, lua, this.o.padBytes, this.o.allowCreate);
      this.seq = seq;
      this.lastWriteAt = this.now();
      this.writes++;
      this.lastError = null;
      const info: WriteInfo = { seq, bytes: r.bytes, contentBytes: r.contentBytes, ms: performance.now() - t0, reason, file: this.o.file };
      if (this.o.secondaryFile && this.now() - this.lastSecondaryAt >= (this.o.secondaryIntervalMs ?? 5000)) {
        this.lastSecondaryAt = this.now();
        try { if (existsSync(this.o.secondaryFile)) writeInPlace(this.o.secondaryFile, lua, this.o.padBytes, false); }
        catch (e) { log.debug(`Inbox.lua write skipped: ${(e as Error).message}`); }
      }
      this.o.onWrite?.(info);
      return info;
    } catch (e) {
      if (!this.lastError || this.lastError.message !== (e as Error).message) log.error(`live.lua write failed: ${(e as Error).message}`);
      this.lastError = e as Error;
      return null;
    }
  }
}

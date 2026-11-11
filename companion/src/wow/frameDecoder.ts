// Decodes the addon's outbound pixel matrix (PROTOCOL.md 3.3/3.6) from a luminance bitmap.
//
// 1. Sync search: scan rows of the top-left search window for 255 alternating runs (cells 0..254 of
//    the `1010...` sync row) with consistent length -> x0, y0, horizontal pitch p (sub-pixel, averaged).
// 2. Threshold: midpoint of the sync row's white and black cell luma (handles gamma/HDR/dim captures).
// 3. Read row 1 (header), derive the frame length, sample only the rows needed, verify CRC-32.
//    If the CRC fails, retry a few vertical pitch/phase candidates (CRC makes trying safe).
// 4. Reassembler: dedupe on (sid, seq, part), join parts, emit each (sid, seq) once, expire partials.
import { OVERHEAD, ROW_BYTES, WIDTH_CELLS, parseFrame, peekHeader, type Frame } from "./frameCodec.js";

export interface LumaImage {
  width: number;
  height: number;
  /** One byte per pixel, row-major. */
  data: Uint8Array;
  /** Bytes per row (default width). */
  stride?: number;
}

export interface DecodeOptions {
  /** Max x of the first sync cell (search window). Default 96. */
  maxX?: number;
  /** Max y of the sync row. Default 200. */
  maxY?: number;
  /** Binarization threshold for the sync search (0..255). Default 128. */
  syncThreshold?: number;
  minPitch?: number;
  maxPitch?: number;
}

export interface Geometry { x0: number; y0: number; pitchX: number; pitchY: number; bandH: number; threshold: number; contrast: number }

export type DecodeResult =
  | { ok: true; frame: Frame; geom: Geometry; attempts: number }
  | { ok: false; reason: "no-sync" | "low-contrast" | "bad-header" | "crc" | "out-of-bounds"; geom?: Geometry; attempts: number };

interface RowSync { x0: number; pitch: number; end: number }

/** BGRA/BGRX (as delivered by Windows capture) -> luma (Rec.709 weights). */
export function bgraToLuma(bgra: Uint8Array, width: number, height: number, stride = width * 4): LumaImage {
  const out = new Uint8Array(width * height);
  for (let y = 0; y < height; y++) {
    let s = y * stride, d = y * width;
    for (let x = 0; x < width; x++, s += 4, d++) out[d] = (bgra[s] * 19 + bgra[s + 1] * 183 + bgra[s + 2] * 54) >> 8;
  }
  return { width, height, data: out };
}

/**
 * All sync-pattern candidates on one row. Run j = white cell 0 (may merge with a light pixel to its
 * left, so its length is only checked from below), runs j+1..j+254 = cells 1..254. The background next
 * to the matrix can mimic the pattern, giving extra candidates shifted by an even number of cells; the
 * CRC check in decodeImage picks the right one.
 */
function syncCandidatesOnRow(img: LumaImage, y: number, maxX: number, thr: number, minP: number, maxP: number, limit = 6): RowSync[] {
  const stride = img.stride ?? img.width;
  const row = y * stride;
  const W = img.width;
  const starts: number[] = [];
  const colors: number[] = [];
  let prev = -1;
  for (let x = 0; x < W; x++) {
    const c = img.data[row + x] >= thr ? 1 : 0;
    if (c !== prev) { starts.push(x); colors.push(c); prev = c; }
  }
  starts.push(W);
  const nRuns = colors.length;
  const out: RowSync[] = [];
  for (let j = 0; j + 255 <= nRuns && starts[j] <= maxX + maxP; j++) {
    if (colors[j] !== 1) continue;
    const p0 = (starts[j + 255] - starts[j + 1]) / 254;
    if (p0 < minP || p0 > maxP) continue;
    // Nearest-neighbour scaling gives runs of floor(p) or ceil(p) px; blur shifts edges by < p/2.
    const lo = Math.min(p0 * 0.5, Math.floor(p0)), hi = Math.max(p0 * 1.5, Math.ceil(p0)) + 0.01;
    if (starts[j + 1] - starts[j] < lo) continue;
    let ok = true;
    for (let k = 1; k < 255; k++) {
      const len = starts[j + k + 1] - starts[j + k];
      if (len < lo || len > hi) { ok = false; break; }
    }
    if (!ok) continue;
    if (j + 255 < nRuns && starts[j + 256] - starts[j + 255] < lo) continue;
    // Least-squares fit of the cell boundaries b_k = x0 + k*p (k = 1..255): sub-pixel pitch and phase.
    let sk = 0, sb = 0, skk = 0, skb = 0;
    for (let k = 1; k <= 255; k++) { const b = starts[j + k]; sk += k; sb += b; skk += k * k; skb += k * b; }
    const n = 255;
    const p = (n * skb - sk * sb) / (n * skk - sk * sk);
    const x0 = (sb - p * sk) / n;
    if (x0 > maxX || x0 < starts[j] - 1) continue;
    out.push({ x0: Math.max(0, x0), pitch: p, end: starts[j + 255] });
    if (out.length >= limit) break;
  }
  return out;
}

function sampleAt(img: LumaImage, xc: number, yc: number, rad: number): number {
  const stride = img.stride ?? img.width;
  const cx = Math.floor(xc), cy = Math.floor(yc);
  if (rad <= 0) {
    if (cx < 0 || cy < 0 || cx >= img.width || cy >= img.height) return -1;
    return img.data[cy * stride + cx];
  }
  let sum = 0, n = 0;
  for (let y = cy - rad; y <= cy + rad; y++) {
    if (y < 0 || y >= img.height) continue;
    for (let x = cx - rad; x <= cx + rad; x++) {
      if (x < 0 || x >= img.width) continue;
      sum += img.data[y * stride + x]; n++;
    }
  }
  return n ? sum / n : -1;
}

type SyncGeom = Omit<Geometry, "threshold" | "contrast">;

/** Sync band candidates (top-most rows first). Geometry is not verified against data. */
export function findSyncCandidates(img: LumaImage, o: DecodeOptions = {}, max = 8): SyncGeom[] {
  const maxY = Math.min(o.maxY ?? 200, img.height - 1);
  const maxX = o.maxX ?? 96;
  const thr = o.syncThreshold ?? 128;
  const minP = o.minPitch ?? 0.75, maxP = o.maxPitch ?? 12;
  const out: SyncGeom[] = [];
  let firstY = -1;
  for (let y = 0; y <= maxY; y++) {
    if (firstY >= 0 && y > firstY + Math.ceil(maxP) * 2) break;
    for (const s of syncCandidatesOnRow(img, y, maxX, thr, minP, maxP)) {
      // Skip if this is the continuation of a band already found.
      if (out.some((g) => Math.abs(g.x0 - s.x0) <= 1.5 && y > g.y0 && y < g.y0 + g.bandH + 1)) continue;
      if (firstY < 0) firstY = y;
      let bandH = 1;
      let pitchSum = s.pitch;
      while (y + bandH < img.height) {
        const t = syncCandidatesOnRow(img, y + bandH, Math.min(img.width - 1, Math.ceil(s.x0) + 2), thr, minP, maxP)
          .find((c) => Math.abs(c.x0 - s.x0) <= 1.5 && Math.abs(c.pitch - s.pitch) <= s.pitch * 0.1);
        if (!t) break;
        pitchSum += t.pitch; bandH++;
      }
      const pitchX = pitchSum / bandH;
      const pitchY = Math.abs(bandH - pitchX) <= 1 || bandH < pitchX ? pitchX : bandH;
      out.push({ x0: s.x0, y0: y, pitchX, pitchY, bandH });
      if (out.length >= max) return out;
    }
  }
  // Prefer taller bands (the real sync row is one cell tall; background look-alikes rarely are).
  return out.sort((a, b) => Math.min(b.bandH, b.pitchX + 1) - Math.min(a.bandH, a.pitchX + 1) || a.y0 - b.y0 || b.x0 - a.x0);
}

/** Best sync band guess (for diagnostics). */
export function findSync(img: LumaImage, o: DecodeOptions = {}): SyncGeom | null {
  return findSyncCandidates(img, o, 1)[0] ?? null;
}

function readBytes(img: LumaImage, g: Geometry, firstRow: number, nRows: number, dx: number, dy: number): Uint8Array | null {
  const out = new Uint8Array(nRows * ROW_BYTES);
  const rad = g.pitchX >= 4 ? Math.floor(g.pitchX / 4) : 0;
  for (let r = 0; r < nRows; r++) {
    const yc = g.y0 + (firstRow + r + 0.5) * g.pitchY + dy;
    if (yc >= img.height) return null;
    for (let b = 0; b < ROW_BYTES; b++) {
      let v = 0;
      for (let bit = 0; bit < 8; bit++) {
        const cell = b * 8 + bit;
        const s = sampleAt(img, g.x0 + (cell + 0.5) * g.pitchX + dx, yc, rad);
        if (s < 0) return null;
        v = (v << 1) | (s >= g.threshold ? 1 : 0);
      }
      out[r * ROW_BYTES + b] = v;
    }
  }
  return out;
}

function threshold(img: LumaImage, s: SyncGeom): { w: number; b: number } {
  const yc = s.y0 + Math.min(s.bandH, s.pitchY) / 2;
  let w = 0, b = 0;
  const rad = s.pitchX >= 4 ? Math.floor(s.pitchX / 4) : 0;
  for (let x = 0; x < WIDTH_CELLS; x++) {
    const v = sampleAt(img, s.x0 + (x + 0.5) * s.pitchX, yc, rad);
    if (x % 2 === 0) w += v; else b += v;
  }
  return { w: w / (WIDTH_CELLS / 2), b: b / (WIDTH_CELLS / 2) };
}

/** Full decode of one image: tries every sync candidate and a few sub-cell phases; CRC decides. */
export function decodeImage(img: LumaImage, o: DecodeOptions = {}): DecodeResult {
  const cands = findSyncCandidates(img, o);
  if (!cands.length) return { ok: false, reason: "no-sync", attempts: 0 };
  let attempts = 0;
  let lastReason: "bad-header" | "crc" | "out-of-bounds" | "low-contrast" = "bad-header";
  let lastGeom: Geometry | undefined;
  for (const s of cands) {
    const { w, b } = threshold(img, s);
    const geom: Geometry = { ...s, threshold: (w + b) / 2, contrast: w - b };
    lastGeom = geom;
    if (w - b < 40) { lastReason = "low-contrast"; continue; }
    const pitchCands = [...new Set([s.pitchY, s.pitchX, Math.round(s.pitchX)].filter((p) => p >= 0.75).map((p) => +p.toFixed(4)))];
    const offs = [0, -0.3, 0.3];
    for (const pitchY of pitchCands) {
      for (const fy of offs) {
        for (const fx of offs) {
          attempts++;
          const g = { ...geom, pitchY };
          const dy = fy * pitchY, dx = fx * s.pitchX;
          const row1 = readBytes(img, g, 1, 1, dx, dy);
          if (!row1) { lastReason = "out-of-bounds"; continue; }
          const h = peekHeader(row1);
          if (!h) { lastReason = "bad-header"; continue; }
          const nBytes = OVERHEAD + h.len;
          const nRows = Math.ceil(nBytes / ROW_BYTES);
          if (nRows > 31) { lastReason = "bad-header"; continue; }
          const all = nRows === 1 ? row1 : readBytes(img, g, 1, nRows, dx, dy);
          if (!all) { lastReason = "out-of-bounds"; continue; }
          const r = parseFrame(all.subarray(0, nBytes));
          if (r.ok) return { ok: true, frame: r.frame, geom: { ...g, x0: g.x0 + dx, y0: g.y0 + dy }, attempts };
          lastReason = r.reason === "crc" ? "crc" : "bad-header";
        }
      }
    }
  }
  return { ok: false, reason: lastReason, geom: lastGeom, attempts };
}

// ---------------------------------------------------------------------------------------------
// Reassembly + dedupe (3.6)
// ---------------------------------------------------------------------------------------------

export interface CompletedMessage { sidHex: string; seq: number; payload: Buffer; parts: number; retransmit: boolean }

export type PushResult =
  | { kind: "complete"; msg: CompletedMessage }
  | { kind: "duplicate"; sidHex: string; seq: number } // already executed; refresh the ack only
  | { kind: "partial"; sidHex: string; seq: number; have: number; parts: number }
  | { kind: "repeat" }; // same part seen before

interface Partial { parts: Buffer[]; count: number; total: number; firstAt: number }

export class Reassembler {
  private partials = new Map<string, Partial>();
  private done = new Map<string, number>(); // key -> time
  private currentSid: string | null = null;
  constructor(private readonly opts: { partialTtlMs?: number; doneMax?: number } = {}) {}

  get sid(): string | null { return this.currentSid; }

  push(f: Frame, now = Date.now()): PushResult {
    const sidHex = f.sid.toString("hex");
    if (this.currentSid !== sidHex) {
      // A new addon session replaces the old one (rule 4).
      this.currentSid = sidHex;
      this.partials.clear();
    }
    const ttl = this.opts.partialTtlMs ?? 30_000;
    for (const [k, p] of this.partials) if (now - p.firstAt > ttl) this.partials.delete(k);
    const key = `${sidHex}:${f.seq}`;
    if (this.done.has(key)) return { kind: "duplicate", sidHex, seq: f.seq };
    let p = this.partials.get(key);
    if (!p || p.total !== f.parts) { p = { parts: new Array(f.parts), count: 0, total: f.parts, firstAt: now }; this.partials.set(key, p); }
    if (p.parts[f.part - 1]) return { kind: "repeat" };
    p.parts[f.part - 1] = f.payload;
    p.count++;
    if (p.count < p.total) return { kind: "partial", sidHex, seq: f.seq, have: p.count, parts: p.total };
    this.partials.delete(key);
    this.done.set(key, now);
    const max = this.opts.doneMax ?? 4096;
    if (this.done.size > max) { const first = this.done.keys().next().value; if (first) this.done.delete(first); }
    return { kind: "complete", msg: { sidHex, seq: f.seq, payload: Buffer.concat(p.parts), parts: p.total, retransmit: (f.flags & 1) === 1 } };
  }
}

/** Strict UTF-8 decode (parts may split a character; they are joined before decoding). */
export function decodeUtf8(b: Buffer): string {
  return new TextDecoder("utf-8", { fatal: false }).decode(b);
}

// Reference encoder + synthetic renderer for the outbound matrix. Used by tests, --selftest and the
// synthetic capture window (capture-helper/T3TestWindow reads frames produced here). It is an
// independent implementation of PROTOCOL.md section 3 so the addon's Lua Codec can be cross-checked
// against the same vectors (companion/test/vectors/*.json).
import { cellStrings, crc32, framesForMessage, WIDTH_CELLS } from "../wow/frameCodec.js";
import type { LumaImage } from "../wow/frameDecoder.js";

export interface EncodedMessage { rows: number; frames: Buffer[] }

export function encodeMessage(sid: Uint8Array, seq: number, message: string | Uint8Array, flags = 0): EncodedMessage {
  const bytes = typeof message === "string" ? Buffer.from(message, "utf8") : message;
  return framesForMessage(sid, seq, bytes, flags);
}

/** Deterministic PRNG (mulberry32). */
export function rng(seed: number): () => number {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

export type Background = "black" | "white" | "noise" | "gradient" | "game";

export interface RenderOptions {
  cell: number;
  /** Canvas size (defaults: matrix + offsets + 40 px margin). */
  width?: number;
  height?: number;
  offsetX?: number;
  offsetY?: number;
  background?: Background;
  seed?: number;
  white?: number;
  black?: number;
}

export function renderMatrix(frame: Uint8Array, rows: number, o: RenderOptions): LumaImage {
  const c = o.cell;
  const ox = o.offsetX ?? 0, oy = o.offsetY ?? 0;
  const W = o.width ?? ox + WIDTH_CELLS * c + 40;
  const H = o.height ?? oy + rows * c + 40;
  const data = new Uint8Array(W * H);
  const r = rng(o.seed ?? 1);
  const bg = o.background ?? "game";
  for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) {
    let v = 0;
    switch (bg) {
      case "black": v = 0; break;
      case "white": v = 255; break;
      case "noise": v = Math.floor(r() * 256); break;
      case "gradient": v = Math.floor((x / W) * 255); break;
      case "game": v = Math.floor(90 + 70 * Math.sin(x / 13) * Math.cos(y / 9) + r() * 60); break;
    }
    data[y * W + x] = Math.max(0, Math.min(255, v));
  }
  const cells = cellStrings(frame, rows);
  const wv = o.white ?? 255, bv = o.black ?? 0;
  for (let row = 0; row < rows; row++) {
    const s = cells[row];
    for (let cx = 0; cx < WIDTH_CELLS; cx++) {
      const v = s.charCodeAt(cx) === 49 ? wv : bv;
      for (let dy = 0; dy < c; dy++) {
        const y = oy + row * c + dy;
        if (y < 0 || y >= H) continue;
        for (let dx = 0; dx < c; dx++) {
          const x = ox + cx * c + dx;
          if (x >= 0 && x < W) data[y * W + x] = v;
        }
      }
    }
  }
  return { width: W, height: H, data };
}

/** Simulates display scaling of an already-rendered image. */
export function scaleImage(img: LumaImage, s: number, mode: "nearest" | "bilinear"): LumaImage {
  const W = Math.max(1, Math.round(img.width * s)), H = Math.max(1, Math.round(img.height * s));
  const out = new Uint8Array(W * H);
  for (let y = 0; y < H; y++) {
    const sy = (y + 0.5) / s - 0.5;
    for (let x = 0; x < W; x++) {
      const sx = (x + 0.5) / s - 0.5;
      if (mode === "nearest") {
        const nx = Math.min(img.width - 1, Math.max(0, Math.floor((x + 0.5) / s)));
        const ny = Math.min(img.height - 1, Math.max(0, Math.floor((y + 0.5) / s)));
        out[y * W + x] = img.data[ny * img.width + nx];
      } else {
        const x0 = Math.max(0, Math.min(img.width - 1, Math.floor(sx))), y0 = Math.max(0, Math.min(img.height - 1, Math.floor(sy)));
        const x1 = Math.min(img.width - 1, x0 + 1), y1 = Math.min(img.height - 1, y0 + 1);
        const fx = Math.max(0, Math.min(1, sx - x0)), fy = Math.max(0, Math.min(1, sy - y0));
        const a = img.data[y0 * img.width + x0], b = img.data[y0 * img.width + x1];
        const c = img.data[y1 * img.width + x0], d = img.data[y1 * img.width + x1];
        out[y * W + x] = Math.round(a * (1 - fx) * (1 - fy) + b * fx * (1 - fy) + c * (1 - fx) * fy + d * fx * fy);
      }
    }
  }
  return { width: W, height: H, data: out };
}

export function addNoise(img: LumaImage, amplitude: number, seed = 7): LumaImage {
  const r = rng(seed);
  const out = new Uint8Array(img.data.length);
  for (let k = 0; k < out.length; k++) out[k] = Math.max(0, Math.min(255, Math.round(img.data[k] + (r() * 2 - 1) * amplitude)));
  return { ...img, data: out };
}

export function boxBlur(img: LumaImage, radius: number): LumaImage {
  if (radius <= 0) return img;
  const { width: W, height: H } = img;
  const tmp = new Float32Array(W * H), out = new Uint8Array(W * H);
  for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) {
    let s = 0, n = 0;
    for (let k = -radius; k <= radius; k++) { const xx = x + k; if (xx >= 0 && xx < W) { s += img.data[y * W + xx]; n++; } }
    tmp[y * W + x] = s / n;
  }
  for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) {
    let s = 0, n = 0;
    for (let k = -radius; k <= radius; k++) { const yy = y + k; if (yy >= 0 && yy < H) { s += tmp[yy * W + x]; n++; } }
    out[y * W + x] = Math.round(s / n);
  }
  return { width: W, height: H, data: out };
}

/** Maps luma through a tone curve (e.g. HDR/night-light/gamma captures). */
export function toneMap(img: LumaImage, lo: number, hi: number, gamma = 1): LumaImage {
  const out = new Uint8Array(img.data.length);
  for (let k = 0; k < out.length; k++) out[k] = Math.round(lo + (hi - lo) * Math.pow(img.data[k] / 255, gamma));
  return { ...img, data: out };
}

/** Test-vector record (also consumed by the synthetic window and by the addon's Lua cross-check). */
export interface VectorFrame { part: number; parts: number; rows: number; hex: string; crc32: string; cells: string[] }
export interface Vector { name: string; sidHex: string; seq: number; flags: number; messageUtf8: string; messageHex: string; frames: VectorFrame[] }

export function makeVector(name: string, sidHex: string, seq: number, message: string, flags = 0): Vector {
  const sid = Buffer.from(sidHex, "hex");
  const enc = encodeMessage(sid, seq, message, flags);
  return {
    name, sidHex, seq, flags,
    messageUtf8: message,
    messageHex: Buffer.from(message, "utf8").toString("hex"),
    frames: enc.frames.map((f, k) => ({
      part: k + 1,
      parts: enc.frames.length,
      rows: enc.rows,
      hex: f.toString("hex"),
      crc32: f.readUInt32BE(f.length - 4).toString(16).padStart(8, "0"),
      cells: cellStrings(f, enc.rows),
    })),
  };
}

export const CRC_CHECK = crc32(Buffer.from("123456789")) === 0xcbf43926;

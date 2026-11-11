// Minimal image decoders for the SECONDARY screenshot fallback: PNG (8-bit gray/RGB/RGBA, non-interlaced),
// TGA (24/32-bit, raw or RLE) and BMP (24/32-bit BI_RGB). Output: luma of the top-left region only.
// JPEG is not supported on purpose: its compression destroys 1-2 px cells (set WoW's screenshotFormat to png or tga).
import { inflateSync } from "node:zlib";
import type { LumaImage } from "./frameDecoder.js";

const luma = (r: number, g: number, b: number) => (r * 54 + g * 183 + b * 19) >> 8;

export function decodePngRegion(buf: Buffer, maxW: number, maxH: number): LumaImage {
  if (buf.readUInt32BE(0) !== 0x89504e47 || buf.readUInt32BE(4) !== 0x0d0a1a0a) throw new Error("not a PNG");
  let pos = 8;
  let width = 0, height = 0, depth = 0, ctype = 0, interlace = 0;
  const idat: Buffer[] = [];
  while (pos + 8 <= buf.length) {
    const len = buf.readUInt32BE(pos);
    const type = buf.toString("latin1", pos + 4, pos + 8);
    const data = buf.subarray(pos + 8, pos + 8 + len);
    if (type === "IHDR") { width = data.readUInt32BE(0); height = data.readUInt32BE(4); depth = data[8]; ctype = data[9]; interlace = data[12]; }
    else if (type === "IDAT") idat.push(data);
    else if (type === "IEND") break;
    pos += 12 + len;
  }
  if (depth !== 8 || interlace !== 0) throw new Error(`unsupported PNG (depth ${depth}, interlace ${interlace})`);
  const bpp = ({ 0: 1, 2: 3, 4: 2, 6: 4 } as Record<number, number>)[ctype];
  if (!bpp) throw new Error(`unsupported PNG color type ${ctype}`);
  const raw = inflateSync(Buffer.concat(idat));
  const stride = width * bpp;
  const W = Math.min(width, maxW), H = Math.min(height, maxH);
  const out = new Uint8Array(W * H);
  let prev = new Uint8Array(stride), cur = new Uint8Array(stride);
  for (let y = 0; y < H; y++) {
    const off = y * (stride + 1);
    const ft = raw[off];
    for (let x = 0; x < stride; x++) {
      const v = raw[off + 1 + x];
      const a = x >= bpp ? cur[x - bpp] : 0, b = prev[x], c = x >= bpp ? prev[x - bpp] : 0;
      let r: number;
      switch (ft) {
        case 0: r = v; break;
        case 1: r = v + a; break;
        case 2: r = v + b; break;
        case 3: r = v + ((a + b) >> 1); break;
        case 4: { const p = a + b - c, pa = Math.abs(p - a), pb = Math.abs(p - b), pc = Math.abs(p - c); r = v + (pa <= pb && pa <= pc ? a : pb <= pc ? b : c); break; }
        default: throw new Error(`bad PNG filter ${ft}`);
      }
      cur[x] = r & 0xff;
    }
    for (let x = 0; x < W; x++) {
      const p = x * bpp;
      out[y * W + x] = bpp >= 3 ? luma(cur[p], cur[p + 1], cur[p + 2]) : cur[p];
    }
    [prev, cur] = [cur, prev];
  }
  return { width: W, height: H, data: out };
}

export function decodeTgaRegion(buf: Buffer, maxW: number, maxH: number): LumaImage {
  const idLen = buf[0], cmapType = buf[1], type = buf[2];
  const width = buf.readUInt16LE(12), height = buf.readUInt16LE(14), bits = buf[16], desc = buf[17];
  if (cmapType !== 0 || (type !== 2 && type !== 10) || (bits !== 24 && bits !== 32)) throw new Error("unsupported TGA");
  const bpp = bits / 8;
  const topDown = (desc & 0x20) !== 0;
  let pos = 18 + idLen;
  const pixels = Buffer.alloc(width * height * bpp);
  if (type === 2) buf.copy(pixels, 0, pos, pos + pixels.length);
  else {
    let o = 0;
    while (o < pixels.length && pos < buf.length) {
      const h = buf[pos++];
      const n = (h & 0x7f) + 1;
      if (h & 0x80) { for (let k = 0; k < n; k++) { buf.copy(pixels, o, pos, pos + bpp); o += bpp; } pos += bpp; }
      else { buf.copy(pixels, o, pos, pos + n * bpp); o += n * bpp; pos += n * bpp; }
    }
  }
  const W = Math.min(width, maxW), H = Math.min(height, maxH);
  const out = new Uint8Array(W * H);
  for (let y = 0; y < H; y++) {
    const sy = topDown ? y : height - 1 - y;
    for (let x = 0; x < W; x++) { const p = (sy * width + x) * bpp; out[y * W + x] = luma(pixels[p + 2], pixels[p + 1], pixels[p]); }
  }
  return { width: W, height: H, data: out };
}

export function decodeBmpRegion(buf: Buffer, maxW: number, maxH: number): LumaImage {
  if (buf.toString("latin1", 0, 2) !== "BM") throw new Error("not a BMP");
  const dataOff = buf.readUInt32LE(10), width = buf.readInt32LE(18), hRaw = buf.readInt32LE(22), bits = buf.readUInt16LE(28), comp = buf.readUInt32LE(30);
  if ((bits !== 24 && bits !== 32) || (comp !== 0 && comp !== 3)) throw new Error("unsupported BMP");
  const height = Math.abs(hRaw), topDown = hRaw < 0, bpp = bits / 8;
  const stride = Math.ceil((width * bpp) / 4) * 4;
  const W = Math.min(width, maxW), H = Math.min(height, maxH);
  const out = new Uint8Array(W * H);
  for (let y = 0; y < H; y++) {
    const sy = topDown ? y : height - 1 - y;
    for (let x = 0; x < W; x++) { const p = dataOff + sy * stride + x * bpp; out[y * W + x] = luma(buf[p + 2], buf[p + 1], buf[p]); }
  }
  return { width: W, height: H, data: out };
}

export function decodeImageFileRegion(name: string, buf: Buffer, maxW: number, maxH: number): LumaImage {
  const ext = name.toLowerCase().split(".").pop();
  if (ext === "png") return decodePngRegion(buf, maxW, maxH);
  if (ext === "tga") return decodeTgaRegion(buf, maxW, maxH);
  if (ext === "bmp") return decodeBmpRegion(buf, maxW, maxH);
  throw new Error(`unsupported screenshot format .${ext} (set WoW's screenshotFormat CVar to png or tga)`);
}

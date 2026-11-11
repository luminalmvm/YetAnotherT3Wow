// Pure-TypeScript image helpers for the image pipeline: size fitting, an area-average resize, a full
// RGBA TGA decoder (WoW screenshots can be TGA, which Windows Imaging Component cannot read) and a minimal
// PNG encoder (to upload a TGA screenshot to T3, which accepts PNG/JPEG/GIF/WebP only).
import { deflateSync, crc32 } from "node:zlib";

export interface Rgba { data: Uint8Array; w: number; h: number }

/**
 * Fit (w, h) inside max x max keeping the aspect ratio; never upscales; both sides >= 1.
 * Same rule as the helper's Tools.Fit (capture-helper/T3Capture/Tools.cs): round half away from zero.
 */
export function fitSize(w: number, h: number, max: number): { w: number; h: number } {
  if (!(w > 0 && h > 0)) throw new Error("bad image size");
  const s = Math.min(1, max / w, max / h);
  const clamp = (v: number) => Math.min(max, Math.max(1, Math.round(v)));
  return { w: clamp(w * s), h: clamp(h * s) };
}

/** Display size of an inline image: at most maxW x maxH, keeping the aspect ratio, never upscaled. */
export function displaySize(w: number, h: number, maxW: number, maxH: number): { w: number; h: number } {
  const s = Math.min(1, maxW / w, maxH / h);
  return { w: Math.max(1, Math.round(w * s)), h: Math.max(1, Math.round(h * s)) };
}

/** Area-average (box) downscale of straight-alpha RGBA; colour is alpha-weighted so transparent pixels do not bleed. */
export function resizeRgba(src: Rgba, tw: number, th: number): Rgba {
  if (tw === src.w && th === src.h) return { data: new Uint8Array(src.data), w: tw, h: th };
  const out = new Uint8Array(tw * th * 4);
  const sx = src.w / tw, sy = src.h / th;
  for (let ty = 0; ty < th; ty++) {
    const y0 = ty * sy, y1 = y0 + sy;
    for (let tx = 0; tx < tw; tx++) {
      const x0 = tx * sx, x1 = x0 + sx;
      let r = 0, g = 0, b = 0, a = 0, area = 0;
      for (let y = Math.floor(y0); y < Math.ceil(y1); y++) {
        const wy = Math.min(y + 1, y1) - Math.max(y, y0);
        if (wy <= 0 || y >= src.h) continue;
        for (let x = Math.floor(x0); x < Math.ceil(x1); x++) {
          const wx = Math.min(x + 1, x1) - Math.max(x, x0);
          if (wx <= 0 || x >= src.w) continue;
          const wgt = wx * wy;
          const i = (y * src.w + x) * 4;
          const al = src.data[i + 3];
          r += src.data[i] * al * wgt; g += src.data[i + 1] * al * wgt; b += src.data[i + 2] * al * wgt;
          a += al * wgt; area += wgt;
        }
      }
      const o = (ty * tw + tx) * 4;
      if (a > 0) { out[o] = Math.round(r / a); out[o + 1] = Math.round(g / a); out[o + 2] = Math.round(b / a); }
      out[o + 3] = area > 0 ? Math.round(a / area) : 0;
    }
  }
  return { data: out, w: tw, h: th };
}

/** Decodes a TGA (types 2/10 true colour 24/32 bpp, 3/11 grey 8 bpp; either origin) to RGBA, top row first. */
export function decodeTga(buf: Uint8Array): Rgba {
  if (buf.length < 18) throw new Error("not a TGA");
  const idLen = buf[0], cmapType = buf[1], type = buf[2];
  const cmapLen = buf[5] | (buf[6] << 8), cmapDepth = buf[7];
  const w = buf[12] | (buf[13] << 8), h = buf[14] | (buf[15] << 8);
  const bpp = buf[16], desc = buf[17];
  if (![2, 3, 10, 11].includes(type) || cmapType !== 0) throw new Error(`unsupported TGA type ${type}`);
  const grey = type === 3 || type === 11;
  if (grey ? bpp !== 8 : bpp !== 24 && bpp !== 32) throw new Error(`unsupported TGA depth ${bpp}`);
  if (!w || !h) throw new Error("empty TGA");
  const px = bpp / 8;
  let pos = 18 + idLen + cmapLen * Math.ceil(cmapDepth / 8);
  const raw = new Uint8Array(w * h * px);
  if (type === 10 || type === 11) {
    let o = 0;
    while (o < raw.length) {
      if (pos >= buf.length) throw new Error("truncated TGA");
      const c = buf[pos++];
      const n = (c & 0x7f) + 1;
      if (c & 0x80) {
        for (let k = 0; k < n && o < raw.length; k++) for (let j = 0; j < px; j++) raw[o++] = buf[pos + j];
        pos += px;
      } else {
        const len = n * px;
        raw.set(buf.subarray(pos, pos + len).subarray(0, raw.length - o), o);
        o += len; pos += len;
      }
    }
  } else {
    if (pos + raw.length > buf.length) throw new Error("truncated TGA");
    raw.set(buf.subarray(pos, pos + raw.length));
  }
  const topDown = (desc & 0x20) !== 0;
  const out = new Uint8Array(w * h * 4);
  for (let y = 0; y < h; y++) {
    const sy = topDown ? y : h - 1 - y;
    for (let x = 0; x < w; x++) {
      const i = (sy * w + x) * px, o = (y * w + x) * 4;
      if (grey) { out[o] = out[o + 1] = out[o + 2] = raw[i]; out[o + 3] = 255; }
      else { out[o] = raw[i + 2]; out[o + 1] = raw[i + 1]; out[o + 2] = raw[i]; out[o + 3] = px === 4 ? raw[i + 3] : 255; }
    }
  }
  // Many writers leave the alpha byte at 0 in 32-bit files that are meant to be opaque.
  if (px === 4) {
    let any = false;
    for (let k = 3; k < out.length; k += 4) if (out[k] !== 0) { any = true; break; }
    if (!any) for (let k = 3; k < out.length; k += 4) out[k] = 255;
  }
  return { data: out, w, h };
}

/** Minimal PNG encoder (8-bit RGBA, filter 0). */
export function encodePng(img: Rgba): Buffer {
  const { w, h, data } = img;
  const raw = Buffer.alloc((w * 4 + 1) * h);
  for (let y = 0; y < h; y++) {
    raw[y * (w * 4 + 1)] = 0;
    raw.set(data.subarray(y * w * 4, (y + 1) * w * 4), y * (w * 4 + 1) + 1);
  }
  const chunk = (type: string, d: Buffer) => {
    const len = Buffer.alloc(4); len.writeUInt32BE(d.length);
    const td = Buffer.concat([Buffer.from(type, "latin1"), d]);
    const c = Buffer.alloc(4); c.writeUInt32BE(crc32(td) >>> 0);
    return Buffer.concat([len, td, c]);
  };
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4); ihdr[8] = 8; ihdr[9] = 6;
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk("IHDR", ihdr), chunk("IDAT", deflateSync(raw)), chunk("IEND", Buffer.alloc(0))]);
}

/** Image type from the first bytes (null if unknown). */
export function sniffMime(b: Uint8Array): string | null {
  if (b.length >= 8 && b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4e && b[3] === 0x47) return "image/png";
  if (b.length >= 3 && b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff) return "image/jpeg";
  if (b.length >= 6 && b[0] === 0x47 && b[1] === 0x49 && b[2] === 0x46) return "image/gif";
  if (b.length >= 12 && b[0] === 0x52 && b[1] === 0x49 && b[2] === 0x46 && b[3] === 0x46 && b[8] === 0x57 && b[9] === 0x45 && b[10] === 0x42 && b[11] === 0x50) return "image/webp";
  if (b.length >= 2 && b[0] === 0x42 && b[1] === 0x4d) return "image/bmp";
  return null;
}

/** MIME types T3 accepts for image attachments (VERIFIED in the 0.1.8 bundle: PROVIDER_SEND_TURN_SUPPORTED_IMAGE_MIME_TYPES). */
export const T3_IMAGE_MIMES = new Set(["image/png", "image/jpeg", "image/gif", "image/webp"]);
/** T3's per-image limit (PROVIDER_SEND_TURN_MAX_IMAGE_BYTES, 10 MiB). */
export const T3_MAX_IMAGE_BYTES = 10 * 1024 * 1024;

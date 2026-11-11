// Image slot textures (PROTOCOL rev 1.3, D16): every slot file is a fixed 512x512, 32-bit uncompressed TGA
// with an 8-bit alpha channel and a bottom-left origin, exactly 18 + 512*512*4 = 1,048,594 bytes, with no
// ID field, colour map or footer (the same layout as the shipped icon.tga, which the client loads).
// An image is placed in the TOP-LEFT corner of the canvas; the rest stays fully transparent. The addon
// crops it with SetTexCoord(0, w/512, 0, h/512).

export const CANVAS = 512;
export const TGA_HEADER = 18;
export const SLOT_BYTES = TGA_HEADER + CANVAS * CANVAS * 4; // 1,048,594

/** 18-byte TGA header: type 2 (uncompressed true colour), 32 bpp, descriptor 0x08 (8 alpha bits, bottom-left origin). */
export function tgaHeader(w: number, h: number): Buffer {
  const b = Buffer.alloc(TGA_HEADER);
  b[2] = 2;
  b.writeUInt16LE(w, 12);
  b.writeUInt16LE(h, 14);
  b[16] = 32;
  b[17] = 0x08;
  return b;
}

/** A fully transparent slot (all pixel bytes 0). */
export function blankSlot(canvas = CANVAS): Buffer {
  const b = Buffer.alloc(TGA_HEADER + canvas * canvas * 4);
  tgaHeader(canvas, canvas).copy(b, 0);
  return b;
}

/**
 * The slot file for an RGBA image (straight alpha, top row first) of w x h <= canvas, placed at the
 * top-left. TGA stores rows bottom-up and pixels as BGRA, so image row y lands in file row canvas-1-y.
 */
export function slotTga(rgba: Uint8Array, w: number, h: number, canvas = CANVAS): Buffer {
  if (w < 1 || h < 1 || w > canvas || h > canvas) throw new Error(`image ${w}x${h} does not fit the ${canvas} canvas`);
  if (rgba.length !== w * h * 4) throw new Error(`expected ${w * h * 4} RGBA bytes, got ${rgba.length}`);
  const out = blankSlot(canvas);
  for (let y = 0; y < h; y++) {
    const fileRow = canvas - 1 - y;
    let o = TGA_HEADER + fileRow * canvas * 4;
    let i = y * w * 4;
    for (let x = 0; x < w; x++, i += 4, o += 4) {
      out[o] = rgba[i + 2];
      out[o + 1] = rgba[i + 1];
      out[o + 2] = rgba[i];
      out[o + 3] = rgba[i + 3];
    }
  }
  return out;
}

/** Reads back pixel (x, y) (top-left origin) of a slot file as [r, g, b, a] (tests and diagnostics). */
export function slotPixel(tga: Uint8Array, x: number, y: number, canvas = CANVAS): [number, number, number, number] {
  const o = TGA_HEADER + ((canvas - 1 - y) * canvas + x) * 4;
  return [tga[o + 2], tga[o + 1], tga[o], tga[o + 3]];
}

/** Texture coordinates the addon uses for an image of w x h in a slot. */
export function texCoords(w: number, h: number, canvas = CANVAS): [number, number, number, number] {
  return [0, w / canvas, 0, h / canvas];
}

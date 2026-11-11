// Screenshot fallback decoders (PNG/TGA/BMP) + watcher, with synthetic files in a temp dir.
import { mkdtempSync, writeFileSync, existsSync, readdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { deflateSync } from "node:zlib";
import { describe, expect, it } from "vitest";
import { decodeBmpRegion, decodePngRegion, decodeTgaRegion } from "../src/wow/imageDecode.js";
import { decodeImage } from "../src/wow/frameDecoder.js";
import { ScreenshotWatcher } from "../src/wow/screenshotWatcher.js";
import { encodeMessage, renderMatrix } from "../src/testing/frameEncoder.js";
import { crc32 } from "../src/wow/frameCodec.js";
import type { LumaImage } from "../src/wow/frameDecoder.js";

function png(img: LumaImage, filterCycle = true): Buffer {
  const rows: Buffer[] = [];
  let prev = Buffer.alloc(img.width * 3);
  for (let y = 0; y < img.height; y++) {
    const cur = Buffer.alloc(img.width * 3);
    for (let x = 0; x < img.width; x++) { const v = img.data[y * img.width + x]; cur[x * 3] = v; cur[x * 3 + 1] = v; cur[x * 3 + 2] = v; }
    const ft = filterCycle ? y % 3 : 0; // none / sub / up
    const line = Buffer.alloc(cur.length + 1);
    line[0] = ft;
    for (let k = 0; k < cur.length; k++) line[k + 1] = (cur[k] - (ft === 1 ? (k >= 3 ? cur[k - 3] : 0) : ft === 2 ? prev[k] : 0)) & 0xff;
    rows.push(line);
    prev = cur;
  }
  const chunk = (type: string, data: Buffer) => {
    const len = Buffer.alloc(4); len.writeUInt32BE(data.length);
    const td = Buffer.concat([Buffer.from(type, "latin1"), data]);
    const c = Buffer.alloc(4); c.writeUInt32BE(crc32(td));
    return Buffer.concat([len, td, c]);
  };
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(img.width, 0); ihdr.writeUInt32BE(img.height, 4); ihdr[8] = 8; ihdr[9] = 2;
  return Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), chunk("IHDR", ihdr), chunk("IDAT", deflateSync(Buffer.concat(rows))), chunk("IEND", Buffer.alloc(0))]);
}

function tga(img: LumaImage, rle: boolean): Buffer {
  const h = Buffer.alloc(18);
  h[2] = rle ? 10 : 2; h.writeUInt16LE(img.width, 12); h.writeUInt16LE(img.height, 14); h[16] = 24; h[17] = 0; // bottom-up
  const px: number[] = [];
  for (let y = img.height - 1; y >= 0; y--) for (let x = 0; x < img.width; x++) { const v = img.data[y * img.width + x]; px.push(v, v, v); }
  if (!rle) return Buffer.concat([h, Buffer.from(px)]);
  const out: number[] = [];
  for (let k = 0; k < px.length; k += 3) out.push(0, px[k], px[k + 1], px[k + 2]); // raw packets of 1
  return Buffer.concat([h, Buffer.from(out)]);
}

function bmp(img: LumaImage): Buffer {
  const stride = Math.ceil((img.width * 3) / 4) * 4;
  const b = Buffer.alloc(54 + stride * img.height);
  b.write("BM", 0, "latin1"); b.writeUInt32LE(54, 10); b.writeUInt32LE(40, 14); b.writeInt32LE(img.width, 18); b.writeInt32LE(img.height, 22); b.writeUInt16LE(24, 28);
  for (let y = 0; y < img.height; y++) for (let x = 0; x < img.width; x++) { const v = img.data[y * img.width + x]; const p = 54 + (img.height - 1 - y) * stride + x * 3; b[p] = b[p + 1] = b[p + 2] = v; }
  return b;
}

const enc = encodeMessage(Buffer.from("9f3a01c2", "hex"), 5, "intr\ta1b2c3d4");
const img = renderMatrix(enc.frames[0], enc.rows, { cell: 2, offsetX: 0, offsetY: 0, width: 700, height: 120, background: "game" });

describe("screenshot decoders", () => {
  it("PNG (filters none/sub/up) -> decodes the frame", () => {
    const r = decodeImage(decodePngRegion(png(img), 1100, 200));
    expect(r.ok && r.frame.seq).toBe(5);
  });
  it("TGA raw + RLE, bottom-up", () => {
    for (const rle of [false, true]) expect(decodeImage(decodeTgaRegion(tga(img, rle), 1100, 200)).ok).toBe(true);
  });
  it("BMP 24-bit bottom-up", () => {
    expect(decodeImage(decodeBmpRegion(bmp(img), 1100, 200)).ok).toBe(true);
  });
});

describe("ScreenshotWatcher (fallback)", () => {
  it("decodes NEW screenshots only and never deletes by default", async () => {
    const dir = mkdtempSync(join(tmpdir(), "t3b-ss-"));
    writeFileSync(join(dir, "WoWScrnShot_old.png"), png(img)); // pre-existing: ignored
    const got: number[] = [];
    const w = new ScreenshotWatcher({ dir, regionW: 1100, regionH: 200, deleteDecoded: false, onFrame: (f) => got.push(f.seq) });
    w.start();
    await new Promise((r) => setTimeout(r, 100));
    writeFileSync(join(dir, "WoWScrnShot_new.png"), png(img));
    for (let k = 0; k < 40 && !got.length; k++) await new Promise((r) => setTimeout(r, 100));
    w.stop();
    expect(got).toEqual([5]);
    expect(readdirSync(dir).sort()).toEqual(["WoWScrnShot_new.png", "WoWScrnShot_old.png"]);
    expect(existsSync(join(dir, "WoWScrnShot_new.png"))).toBe(true);
  });
});

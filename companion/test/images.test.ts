// Image support (PROTOCOL rev 1.3): TGA slot writer, sizing, slot pool, image manager, protocol, snapshot.
import { createHash } from "node:crypto";
import { mkdtempSync, readFileSync, rmSync, writeFileSync, existsSync, mkdirSync, utimesSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { inflateSync } from "node:zlib";
import { afterEach, describe, expect, it } from "vitest";
import { Bridge } from "../src/bridge.js";
import { decodeTga, displaySize, encodePng, fitSize, resizeRgba, sniffMime, type Rgba } from "../src/images/codecs.js";
import type { ImageTools } from "../src/images/helper.js";
import { clipName, ImageManager, looksLikeTga } from "../src/images/manager.js";
import { SlotPool, slotName } from "../src/images/slots.js";
import { blankSlot, CANVAS, SLOT_BYTES, slotPixel, slotTga, tgaHeader, texCoords } from "../src/images/tga.js";
import { imageAttachments, itemsToMessages } from "../src/t3/project.js";
import { FakeT3Client } from "../src/t3/fakeClient.js";
import { messageToSnap, DEFAULT_CAPS, serializeSnapshot } from "../src/model/snapshot.js";
import { framesForMessage, parseCommand, parseFrame, type Frame } from "../src/wow/frameCodec.js";
import { parseLuaChunk, toJs } from "./helpers/luaParse.js";

const tmps: string[] = [];
const tmp = () => { const d = mkdtempSync(join(tmpdir(), "t3b-img-")); tmps.push(d); return d; };
afterEach(() => { while (tmps.length) rmSync(tmps.pop()!, { recursive: true, force: true }); });

function solid(w: number, h: number, rgba: [number, number, number, number]): Rgba {
  const data = new Uint8Array(w * h * 4);
  for (let k = 0; k < w * h; k++) data.set(rgba, k * 4);
  return { data, w, h };
}

/** Decodes PNGs written by encodePng (8-bit RGBA, filter 0) - stands in for the helper in tests. */
function decodeOurPng(b: Buffer): Rgba {
  const w = b.readUInt32BE(16), h = b.readUInt32BE(20);
  let pos = 8; const idat: Buffer[] = [];
  while (pos < b.length) { const len = b.readUInt32BE(pos); const t = b.toString("latin1", pos + 4, pos + 8); if (t === "IDAT") idat.push(b.subarray(pos + 8, pos + 8 + len)); pos += 12 + len; }
  const raw = inflateSync(Buffer.concat(idat));
  const data = new Uint8Array(w * h * 4);
  for (let y = 0; y < h; y++) data.set(raw.subarray(y * (w * 4 + 1) + 1, (y + 1) * (w * 4 + 1)), y * w * 4);
  return { data, w, h };
}

class FakeTools implements ImageTools {
  clipboardPng: Buffer | null = null;
  calls: string[] = [];
  async clipboard(out: string) { this.calls.push("clipboard"); if (!this.clipboardPng) return null; writeFileSync(out, this.clipboardPng); return { source: "png", bytes: this.clipboardPng.length }; }
  async decode(inFile: string, outRaw: string, max: number) {
    this.calls.push("decode");
    const src = decodeOurPng(readFileSync(inFile));
    const t = fitSize(src.w, src.h, max);
    const r = resizeRgba(src, t.w, t.h);
    writeFileSync(outRaw, r.data);
    return { w: r.w, h: r.h, srcW: src.w, srcH: src.h };
  }
  async convert(inFile: string, out: string) { this.calls.push("convert"); writeFileSync(out, Buffer.from([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3])); return { w: 1, h: 1, bytes: 7 }; }
  wow: { pid: number; startMs: number }[] = [{ pid: 4242, startMs: 1000 }];
  async procinfo() { return this.wow; }
}

function slotDir(n: number): string {
  const d = join(tmp(), "T3Bridge_Img");
  mkdirSync(d);
  for (let k = 1; k <= n; k++) writeFileSync(join(d, slotName(k)), blankSlot());
  return d;
}

// ---------------------------------------------------------------------------------------------
describe("TGA slot writer", () => {
  it("golden header: 512x512, 32 bpp, 8 alpha bits, bottom-left origin; exact slot size", () => {
    expect([...tgaHeader(512, 512)]).toEqual([0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 2, 32, 8]);
    expect(SLOT_BYTES).toBe(1048594);
    const b = blankSlot();
    expect(b.length).toBe(1048594);
    expect(b.subarray(18).every((x) => x === 0)).toBe(true);
  });
  it("golden bytes on a 4x4 canvas: image at the top-left, rows stored bottom-up as BGRA", () => {
    const img = new Uint8Array([255, 0, 0, 255, 0, 255, 0, 128]); // 2x1: red, half-transparent green
    const t = slotTga(img, 2, 1, 4);
    expect(t.length).toBe(18 + 64);
    const rows = [...t.subarray(18)];
    // file row 3 (last in the file) = image row 0
    expect(rows.slice(48, 56)).toEqual([0, 0, 255, 255, 0, 255, 0, 128]);
    expect(rows.slice(0, 48).every((x) => x === 0)).toBe(true);
    expect(rows.slice(56).every((x) => x === 0)).toBe(true);
    expect(createHash("sha256").update(t).digest("hex").slice(0, 16)).toBe(createHash("sha256").update(Buffer.concat([tgaHeader(4, 4), Buffer.alloc(48), Buffer.from([0, 0, 255, 255, 0, 255, 0, 128]), Buffer.alloc(8)])).digest("hex").slice(0, 16));
  });
  it("orientation on the real canvas: slotPixel reads back what was written; outside stays transparent", () => {
    const w = 300, h = 100, img = new Uint8Array(w * h * 4);
    for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) img.set([x % 256, y, 7, 255], (y * w + x) * 4);
    const t = slotTga(img, w, h);
    expect(t.length).toBe(SLOT_BYTES);
    expect(slotPixel(t, 0, 0)).toEqual([0, 0, 7, 255]);
    expect(slotPixel(t, 299, 99)).toEqual([299 % 256, 99, 7, 255]);
    expect(slotPixel(t, 300, 0)).toEqual([0, 0, 0, 0]);
    expect(slotPixel(t, 0, 100)).toEqual([0, 0, 0, 0]);
    expect(slotPixel(t, 511, 511)).toEqual([0, 0, 0, 0]);
    expect(texCoords(300, 100)).toEqual([0, 300 / 512, 0, 100 / 512]);
  });
  it("rejects images larger than the canvas or with a wrong byte count", () => {
    expect(() => slotTga(new Uint8Array(513 * 4), 513, 1)).toThrow();
    expect(() => slotTga(new Uint8Array(10), 2, 2)).toThrow();
  });
});

describe("sizing and codecs", () => {
  it("fitSize keeps the aspect ratio, never upscales, clamps to 1..max", () => {
    expect(fitSize(2000, 1000, 512)).toEqual({ w: 512, h: 256 });
    expect(fitSize(1000, 2000, 512)).toEqual({ w: 256, h: 512 });
    expect(fitSize(100, 50, 512)).toEqual({ w: 100, h: 50 });
    expect(fitSize(1, 5000, 512)).toEqual({ w: 1, h: 512 });
    expect(fitSize(513, 1, 512)).toEqual({ w: 512, h: 1 });
    expect(fitSize(1920, 1080, 512)).toEqual({ w: 512, h: 288 });
    expect(displaySize(512, 256, 240, 160)).toEqual({ w: 240, h: 120 });
    expect(displaySize(100, 300, 240, 160)).toEqual({ w: 53, h: 160 });
    expect(displaySize(50, 20, 240, 160)).toEqual({ w: 50, h: 20 });
  });
  it("resizeRgba averages areas and does not bleed colour out of transparent pixels", () => {
    const src: Rgba = { w: 4, h: 2, data: new Uint8Array([
      255, 0, 0, 255, 255, 0, 0, 255, 0, 0, 255, 255, 0, 0, 255, 255,
      255, 0, 0, 255, 255, 0, 0, 255, 0, 0, 255, 255, 0, 0, 255, 255]) };
    expect([...resizeRgba(src, 2, 1).data]).toEqual([255, 0, 0, 255, 0, 0, 255, 255]);
    const half: Rgba = { w: 2, h: 1, data: new Uint8Array([0, 255, 0, 255, 255, 255, 255, 0]) };
    expect([...resizeRgba(half, 1, 1).data]).toEqual([0, 255, 0, 128]);
  });
  it("decodeTga reads raw and RLE, both origins, and fixes all-zero alpha", () => {
    const head = (type: number, desc: number, bpp = 24) => { const b = tgaHeader(2, 2); b[2] = type; b[16] = bpp; b[17] = desc; return b; };
    // bottom-left origin, 24 bit: file rows bottom-up (BGR)
    const raw = Buffer.concat([head(2, 0), Buffer.from([255, 0, 0, 255, 0, 0, /* top: */ 0, 0, 255, 0, 255, 0])]);
    const a = decodeTga(raw);
    expect([...a.data.subarray(0, 8)]).toEqual([255, 0, 0, 255, 0, 255, 0, 255]); // top row: red, green
    expect([...a.data.subarray(8, 12)]).toEqual([0, 0, 255, 255]);
    const rle = Buffer.concat([head(10, 0x20), Buffer.from([0x83, 10, 20, 30])]); // 4 x (B10,G20,R30), top-left
    expect([...decodeTga(rle).data.subarray(0, 4)]).toEqual([30, 20, 10, 255]);
    const zeroAlpha = Buffer.concat([head(2, 0x28, 32), Buffer.alloc(16, 0)]);
    expect(decodeTga(zeroAlpha).data[3]).toBe(255);
    expect(looksLikeTga(raw)).toBe(true);
    expect(looksLikeTga(encodePng(solid(1, 1, [1, 2, 3, 4])))).toBe(false);
  });
  it("encodePng round-trips and sniffMime recognises the T3 formats", () => {
    const img = solid(3, 2, [10, 20, 30, 40]);
    const png = encodePng(img);
    expect(sniffMime(png)).toBe("image/png");
    expect(decodeOurPng(png)).toEqual(img);
    expect(sniffMime(Buffer.from([0xff, 0xd8, 0xff, 0xe0]))).toBe("image/jpeg");
    expect(sniffMime(Buffer.from("GIF89a"))).toBe("image/gif");
    expect(sniffMime(Buffer.from("RIFF\0\0\0\0WEBPVP8 "))).toBe("image/webp");
    expect(sniffMime(Buffer.from([0, 0, 2]))).toBeNull();
    expect(clipName("C:\\x\\y\\my shot<1>.png")).toBe("my shot_1_.png");
  });
});

// ---------------------------------------------------------------------------------------------
describe("slot pool", () => {
  it("counts installed slots, burns them per WoW process, resets on a new process and blanks the old ones", () => {
    const dir = slotDir(3);
    const state = join(tmp(), "imgslots.json");
    const pool = new SlotPool({ dir, stateFile: state, resetOnReload: false });
    expect(pool.total).toBe(3);
    pool.setWow("4242:1000");
    const tga = slotTga(solid(2, 2, [9, 9, 9, 255]).data, 2, 2);
    for (const k of [1, 2, 3]) { const s = pool.alloc(); expect(s).toBe(k); pool.write(s, tga, `a${k}`, 2, 2); }
    expect(pool.alloc()).toBe(0);
    expect(pool.left).toBe(0);
    expect(pool.setWow("4242:1000")).toBe(false);
    // persisted: a restarted companion with the same WoW keeps the burned count
    const again = new SlotPool({ dir, stateFile: state, resetOnReload: false });
    expect(again.left).toBe(0);
    expect(again.get("a2")).toEqual({ slot: 2, w: 2, h: 2 });
    // new WoW process: all free again, old content blanked
    expect(again.setWow("777:2000")).toBe(true);
    expect(again.left).toBe(3);
    expect(again.get("a2")).toBeUndefined();
    expect(readFileSync(join(dir, slotName(2))).equals(blankSlot())).toBe(true);
  });
  it("resets on a new addon session only with resetOnReload", () => {
    const dir = slotDir(2);
    const off = new SlotPool({ dir, stateFile: join(tmp(), "s.json"), resetOnReload: false });
    off.setWow("1:1"); off.onAddonSession("aaaa0001"); off.alloc();
    expect(off.onAddonSession("aaaa0002")).toBe(false);
    expect(off.left).toBe(1);
    const on = new SlotPool({ dir, stateFile: join(tmp(), "s2.json"), resetOnReload: true });
    on.setWow("1:1"); on.onAddonSession("aaaa0001"); on.alloc();
    expect(on.onAddonSession("aaaa0002")).toBe(true);
    expect(on.left).toBe(2);
  });
  it("never creates slot files and ignores wrong-sized ones", () => {
    const d = join(tmp(), "T3Bridge_Img");
    mkdirSync(d);
    writeFileSync(join(d, slotName(1)), blankSlot());
    writeFileSync(join(d, slotName(2)), Buffer.alloc(100));
    const pool = new SlotPool({ dir: d, stateFile: join(tmp(), "s.json"), resetOnReload: false });
    expect(pool.total).toBe(1);
    expect(new SlotPool({ dir: join(tmp(), "missing"), stateFile: join(tmp(), "s.json"), resetOnReload: false }).total).toBe(0);
    expect(() => pool.write(5, blankSlot(), "x", 1, 1)).toThrow(/missing/);
    expect(existsSync(join(d, slotName(5)))).toBe(false);
  });
});

// ---------------------------------------------------------------------------------------------
function managerSetup(slots = 3) {
  const t3 = new FakeT3Client(1794393000_000);
  t3.streamDelayMs = 0;
  const tools = new FakeTools();
  const dir = slotDir(slots);
  const pool = new SlotPool({ dir, stateFile: join(tmp(), "imgslots.json"), resetOnReload: false });
  const shots = join(tmp(), "Screenshots");
  let dirty = 0;
  const images = new ImageManager({ t3, tools, pool, tmpDir: join(tmp(), "tmp"), screenshotsDir: shots, onDirty: () => dirty++, noticeMs: 60_000 });
  return { t3, tools, dir, pool, images, shots, dirty: () => dirty };
}

describe("image manager", () => {
  it("inline image: load -> slot written with the decoded image -> cached", async () => {
    const m = managerSetup();
    const png = encodePng(solid(1024, 512, [200, 10, 10, 255]));
    m.t3.attachmentBytes.set("att-1", png);
    const ref = { id: "att-1", name: "red.png", mimeType: "image/png", sizeBytes: png.length };
    m.images.beginRender();
    expect(m.images.resolve(ref)).toEqual({ s: 0, st: "load" });
    await m.images.idle();
    expect(m.images.resolve(ref)).toEqual({ s: 1, w: 512, h: 256 });
    const file = readFileSync(join(m.dir, slotName(1)));
    expect(slotPixel(file, 10, 10)).toEqual([200, 10, 10, 255]);
    expect(slotPixel(file, 10, 300)).toEqual([0, 0, 0, 0]);
    expect(m.t3.calls.filter((c) => c.method === "fetchAttachment")).toHaveLength(1);
    expect(m.dirty()).toBeGreaterThan(0);
  });
  it("starts at most 8 new images per snapshot and reports a full pool", async () => {
    const m = managerSetup(9);
    const png = encodePng(solid(4, 4, [1, 2, 3, 255]));
    const refs = Array.from({ length: 10 }, (_, k) => { m.t3.attachmentBytes.set(`a${k}`, png); return { id: `a${k}`, name: `${k}.png`, mimeType: "image/png", sizeBytes: png.length }; });
    m.images.beginRender();
    refs.forEach((r) => m.images.resolve(r));
    await m.images.idle();
    expect(m.t3.calls.filter((c) => c.method === "fetchAttachment")).toHaveLength(8);
    m.images.beginRender();
    expect(m.images.resolve(refs[8]).st).toBe("load");
    await m.images.idle();
    expect(m.images.resolve(refs[8]).s).toBe(9);
    m.images.beginRender();
    expect(m.images.resolve(refs[9])).toEqual({ s: 0, st: "full" });
    expect(m.images.slotsInfo()).toEqual({ left: 0, total: 9, reset: "restart" });
  });
  it("slots installed while the companion runs are found (no restart of the bridge needed)", () => {
    const t3 = new FakeT3Client(1794393000_000);
    const d = join(tmp(), "T3Bridge_Img");
    const pool = new SlotPool({ dir: d, stateFile: join(tmp(), "s.json"), resetOnReload: false });
    let now = 1_000_000, dirty = 0;
    const images = new ImageManager({ t3, tools: new FakeTools(), pool, tmpDir: join(tmp(), "tmp"), screenshotsDir: tmp(), onDirty: () => dirty++, now: () => now });
    images.beginRender();
    expect(images.slotsInfo().total).toBe(0);
    mkdirSync(d);
    for (let k = 1; k <= 2; k++) writeFileSync(join(d, slotName(k)), blankSlot());
    now += 11_000;
    images.beginRender();
    expect(images.slotsInfo()).toMatchObject({ total: 2, left: 2 });
    expect(dirty).toBeGreaterThan(0);
  });
  it("images are off without slots or when the addon opted out", () => {
    const m = managerSetup(0);
    expect(m.images.resolve({ id: "x", name: "x.png", mimeType: "image/png", sizeBytes: 1 })).toEqual({ s: 0, st: "off" });
    const n = managerSetup(2);
    n.images.addonImagesOff = true;
    expect(n.images.resolve({ id: "x", name: "x.png", mimeType: "image/png", sizeBytes: 1 })).toEqual({ s: 0, st: "off" });
    expect(n.images.slotsInfo().total).toBe(0);
  });
  it("a new WoW process frees the pool (pool accounting across a PID change)", async () => {
    const m = managerSetup(1);
    const png = encodePng(solid(4, 4, [1, 2, 3, 255]));
    m.t3.attachmentBytes.set("a", png); m.t3.attachmentBytes.set("b", png);
    m.images.beginRender(); m.images.resolve({ id: "a", name: "a.png", mimeType: "image/png", sizeBytes: 1 }); await m.images.idle();
    m.images.beginRender(); expect(m.images.resolve({ id: "b", name: "b.png", mimeType: "image/png", sizeBytes: 1 }).st).toBe("full");
    // WoW restarts while the companion keeps running: the next snapshot build notices it in the background.
    m.tools.wow = [{ pid: 9999, startMs: 5000 }];
    (m.images as any).wowCache.at -= 10_000;
    const before = m.dirty();
    m.images.beginRender();
    await new Promise((r) => setTimeout(r, 20));
    expect(m.pool.key).toBe("9999:5000");
    expect(m.dirty()).toBeGreaterThan(before);
    expect(readFileSync(join(m.dir, slotName(1))).equals(blankSlot())).toBe(true); // old image blanked
    m.images.beginRender(); expect(m.images.resolve({ id: "b", name: "b.png", mimeType: "image/png", sizeBytes: 1 }).st).toBe("load");
    await m.images.idle();
    expect(m.images.resolve({ id: "b", name: "b.png", mimeType: "image/png", sizeBytes: 1 }).s).toBe(1);
    expect(m.pool.key).toBe("9999:5000");
  });
  it("clip: quiet ignores an empty clipboard, otherwise a notice; stages, dedupes, caps at 4, unstage", async () => {
    const m = managerSetup();
    await m.images.clip("t1", true);
    expect(m.images.notice("t1")).toBeUndefined();
    await m.images.clip("t1", false);
    expect(m.images.notice("t1")?.text).toBe("No image on the clipboard");
    m.tools.clipboardPng = encodePng(solid(64, 32, [0, 0, 255, 255]));
    await m.images.clip("t1", true);
    const st = m.images.stagedFor("t1");
    expect(st).toHaveLength(1);
    expect(st[0]).toMatchObject({ name: "clip-1.png", slot: 1, w: 64, h: 32 });
    await m.images.clip("t1", true);
    expect(m.images.stagedFor("t1")).toHaveLength(1);
    expect(m.images.notice("t1")?.text).toMatch(/already attached/);
    for (let k = 0; k < 4; k++) { m.tools.clipboardPng = encodePng(solid(8, 8 + k, [k, 0, 0, 255])); await m.images.clip("t1", true); }
    expect(m.images.stagedFor("t1")).toHaveLength(4);
    expect(m.images.notice("t1")?.text).toMatch(/At most 4/);
    const aid = m.images.stagedFor("t1")[0].aid;
    const file = m.images.stagedFor("t1")[0].file;
    m.images.unstage("t1", aid);
    expect(m.images.stagedFor("t1")).toHaveLength(3);
    expect(existsSync(file)).toBe(false);
  });
  it("shot: stages the newest recent screenshot (copy only), refuses old ones", async () => {
    const m = managerSetup();
    mkdirSync(m.shots, { recursive: true });
    const old = join(m.shots, "WoWScrnShot_old.png");
    writeFileSync(old, encodePng(solid(4, 4, [1, 1, 1, 255])));
    const past = new Date(Date.now() - 60 * 60_000);
    utimesSync(old, past, past);
    await m.images.shot("t1");
    expect(m.images.notice("t1")?.text).toMatch(/No recent screenshot/);
    const fresh = join(m.shots, "WoWScrnShot_new.png");
    const bytes = encodePng(solid(40, 20, [5, 5, 5, 255]));
    writeFileSync(fresh, bytes);
    await m.images.shot("t1");
    expect(m.images.stagedFor("t1")[0]).toMatchObject({ name: "WoWScrnShot_new.png", w: 40, h: 20 });
    expect(readFileSync(fresh).equals(bytes)).toBe(true);
  });
  it("stop blanks every used slot and deletes staged temp files (blank-on-stop)", async () => {
    const m = managerSetup();
    m.tools.clipboardPng = encodePng(solid(16, 16, [255, 255, 255, 255]));
    await m.images.clip("t1", true);
    const file = m.images.stagedFor("t1")[0].file;
    expect(readFileSync(join(m.dir, slotName(1))).equals(blankSlot())).toBe(false);
    expect(m.images.stop()).toBe(1);
    expect(readFileSync(join(m.dir, slotName(1))).equals(blankSlot())).toBe(true);
    expect(existsSync(file)).toBe(false);
    expect(m.pool.left).toBe(2); // still burned for this WoW session
  });
});

// ---------------------------------------------------------------------------------------------
const SID = Buffer.from("9f3a01c2", "hex");
const frames = (seq: number, msg: string): Frame[] => framesForMessage(SID, seq, Buffer.from(msg)).frames.map((f) => (parseFrame(f) as any).frame);

describe("protocol rev 1.3", () => {
  it("parses clip, shot, unstage and the hello image flag", () => {
    expect(parseCommand("clip\ta1b2c3d4\t1")).toEqual({ ok: true, cmd: { kind: "clip", tid: "a1b2c3d4", quiet: true } });
    expect(parseCommand("clip\ta1b2c3d4\t0")).toEqual({ ok: true, cmd: { kind: "clip", tid: "a1b2c3d4", quiet: false } });
    expect(parseCommand("shot\ta1b2c3d4")).toEqual({ ok: true, cmd: { kind: "shot", tid: "a1b2c3d4" } });
    expect(parseCommand("unstage\ta1b2c3d4\tk1")).toEqual({ ok: true, cmd: { kind: "unstage", tid: "a1b2c3d4", aid: "k1" } });
    expect(parseCommand("unstage\ta1b2c3d4\tbad aid").ok).toBe(false);
    expect(parseCommand("clip\tbad tid").ok).toBe(false);
    expect(parseCommand("hello\t1\t0.2.0\t2\t8\t0")).toMatchObject({ ok: true, cmd: { img: "0" } });
    expect(parseCommand("send\ta1b2c3d4\t9f3a01c2-15\t")).toEqual({ ok: true, cmd: { kind: "send", tid: "a1b2c3d4", clientMsgId: "9f3a01c2-15", text: "" } });
  });
  it("image attachments are read from user_message items (VERIFIED shape)", () => {
    const att = [{ type: "image", id: "fa4e0001-0000-4000-8000-000000000001-fa4e0002-0000-4000-8000-000000000002", name: "spike-red-blue.png", mimeType: "image/png", sizeBytes: 129 }, { type: "file", id: "f1", name: "a.txt", mimeType: "text/plain", sizeBytes: 3 }];
    const { type: _t, ...ref } = att[0];
    expect(imageAttachments(att)).toEqual([ref]);
    const msgs = itemsToMessages([{ type: "user_message", ordinal: 1_000_001, text: "What colours?", attachments: att, startedAt: "2026-01-01T00:00:00Z" }]);
    expect(msgs[0].images).toHaveLength(1);
  });
  it("image segments serialize as mixed Lua tables with a text fallback for 1.2 addons", () => {
    const m = messageToSnap({ i: 1, role: "u", ts: 1, text: "", images: [{ id: "abc", name: "red.png", mimeType: "image/png", sizeBytes: 9 }] }, 8000, DEFAULT_CAPS, () => ({ s: 3, w: 320, h: 180 }));
    expect(m.segs).toHaveLength(1);
    const lua = serializeSnapshot({ v: 1, sid: "k", seq: 1, ts: 1, ack: 0, asid: "", threads: [], imgslots: { left: 7, total: 100, reset: "restart" }, focus: { id: "t", streaming: false, msgs: [m], staged: [{ aid: "k1", s: 4, w: 36, h: 20, name: "clip-1.png" }], notice: "No image on the clipboard", nid: 2 } });
    expect(lua).toContain(`{"img","[image: red.png]",s=3,w=320,h=180,alt="red.png",aid="`);
    const doc = toJs(parseLuaChunk(lua).T3B_IN as any);
    expect(doc.imgslots).toEqual({ left: 7, total: 100, reset: "restart" });
    const seg = doc.focus.msgs[0].segs[0];
    expect(seg.__array).toEqual(["img", "[image: red.png]"]); // what a 1.2 addon reads as seg[1], seg[2]
    expect(seg).toMatchObject({ s: 3, w: 320, h: 180, alt: "red.png" });
    expect(doc.focus.staged[0]).toEqual({ aid: "k1", s: 4, w: 36, h: 20, name: "clip-1.png" });
    expect(doc.focus.notice).toBe("No image on the clipboard");
    expect(doc.focus.nid).toBe(2);
    const off = messageToSnap({ i: 2, role: "u", ts: 1, text: "look", images: [{ id: "x", name: "x.png", mimeType: "image/png", sizeBytes: 1 }] }, 8000, DEFAULT_CAPS);
    expect(off.segs.map((s) => s[0])).toEqual(["p", "img"]);
  });
  it("end to end through the bridge: clip -> staged in focus -> send uploads and attaches -> echo reuses the slot", async () => {
    const m = managerSetup();
    const bridge = new Bridge({ t3: m.t3, onDirty: () => {}, onAck: () => {}, images: m.images });
    bridge.render(1, 1);
    const tid = bridge.tids.tid(m.t3.threads()[0].id);
    for (const f of frames(1, `focus\t${tid}`)) bridge.onFrame(f);
    await bridge.idle();
    m.tools.clipboardPng = encodePng(solid(100, 50, [0, 200, 0, 255]));
    for (const f of frames(2, `clip\t${tid}\t1`)) bridge.onFrame(f);
    await bridge.idle();
    let doc = toJs(parseLuaChunk(bridge.render(10, 1)).T3B_IN as any);
    expect(doc.focus.staged).toEqual([{ aid: expect.any(String), s: 1, w: 100, h: 50, name: "clip-1.png" }]);
    expect(doc.imgslots).toMatchObject({ left: 2, total: 3 });
    for (const f of frames(3, `send\t${tid}\t9f3a01c2-3\t`)) bridge.onFrame(f); // images only, no text
    await bridge.idle();
    expect(bridge.ackState.err).toBeUndefined();
    const send = m.t3.calls.find((c) => c.method === "sendMessage")!;
    expect(send.args[1]).toBe("");
    expect(send.args[3]).toEqual([{ type: "image", id: expect.stringMatching(/^pending-/), name: "clip-1.png", mimeType: "image/png", sizeBytes: m.tools.clipboardPng.length }]);
    doc = toJs(parseLuaChunk(bridge.render(11, 1)).T3B_IN as any);
    expect(doc.focus.staged).toBeUndefined();
    const last = doc.focus.msgs.filter((x: any) => x.r === "u").at(-1);
    const img = last.segs.find((s: any) => s.__array?.[0] === "img");
    expect(img).toMatchObject({ s: 1, w: 100, h: 50 }); // same slot, no second fetch
    expect(m.t3.calls.filter((c) => c.method === "fetchAttachment")).toHaveLength(0);
  });
  it("send with an empty text and nothing staged is still refused", async () => {
    const m = managerSetup();
    const bridge = new Bridge({ t3: m.t3, onDirty: () => {}, onAck: () => {}, images: m.images });
    bridge.render(1, 1);
    const tid = bridge.tids.tid(m.t3.threads()[0].id);
    for (const f of frames(1, `send\t${tid}\t9f3a01c2-1\t `)) bridge.onFrame(f);
    await bridge.idle();
    expect(bridge.ackState.err?.text).toBe("Empty message");
  });
});

void CANVAS;

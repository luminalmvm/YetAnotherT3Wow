import { describe, expect, it } from "vitest";
import { buildFrame, CAP_LONG, CAP_SHORT, cellAt, crc32, framesForMessage, parseCommand, parseFrame, splitFields } from "../src/wow/frameCodec.js";
import { bgraToLuma, decodeImage, decodeUtf8, findSync, Reassembler } from "../src/wow/frameDecoder.js";
import { addNoise, encodeMessage, renderMatrix, scaleImage, toneMap } from "../src/testing/frameEncoder.js";
import { RecordParser } from "../src/wow/captureClient.js";

const SID = Buffer.from("9f3a01c2", "hex");

describe("frame codec", () => {
  it("CRC-32/ISO-HDLC check value", () => {
    expect(crc32(Buffer.from("123456789"))).toBe(0xcbf43926);
  });
  it("builds/parses frames, big-endian fields, 18 bytes overhead", () => {
    const f = buildFrame(SID, 0x1234, 2, 3, Buffer.from("hi"), 1);
    expect(f.length).toBe(20);
    expect(f.subarray(0, 4).toString("latin1")).toBe("T3\x01\x01");
    expect(f.readUInt16BE(8)).toBe(0x1234);
    const p = parseFrame(f);
    expect(p.ok && p.frame.payload.toString()).toBe("hi");
    const bad = Buffer.from(f); bad[15] ^= 1;
    expect(parseFrame(bad)).toEqual({ ok: false, reason: "crc" });
  });
  it("splits like the addon: <=206 one R=8 frame, else R=32 frames of 974", () => {
    expect(CAP_SHORT).toBe(206);
    expect(CAP_LONG).toBe(974);
    expect(framesForMessage(SID, 1, Buffer.alloc(206)).frames).toHaveLength(1);
    const big = framesForMessage(SID, 1, Buffer.alloc(4070));
    expect(big.rows).toBe(32);
    expect(big.frames).toHaveLength(5);
    expect(big.frames[0].readUInt16BE(12)).toBe(974);
  });
  it("cell layout: sync row 1010..., data MSB first row-major", () => {
    const f = buildFrame(SID, 1, 1, 1, Buffer.alloc(0));
    expect(cellAt(f, 0, 0)).toBe(1);
    expect(cellAt(f, 0, 1)).toBe(0);
    // 'T' = 0x54 = 01010100
    expect([0, 1, 2, 3, 4, 5, 6, 7].map((x) => cellAt(f, 1, x)).join("")).toBe("01010100");
  });
});

describe("commands", () => {
  it("send/ans keep tabs and newlines in the last field; others ignore extras", () => {
    expect(splitFields("send\tt\tc-1\ta\tb\nc")).toEqual(["send", "t", "c-1", "a\tb\nc"]);
    expect(parseCommand("ans\ta1\tr1\tfree\ttext")).toEqual({ ok: true, cmd: { kind: "ans", tid: "a1", rid: "r1", answer: "free\ttext" } });
    expect(parseCommand("focus\ta1b2c3d4\textra")).toEqual({ ok: true, cmd: { kind: "focus", tid: "a1b2c3d4" } });
    expect(parseCommand("hello\t1\t0.1.0\t2\t8")).toMatchObject({ ok: true, cmd: { kind: "hello", proto: "1", cell: "2", rows: "8" } });
    expect(parseCommand("hist\ta1\t131")).toEqual({ ok: true, cmd: { kind: "hist", tid: "a1", beforeIndex: 131 } });
    expect(parseCommand("open")).toEqual({ ok: true, cmd: { kind: "open", tid: undefined } });
    expect(parseCommand("focus\tbad tid").ok).toBe(false);
    expect(parseCommand("nope").ok).toBe(false);
  });
});

function roundTrip(msg: string, render: (f: Buffer, rows: number, k: number) => ReturnType<typeof renderMatrix>) {
  const enc = encodeMessage(SID, 7, msg);
  const re = new Reassembler();
  let out: string | undefined;
  enc.frames.forEach((f, k) => {
    const r = decodeImage(render(f, enc.rows, k));
    expect(r.ok, `part ${k + 1}: ${!r.ok ? r.reason : ""}`).toBe(true);
    if (r.ok) { const p = re.push(r.frame); if (p.kind === "complete") out = decodeUtf8(p.msg.payload); }
  });
  return out;
}

describe("matrix decode", () => {
  const msgs = ["focus\ta1b2c3d4", "send\ta1b2c3d4\tab-1\t" + "Grüße ✓ ".repeat(300)];
  for (const cell of [1, 2, 4]) {
    it(`pixel-exact cells c=${cell}, with window-border offsets and busy backgrounds`, () => {
      for (const bg of ["game", "white", "noise", "black"] as const) for (const m of msgs) {
        expect(roundTrip(m, (f, rows, k) => renderMatrix(f, rows, { cell, offsetX: 1 + k, offsetY: 31, background: bg, seed: k + 3 }))).toBe(m);
      }
    });
  }
  it("reports the geometry (cell size from the sync row)", () => {
    const enc = encodeMessage(SID, 1, "intr\ta1");
    const g = findSync(renderMatrix(enc.frames[0], enc.rows, { cell: 4, offsetX: 5, offsetY: 9, background: "game" }))!;
    expect(g.x0).toBeCloseTo(5, 1);
    expect(g.y0).toBe(9);
    expect(g.pitchX).toBeCloseTo(4, 2);
    expect(g.bandH).toBe(4);
  });
  it("survives display scaling for c>=2 (nearest and bilinear), noise and tone changes", () => {
    for (const s of [1.25, 1.5, 2]) for (const mode of ["nearest", "bilinear"] as const)
      expect(roundTrip(msgs[1], (f, rows) => scaleImage(renderMatrix(f, rows, { cell: 2, offsetX: 2, offsetY: 30 }), s, mode))).toBe(msgs[1]);
    expect(roundTrip(msgs[0], (f, rows) => addNoise(renderMatrix(f, rows, { cell: 2, offsetY: 3 }), 40))).toBe(msgs[0]);
    expect(roundTrip(msgs[0], (f, rows) => toneMap(renderMatrix(f, rows, { cell: 1, offsetY: 3 }), 30, 170, 1.8))).toBe(msgs[0]);
  });
  it("rejects images without a matrix and corrupted frames", () => {
    expect(decodeImage({ width: 600, height: 100, data: new Uint8Array(60000).fill(80) })).toMatchObject({ ok: false, reason: "no-sync" });
    const enc = encodeMessage(SID, 1, "focus\ta1b2c3d4");
    const img = renderMatrix(enc.frames[0], enc.rows, { cell: 2, background: "black" });
    // flip one payload cell (row 1, cell 200) -> CRC failure, never a wrong command
    for (let y = 2; y < 4; y++) for (let x = 400; x < 402; x++) img.data[y * img.width + x] ^= 0xff;
    const r = decodeImage(img);
    expect(r.ok).toBe(false);
  });
  it("converts BGRA captures to luma", () => {
    const bgra = new Uint8Array([255, 255, 255, 255, 0, 0, 0, 255]);
    expect(Array.from(bgraToLuma(bgra, 2, 1).data)).toEqual([255, 0]);
  });
});

describe("Reassembler", () => {
  const frames = framesForMessage(SID, 9, Buffer.from("x".repeat(2500))).frames.map((f) => (parseFrame(f) as any).frame);
  it("joins parts in any order, emits once, dedupes repeats and retransmits", () => {
    const re = new Reassembler();
    expect(re.push(frames[2]).kind).toBe("partial");
    expect(re.push(frames[2]).kind).toBe("repeat");
    expect(re.push(frames[0]).kind).toBe("partial");
    const done = re.push(frames[1]);
    expect(done.kind).toBe("complete");
    if (done.kind === "complete") expect(done.msg.payload.toString()).toBe("x".repeat(2500));
    expect(re.push(frames[0]).kind).toBe("duplicate");
  });
  it("a new addon session (sid) drops old partials; partials expire after 30 s", () => {
    const re = new Reassembler();
    re.push(frames[0], 0);
    const other = { ...frames[1], sid: Buffer.from("00000001", "hex") };
    re.push(other, 1);
    expect(re.push(frames[1], 2).kind).toBe("partial"); // old partial for sid 9f3a01c2 is gone
    const r2 = new Reassembler();
    r2.push(frames[0], 0);
    r2.push(frames[1], 31_000);
    expect(r2.push(frames[2], 31_001).kind).toBe("partial");
  });
  it("joins UTF-8 split across parts before decoding", () => {
    const msg = Buffer.from("send\ta\tb-1\t" + "é".repeat(700));
    const fr = framesForMessage(SID, 3, msg).frames.map((f) => (parseFrame(f) as any).frame);
    const re = new Reassembler();
    let out = "";
    for (const f of fr) { const r = re.push(f); if (r.kind === "complete") out = decodeUtf8(r.msg.payload); }
    expect(out).toBe(msg.toString());
  });
});

describe("capture record parser", () => {
  it("parses records split across chunks and resyncs after garbage", () => {
    const rec = (w: number, h: number, seq: number) => {
      const b = Buffer.alloc(38 + w * h);
      b.write("T3CF", 0, "latin1"); b[4] = 1; b[5] = 1;
      b.writeUInt16LE(w, 6); b.writeUInt16LE(h, 8); b.writeUInt16LE(3, 10); b.writeUInt16LE(4, 12);
      b.writeUInt32LE(seq, 14); b.writeBigInt64LE(123n, 18); b.writeBigInt64LE(456n, 26); b.writeUInt32LE(2000, 34);
      b.fill(seq, 38);
      return b;
    };
    const all = Buffer.concat([Buffer.from("junk"), rec(4, 2, 1), rec(3, 3, 2)]);
    const p = new RecordParser();
    const got: number[] = [];
    for (let k = 0; k < all.length; k += 5) p.push(all.subarray(k, k + 5), (r) => { got.push(r.seq); expect(r.pitch).toBe(2); expect(r.image.data[0]).toBe(r.seq); });
    expect(got).toEqual([1, 2]);
  });
});

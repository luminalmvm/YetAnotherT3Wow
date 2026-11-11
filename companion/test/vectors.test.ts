// Shared outbound test vectors (companion/test/vectors/*.json). Run with UPDATE_VECTORS=1 to regenerate.
// The addon's Lua encoder (addon/T3Bridge/Codec.lua) can be checked against the same files: for each vector,
// Codec.FramesForMessage(sid, seq, message) must produce exactly `frames[].hex` and Codec.CellStrings the `cells`.
import { existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";
import { makeVector, renderMatrix } from "../src/testing/frameEncoder.js";
import { checkVector, loadVectors } from "../src/selftest.js";
import { decodeImage } from "../src/wow/frameDecoder.js";

const DIR = resolve(__dirname, "vectors");
const SPECS: [string, string, number, string, number?][] = [
  ["hello", "9f3a01c2", 1, "hello\t1\t0.1.0\t2\t8"],
  ["focus", "9f3a01c2", 2, "focus\ta1b2c3d4"],
  ["send-short", "9f3a01c2", 3, "send\ta1b2c3d4\t9f3a01c2-3\tCan you rerun the tests?"],
  ["send-unicode-tabs", "9f3a01c2", 4, "send\ta1b2c3d4\t9f3a01c2-4\tGrüße ✓ — tabs\there\nand a | pipe"],
  ["model", "9f3a01c2", 5, "model\ta1b2c3d4\tclaude-sonnet-5-5"],
  ["model-effort", "9f3a01c2", 12, "model\ta1b2c3d4\tclaude-opus-5-5\txhigh"],
  ["intr-retransmit", "9f3a01c2", 6, "intr\ta1b2c3d4", 1],
  ["ans-option", "9f3a01c2", 7, "ans\ta1b2c3d4\tr0123456789ab\taccept"],
  ["hist", "9f3a01c2", 8, "hist\ta1b2c3d4\t100131"],
  ["send-206-boundary", "0badf00d", 9, "send\ta1b2c3d4\t0badf00d-9\t" + "a".repeat(206 - "send\ta1b2c3d4\t0badf00d-9\t".length)],
  ["send-207-two-rows-mode", "0badf00d", 10, "send\ta1b2c3d4\t0badf00d-10\t" + "b".repeat(207 - "send\ta1b2c3d4\t0badf00d-10\t".length)],
  ["send-max-5-parts", "ffffffff", 65535, "send\ta1b2c3d4\tffffffff-65535\t" + "Zz ✓ é ".repeat(444)],
];

describe("test vectors", () => {
  it("generate (UPDATE_VECTORS=1) / are up to date", () => {
    mkdirSync(DIR, { recursive: true });
    for (const [name, sid, seq, msg, flags] of SPECS) {
      const v = makeVector(name, sid, seq, msg, flags ?? 0);
      const file = resolve(DIR, `${name}.json`);
      if (process.env.UPDATE_VECTORS || !existsSync(file)) writeFileSync(file, JSON.stringify(v, null, 1) + "\n");
      expect(JSON.parse(readFileSync(file, "utf8"))).toEqual(v);
    }
    expect(readdirSync(DIR).filter((f) => f.endsWith(".json")).length).toBeGreaterThanOrEqual(SPECS.length);
  });
  it("every vector (ours and the addon's, if present) parses, matches its cells and reassembles", () => {
    const vecs = loadVectors([DIR, resolve(__dirname, "..", "..", "protocol", "vectors")]);
    expect(vecs.length).toBeGreaterThanOrEqual(SPECS.length);
    for (const { file, v } of vecs) expect(checkVector(v), file).toBeNull();
  });
  it("vector cells render and decode through the image path", () => {
    const v = JSON.parse(readFileSync(resolve(DIR, "send-max-5-parts.json"), "utf8"));
    expect(v.frames).toHaveLength(5);
    for (const f of v.frames) {
      const r = decodeImage(renderMatrix(Buffer.from(f.hex, "hex"), f.rows, { cell: 2, offsetX: 1, offsetY: 31 }));
      expect(r.ok && r.frame.part).toBe(f.part);
    }
  });
});

describe("Addon vectors (protocol/vectors, produced by the Lua encoder path)", () => {
  const pdir = resolve(__dirname, "..", "..", "protocol", "vectors");
  it("their rendered PNGs decode through the companion's screenshot+matrix decoder", async () => {
    if (!existsSync(pdir)) return;
    const { decodePngRegion } = await import("../src/wow/imageDecode.js");
    const { fromTrackB } = await import("../src/selftest.js");
    const pngs = readdirSync(pdir).filter((f) => f.endsWith(".png"));
    let checked = 0;
    for (const png of pngs) {
      const m = /^(.*)\.p(\d+)\.png$/.exec(png);
      if (!m) continue;
      const v = fromTrackB(JSON.parse(readFileSync(resolve(pdir, `${m[1]}.json`), "utf8")));
      const img = decodePngRegion(readFileSync(resolve(pdir, png)), 4096, 512);
      const r = decodeImage(img, { maxX: 512, maxY: 512 });
      expect(r.ok, `${png}: ${!r.ok ? r.reason : ""}`).toBe(true);
      if (r.ok) expect(r.frame.payload.toString("hex")).toBe(v.frames[Number(m[2]) - 1].hex.slice(28, -8));
      checked++;
    }
    expect(checked).toBeGreaterThan(0);
  });
});

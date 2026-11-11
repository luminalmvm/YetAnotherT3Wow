// --selftest: exercises the outbound decoder against synthetic frames (no WoW, no T3).
// Required cases (pixel-exact cells, as the addon draws them) must all pass; scaled/blurred cases are
// reported as a reliability matrix (used for docs/dev-notes/PHASE0-REPORT-A.md).
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { crc32, parseFrame, parseCommand } from "./wow/frameCodec.js";
import { decodeImage, decodeUtf8, Reassembler } from "./wow/frameDecoder.js";
import { addNoise, boxBlur, encodeMessage, renderMatrix, scaleImage, toneMap, type Vector } from "./testing/frameEncoder.js";

export interface MatrixCell { cell: number; scale: number; mode: string; ok: number; total: number }

const MESSAGES = (): string[] => {
  const long = "Grüße aus Azeroth — ✓ " + "lorem ipsum dolor sit amet ".repeat(160);
  return [
    "hello\t1\t0.1.0\t2\t8",
    "focus\ta1b2c3d4",
    "send\ta1b2c3d4\t9f3a01c2-3\tCan you rerun the flaky test? | pipes | and\ttabs\nand newlines",
    "ans\ta1b2c3d4\tr0123456789ab\taccept",
    `send\ta1b2c3d4\t9f3a01c2-5\t${long.slice(0, 900)}`,
    `send\ta1b2c3d4\t9f3a01c2-6\t${long.slice(0, 3990)}`,
  ];
};

function decodeMessage(msg: string, seq: number, render: (frame: Buffer, rows: number, k: number) => ReturnType<typeof renderMatrix>): boolean {
  const sid = Buffer.from("9f3a01c2", "hex");
  const enc = encodeMessage(sid, seq, msg);
  const re = new Reassembler();
  let out: string | null = null;
  enc.frames.forEach((f, k) => {
    const r = decodeImage(render(f, enc.rows, k));
    if (!r.ok) return;
    const p = re.push(r.frame);
    if (p.kind === "complete") out = decodeUtf8(p.msg.payload);
  });
  return out === msg;
}

export function reliabilityMatrix(opts: { cells?: number[]; scales?: number[]; modes?: string[] } = {}): MatrixCell[] {
  const cells = opts.cells ?? [1, 2, 4];
  const scales = opts.scales ?? [1, 1.25, 1.5, 1.75, 2];
  const modes = opts.modes ?? ["nearest", "bilinear"];
  const msgs = MESSAGES();
  const res: MatrixCell[] = [];
  for (const cell of cells) for (const scale of scales) for (const mode of modes) {
    if (scale === 1 && mode === "bilinear") continue;
    let ok = 0, total = 0;
    msgs.forEach((m, k) => {
      for (const bg of ["game", "white", "noise"] as const) {
        total++;
        const good = decodeMessage(m, k + 1, (f, rows, part) => {
          let img = renderMatrix(f, rows, { cell, offsetX: 1 + (part % 3), offsetY: 31 + (k % 2), background: bg, seed: k * 7 + part });
          if (scale !== 1) img = scaleImage(img, scale, mode as any);
          return img;
        });
        if (good) ok++;
      }
    });
    res.push({ cell, scale, mode: scale === 1 ? "exact" : mode, ok, total });
  }
  return res;
}

export function robustnessCases(): { name: string; ok: number; total: number }[] {
  const msgs = MESSAGES();
  const cases: { name: string; fn: (img: ReturnType<typeof renderMatrix>) => ReturnType<typeof renderMatrix>; cell: number }[] = [
    { name: "c2 noise±40", cell: 2, fn: (i) => addNoise(i, 40) },
    { name: "c2 blur r1", cell: 2, fn: (i) => boxBlur(i, 1) },
    { name: "c4 blur r1", cell: 4, fn: (i) => boxBlur(i, 1) },
    { name: "c1 blur r1", cell: 1, fn: (i) => boxBlur(i, 1) },
    { name: "c2 dim tone 30..170 γ1.8", cell: 2, fn: (i) => toneMap(i, 30, 170, 1.8) },
    { name: "c1 dim tone 30..170 γ1.8", cell: 1, fn: (i) => toneMap(i, 30, 170, 1.8) },
    { name: "c2 HDR-ish 0..255 γ0.5", cell: 2, fn: (i) => toneMap(i, 0, 255, 0.5) },
  ];
  return cases.map((c) => {
    let ok = 0;
    msgs.forEach((m, k) => { if (decodeMessage(m, k + 1, (f, rows) => c.fn(renderMatrix(f, rows, { cell: c.cell, offsetX: 3, offsetY: 30, background: "game", seed: k })))) ok++; });
    return { name: c.name, ok, total: msgs.length };
  });
}

/** Adapter for the addon's vector schema (protocol/vectors/*.json, snake_case, parts[].frame_hex). */
export function fromTrackB(v: any): Vector {
  return {
    name: v.name, sidHex: v.sid_hex, seq: v.seq, flags: v.flags ?? 0, messageUtf8: v.message_utf8, messageHex: v.message_hex,
    frames: v.parts.map((p: any) => ({ part: p.part, parts: p.parts, rows: v.rows, hex: p.frame_hex, crc32: p.crc32_hex, cells: p.cells })),
  };
}

export function loadVectors(dirs: string[]): { file: string; v: Vector }[] {
  const out: { file: string; v: Vector }[] = [];
  for (const d of dirs) {
    if (!existsSync(d)) continue;
    for (const f of readdirSync(d)) if (f.endsWith(".json")) {
      try {
        const v = JSON.parse(readFileSync(join(d, f), "utf8"));
        if (Array.isArray(v?.frames)) out.push({ file: join(d, f), v });
        else if (Array.isArray(v?.parts) && v.sid_hex) out.push({ file: join(d, f), v: fromTrackB(v) });
      } catch { /* not a vector */ }
    }
  }
  return out;
}

/** Checks vectors: hex parses with valid CRC, cells match hex, message reassembles. */
export function checkVector(v: Vector): string | null {
  const re = new Reassembler();
  let msg: Buffer | null = null;
  for (const f of v.frames) {
    const bytes = Buffer.from(f.hex, "hex");
    const p = parseFrame(bytes);
    if (!p.ok) return `${v.name} part ${f.part}: ${p.reason}`;
    if (f.cells) {
      // cells -> bytes (rows 1..)
      const rec: number[] = [];
      for (let r = 1; r < f.cells.length; r++) for (let b = 0; b < 32; b++) rec.push(parseInt(f.cells[r].slice(b * 8, b * 8 + 8), 2));
      if (!Buffer.from(rec).subarray(0, bytes.length).equals(bytes)) return `${v.name} part ${f.part}: cells do not match hex`;
      if (f.cells[0] !== "10".repeat(128)) return `${v.name} part ${f.part}: bad sync row`;
    }
    const r = re.push(p.frame);
    if (r.kind === "complete") msg = r.msg.payload;
  }
  if (!msg) return `${v.name}: incomplete`;
  const want = v.messageHex ? Buffer.from(v.messageHex, "hex") : Buffer.from(v.messageUtf8, "utf8");
  return msg.equals(want) ? null : `${v.name}: payload mismatch`;
}

export function runSelftest(print: (s: string) => void = console.log): boolean {
  let pass = true;
  const check = (name: string, ok: boolean, detail = "") => { print(`${ok ? "PASS" : "FAIL"}  ${name}${detail ? "  " + detail : ""}`); if (!ok) pass = false; };
  check("crc32('123456789') = 0xCBF43926", crc32(Buffer.from("123456789")) === 0xcbf43926);
  const p = parseCommand("send\ta1b2c3d4\tx-1\tline1\tstill text\nline2");
  check("send keeps tabs/newlines in its last field", p.ok && p.cmd.kind === "send" && p.cmd.text === "line1\tstill text\nline2");

  const here = dirname(fileURLToPath(import.meta.url));
  const vecDirs = [resolve(here, "..", "test", "vectors"), resolve(here, "..", "..", "protocol", "vectors")];
  const vecs = loadVectors(vecDirs);
  for (const { file, v } of vecs) { const e = checkVector(v); check(`vector ${file.replace(/\\/g, "/").split("/").slice(-3).join("/")}`, !e, e ?? ""); }
  if (!vecs.length) print("SKIP  no vector files found");

  const m = reliabilityMatrix();
  print("\nDecode reliability on synthetic captures (messages decoded / attempted; offsets 1-3 px, title-bar offset ~31 px, 3 backgrounds):");
  print("cell  scale  mode       ok/total");
  for (const r of m) {
    print(`${String(r.cell).padEnd(5)} ${String(r.scale).padEnd(6)} ${r.mode.padEnd(10)} ${r.ok}/${r.total}`);
    if (r.mode === "exact") check(`exact pixels, cell ${r.cell}`, r.ok === r.total);
  }
  print("\nRobustness (pixel-exact cells after degradation):");
  for (const r of robustnessCases()) print(`  ${r.name.padEnd(28)} ${r.ok}/${r.total}`);
  print(pass ? "\nSELFTEST PASS" : "\nSELFTEST FAIL");
  return pass;
}

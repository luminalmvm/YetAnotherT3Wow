#!/usr/bin/env node
// A second implementation of the T3Bridge outbound frame (PROTOCOL.md section 3), separate from
// addon/T3Bridge/Codec.lua. It cross-checks the vectors and renders them to PNG for decoder tests.
//
//   node scripts/dev/gen-vectors.js --check        verify protocol/vectors/*.json
//   node scripts/dev/gen-vectors.js --check --png  ...and write <name>.p<part>.png next to each
//
// The vectors themselves come from the Lua encoder: python addon/T3Bridge/test/run_tests.py --write-vectors
// Exit code 0 = every vector matches this implementation.
"use strict";
const fs = require("fs");
const path = require("path");
const zlib = require("zlib");

const VEC_DIR = path.resolve(__dirname, "..", "..", "protocol", "vectors");

// --- reference CRC-32 (bitwise, no table, unlike the Lua table version) ---------------------
function crc32(buf) {
  let crc = 0xffffffff;
  for (const b of buf) {
    crc ^= b;
    for (let k = 0; k < 8; k++) crc = crc & 1 ? (crc >>> 1) ^ 0xedb88320 : crc >>> 1;
  }
  return (crc ^ 0xffffffff) >>> 0;
}

// --- reference frame builder ---------------------------------------------------------------
const CAP = { 8: 7 * 32 - 18, 32: 31 * 32 - 18 };
function frames(sid, seq, msg, flags) {
  const rows = msg.length <= CAP[8] ? 8 : 32;
  const cap = CAP[rows];
  const chunks = [];
  if (rows === 8) chunks.push(msg);
  else for (let i = 0; i < msg.length; i += cap) chunks.push(msg.subarray(i, i + cap));
  return {
    rows,
    frames: chunks.map((c, k) => {
      const head = Buffer.alloc(14);
      head.write("T3", 0, "latin1");
      head[2] = 1; head[3] = flags;
      sid.copy(head, 4);
      head.writeUInt16BE(seq, 8);
      head[10] = k + 1; head[11] = chunks.length;
      head.writeUInt16BE(c.length, 12);
      const body = Buffer.concat([head, c]);
      const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(body));
      return Buffer.concat([body, crc]);
    }),
  };
}

function cells(frame, rows) {
  const out = [];
  for (let r = 0; r < rows; r++) {
    let s = "";
    for (let x = 0; x < 256; x++) {
      if (r === 0) { s += x % 2 === 0 ? "1" : "0"; continue; }
      const k = (r - 1) * 32 + (x >> 3);
      const b = k < frame.length ? frame[k] : 0;
      s += (b >> (7 - (x & 7))) & 1 ? "1" : "0";
    }
    out.push(s);
  }
  return out;
}

// --- PNG writer (RGB, no deps) -------------------------------------------------------------
function png(w, h, pixel) {
  const raw = Buffer.alloc((w * 3 + 1) * h);
  for (let y = 0; y < h; y++) {
    raw[y * (w * 3 + 1)] = 0;
    for (let x = 0; x < w; x++) {
      const [r, g, b] = pixel(x, y);
      const o = y * (w * 3 + 1) + 1 + x * 3;
      raw[o] = r; raw[o + 1] = g; raw[o + 2] = b;
    }
  }
  const chunk = (type, data) => {
    const len = Buffer.alloc(4); len.writeUInt32BE(data.length);
    const td = Buffer.concat([Buffer.from(type, "latin1"), data]);
    const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(td));
    return Buffer.concat([len, td, crc]);
  };
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4);
  ihdr[8] = 8; ihdr[9] = 2; ihdr[10] = 0; ihdr[11] = 0; ihdr[12] = 0;
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk("IHDR", ihdr), chunk("IDAT", zlib.deflateSync(raw)), chunk("IEND", Buffer.alloc(0)),
  ]);
}

// Matrix at physical (0,0) over a fake "game scene" gradient, like a real WGC capture.
function renderPng(cellRows, cell) {
  const rows = cellRows.length;
  const mw = 256 * cell, mh = rows * cell;
  const w = mw + 64, h = mh + 48;
  return png(w, h, (x, y) => {
    if (x < mw && y < mh) {
      const v = cellRows[Math.floor(y / cell)][Math.floor(x / cell)] === "1" ? 255 : 0;
      return [v, v, v];
    }
    return [40 + ((x * 3) % 90), 70 + ((y * 5) % 60), 110 + (((x + y) * 2) % 80)];
  });
}

// --- main ----------------------------------------------------------------------------------
const args = process.argv.slice(2);
const wantPng = args.includes("--png");
if (!args.includes("--check")) {
  console.log("usage: node gen-vectors.js --check [--png]");
  process.exit(2);
}
if (crc32(Buffer.from("123456789")) !== 0xcbf43926) throw new Error("reference crc broken");

const files = fs.readdirSync(VEC_DIR).filter((f) => f.endsWith(".json")).sort();
if (!files.length) { console.error("no vectors in", VEC_DIR); process.exit(1); }
let bad = 0, nParts = 0;
for (const f of files) {
  const v = JSON.parse(fs.readFileSync(path.join(VEC_DIR, f), "utf8"));
  const msg = Buffer.from(v.message_hex, "hex");
  const problems = [];
  if (Buffer.from(v.message_utf8, "utf8").toString("hex") !== v.message_hex) problems.push("message_utf8 != message_hex");
  const ref = frames(Buffer.from(v.sid_hex, "hex"), v.seq, msg, v.flags);
  if (ref.rows !== v.rows) problems.push(`rows ${v.rows} != ref ${ref.rows}`);
  if (ref.frames.length !== v.parts.length) problems.push(`parts ${v.parts.length} != ref ${ref.frames.length}`);
  ref.frames.forEach((fr, k) => {
    const p = v.parts[k];
    if (!p) return;
    nParts++;
    if (fr.toString("hex") !== p.frame_hex) problems.push(`part ${k + 1}: frame_hex mismatch`);
    if (fr.subarray(14, 14 + p.len).toString("hex") !== p.payload_hex) problems.push(`part ${k + 1}: payload mismatch`);
    const c = cells(fr, ref.rows);
    if (c.join("\n") !== p.cells.join("\n")) problems.push(`part ${k + 1}: cells mismatch`);
    if (wantPng) fs.writeFileSync(path.join(VEC_DIR, `${v.name}.p${k + 1}.png`), renderPng(p.cells, v.cell));
  });
  if (problems.length) { bad++; console.log("FAIL", f, problems.join("; ")); }
  else console.log("ok  ", f, `(${v.parts.length} part(s), ${v.rows} rows, cell ${v.cell})`);
}
console.log(`\n${files.length - bad}/${files.length} vectors match the reference implementation (${nParts} frames)`);
process.exit(bad ? 1 : 0);

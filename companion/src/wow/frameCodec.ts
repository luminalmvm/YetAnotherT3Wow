// Outbound frame format (PROTOCOL.md 3.1/3.2). Shared by decoder, selftest and the test encoder.

export const MAGIC0 = 0x54; // 'T'
export const MAGIC1 = 0x33; // '3'
export const VERSION = 1;
export const HEADER = 14;
export const OVERHEAD = 18;
export const WIDTH_CELLS = 256;
export const ROW_BYTES = 32;
export const ROWS_SHORT = 8;
export const ROWS_LONG = 32;
export const capacity = (rows: number) => (rows - 1) * ROW_BYTES - OVERHEAD;
export const CAP_SHORT = capacity(ROWS_SHORT); // 206
export const CAP_LONG = capacity(ROWS_LONG); // 974

const CRC_TABLE = (() => {
  const t = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c >>> 0;
  }
  return t;
})();

/** CRC-32/ISO-HDLC (zlib). crc32("123456789") = 0xCBF43926. */
export function crc32(buf: Uint8Array, start = 0, end = buf.length): number {
  let c = 0xffffffff;
  for (let k = start; k < end; k++) c = CRC_TABLE[(c ^ buf[k]) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

export interface Frame {
  flags: number;
  sid: Buffer; // 4 raw bytes
  seq: number;
  part: number;
  parts: number;
  payload: Buffer;
}

export type ParseResult = { ok: true; frame: Frame; totalBytes: number } | { ok: false; reason: string };

/** Header-only check: returns payload length if bytes 0..13 look like a v1 frame header. */
export function peekHeader(b: Uint8Array): { len: number; part: number; parts: number } | null {
  if (b.length < HEADER || b[0] !== MAGIC0 || b[1] !== MAGIC1 || b[2] !== VERSION) return null;
  const part = b[10], parts = b[11];
  const len = (b[12] << 8) | b[13];
  if (parts < 1 || part < 1 || part > parts) return null;
  return { len, part, parts };
}

export function parseFrame(b: Uint8Array): ParseResult {
  if (b.length < OVERHEAD) return { ok: false, reason: "short" };
  if (b[0] !== MAGIC0 || b[1] !== MAGIC1) return { ok: false, reason: "magic" };
  if (b[2] !== VERSION) return { ok: false, reason: "version" };
  const len = (b[12] << 8) | b[13];
  if (b.length < OVERHEAD + len) return { ok: false, reason: "len" };
  const want = ((b[14 + len] << 24) | (b[15 + len] << 16) | (b[16 + len] << 8) | b[17 + len]) >>> 0;
  if (crc32(b, 0, HEADER + len) !== want) return { ok: false, reason: "crc" };
  const seq = (b[8] << 8) | b[9];
  const part = b[10], parts = b[11];
  if (seq < 1) return { ok: false, reason: "seq" };
  if (parts < 1 || part < 1 || part > parts) return { ok: false, reason: "part" };
  return {
    ok: true,
    totalBytes: OVERHEAD + len,
    frame: { flags: b[3], sid: Buffer.from(b.subarray(4, 8)), seq, part, parts, payload: Buffer.from(b.subarray(HEADER, HEADER + len)) },
  };
}

export function buildFrame(sid: Uint8Array, seq: number, part: number, parts: number, payload: Uint8Array, flags = 0): Buffer {
  if (sid.length !== 4) throw new Error("sid must be 4 bytes");
  if (seq < 1 || seq > 65535) throw new Error("seq out of range");
  if (part < 1 || part > parts || parts > 255) throw new Error("bad part");
  const b = Buffer.alloc(OVERHEAD + payload.length);
  b[0] = MAGIC0; b[1] = MAGIC1; b[2] = VERSION; b[3] = flags & 0xff;
  Buffer.from(sid).copy(b, 4);
  b.writeUInt16BE(seq, 8);
  b[10] = part; b[11] = parts;
  b.writeUInt16BE(payload.length, 12);
  Buffer.from(payload).copy(b, HEADER);
  b.writeUInt32BE(crc32(b, 0, HEADER + payload.length), HEADER + payload.length);
  return b;
}

/** Splits a message into frames exactly like the addon (Codec.SplitMessage). */
export function framesForMessage(sid: Uint8Array, seq: number, msg: Uint8Array, flags = 0): { rows: number; frames: Buffer[] } {
  if (msg.length <= CAP_SHORT) return { rows: ROWS_SHORT, frames: [buildFrame(sid, seq, 1, 1, msg, flags)] };
  const chunks: Uint8Array[] = [];
  for (let k = 0; k < msg.length; k += CAP_LONG) chunks.push(msg.subarray(k, k + CAP_LONG));
  if (chunks.length > 255) throw new Error("message too long");
  return { rows: ROWS_LONG, frames: chunks.map((c, k) => buildFrame(sid, seq, k + 1, chunks.length, c, flags)) };
}

/** Cell value (0/1) at (row, x); row 0 is the sync row. */
export function cellAt(frame: Uint8Array, row: number, x: number): number {
  if (row === 0) return x % 2 === 0 ? 1 : 0;
  const k = (row - 1) * ROW_BYTES + (x >> 3);
  if (k >= frame.length) return 0;
  return (frame[k] >> (7 - (x & 7))) & 1;
}

export function cellStrings(frame: Uint8Array, rows: number): string[] {
  if (frame.length > (rows - 1) * ROW_BYTES) throw new Error("frame does not fit");
  const out: string[] = [];
  for (let r = 0; r < rows; r++) {
    let s = "";
    for (let x = 0; x < WIDTH_CELLS; x++) s += cellAt(frame, r, x) ? "1" : "0";
    out.push(s);
  }
  return out;
}

// ---------------------------------------------------------------------------------------------
// Commands (3.1)
// ---------------------------------------------------------------------------------------------

export type Command =
  | { kind: "hello"; proto?: string; addonVersion?: string; cell?: string; rows?: string; img?: string }
  | { kind: "focus"; tid: string }
  | { kind: "send"; tid: string; clientMsgId: string; text: string }
  | { kind: "model"; tid: string; modelId: string; effort?: string }
  | { kind: "intr"; tid: string }
  | { kind: "ans"; tid: string; rid: string; answer: string }
  | { kind: "hist"; tid: string; beforeIndex: number }
  | { kind: "open"; tid?: string }
  // PROTOCOL rev 1.3 (D17): image attachments.
  | { kind: "clip"; tid: string; quiet: boolean }
  | { kind: "shot"; tid: string }
  | { kind: "unstage"; tid: string; aid: string };

/** Splits on TAB; the last field of send/ans keeps any further tabs/newlines (split at most 3 times). */
export function splitFields(payload: string): string[] {
  const first = payload.indexOf("\t");
  const kind = first < 0 ? payload : payload.slice(0, first);
  const limit = kind === "send" || kind === "ans" ? 4 : Infinity;
  const out: string[] = [];
  let pos = 0;
  for (;;) {
    if (out.length === limit - 1) { out.push(payload.slice(pos)); break; }
    const t = payload.indexOf("\t", pos);
    if (t < 0) { out.push(payload.slice(pos)); break; }
    out.push(payload.slice(pos, t));
    pos = t + 1;
  }
  return out;
}

const TID = /^[A-Za-z0-9_-]{1,40}$/;
const ID64 = /^[A-Za-z0-9_.:/-]{1,64}$/;
const OPT = /^[A-Za-z0-9_.:-]{1,32}$/;
const AID = /^[A-Za-z0-9_-]{1,16}$/;

export function parseCommand(payload: string): { ok: true; cmd: Command } | { ok: false; reason: string } {
  const f = splitFields(payload);
  const need = (n: number) => f.length >= n;
  switch (f[0]) {
    case "hello": return { ok: true, cmd: { kind: "hello", proto: f[1], addonVersion: f[2], cell: f[3], rows: f[4], ...(f[5] !== undefined ? { img: f[5] } : {}) } };
    case "focus": return need(2) && TID.test(f[1]) ? { ok: true, cmd: { kind: "focus", tid: f[1] } } : { ok: false, reason: "focus: bad tid" };
    case "send": return need(4) && TID.test(f[1]) && f[2].length > 0 ? { ok: true, cmd: { kind: "send", tid: f[1], clientMsgId: f[2], text: f[3] } } : { ok: false, reason: "send: bad fields" };
    case "model": {
      // Optional 4th field (PROTOCOL D14): the reasoning effort to set together with the model.
      if (!(need(3) && TID.test(f[1]) && ID64.test(f[2]))) return { ok: false, reason: "model: bad fields" };
      const effort = f[3] !== undefined && f[3] !== "" ? f[3] : undefined;
      if (effort !== undefined && !OPT.test(effort)) return { ok: false, reason: "model: bad effort" };
      return { ok: true, cmd: { kind: "model", tid: f[1], modelId: f[2], ...(effort ? { effort } : {}) } };
    }
    case "intr": return need(2) && TID.test(f[1]) ? { ok: true, cmd: { kind: "intr", tid: f[1] } } : { ok: false, reason: "intr: bad tid" };
    case "ans": return need(4) && TID.test(f[1]) && ID64.test(f[2]) ? { ok: true, cmd: { kind: "ans", tid: f[1], rid: f[2], answer: f[3] } } : { ok: false, reason: "ans: bad fields" };
    case "hist": {
      const n = Number(f[2]);
      return need(3) && TID.test(f[1]) && Number.isInteger(n) && n >= 0 ? { ok: true, cmd: { kind: "hist", tid: f[1], beforeIndex: n } } : { ok: false, reason: "hist: bad fields" };
    }
    case "open": return { ok: true, cmd: { kind: "open", tid: f[1] && TID.test(f[1]) ? f[1] : undefined } };
    case "clip": return need(2) && TID.test(f[1]) ? { ok: true, cmd: { kind: "clip", tid: f[1], quiet: f[2] === "1" } } : { ok: false, reason: "clip: bad tid" };
    case "shot": return need(2) && TID.test(f[1]) ? { ok: true, cmd: { kind: "shot", tid: f[1] } } : { ok: false, reason: "shot: bad tid" };
    case "unstage": return need(3) && TID.test(f[1]) && AID.test(f[2]) ? { ok: true, cmd: { kind: "unstage", tid: f[1], aid: f[2] } } : { ok: false, reason: "unstage: bad fields" };
    default: return { ok: false, reason: `unknown command ${JSON.stringify((f[0] ?? "").slice(0, 16))}` };
  }
}

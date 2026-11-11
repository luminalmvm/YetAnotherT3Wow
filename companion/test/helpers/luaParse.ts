// Strict parser for the live.lua subset (PROTOCOL.md 2.3 rule 4): `Name = <expr>` statements, table
// constructors, short strings with Lua 5.1 escapes, integers, true/false/nil, `--` comments.
// Rejects anything else (function calls, operators, long brackets, \x / \u / \z escapes).
export type LuaValue = string | number | boolean | null | LuaTable;
export interface LuaTable { array: LuaValue[]; hash: Record<string, LuaValue> }

export function parseLuaChunk(src: Buffer | string): Record<string, LuaValue> {
  const b = typeof src === "string" ? Buffer.from(src, "utf8") : src;
  let i = 0;
  const err = (m: string): never => { throw new Error(`${m} at byte ${i}`); };
  const ws = () => {
    for (;;) {
      while (i < b.length && (b[i] === 0x20 || b[i] === 0x09 || b[i] === 0x0a || b[i] === 0x0d)) i++;
      if (b[i] === 0x2d && b[i + 1] === 0x2d) {
        if (b[i + 2] === 0x5b && b[i + 3] === 0x5b) err("long comment not allowed");
        while (i < b.length && b[i] !== 0x0a) i++;
        continue;
      }
      return;
    }
  };
  const name = (): string => {
    const m = /^[A-Za-z_][A-Za-z0-9_]*/.exec(b.subarray(i, i + 64).toString("latin1"));
    if (!m) err("name expected");
    i += m![0].length;
    return m![0];
  };
  const str = (): string => {
    const q = b[i++];
    const out: number[] = [];
    for (;;) {
      if (i >= b.length) err("unterminated string");
      const c = b[i++];
      if (c === q) break;
      if (c === 0x0a || c === 0x0d) err("newline in string");
      if (c !== 0x5c) { out.push(c); continue; }
      const e = b[i++];
      switch (e) {
        case 0x6e: out.push(10); break;
        case 0x72: out.push(13); break;
        case 0x74: out.push(9); break;
        case 0x5c: out.push(0x5c); break;
        case 0x22: out.push(0x22); break;
        case 0x27: out.push(0x27); break;
        default:
          if (e >= 0x30 && e <= 0x39) {
            let v = e - 0x30, d = 1;
            while (d < 3 && b[i] >= 0x30 && b[i] <= 0x39) { v = v * 10 + (b[i] - 0x30); i++; d++; }
            if (v > 255) err("escape > 255");
            out.push(v);
          } else err(`escape \\${String.fromCharCode(e)} not allowed`);
      }
    }
    return Buffer.from(out).toString("utf8");
  };
  const value = (): LuaValue => {
    ws();
    const c = b[i];
    if (c === 0x22 || c === 0x27) return str();
    if (c === 0x7b) return table();
    if (c === 0x5b) err("long string not allowed");
    const m = /^-?[0-9]+/.exec(b.subarray(i, i + 24).toString("latin1"));
    if (m) { i += m[0].length; if (b[i] === 0x2e || b[i] === 0x65 || b[i] === 0x78) err("only integers allowed"); return Number(m[0]); }
    const n = name();
    if (n === "true") return true;
    if (n === "false") return false;
    if (n === "nil") return null;
    return err(`unexpected name ${n}`);
  };
  const table = (): LuaTable => {
    i++; // {
    const t: LuaTable = { array: [], hash: {} };
    for (;;) {
      ws();
      if (b[i] === 0x7d) { i++; return t; }
      const save = i;
      let key: string | null = null;
      if (/[A-Za-z_]/.test(String.fromCharCode(b[i]))) {
        const n = name(); ws();
        if (b[i] === 0x3d) { i++; key = n; } else i = save;
      }
      const v = value();
      if (key !== null) t.hash[key] = v; else t.array.push(v);
      ws();
      if (b[i] === 0x2c || b[i] === 0x3b) { i++; continue; }
      if (b[i] === 0x7d) { i++; return t; }
      err("',' or '}' expected");
    }
  };
  const env: Record<string, LuaValue> = {};
  for (;;) {
    ws();
    if (i >= b.length) break;
    const n = name(); ws();
    if (b[i] !== 0x3d) err("'=' expected");
    i++;
    env[n] = value();
  }
  return env;
}

/** Converts a parsed table to plain JS (arrays where only array part, objects otherwise). */
export function toJs(v: LuaValue): any {
  if (v === null || typeof v !== "object") return v;
  const keys = Object.keys(v.hash);
  if (!keys.length) return v.array.map(toJs);
  const o: any = {};
  for (const k of keys) o[k] = toJs(v.hash[k]);
  if (v.array.length) o.__array = v.array.map(toJs);
  return o;
}

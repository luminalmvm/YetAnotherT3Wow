// Lua 5.1 literal serialization for live.lua (PROTOCOL.md 2.3 rule 3/4).
// Strings: double quotes; escapes \\ \" \n \r \t and \ddd (exactly 3 decimal digits) for other bytes < 0x20 and 0x7F.
// Never \x.., \u{..}, \z or long brackets. Bytes >= 0x80 are raw UTF-8 by default, or \ddd with asciiOnly.

export interface LuaOptions { asciiOnly?: boolean }

/**
 * Named fields for a mixed Lua table. As the LAST element of an array, `["img", "alt", new LuaFields({s: 3})]`
 * serializes to `{"img","alt",s=3}` (PROTOCOL rev 1.3 image segments).
 */
export class LuaFields { constructor(readonly fields: Record<string, unknown>) {} }

const ESC: Record<number, string> = { 0x5c: "\\\\", 0x22: '\\"', 0x0a: "\\n", 0x0d: "\\r", 0x09: "\\t" };

function ddd(b: number): string { return "\\" + String(b).padStart(3, "0"); }

/** Returns the Lua string literal (including quotes) as a JS string. Non-ASCII chars stay as chars unless asciiOnly. */
export function luaString(s: string, o: LuaOptions = {}): string {
  let out = '"';
  for (const ch of s) {
    const cp = ch.codePointAt(0)!;
    if (cp < 0x80) {
      const e = ESC[cp];
      if (e) out += e;
      else if (cp < 0x20 || cp === 0x7f) out += ddd(cp);
      else out += ch;
    } else if (cp >= 0xd800 && cp <= 0xdfff) {
      // lone surrogate: not representable in UTF-8
      out += o.asciiOnly ? "\\239\\191\\189" : "�";
    } else if (o.asciiOnly) {
      for (const b of Buffer.from(ch, "utf8")) out += ddd(b);
    } else out += ch;
  }
  return out + '"';
}

const IDENT = /^[A-Za-z_][A-Za-z0-9_]*$/;
const RESERVED = new Set("and break do else elseif end false for function if in local nil not or repeat return then true until while".split(" "));

export function luaKey(k: string): string {
  if (!IDENT.test(k) || RESERVED.has(k)) throw new Error(`invalid Lua key: ${k}`);
  return k;
}

export function luaNumber(n: number): string {
  if (!Number.isFinite(n)) return "0";
  const i = Math.trunc(n);
  if (Math.abs(i) > Number.MAX_SAFE_INTEGER) throw new Error("integer out of range");
  return String(i);
}

/**
 * Serializes plain data: arrays -> {a,b}, objects -> {k=v}, strings, integers, booleans; null/undefined
 * object fields are omitted (`nil`), null array elements become `nil`.
 */
export function toLua(v: unknown, o: LuaOptions = {}): string {
  if (v === null || v === undefined) return "nil";
  if (typeof v === "string") return luaString(v, o);
  if (typeof v === "number") return luaNumber(v);
  if (typeof v === "boolean") return v ? "true" : "false";
  if (Array.isArray(v)) {
    const last = v[v.length - 1];
    if (last instanceof LuaFields) {
      const items = v.slice(0, -1).map((x) => toLua(x, o));
      for (const [k, x] of Object.entries(last.fields)) if (x !== undefined && x !== null) items.push(`${luaKey(k)}=${toLua(x, o)}`);
      return "{" + items.join(",") + "}";
    }
    return "{" + v.map((x) => toLua(x, o)).join(",") + "}";
  }
  if (typeof v === "object") {
    const parts: string[] = [];
    for (const [k, x] of Object.entries(v as Record<string, unknown>)) {
      if (x === undefined || x === null) continue;
      parts.push(`${luaKey(k)}=${toLua(x, o)}`);
    }
    return "{" + parts.join(",") + "}";
  }
  throw new Error(`cannot serialize ${typeof v} to Lua`);
}

/** Inverse of luaString for tests: parses one Lua 5.1 short string literal body (without quotes) to bytes. */
export function parseLuaStringBody(body: string): Buffer {
  const bytes: number[] = [];
  const src = Buffer.from(body, "utf8");
  for (let k = 0; k < src.length; k++) {
    const b = src[k];
    if (b !== 0x5c) { bytes.push(b); continue; }
    const n = src[++k];
    switch (n) {
      case 0x6e: bytes.push(10); break; // n
      case 0x72: bytes.push(13); break; // r
      case 0x74: bytes.push(9); break; // t
      case 0x5c: bytes.push(0x5c); break;
      case 0x22: bytes.push(0x22); break;
      case 0x27: bytes.push(0x27); break;
      default:
        if (n >= 0x30 && n <= 0x39) {
          let v = 0; let d = 0;
          while (d < 3 && src[k] >= 0x30 && src[k] <= 0x39) { v = v * 10 + (src[k] - 0x30); k++; d++; }
          k--;
          if (v > 255) throw new Error("escape too large");
          bytes.push(v);
        } else throw new Error(`unsupported escape \\${String.fromCharCode(n)}`);
    }
  }
  return Buffer.from(bytes);
}

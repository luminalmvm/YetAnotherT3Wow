import { readFileSync, existsSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";
import { luaString, parseLuaStringBody, toLua } from "../src/wow/luaEscape.js";
import { parseLuaChunk, toJs } from "./helpers/luaParse.js";

describe("luaString", () => {
  it("escapes the Lua 5.1 set and control bytes as \\ddd", () => {
    expect(luaString('a"b\\c\n\r\t')).toBe('"a\\"b\\\\c\\n\\r\\t"');
    expect(luaString("\x00\x01\x1f\x7f")).toBe('"\\000\\001\\031\\127"');
    expect(luaString("x\x007")).toBe('"x\\0007"'); // 3 digits always, so a following digit is safe
  });
  it("keeps raw UTF-8 by default and escapes it with asciiOnly", () => {
    expect(luaString("åä✓")).toBe('"åä✓"');
    expect(luaString("å", { asciiOnly: true })).toBe('"\\195\\165"');
  });
  it("never emits forbidden escape forms", () => {
    let all = "";
    for (let c = 0; c < 0x2600; c++) if (c < 0xd800 || c > 0xdfff) all += String.fromCodePoint(c);
    for (const ascii of [false, true]) {
      const s = luaString(all, { asciiOnly: ascii });
      expect(s).not.toMatch(/\\x|\\u\{|\\z|\[\[/);
    }
  });
  it("round-trips every byte value", () => {
    const bytes = Buffer.from(Array.from({ length: 256 }, (_, k) => k));
    // Bytes >= 0x80 alone are not valid UTF-8 in a JS string, so test via a latin1 string for 0..127
    const ascii = bytes.subarray(0, 128).toString("latin1");
    const lit = luaString(ascii);
    expect(parseLuaStringBody(lit.slice(1, -1)).equals(bytes.subarray(0, 128))).toBe(true);
    const uni = "héllo wörld ✓ 日本 😀 |c|r";
    for (const asciiOnly of [false, true]) {
      const l = luaString(uni, { asciiOnly });
      expect(parseLuaStringBody(l.slice(1, -1)).toString("utf8")).toBe(uni);
    }
  });
  it("replaces lone surrogates", () => {
    expect(luaString("a\ud800b")).toBe('"a�b"');
  });
});

describe("toLua", () => {
  it("serializes tables, omits nil fields, rejects bad keys", () => {
    expect(toLua({ a: 1, b: "x", c: null, d: [1, 2], e: true })).toBe('{a=1,b="x",d={1,2},e=true}');
    expect(() => toLua({ "bad key": 1 })).toThrow();
    expect(() => toLua({ end: 1 })).toThrow();
    expect(toLua(3.9)).toBe("3");
  });
});

describe("luaParse helper", () => {
  it("parses the addon's reference fixture (cross-check of the format)", () => {
    const f = resolve(__dirname, "..", "..", "protocol", "fixtures", "live.sample.lua");
    if (!existsSync(f)) return;
    const env = parseLuaChunk(readFileSync(f));
    const t = toJs(env.T3B_IN as any);
    expect(t.v).toBe(1);
    expect(env.T3B_IN_END).toBe(t.seq);
    expect(Array.isArray(t.threads)).toBe(true);
    expect(t.focus.msgs.length).toBeGreaterThan(0);
  });
  it("rejects function calls and \\x escapes", () => {
    expect(() => parseLuaChunk('T3B_IN=print("x")')).toThrow();
    expect(() => parseLuaChunk('T3B_IN={a="\\x41"}')).toThrow();
  });
});

import { describe, expect, it } from "vitest";
import { cleanInline, markdownToSegs, transliterate, truncateMarkdownTail, utf8Head, utf8Len, utf8Tail } from "../src/model/markdown.js";

describe("markdownToSegs", () => {
  it("splits fenced code from paragraphs and strips fences", () => {
    const md = "Here is the fix:\n\n```ts\nconst x = 1;\n  indented();\n```\n\nDone **now**.";
    expect(markdownToSegs(md)).toEqual([["p", "Here is the fix:"], ["c", "const x = 1;\n  indented();"], ["p", "Done now."]]);
  });
  it("handles ~~~ fences, unterminated fences (streaming) and inline triple backticks", () => {
    expect(markdownToSegs("a\n~~~\ncode\n~~~")).toEqual([["p", "a"], ["c", "code"]]);
    expect(markdownToSegs("a\n```py\nprint(1)")).toEqual([["p", "a"], ["c", "print(1)"]]);
    expect(markdownToSegs("use ```inline``` here")).toEqual([["p", "use ```inline``` here"]]);
  });
  it("keeps pipes, tabs and backslashes raw (the addon escapes |)", () => {
    expect(markdownToSegs("| a | b |\n|---|---|\n| 1\t| \\n |")).toEqual([["p", "| a | b |\n|---|---|\n| 1\t| \\n |"]]);
  });
  it("does not transliterate inside code when disabled", () => {
    expect(markdownToSegs("```\n“x”\n```", { transliterate: false })).toEqual([["c", "“x”"]]);
    expect(markdownToSegs("```\n“x”\n```")).toEqual([["c", '"x"']]);
  });
});

describe("cleanInline", () => {
  it("removes emphasis/heading markers and expands links", () => {
    expect(cleanInline("## Title\n**bold** and *it* and ~~old~~ [docs](https://x.y/z) ![img](a.png)\n* item")).toBe("Title\nbold and it and old docs (https://x.y/z) [image: img]\n- item");
    expect(cleanInline("2 * 3 * 4")).toBe("2 * 3 * 4");
  });
});

describe("transliterate", () => {
  it("maps typographic punctuation and symbols, keeps Latin-1 letters", () => {
    expect(transliterate("“Hi” — it’s… → ✓ ✅ ❌ • ≤ ≥")).toBe('"Hi" -- it\'s... -> [ok] [ok] [x] * <= >=');
    expect(transliterate("Grüße åäö ñ ç")).toBe("Grüße åäö ñ ç");
    expect(transliterate("ơ ư Ș")).toBe("o u S");
    expect(transliterate("日本😀​")).toBe("??");
  });
});

describe("utf8 helpers and tail truncation", () => {
  it("never splits code points", () => {
    expect(utf8Head("aåb", 2)).toBe("a");
    expect(utf8Tail("aåb", 2)).toBe("b");
    expect(utf8Len("å✓")).toBe(5);
  });
  it("keeps the tail, marks truncation and re-opens a cut code fence", () => {
    const md = "intro\n```\n" + "line\n".repeat(3000) + "```\nend";
    const [t, cut] = truncateMarkdownTail(md, 2000);
    expect(cut).toBe(true);
    expect(utf8Len(t)).toBeLessThanOrEqual(2000);
    expect(t.endsWith("end")).toBe(true);
    const segs = markdownToSegs(t);
    expect(segs.some((s) => s[0] === "c")).toBe(true);
    expect(truncateMarkdownTail("short", 100)).toEqual(["short", false]);
  });
});

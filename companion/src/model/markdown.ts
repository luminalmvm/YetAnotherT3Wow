// Markdown -> WoW-friendly segments {p,c} (PROTOCOL.md D7) and transliteration of glyphs the
// default (enUS) WoW fonts lack.

export type Seg = [kind: "p" | "c", text: string];

const MAP: Record<string, string> = {
  "‘": "'", "’": "'", "‚": "'", "‛": "'", "′": "'",
  "“": '"', "”": '"', "„": '"', "‟": '"', "″": '"', "«": "<<", "»": ">>",
  "‐": "-", "‑": "-", "‒": "-", "–": "-", "—": "--", "―": "--", "−": "-",
  "…": "...", "•": "*", "‣": ">", "●": "*", "○": "o", "▪": "*", "◦": "o", "⁃": "-",
  "→": "->", "←": "<-", "↑": "^", "↓": "v", "↔": "<->", "⇒": "=>", "⇐": "<=", "⟶": "->",
  "≤": "<=", "≥": ">=", "≠": "!=", "≈": "~", "×": "x", "÷": "/", "∗": "*",
  "✓": "[ok]", "✔": "[ok]", "✅": "[ok]", "☑": "[x]", "☐": "[ ]", "✗": "[x]", "✘": "[x]", "❌": "[x]", "❎": "[x]",
  "⚠": "(!)", "❗": "!", "❓": "?", "ℹ": "(i)", "⭐": "*", "✨": "*", "\u{1F680}": "", "\u{1F389}": "", "\u{1F44D}": "(+1)", "\u{1F44E}": "(-1)",
  "\u{1F525}": "", "\u{1F4A1}": "(idea)", "\u{1F6A7}": "(wip)", "\u{1F41B}": "(bug)", "\u{1F4DD}": "", "\u{1F4E6}": "", "\u{1F527}": "", "\u{1F50D}": "",
  "─": "-", "━": "-", "│": "|", "┃": "|", "┌": "+", "┐": "+", "└": "+", "┘": "+", "├": "+", "┤": "+",
  "┬": "+", "┴": "+", "┼": "+", "═": "=", "║": "|", "╔": "+", "╗": "+", "╚": "+", "╝": "+", "╠": "+", "╣": "+", "╦": "+", "╩": "+", "╬": "+",
  " ": " ", " ": " ", " ": " ", " ": " ", " ": " ", " ": " ", "　": " ",
  "​": "", "‌": "", "‍": "", "⁠": "", "﻿": "", "️": "", "︎": "",
  "·": "*", "™": "(TM)", "©": "(c)", "®": "(R)", "€": "EUR", "°": " deg",
};

/** Characters the enUS WoW fonts render: printable ASCII, Latin-1 Supplement, Latin Extended-A, plus \n \t. */
function isSafe(cp: number): boolean {
  return (cp >= 0x20 && cp < 0x7f) || cp === 0x0a || cp === 0x09 || (cp >= 0xa1 && cp <= 0x17f);
}

export function transliterate(s: string): string {
  let out = "";
  for (const ch of s) {
    const cp = ch.codePointAt(0)!;
    if (isSafe(cp)) { out += ch; continue; }
    if (cp === 0x0d) continue;
    const m = MAP[ch];
    if (m !== undefined) { out += m; continue; }
    if (cp < 0x20) { out += " "; continue; }
    // Strip diacritics where the base letter is safe (e.g. Vietnamese, Latin Extended-B).
    const base = ch.normalize("NFKD").replace(/[̀-ͯ]/g, "");
    if (base && [...base].every((c) => isSafe(c.codePointAt(0)!))) { out += base; continue; }
    if (cp >= 0x1f000 && cp <= 0x1faff) continue; // other emoji: drop
    if (cp >= 0x2600 && cp <= 0x27bf) continue; // misc symbols/dingbats: drop
    out += "?";
  }
  return out;
}

/**
 * Inline markdown cleanup for a paragraph (bold/italic markers, links, headings, images).
 * keepMarks (PROTOCOL D14): keep `**bold**` (`__x__` becomes `**x**`) and headings as "# text" so the
 * addon can style them. Inline `code` and "- " / "1. " list items are kept either way.
 */
export function cleanInline(text: string, keepMarks = false): string {
  return text
    .split("\n")
    .map((line) => {
      let l = line;
      l = l.replace(/^(\s{0,3})#{1,6}\s+(.*?)\s*#*\s*$/, keepMarks ? "# $2" : "$1$2");
      l = l.replace(/!\[([^\]]*)\]\(([^)]+)\)/g, "[image: $1]");
      l = l.replace(/\[([^\]]+)\]\((https?:[^)\s]+)\)/g, (_m, t, u) => (t === u ? u : `${t} (${u})`));
      l = l.replace(/\[([^\]]+)\]\(([^)]+)\)/g, "$1");
      l = l.replace(/(\*\*|__)(?=\S)(.+?)(?<=\S)\1/g, keepMarks ? "**$2**" : "$2");
      l = l.replace(/(^|[^*\w])\*(?=\S)([^*\n]+?)(?<=\S)\*(?!\*)/g, "$1$2");
      l = l.replace(/~~(?=\S)(.+?)(?<=\S)~~/g, "$1");
      l = l.replace(/^(\s*)[*+]\s+/, "$1- ");
      l = l.replace(/^\s*(?:-{3,}|\*{3,}|_{3,})\s*$/, "----");
      return l;
    })
    .join("\n");
}

export interface SegmentOptions { transliterate?: boolean; keepMarks?: boolean }

/**
 * Splits markdown into ordered segments: fenced code blocks (``` or ~~~) become "c" (without fences),
 * everything else "p" (inline-cleaned). An unterminated fence runs to the end (streaming output).
 */
export function markdownToSegs(md: string, o: SegmentOptions = {}): Seg[] {
  const tr = o.transliterate ?? true;
  const fix = (s: string) => (tr ? transliterate(s) : s.replace(/\r/g, ""));
  const lines = md.replace(/\r\n?/g, "\n").split("\n");
  const segs: Seg[] = [];
  let para: string[] = [];
  let code: string[] | null = null;
  let fence = "";
  const flushPara = () => {
    const t = cleanInline(para.join("\n"), o.keepMarks).replace(/^\n+|\s+$/g, "");
    if (t.length) segs.push(["p", fix(t)]);
    para = [];
  };
  for (const line of lines) {
    if (code) {
      const m = /^\s{0,3}(`{3,}|~{3,})\s*$/.exec(line);
      if (m && m[1][0] === fence[0] && m[1].length >= fence.length) {
        segs.push(["c", fix(code.join("\n"))]);
        code = null;
      } else code.push(line);
      continue;
    }
    const open = /^\s{0,3}(`{3,}|~{3,})(.*)$/.exec(line);
    if (open && !(open[1][0] === "`" && open[2].includes("`"))) {
      flushPara();
      fence = open[1];
      code = [];
      continue;
    }
    para.push(line);
  }
  if (code) segs.push(["c", fix(code.join("\n"))]);
  flushPara();
  return segs;
}

/** Number of UTF-8 bytes. */
export function utf8Len(s: string): number { return Buffer.byteLength(s, "utf8"); }

/** Longest prefix within maxBytes that does not split a code point. */
export function utf8Head(s: string, maxBytes: number): string {
  const b = Buffer.from(s, "utf8");
  if (b.length <= maxBytes) return s;
  let cut = maxBytes;
  while (cut > 0 && (b[cut] & 0xc0) === 0x80) cut--;
  return b.subarray(0, cut).toString("utf8");
}

/** Longest suffix within maxBytes that does not split a code point. */
export function utf8Tail(s: string, maxBytes: number): string {
  const b = Buffer.from(s, "utf8");
  if (b.length <= maxBytes) return s;
  let start = b.length - maxBytes;
  while (start < b.length && (b[start] & 0xc0) === 0x80) start++;
  return b.subarray(start).toString("utf8");
}

/**
 * Keeps the tail of a long markdown message within maxBytes. Re-opens a code fence if the cut fell
 * inside one, so the kept part still renders as code. Returns [text, truncated].
 */
export function truncateMarkdownTail(md: string, maxBytes: number): [string, boolean] {
  if (utf8Len(md) <= maxBytes) return [md, false];
  const marker = "(...earlier text cut...)\n";
  let tail = utf8Tail(md, Math.max(0, maxBytes - utf8Len(marker) - 4));
  // start at a line boundary when possible
  const nl = tail.indexOf("\n");
  if (nl >= 0 && nl < 200) tail = tail.slice(nl + 1);
  const head = md.slice(0, md.length - tail.length);
  const fences = (head.match(/^\s{0,3}(`{3,}|~{3,})/gm) ?? []).length;
  return [(fences % 2 === 1 ? marker + "```\n" : marker) + tail, true];
}

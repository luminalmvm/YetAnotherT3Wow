#!/usr/bin/env node
// Generates protocol/fixtures/live.sample.lua (the reference snapshot) and
// addon/T3Bridge/Demo.lua (the same snapshot wrapped in a function for `/t3 demo`).
// Also contains the reference Lua-5.1 string escaper described in PROTOCOL.md §2.3.
// Usage: node scripts/dev/make-fixture.js
"use strict";
const fs = require("fs");
const path = require("path");

const ROOT = path.resolve(__dirname, "..", "..");
const TS = 1794393000; // fixed "now" of the fixture (2026-11-11T..Z); /t3 demo rebases it to time()

// ---- Lua 5.1 literal writer (PROTOCOL.md §2.3) ------------------------------------------
function luaStr(s) {
  const b = Buffer.from(String(s), "utf8");
  let out = '"';
  for (const c of b) {
    if (c === 0x5c) out += "\\\\";
    else if (c === 0x22) out += '\\"';
    else if (c === 0x0a) out += "\\n";
    else if (c === 0x0d) out += "\\r";
    else if (c === 0x09) out += "\\t";
    else if (c < 0x20 || c === 0x7f) out += "\\" + String(c).padStart(3, "0");
    else out += String.fromCharCode(c); // raw byte; re-encoded below as latin1
  }
  return out + '"';
}
function luaVal(v, ind) {
  if (v === null || v === undefined) return "nil";
  if (typeof v === "boolean") return v ? "true" : "false";
  if (typeof v === "number") { if (!Number.isInteger(v)) throw new Error("ints only"); return String(v); }
  if (typeof v === "string") return luaStr(v);
  if (Array.isArray(v)) {
    const nl = v.length && typeof v[0] === "object" && !Array.isArray(v[0]) ? "\n" + ind + " " : "";
    return "{" + nl + v.map((x) => luaVal(x, ind + " ")).join("," + nl) + "}";
  }
  // object: keep key order; nil fields are written explicitly (valid Lua, documents optional fields)
  return "{" + Object.entries(v).map(([k, x]) => `${k}=${luaVal(x, ind + " ")}`).join(",") + "}";
}
// luaStr emits raw UTF-8 bytes as latin1 chars; write the final text back as latin1 to get bytes.
function writeLuaFile(file, text) { fs.writeFileSync(file, Buffer.from(text, "latin1")); }

// ---- content ---------------------------------------------------------------------------
const threads = [
  { id: "a1b2c3d4", title: "Fix flaky login test in auth.spec.ts", st: "running", need: "approval", t0: TS - 754, t1: null, model: "Opus 5.5", proj: "t3code-web" },
  { id: "b2c3d4e5", title: "Add dark mode toggle to the settings page", st: "running", need: null, t0: TS - 192, t1: null, model: "Sonnet 5.5", proj: "t3code-web" },
  { id: "c3d4e5f6", title: "Migrate CI from Travis to GitHub Actions", st: "running", need: "input", t0: TS - 3725, t1: null, model: "Opus 5.5", proj: "infra" },
  { id: "d4e5f6a7", title: "Write release notes for v2.3 — “Aurora”", st: "completed", need: null, t0: TS - 1500, t1: TS - 420, model: "Haiku 5.5", proj: "docs" },
  { id: "e5f6a7b8", title: "Upgrade to React 19 and fix type errors | strict mode", st: "failed", need: null, t0: TS - 2400, t1: TS - 900, model: "Sonnet 5.5", proj: "t3code-web" },
  { id: "f6a7b8c9", title: "Profile the slow dashboard query (Postgres EXPLAIN)", st: "stopped", need: null, t0: TS - 5000, t1: TS - 1100, model: "Opus 5.5", proj: "api" },
  { id: "a7b8c9d0", title: "Refactor auth middleware into its own package", st: "idle", need: null, t0: TS - 86400, t1: TS - 80000, model: "Opus 5.5", proj: "api" },
];

const P = (t) => ["p", t];
const C = (t) => ["c", t];
const convo = [
  ["u", [P("The login test in auth.spec.ts fails about 1 in 5 runs on CI. Can you find out why and fix it?")]],
  ["a", [P("I'll start by reading the test and running it in a loop to reproduce the flake.")]],
  ["t", [P("Read file: tests/auth.spec.ts (142 lines)")]],
  ["t", [P("Ran: npx vitest run tests/auth.spec.ts --repeat 20\n17 passed, 3 failed")]],
  ["a", [P("Reproduced: 3 of 20 runs fail. The failure is always the same assertion:"), C("AssertionError: expected 'pending' to equal 'authenticated'\n  at tests/auth.spec.ts:88:31")]],
  ["a", [P("Line 88 checks the session state right after `login()` resolves. Let me look at `login()`.")]],
  ["t", [P("Read file: src/auth/session.ts (210 lines)")]],
  ["a", [P("Found it. `login()` resolves when the HTTP request finishes, but the session store is updated in a microtask scheduled by the `onAuthChange` listener:"), C("export async function login(user: string, pass: string) {\n  const res = await api.post(\"/login\", { user, pass });\n  emitter.emit(\"auth\", res.token); // listener updates the store later\n  return res;\n}"), P("So the test races the listener. On a loaded CI box the listener sometimes runs after the assertion.")]],
  ["u", [P("Makes sense. Should we fix the test or the code?")]],
  ["a", [P("The code. Callers reasonably expect the session to be ready once `login()` resolves — the test is just the first caller to notice. I propose awaiting the store update inside `login()`:"), C("export async function login(user: string, pass: string) {\n  const res = await api.post(\"/login\", { user, pass });\n  await store.setToken(res.token); // resolves after state === \"authenticated\"\n  emitter.emit(\"auth\", res.token);\n  return res;\n}")]],
  ["u", [P("Go ahead.")]],
  ["t", [P("Edited: src/auth/session.ts (+3 −2)")]],
  ["t", [P("Edited: src/auth/store.ts (+11 −1)")]],
  ["a", [P("`store.setToken` now returns a promise:"), C("setToken(token: string): Promise<void> {\n  this.token = token;\n  this.state = \"authenticated\";\n  return new Promise((resolve) => queueMicrotask(resolve));\n}")]],
  ["t", [P("Ran: npx tsc --noEmit\nsrc/auth/logout.ts:14:5 - error TS2322: Type 'Promise<void>' is not assignable to type 'void'.")]],
  ["a", [P("One type error in `logout.ts`, which overrides `setToken`. Updating its signature too.")]],
  ["t", [P("Edited: src/auth/logout.ts (+1 −1)")]],
  ["t", [P("Ran: npx tsc --noEmit\n(no errors)")]],
  ["s", [P("Context compacted: 18 earlier tool results were summarized.")]],
  ["u", [P("While you're in there — the test file uses a hard-coded password \"hunter2\\n\" with a stray backslash. Clean that up?")]],
  ["a", [P("Sure. The literal is \"hunter2\\\\n\" in the source, i.e. a backslash followed by n, not a newline. It only worked because the mock accepts any password. Replacing it with a named fixture:"), C("const TEST_USER = { user: \"ada\", pass: \"correct horse battery staple\" };\n// was: login(\"ada\", \"hunter2\\\\n\")\nawait login(TEST_USER.user, TEST_USER.pass);")]],
  ["t", [P("Edited: tests/auth.spec.ts (+4 −3)")]],
  ["a", [P("Next I want to check the other callers of `login()` so nothing depends on the old fire-and-forget behaviour.")]],
  ["t", [P("Searched: \"login(\" in src/ — 6 matches in 4 files")]],
  ["a", [P("# Call sites of login()\nAll six call sites either `await` the result or ignore it, so making it wait slightly longer is **safe**. Summary:\n- `src/pages/Login.tsx` — awaits, then navigates\n- `src/pages/Signup.tsx` — awaits after `register()`\n  (continuation line of the same item)\n- `src/cli/auth.ts` — awaits, prints \"Logged in as …\"\n  - nested: **fire-and-forget** in `src/hooks/useAutoLogin.ts` (fine)\n1. tests/auth.spec.ts ×2\n2. a stray ** marker and a lone ` backtick stay literal")]],
  ["u", [P("Great. Also add a regression test that would have caught the race.")]],
  ["a", [P("Here's a test that delays the listener with a fake scheduler so the race is deterministic instead of 1-in-5:"), C("it(\"session is authenticated as soon as login() resolves\", async () => {\n  vi.useFakeTimers();\n  emitter.on(\"auth\", () => new Promise((r) => setTimeout(r, 50)));\n  await login(TEST_USER.user, TEST_USER.pass);\n  expect(store.state).toBe(\"authenticated\");\n  vi.useRealTimers();\n});")]],
  ["t", [P("Edited: tests/auth.spec.ts (+9 −0)")]],
  ["u", [P("What about the table output in the CI log? Paste the summary as a table please.")]],
  ["a", [P("Here's last night's CI summary for this suite (pipes and tabs preserved):"), C("| suite        | runs | fail | p95 ms |\n|--------------|------|------|--------|\n| auth.spec    |  20  |   3  |   412  |\n| session.spec |  20  |   0  |   120  |\n| api.spec     |  20  |   0  |\t 98  |"), P("Note the `|` characters — WoW must escape them or they'd be read as UI codes. |cffff0000 this should NOT turn red|r and |TInterface\\Icons\\INV_Misc_QuestionMark:16|t should not show an icon.")]],
  ["u", [P("Ha, nice test. Now run the full suite 50× to be sure.")]],
  ["a", [P("That needs to run a shell command repeatedly; requesting approval.")]],
  ["t", [P("Ran: npx vitest run tests/auth.spec.ts --repeat 20\n20 passed")]],
  ["a", [P("20/20 locally after the fix (was 17/20). Unicode check for the renderer: café, naïve, Ærøskøbing, “smart quotes”, em — dash, ellipsis…, 日本語, emoji 🙂 (may render as a box in WoW).")]],
  ["u", [P("ok")]],
  ["a", [P(longText())], true],
  ["s", [P("Model switched to Opus 5.5.")]],
  ["u", [P("Ship it once the 50× run passes.")]],
  ["a", [P("Will do. Starting the 50× run now — this will take about 3 minutes.")]],
  ["t", [P("Waiting for approval: npm test -- --repeat 50")]],
];

function longText() {
  const para = "This is a deliberately long assistant message used to exercise the addon's FontString splitting (each FontString holds at most 2000 characters). It explains, in more detail than anyone needs, how the race between the HTTP response and the store listener happened, why fake timers make the regression test deterministic, and why awaiting the store inside login() is the least surprising fix for every caller. ";
  let s = "";
  for (let n = 1; s.length < 5200; n++) s += `(${n}) ` + para + (n % 3 === 0 ? "\n\n" : "");
  return s.trim();
}

if (convo.length !== 40) throw new Error("need exactly 40 messages, have " + convo.length);
const firstIndex = 93;
const msgs = convo.map(([r, segs, more], k) => ({
  i: firstIndex + k, r, ts: TS - (40 - k) * 17, segs, more: !!more,
}));

const snapshot = {
  v: 1, sid: "k3f9", seq: 4812, ts: TS, ack: 17, asid: "9f3a01c2", err: null,
  threads,
  focus: {
    id: "a1b2c3d4", model: "claude-opus-5-5", effort: "high",
    // Effort choices as T3 0.1.8 reports them (PROTOCOL D14); Haiku 4.5 has none (picker hidden).
    models: [
      { id: "claude-opus-5-5", name: "Claude Opus 5.5", opts: [{ id: "effort", vals: ["low", "medium", "high", "xhigh", "max", "ultrathink"], def: "medium" }] },
      { id: "claude-sonnet-5-5", name: "Claude Sonnet 5.5", opts: [{ id: "effort", vals: ["low", "medium", "high", "xhigh", "max", "ultrathink"], def: "high" }] },
      { id: "claude-opus-4-5", name: "Claude Opus 4.5", opts: [{ id: "effort", vals: ["low", "medium", "high", "max"], def: "high" }] },
      { id: "claude-haiku-4-5", name: "Claude Haiku 4.5" },
    ],
    streaming: false,
    pending: {
      kind: "approval", rid: "req-77",
      text: "Run shell command:\nnpm test -- --repeat 50",
      options: [
        { id: "allow", label: "Allow" },
        { id: "allow_always", label: "Always allow" },
        { id: "deny", label: "Deny" },
      ],
    },
    msgs,
  },
};

// msgs are long: put each on its own line for readability
function snapshotLua(s) {
  const head = `T3B_IN={v=${s.v},sid=${luaStr(s.sid)},seq=${s.seq},ts=${s.ts},ack=${s.ack},asid=${luaStr(s.asid)},err=nil,\n threads={\n  `
    + s.threads.map((t) => luaVal(t, "  ")).join(",\n  ") + "},\n";
  const f = s.focus;
  const focus = ` focus={id=${luaStr(f.id)},model=${luaStr(f.model)},effort=${luaStr(f.effort)},\n  models=${luaVal(f.models, "  ")},\n  streaming=${f.streaming},\n  pending=${luaVal(f.pending, "  ")},\n  msgs={\n   `
    + f.msgs.map((m) => luaVal(m, "   ")).join(",\n   ") + "}}}\n";
  return head + focus + `T3B_IN_END=${s.seq}\n`;
}

const lua = snapshotLua(snapshot);
const header = "-- T3Bridge reference snapshot (PROTOCOL.md section 2.2). Generated by scripts/dev/make-fixture.js.\n-- 7 threads (running, needs approval, needs input, completed, failed, stopped, idle),\n-- focused thread with 40 messages (code, pipes, tabs, backslashes, unicode, a 5 KB message, more=true) and a pending approval.\n";
const fixturePath = path.join(ROOT, "protocol", "fixtures", "live.sample.lua");
writeLuaFile(fixturePath, header + lua);

const demo = "-- GENERATED by scripts/dev/make-fixture.js from protocol/fixtures/live.sample.lua. Do not edit.\n"
  + "local _, ns = ...\nns = ns or {}\nfunction ns.DemoSnapshot()\n  local T3B_IN, T3B_IN_END\n"
  + lua + "  return T3B_IN, T3B_IN_END\nend\nreturn ns\n";
writeLuaFile(path.join(ROOT, "addon", "T3Bridge", "Demo.lua"), demo);

// Small fixtures for the companion parser tests and spike loop (no focus / torn).
const tiny = `T3B_IN={v=1,sid="k3f9",seq=1,ts=${TS},ack=0,asid="",threads={}}\nT3B_IN_END=1\n`;
writeLuaFile(path.join(ROOT, "protocol", "fixtures", "live.empty.lua"), tiny);
const torn = lua.slice(0, Math.floor(lua.length * 0.6));
writeLuaFile(path.join(ROOT, "protocol", "fixtures", "live.torn.lua"), torn);
console.log("wrote", fixturePath, Buffer.byteLength(lua, "latin1"), "bytes");
module.exports = { luaStr, luaVal };

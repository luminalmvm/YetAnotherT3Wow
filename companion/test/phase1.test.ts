// Phase 1: thread selection rules, focus.older, privacy clear on exit, graceful stop.
import { spawn } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { afterAll, describe, expect, it } from "vitest";
import { Bridge } from "../src/bridge.js";
import { DEFAULT_CAPS, emptySnapshotLua, fitSnapshot, focusToSnap, RidMap, selectThreads, serializeSnapshot, TidMap } from "../src/model/snapshot.js";
import { FakeT3Client } from "../src/t3/fakeClient.js";
import { shellThreadToSummary } from "../src/t3/project.js";
import type { ChatMessage, ThreadDetail, ThreadSummary } from "../src/t3/types.js";
import { LiveWriter } from "../src/wow/liveWriter.js";
import { parseLuaChunk, toJs } from "./helpers/luaParse.js";

const here = dirname(fileURLToPath(import.meta.url));
const tmp = mkdtempSync(join(tmpdir(), "t3b-phase1-"));
afterAll(() => rmSync(tmp, { recursive: true, force: true }));

const NOW = 1_800_000_000_000;
const MIN = 60_000;
const thread = (id: string, status: string, updatedAt: number, extra: Partial<ThreadSummary> = {}): ThreadSummary => ({
  id, title: id, status, pending: null, startedAt: updatedAt - 1000, completedAt: null, updatedAt, providerInstanceId: "p", modelSlug: "m",
  projectId: "x", isSubagent: false, createdBy: "user", archived: false, settled: false, ...extra,
});

describe("selectThreads (Phase 1 rules)", () => {
  it("needs-you, running, then most recently updated (no 30-min rank); never archived/deleted/subagents", () => {
    const all = [
      thread("idle-fresh", "idle", NOW - 1 * MIN),
      thread("done-old", "completed", NOW - 120 * MIN, { completedAt: NOW - 120 * MIN }),
      thread("done-recent", "completed", NOW - 20 * MIN, { completedAt: NOW - 20 * MIN }),
      thread("failed-recent", "failed", NOW - 25 * MIN, { completedAt: NOW - 25 * MIN }),
      thread("run", "running", NOW - 60 * MIN),
      thread("need", "waiting", NOW - 90 * MIN, { pending: { id: "r", kind: "user_input" } }),
      thread("deleted", "running", NOW, { archived: true }),
      thread("sub", "running", NOW, { isSubagent: true }),
    ];
    expect(selectThreads(all, { maxThreads: 12, now: NOW }).map((t) => t.id))
      .toEqual(["need", "run", "idle-fresh", "done-recent", "failed-recent", "done-old"]);
  });

  it("caps (12 here) and always keeps the focused thread", () => {
    const many = Array.from({ length: 30 }, (_, k) => thread(`t${k}`, "idle", NOW - k * MIN));
    const out = selectThreads(many, { maxThreads: 12, now: NOW, focusId: "t29" });
    expect(out).toHaveLength(12);
    expect(out.at(-1)!.id).toBe("t29");
  });

  it("non-UUID thread ids get short distinct hashed tids (seen live: thread-mcp...)", () => {
    const m = new TidMap();
    const ids = ["thread-mcp", "thread-mcpf", "thread-mcp5", "thread-mcp5d"].map((s) => m.tid(s));
    for (const id of ids) expect(id).toMatch(/^[0-9a-f]{8}$/);
    expect(new Set(ids).size).toBe(4);
    expect(m.resolve(ids[1])).toBe("thread-mcpf");
    expect(m.tid("a1b2c3d4-0000-4000-8000-000000000001")).toBe("a1b2c3d4");
  });

  it("deleted and archived shell threads are flagged and dropped", () => {
    expect(shellThreadToSummary({ id: "a", status: "completed", deletedAt: "2026-11-11T10:00:00Z" }).archived).toBe(true);
    expect(shellThreadToSummary({ id: "b", status: "completed", archivedAt: "2026-11-11T10:00:00Z" }).archived).toBe(true);
    expect(shellThreadToSummary({ id: "c", status: "completed" }).archived).toBe(false);
  });
});

const detail = (n: number, hasOlder: boolean, first = 1): ThreadDetail => ({
  id: "a1b2c3d4-0000-4000-8000-000000000001", title: "t", providerInstanceId: "p", modelSlug: "m", modelOptions: null,
  streaming: false, activeRunId: null, pending: null, hasOlder,
  messages: Array.from({ length: n }, (_, k): ChatMessage => ({ i: first + k * 7, role: k % 2 ? "a" : "u", ts: 1, text: `m${k}`, streaming: false })),
});

describe("focus.older", () => {
  const snap = (d: ThreadDetail, windowStart: number | null = null) => focusToSnap({ detail: d, windowStart }, new TidMap(), new RidMap(), [], DEFAULT_CAPS);
  it("true when the window leaves loaded messages out, or T3 has more pages", () => {
    expect(snap(detail(50, false)).older).toBe(true);           // 40-message window of 50
    expect(snap(detail(10, false)).older).toBe(false);          // everything loaded and shown
    expect(snap(detail(10, true)).older).toBe(true);            // T3 says more pages exist
    expect(snap(detail(10, false, 200001)).older).toBe(false);  // sparse i > 1 but nothing older
  });
  it("is written to Lua and parses", () => {
    const f = snap(detail(10, false, 200001));
    const lua = serializeSnapshot({ v: 1, sid: "abcd", seq: 3, ts: 5, ack: 0, asid: "", threads: [], focus: f });
    const t = toJs(parseLuaChunk(lua).T3B_IN as any);
    expect(t.focus.older).toBe(false);
    expect(t.focus.msgs).toHaveLength(10);
  });
  it("becomes true when fitting the size cap drops the oldest messages", () => {
    const f = snap(detail(10, false));
    expect(f.older).toBe(false);
    const doc = { v: 1 as const, sid: "abcd", seq: 3, ts: 5, ack: 0, asid: "", threads: [], focus: f };
    fitSnapshot(doc, serializeSnapshot(doc).length - 10);
    expect(doc.focus.older).toBe(true);
  });
});

describe("privacy: empty snapshot on exit", () => {
  it("emptySnapshotLua has no threads, no focus, ts=0 and a matching END", () => {
    const env = parseLuaChunk(emptySnapshotLua("zz99", 42, 7, "9f3a01c2"));
    const t = toJs(env.T3B_IN as any);
    expect(t).toMatchObject({ v: 1, sid: "zz99", seq: 42, ts: 0, ack: 7, asid: "9f3a01c2" });
    expect(t.threads).toEqual([]);
    expect(t.focus).toBeUndefined();
    expect(toJs(env.T3B_IN_END as any)).toBe(42);
  });

  it("Bridge.clear() removes every title and message from the rendered file", async () => {
    const t3 = new FakeT3Client(NOW);
    t3.streamDelayMs = 0;
    const b = new Bridge({ t3, onDirty: () => {}, onAck: () => {} });
    const first = t3.threads()[0];
    b.focus.tid = b.tids.tid(first.id);
    await t3.focus(first.id);
    const before = b.render(1, 100);
    expect(before).toContain("Fix flaky login test");
    expect(before).toContain("Please keep the change small");
    b.clear();
    const after = b.render(2, 101);
    expect(after).not.toContain("Fix flaky login test");
    expect(after).not.toContain("Please keep the change small");
    expect(toJs(parseLuaChunk(after).T3B_IN as any).threads).toEqual([]);
  });

  it("the exit write also overwrites Inbox.lua at once (forceSecondary)", () => {
    const live = join(tmp, "live.lua"), inbox = join(tmp, "Inbox.lua");
    writeFileSync(live, ""); writeFileSync(inbox, "");
    let text = "SECRET";
    const w = new LiveWriter({ file: live, mode: "inplace", padBytes: 4096, debounceMs: 0, minIntervalMs: 0, heartbeatMs: 1e9,
      render: (seq) => `T3B_IN={v=1,sid="s",seq=${seq},ts=1,ack=0,asid="",threads={{id="a",title="${text}",st="idle"}}}\nT3B_IN_END=${seq}\n`,
      secondaryFile: inbox, secondaryIntervalMs: 60_000 });
    w.writeNow("first");
    expect(readFileSync(inbox, "utf8")).toContain("SECRET");
    text = "gone";
    w.writeNow("change");
    expect(readFileSync(inbox, "utf8")).toContain("SECRET"); // rate-limited: not rewritten yet
    w.writeNow("exit", true);
    expect(readFileSync(inbox, "utf8")).not.toContain("SECRET");
    expect(statSync(live).size).toBe(4096);
    expect(statSync(inbox).size).toBe(4096);
  });
});

describe("graceful stop via stop.request (end to end, spawns dist/main.js --demo)", () => {
  const main = resolve(here, "..", "dist", "main.js");
  it.skipIf(!existsSync(main))("clears the live file and exits when stop.request appears", async () => {
    const appData = join(tmp, "appdata");
    mkdirSync(join(appData, "T3Bridge"), { recursive: true });
    const out = join(tmp, "demo-live.lua");
    writeFileSync(out, "");
    const child = spawn(process.execPath, [main, "--demo", "--no-capture", "--out", out], {
      env: { ...process.env, LOCALAPPDATA: appData, T3B_CONFIG: join(appData, "none.json") }, stdio: "ignore", windowsHide: true,
    });
    const exited = new Promise<number | null>((res) => child.on("exit", (c) => res(c)));
    const deadline = Date.now() + 10_000;
    while (Date.now() < deadline && !readFileSync(out, "utf8").includes("Fix flaky login test")) await new Promise((r) => setTimeout(r, 100));
    expect(readFileSync(out, "utf8")).toContain("Fix flaky login test");
    writeFileSync(join(appData, "T3Bridge", "stop.request"), "stop");
    const code = await Promise.race([exited, new Promise<string>((r) => setTimeout(() => r("timeout"), 8000))]);
    if (code === "timeout") child.kill();
    expect(code).toBe(0);
    const text = readFileSync(out, "utf8");
    expect(text).not.toContain("Fix flaky login test");
    const t = toJs(parseLuaChunk(text).T3B_IN as any);
    expect(t.threads).toEqual([]);
    expect(t.ts).toBe(0);
    expect(existsSync(join(appData, "T3Bridge", "stop.request"))).toBe(false);
  }, 30_000);
});

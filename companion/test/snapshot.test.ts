import { describe, expect, it } from "vitest";
import { Bridge } from "../src/bridge.js";
import { DEFAULT_CAPS, fitSnapshot, mapNeed, mapStatus, messageToSnap, RidMap, selectThreads, serializeSnapshot, TidMap, type SnapshotDoc } from "../src/model/snapshot.js";
import { FakeT3Client } from "../src/t3/fakeClient.js";
import type { ThreadSummary } from "../src/t3/types.js";
import { parseLuaChunk, toJs } from "./helpers/luaParse.js";

const thread = (id: string, status: string, updatedAt: number, extra: Partial<ThreadSummary> = {}): ThreadSummary => ({
  id, title: id, status, pending: null, startedAt: updatedAt - 1000, completedAt: null, updatedAt, providerInstanceId: "p", modelSlug: "m",
  projectId: "x", isSubagent: false, createdBy: "user", archived: false, settled: false, ...extra,
});

describe("status mapping", () => {
  it("collapses T3 statuses to the protocol set", () => {
    expect(["preparing", "queued", "starting", "running", "waiting"].map(mapStatus)).toEqual(Array(5).fill("running"));
    expect(mapStatus("completed")).toBe("completed");
    expect(mapStatus("failed")).toBe("failed");
    expect(["interrupted", "cancelled", "rolled_back"].map(mapStatus)).toEqual(["stopped", "stopped", "stopped"]);
    expect(mapStatus("idle")).toBe("idle");
    expect(mapStatus("something-new")).toBe("idle");
    expect(mapNeed("user_input")).toBe("input");
    expect(mapNeed("command")).toBe("approval");
    expect(mapNeed(undefined)).toBeUndefined();
  });
});

describe("selectThreads", () => {
  it("orders needs-you, running, recent; excludes subagents/archived; caps; keeps focus", () => {
    const all = [
      thread("old-done", "completed", 1), thread("run", "running", 5), thread("need", "waiting", 2, { pending: { id: "r", kind: "command" } }),
      thread("sub", "running", 9, { isSubagent: true }), thread("arch", "completed", 9, { archived: true }), thread("new-done", "completed", 8),
    ];
    expect(selectThreads(all, { maxThreads: 12 }).map((t) => t.id)).toEqual(["need", "run", "new-done", "old-done"]);
    expect(selectThreads(all, { maxThreads: 2, focusId: "old-done" }).map((t) => t.id)).toEqual(["need", "old-done"]);
  });
});

describe("TidMap / RidMap", () => {
  it("uses 8 chars and lengthens on collision; resolves back", () => {
    const m = new TidMap();
    expect(m.tid("a1b2c3d4-0000-4000-8000-000000000001")).toBe("a1b2c3d4");
    expect(m.tid("a1b2c3d4-ffff-4000-8000-000000000002")).toBe("a1b2c3d4-");
    expect(m.resolve("a1b2c3d4")).toBe("a1b2c3d4-0000-4000-8000-000000000001");
    expect(m.tid("a1b2c3d4-0000-4000-8000-000000000001")).toBe("a1b2c3d4");
  });
  it("maps long request ids to protocol-safe rids", () => {
    const r = new RidMap();
    const long = "runtime-request:provider:claudeAgent:provider-turn:provider-turn%3A" + "x".repeat(300);
    const rid = r.rid(long);
    expect(rid).toMatch(/^[A-Za-z0-9_.:/-]{1,64}$/);
    expect(r.resolve(rid)).toBe(long);
  });
});

describe("messageToSnap", () => {
  it("caps message bytes (keeps the tail, more=true)", () => {
    const m = messageToSnap({ i: 5, role: "a", ts: 1, text: "start " + "x".repeat(20000) + " THE END" }, 8000, DEFAULT_CAPS);
    expect(m.more).toBe(true);
    const total = m.segs.reduce((n, s) => n + Buffer.byteLength(s[1]), 0);
    expect(total).toBeLessThanOrEqual(8000);
    expect(m.segs.at(-1)![1].endsWith("THE END")).toBe(true);
  });
});

describe("serializeSnapshot + fitSnapshot", () => {
  it("produces a parseable Lua chunk with T3B_IN_END == seq last", () => {
    const doc: SnapshotDoc = { v: 1, sid: "k3f9ab", seq: 4812, ts: 1794393000, ack: 17, asid: "9f3a01c2", threads: [{ id: "a1b2c3d4", title: 'Fix "quotes" | pipes \\ and åäö', st: "running", need: "approval", t0: 1 }],
      focus: { id: "a1b2c3d4", model: "m", models: [{ id: "m", name: "M" }], streaming: true, pending: { kind: "approval", rid: "r1", text: "Run?", options: [{ id: "accept", label: "Allow" }] }, msgs: [{ i: 1, r: "u", ts: 1, segs: [["p", "hi\n\tthere"], ["c", "x = 1"]], more: false }] } };
    const lua = serializeSnapshot(doc);
    expect(lua.trimEnd().split("\n").at(-1)).toBe("T3B_IN_END=4812");
    const env = parseLuaChunk(lua);
    const t = toJs(env.T3B_IN as any);
    expect(t.seq).toBe(4812);
    expect(t.threads[0].title).toBe('Fix "quotes" | pipes \\ and åäö');
    expect(t.focus.msgs[0].segs[0]).toEqual(["p", "hi\n\tthere"]);
    expect(t.focus.pending.options[0].id).toBe("accept");
    // ASCII-only variant parses to identical strings
    const env2 = parseLuaChunk(serializeSnapshot(doc, { asciiOnly: true }));
    expect(toJs(env2.T3B_IN as any)).toEqual(t);
    expect(/[^\x00-\x7f]/.test(serializeSnapshot(doc, { asciiOnly: true }))).toBe(false);
  });
  it("shrinks oldest messages first to fit the size cap", () => {
    const msgs = Array.from({ length: 40 }, (_, k) => ({ i: k + 1, r: "a" as const, ts: 1, segs: [["p", `m${k} ` + "y".repeat(7900)]] as any, more: false }));
    const doc: SnapshotDoc = { v: 1, sid: "s", seq: 1, ts: 1, ack: 0, asid: "", threads: [], focus: { id: "t", streaming: false, msgs } };
    const { lua, shrunk } = fitSnapshot(doc, 100_000);
    expect(Buffer.byteLength(lua)).toBeLessThanOrEqual(100_000);
    expect(shrunk).toBeGreaterThan(0);
    const t = toJs(parseLuaChunk(lua).T3B_IN as any);
    expect(t.focus.msgs.at(-1).segs[0][1].startsWith("m39")).toBe(true); // newest kept intact
  });
});

describe("Bridge.buildDoc with demo data", () => {
  it("renders ≤30 threads, focus with ≤40 msgs, models + effort, pending and parses", async () => {
    const t3 = new FakeT3Client(1794393000_000);
    const bridge = new Bridge({ t3, onDirty: () => {}, onAck: () => {} });
    const first = t3.threads()[0];
    bridge.focus.tid = bridge.tids.tid(first.id);
    await t3.focus(first.id);
    const lua = bridge.render(1, 1794393000);
    expect(Buffer.byteLength(lua)).toBeLessThan(480 * 1024);
    const t = toJs(parseLuaChunk(lua).T3B_IN as any);
    expect(t.threads.length).toBeLessThanOrEqual(30);
    expect(t.threads[0].need).toBe("approval");
    expect(t.focus.id).toBe("a1b2c3d4");
    expect(t.focus.msgs.length).toBe(37); // 1 user + 18*2 (tool+assistant)
    expect(t.focus.models.length).toBe(6);
    expect(t.focus.effort).toBe("high");
    expect(t.focus.models[0].opts).toEqual([{ id: "effort", vals: ["low", "medium", "high", "xhigh", "max", "ultrathink"], def: "medium" }]);
    expect(t.focus.models.find((m: any) => m.id === "claude-haiku-4-5").opts).toBeUndefined();
    expect(t.focus.pending.kind).toBe("approval");
    expect(t.focus.pending.rid).toMatch(/^r[0-9a-f]{12}$/);
    const titles = t.threads.map((x: any) => x.title);
    expect(titles).toContain('Write release notes for v2.3 -- "Aurora"'); // transliterated
    expect(t.threads.find((x: any) => x.title.includes("strict mode")).st).toBe("failed");
  });
});

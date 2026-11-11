// Subagent threads (PROTOCOL rev 1.4): lineage, family cache, thread tree (threads/subs/focus extras),
// thread links in messages, serialization. Ids and titles are fake; shapes are the ones VERIFIED live.
import { afterEach, describe, expect, it, vi } from "vitest";
import { executeCommand, type ActionContext } from "../src/actions.js";
import { Bridge } from "../src/bridge.js";
import { buildThreadTree, DEFAULT_CAPS, fitSnapshot, focusToSnap, messageToSnap, RidMap, runState, serializeSnapshot, TidMap, type SnapshotDoc } from "../src/model/snapshot.js";
import { FAMILY_REFRESH_MS, RpcT3Client } from "../src/t3/client.js";
import { FAKE_KIDS, FakeT3Client } from "../src/t3/fakeClient.js";
import { extractThreadLinks, itemsToMessages, lineageOf, shellThreadToSummary, subagentRefs } from "../src/t3/project.js";
import type { SubagentRef, ThreadSummary } from "../src/t3/types.js";
import { parseLuaChunk, toJs } from "./helpers/luaParse.js";

const ROOT = "fa4e0200-0000-4000-8000-000000000200";
const DEL = "thread:delegated-task:command%3Amcp%3Afa4e0201-0000-4000-8000-000000000201%3Adelegate-task%3Afa4e0202-0000-4000-8000-000000000202";
const NAT = "thread:provider:claudeAgent:native-thread:provider-thread%3Aprovider%3AclaudeAgent%3Anative-thread%3Apending%253Arun%253Athread%253Afa4e0200%3Aa0000000000000009";
const ENV = "fa4e0203-0000-4000-8000-000000000203";
const iso = (ms: number) => new Date(ms).toISOString();
const T0 = 1794390000_000;

/** A shell row shaped like T3 0.1.8's (only the fields the bridge reads). */
function row(id: string, o: Record<string, unknown> = {}): any {
  return {
    id, title: "Thread " + id.slice(-4), status: "completed", pendingRuntimeRequest: null, projectId: "p1", createdBy: "agent",
    modelSelection: { instanceId: "claudeAgent_2", model: "claude-opus-5-5" }, providerInstanceId: "claudeAgent_2",
    latestRunStartedAt: iso(T0), latestRunCompletedAt: iso(T0 + 60_000), updatedAt: iso(T0 + 60_000), createdAt: iso(T0),
    archivedAt: null, deletedAt: null, settledAt: null, activityRunStatus: null,
    lineage: { parentThreadId: null, relationshipToParent: null, rootThreadId: id }, ...o,
  };
}
const child = (id: string, parent: string, o: Record<string, unknown> = {}) =>
  row(id, { lineage: { parentThreadId: parent, relationshipToParent: "subagent", rootThreadId: ROOT }, ...o });

function sum(id: string, o: Partial<ThreadSummary> = {}): ThreadSummary {
  return { ...shellThreadToSummary(row(id)), ...o };
}
function kid(id: string, parent: string, o: Partial<ThreadSummary> = {}): ThreadSummary {
  return { ...shellThreadToSummary(child(id, parent)), ...o };
}

describe("lineage (VERIFIED shell shape)", () => {
  it("top-level, delegated-task and provider-native subagents, forks", () => {
    const top = shellThreadToSummary(row(ROOT));
    expect(top).toMatchObject({ isSubagent: false, parentId: null, rootId: ROOT, native: false });
    const d = shellThreadToSummary(child(DEL, ROOT));
    expect(d).toMatchObject({ isSubagent: true, parentId: ROOT, rootId: ROOT, native: false });
    const n = shellThreadToSummary(child(NAT, DEL, { status: "idle", latestRunStartedAt: null, latestRunCompletedAt: null, activityRunStatus: "running" }));
    expect(n).toMatchObject({ isSubagent: true, parentId: DEL, rootId: ROOT, native: true, activity: "running" });
    // a fork has a parent but is listed like a top-level thread
    expect(lineageOf({ id: "f1", lineage: { parentThreadId: ROOT, relationshipToParent: "fork", rootThreadId: ROOT } })).toEqual({ parentId: null, rootId: "f1" });
  });

  it("run state: native subagents stay idle in T3 (live = activityRunStatus); the parent's subagent item wins", () => {
    const nat = kid(NAT, ROOT, { status: "idle", native: true, startedAt: null, completedAt: null, activity: null });
    expect(runState(nat).st).toBe("completed");
    expect(runState(nat).t0).toBe(Math.floor(T0 / 1000)); // createdAt
    expect(runState({ ...nat, activity: "running" }).st).toBe("running");
    const ref: SubagentRef = { childThreadId: NAT, status: "failed", title: "x", startedAt: T0, completedAt: T0 + 5000 };
    expect(runState(nat, ref)).toEqual({ st: "failed", t0: Math.floor(T0 / 1000), t1: Math.floor(T0 / 1000) + 5 });
    expect(runState(nat, { ...ref, status: "running", completedAt: null }).st).toBe("running");
    expect(runState(kid(DEL, ROOT, { status: "running" })).st).toBe("running");
    // a delegated task's own status wins over the parent's item (cancelled task, item says completed)
    expect(runState(kid(DEL, ROOT, { status: "cancelled" }), { ...ref, childThreadId: DEL, status: "completed" }).st).toBe("stopped");
  });
});

describe("thread links in messages (VERIFIED item shapes)", () => {
  it("notification with source.childThreadId becomes one link", () => {
    const msgs = itemsToMessages([{ id: "n1", type: "notification", ordinal: 2_000_001, startedAt: iso(T0), summary: 'Delegated task "Phase 1" finished',
      source: { kind: "delegated_task", taskIds: ["node:x"], childThreadId: DEL }, outcome: "completed" }]);
    expect(msgs).toHaveLength(1);
    expect(msgs[0].parts).toEqual([{ kind: "link", threadId: DEL, label: 'Delegated task "Phase 1" finished' }]);
  });

  it("subagent items in a tool run become links in order and do not use the line cap", () => {
    const items = [
      { id: "t1", type: "command_execution", ordinal: 1_000_001, input: "ls", exitCode: 0 },
      { id: "s1", type: "subagent", ordinal: 1_000_002, status: "completed", title: "Scout the repo", childThreadId: NAT, prompt: "..." },
      { id: "t2", type: "dynamic_tool", ordinal: 1_000_003, toolName: "Read", title: "README.md" },
      { id: "s2", type: "subagent", ordinal: 1_000_004, status: "running", title: "Phase 1", childThreadId: DEL, prompt: "..." },
      ...Array.from({ length: 10 }, (_, k) => ({ id: "c" + k, type: "command_execution", ordinal: 1_000_010 + k, input: "echo " + k, exitCode: 0 })),
    ];
    const [m] = itemsToMessages(items);
    expect(m.role).toBe("t");
    expect(m.parts!.map((p) => p.kind)).toEqual(["text", "link", "text", "link", "text"]);
    expect(m.parts![1]).toEqual({ kind: "link", threadId: NAT, label: "Subagent: Scout the repo (done)" });
    expect(m.parts![3]).toMatchObject({ threadId: DEL, label: "Subagent: Phase 1 (running)" });
    expect((m.parts![4] as any).text).toMatch(/\(\+4 more\)$/); // 8 plain lines kept, links not counted
    expect(subagentRefs(items)).toEqual([
      { childThreadId: NAT, status: "completed", title: "Scout the repo", startedAt: null, completedAt: null },
      { childThreadId: DEL, status: "running", title: "Phase 1", startedAt: null, completedAt: null },
    ]);
  });

  it("t3-thread links in assistant markdown (label kept; bare links replaced)", () => {
    const text = `Track A ([companion spike](t3-thread://v2/${ENV}/${DEL})) and Track B ([addon](t3-thread://v2/${ENV}/${NAT})).\nAgain: t3-thread://v2/${ENV}/${DEL} and t3-thread://v2/${ENV}/${ROOT}`;
    const r = extractThreadLinks(text);
    expect(r.links).toEqual([{ threadId: DEL, label: "companion spike" }, { threadId: NAT, label: "addon" }, { threadId: ROOT, label: "Linked thread" }]);
    expect(r.text).toContain("[companion spike](t3-thread://");
    expect(r.text).toContain("Again: (linked thread) and (linked thread)");
    const [m] = itemsToMessages([{ id: "a1", type: "assistant_message", ordinal: 1_000_001, text }]);
    expect(m.parts!.filter((p) => p.kind === "link")).toHaveLength(3);
    // segments: the markdown link shows only its label; links follow as tl segments
    const snap = messageToSnap(m, 8000, DEFAULT_CAPS, undefined, (id) => new TidMap().tid(id));
    expect(snap.segs[0][1]).toContain("Track A (companion spike) and Track B (addon).");
    expect(snap.segs.slice(1).map((s) => s[0])).toEqual(["tl", "tl", "tl"]);
    expect(extractThreadLinks("no links here")).toEqual({ text: "no links here", links: [] });
  });
});

describe("thread tree (threads / subs / focus extras)", () => {
  const caps = DEFAULT_CAPS;
  const projects = new Map([["p1", { id: "p1", title: "proj" }]]);

  function tree(shell: ThreadSummary[], family: ThreadSummary[], focusId: string | null, extra: Partial<Parameters<typeof buildThreadTree>[0]> = {}) {
    const tids = new TidMap();
    const r = buildThreadTree({ shell, familyOf: (root) => (root === ROOT ? family : null), focusId, ...extra }, tids, projects, [], caps);
    return { r, tids };
  }

  it("top-level rows get kids counts; subs list the kids; the filtered shell's live kid merges with the family", () => {
    const root = sum(ROOT, { status: "running" });
    const family = [root, kid(DEL, ROOT, { status: "running", updatedAt: T0 }), kid(NAT, ROOT, { status: "idle", native: true }), kid("k3", ROOT, { status: "completed", pending: { id: "r1", kind: "command" } })];
    // the shell still has DEL as running but newer data in the family says completed
    const shell = [root, kid(DEL, ROOT, { status: "running", updatedAt: T0 })];
    const fam2 = family.map((t) => (t.id === DEL ? { ...t, status: "completed", updatedAt: T0 + 120_000 } : t));
    const { r, tids } = tree(shell, fam2, null);
    expect(r.wantRoots).toEqual([ROOT]);
    expect(r.threads).toHaveLength(1);
    expect(r.threads[0]).toMatchObject({ id: tids.tid(ROOT), kids: 3, kidsNeed: 1 });
    expect(r.threads[0].kidsRunning).toBeUndefined(); // DEL finished (family row is newer)
    expect(r.subs.map((s) => s.parent)).toEqual([tids.tid(ROOT), tids.tid(ROOT), tids.tid(ROOT)]);
    expect(r.subs[0]).toMatchObject({ id: tids.tid("k3"), need: "approval" }); // needs you first
    // before the family is loaded: only the shell's live kid counts
    const early = tree(shell, [], null).r;
    expect(early.threads[0]).toMatchObject({ kids: 1, kidsRunning: 1 });
    expect(tids.tid(DEL)).toMatch(/^[0-9a-f]{8}$/); // long child ids map to short tids
  });

  it("caps: 8 subs per thread, 40 in total, 20 focus.kids (needs you, running, then most recent)", () => {
    const tops: ThreadSummary[] = [];
    const fam: ThreadSummary[] = [];
    for (let t = 0; t < 7; t++) {
      const id = `fa4e03${String(t).padStart(2, "0")}-0000-4000-8000-000000000300`;
      tops.push(sum(id, { updatedAt: T0 + t }));
      for (let k = 0; k < 10; k++) fam.push({ ...kid(`${id}:k${k}`, id), rootId: id, updatedAt: T0 + k * 1000 });
    }
    const tids = new TidMap();
    const r = buildThreadTree({ shell: tops, familyOf: (root) => fam.filter((k) => k.rootId === root), focusId: null }, tids, projects, [], caps);
    expect(r.subs).toHaveLength(40);
    const perParent = new Map<string, number>();
    for (const s of r.subs) perParent.set(s.parent!, (perParent.get(s.parent!) ?? 0) + 1);
    expect(Math.max(...perParent.values())).toBe(8);
    // focus.kids: 25 kids, 1 needs you, 2 running
    const many = [sum(ROOT), ...Array.from({ length: 25 }, (_, k) => kid(`k${k}`, ROOT, { updatedAt: T0 + 100_000 + k * 1000, status: k === 3 || k === 4 ? "running" : "completed", pending: k === 20 ? { id: "r", kind: "user_input" } : null }))];
    const f = tree([sum(ROOT)], many, ROOT).r;
    expect(f.focus.nkids).toBe(25);
    expect(f.focus.kids).toHaveLength(20);
    expect(f.focus.kids!.slice(0, 3).map((k) => [k.need ?? "", k.st])).toEqual([["input", "completed"], ["", "running"], ["", "running"]]);
    expect(f.focus.kids![3].title).toBe("Thread k24"); // then most recent first
  });

  it("a focused subagent is listed with parent= even when settled/finished; breadcrumb root -> focused", () => {
    const root = sum(ROOT);
    const d = kid(DEL, ROOT, { status: "completed", settled: true });
    const n = kid(NAT, DEL, { status: "idle", native: true, title: "Native helper" });
    const { r, tids } = tree([root], [root, d, n], NAT);
    const listed = r.threads.map((t) => [t.id, t.parent ?? null]);
    expect(listed).toEqual([[tids.tid(ROOT), null], [tids.tid(DEL), tids.tid(ROOT)], [tids.tid(NAT), tids.tid(DEL)]]);
    expect(r.threads[2].st).toBe("completed");
    expect(r.focus.parent).toEqual({ id: tids.tid(DEL), title: d.title });
    expect(r.focus.path!.map((p) => p.id)).toEqual([tids.tid(ROOT), tids.tid(DEL), tids.tid(NAT)]);
    expect(r.wantRoots).toContain(ROOT);
  });

  it("breadcrumb keeps the root and the last 3 entries (depth cap 4)", () => {
    const chain = [sum(ROOT)];
    let parent = ROOT;
    for (let k = 1; k <= 5; k++) { const id = `deep${k}`; chain.push(kid(id, parent)); parent = id; }
    const { r, tids } = tree([sum(ROOT)], chain, "deep5");
    expect(r.focus.path!.map((p) => p.id)).toEqual([tids.tid(ROOT), tids.tid("deep3"), tids.tid("deep4"), tids.tid("deep5")]);
  });

  it("focused subagent before its family is loaded: lineage from its projection", () => {
    const { r, tids } = tree([sum(ROOT)], [], DEL, { focusLineage: { parentId: ROOT, rootId: ROOT }, focusTitle: "Phase 1" });
    expect(r.focus.parent?.id).toBe(tids.tid(ROOT));
    expect(r.focus.path).toEqual([{ id: tids.tid(ROOT), title: "Thread 0200" }, { id: tids.tid(DEL), title: "Phase 1" }]);
    expect(r.wantRoots).toEqual([ROOT]);
  });

  it("the parent's subagent items give its kids' run state", () => {
    const root = sum(ROOT);
    const fam = [root, kid(NAT, ROOT, { status: "idle", native: true })];
    const refs: SubagentRef[] = [{ childThreadId: NAT, status: "failed", title: "x", startedAt: T0, completedAt: T0 + 1000 }];
    const r = tree([root], fam, ROOT, { focusSubagents: refs }).r;
    expect(r.focus.kids![0].st).toBe("failed");
  });
});

describe("serialization", () => {
  it("tl segments, subs and focus extras are valid Lua 5.1 and parse back", () => {
    const tids = new TidMap();
    const doc: SnapshotDoc = {
      v: 1, sid: "abc", seq: 3, ts: 1, ack: 0, asid: "",
      threads: [{ id: "p0000001", title: "Parent", st: "completed", kids: 1 }],
      subs: [{ id: "c0000001", title: "Child", st: "running", parent: "p0000001" }],
      focus: {
        id: "p0000001", streaming: false, kids: [{ id: "c0000001", title: "Child", st: "running" }], nkids: 1,
        msgs: [messageToSnap({ i: 1, role: "s", ts: 1, text: "Delegated task \"Child\" finished", parts: [{ kind: "link", threadId: DEL, label: 'Delegated task "Child" finished' }] }, 8000, DEFAULT_CAPS, undefined, (id) => tids.tid(id))],
      },
    };
    const lua = serializeSnapshot(doc);
    expect(lua).toContain(`{"tl","Delegated task \\"Child\\" finished",id="${tids.tid(DEL)}"}`);
    expect(lua).toContain('\n subs={\n  {id="c0000001"');
    const t = toJs(parseLuaChunk(lua).T3B_IN as any);
    expect(t.subs[0].parent).toBe("p0000001");
    expect(t.focus.kids[0].id).toBe("c0000001");
    expect(t.focus.msgs[0].segs[0].__array).toEqual(["tl", 'Delegated task "Child" finished']);
  });

  it("fitSnapshot terminates on link-only messages", () => {
    const tids = new TidMap();
    const links = Array.from({ length: 8 }, (_, k) => ({ kind: "link" as const, threadId: `x${k}`, label: "L".repeat(110) }));
    const msgs = Array.from({ length: 30 }, (_, i) => messageToSnap({ i: i + 1, role: "t", ts: 1, text: "", parts: links }, 8000, DEFAULT_CAPS, undefined, (id) => tids.tid(id)));
    const doc: SnapshotDoc = { v: 1, sid: "a", seq: 1, ts: 1, ack: 0, asid: "", threads: [], focus: { id: "f", streaming: false, msgs } };
    const { lua } = fitSnapshot(doc, 4000);
    expect(Buffer.byteLength(lua)).toBeLessThanOrEqual(4000);
  });
});

describe("bridge with the fake T3 (demo data has subagents)", () => {
  it("focus on a subagent works with every command path; snapshot lists it with parent and breadcrumb", async () => {
    const t3 = new FakeT3Client(1794393000_000);
    t3.streamDelayMs = 0;
    const bridge = new Bridge({ t3, onDirty: () => {}, onAck: () => {} });
    let doc = bridge.buildDoc(1, 1794393000);
    const parentTid = bridge.tids.tid("b2c3d4e5-0000-4000-8000-000000000002");
    const top = doc.threads.find((t) => t.id === parentTid)!;
    expect(top).toMatchObject({ kids: 3, kidsRunning: 1 });
    expect(doc.threads.some((t) => t.parent)).toBe(false);
    expect(doc.subs!.filter((s) => s.parent === parentTid)).toHaveLength(3);
    expect(t3.wantedRoots).toContain("b2c3d4e5-0000-4000-8000-000000000002");
    const kidTid = bridge.tids.tid(FAKE_KIDS.css);
    const ctx: ActionContext = { t3, tids: bridge.tids, rids: new RidMap(), focus: bridge.focus, caps: { focusWindow: 40, maxFocusWindow: 120 } };
    await executeCommand(ctx, { kind: "focus", tid: kidTid });
    doc = bridge.buildDoc(2, 1794393000);
    expect(doc.focus!.id).toBe(kidTid);
    expect(doc.focus!.parent).toEqual({ id: parentTid, title: "Add dark mode toggle to the settings page" });
    expect(doc.focus!.path!.map((p) => p.id)).toEqual([parentTid, kidTid]);
    expect(doc.focus!.kids!.map((k) => k.title)).toEqual(["Find hard-coded colours"]);
    expect(doc.threads.find((t) => t.id === kidTid)).toMatchObject({ parent: parentTid, st: "running" });
    // a subagent is just a thread: send and model work as for any thread
    await executeCommand(ctx, { kind: "send", tid: kidTid, clientMsgId: "abcd-1", text: "hi" });
    await executeCommand(ctx, { kind: "model", tid: kidTid, modelId: "claude-opus-5-5", effort: "high" });
    expect(t3.calls.filter((c) => c.method === "sendMessage" || c.method === "setModel").map((c) => c.args[0])).toEqual([FAKE_KIDS.css, FAKE_KIDS.css]);
    // the parent's history links to its subagents
    await executeCommand(ctx, { kind: "focus", tid: parentTid });
    doc = bridge.buildDoc(3, 1794393000);
    const tl = doc.focus!.msgs.flatMap((m) => m.segs).filter((s) => s[0] === "tl");
    expect(tl.map((s) => s[1])).toContain('Delegated task "Screenshot test for dark mode" finished');
    expect(doc.focus!.nkids).toBe(3);
  });

  it("after a companion restart a subagent tid the new snapshot never named still resolves (focus re-send)", async () => {
    const t3 = new FakeT3Client(1794393000_000);
    const fresh = new Bridge({ t3, onDirty: () => {}, onAck: () => {} }); // a new companion: empty TidMap
    const kidTid = new TidMap().tid(FAKE_KIDS.vars); // the tid the old companion had sent
    expect(fresh.tids.resolve(kidTid)).toBeUndefined();
    const ctx: ActionContext = { t3, tids: fresh.tids, rids: new RidMap(), focus: fresh.focus, caps: { focusWindow: 40, maxFocusWindow: 120 } };
    await executeCommand(ctx, { kind: "focus", tid: kidTid });
    expect(t3.focusedThreadId()).toBe(FAKE_KIDS.vars);
    await expect(executeCommand(ctx, { kind: "focus", tid: "ffffffff" })).rejects.toThrow("Unknown thread ffffffff");
  });

  it("the focused thread's projection-derived row never hides its real shell/family row", () => {
    const root = sum(ROOT);
    const real = kid(DEL, ROOT, { status: "completed", updatedAt: T0 });
    const partial = { ...kid(DEL, ROOT, { status: "idle", updatedAt: T0 + 999_999, startedAt: null, completedAt: null }), partial: true };
    const tids = new TidMap();
    const r = buildThreadTree({ shell: [root, partial], familyOf: () => [root, real], focusId: DEL }, tids, new Map(), [], DEFAULT_CAPS);
    expect(r.threads.find((t) => t.id === tids.tid(DEL))!.st).toBe("completed");
    // with no other row the partial one is still listed
    const r2 = buildThreadTree({ shell: [root, partial], familyOf: () => null, focusId: DEL }, tids, new Map(), [], DEFAULT_CAPS);
    expect(r2.threads.find((t) => t.id === tids.tid(DEL))).toMatchObject({ parent: tids.tid(ROOT) });
  });
});

describe("family cache (RpcT3Client)", () => {
  afterEach(() => { vi.useRealTimers(); });

  it("fetches wanted families once, refetches a changed one after the throttle, drops unwanted ones", async () => {
    vi.useFakeTimers();
    const client = new RpcT3Client({ origin: "http://127.0.0.1:1", getBearer: async () => "x" });
    const calls: string[] = [];
    let status = "running";
    (client as any).sock = {
      isOpen: true, close: () => {},
      request: async (method: string, payload: any) => {
        calls.push(`${method}:${payload.threadId}`);
        return { snapshotSequence: 1, threads: [row(ROOT), child(DEL, ROOT, { status })] };
      },
    };
    const changes: string[] = [];
    client.on("change", (why: string) => changes.push(why));
    client.wantFamilies([ROOT, ROOT]);
    await vi.advanceTimersByTimeAsync(0);
    expect(calls).toEqual([`orchestration.getThreadFamily:${ROOT}`]);
    expect(client.family(ROOT)!.map((t) => t.id)).toEqual([ROOT, DEL]);
    expect(changes).toEqual(["family"]);
    client.wantFamilies([ROOT]); // same set: nothing to fetch
    await vi.advanceTimersByTimeAsync(0);
    expect(calls).toHaveLength(1);
    // a subagent update in the shell marks the family dirty; refetched after the throttle
    status = "completed";
    (client as any).onShellItem({ kind: "thread.updated", location: "active", thread: child(DEL, ROOT, { status }) });
    await vi.advanceTimersByTimeAsync(0);
    expect(calls).toHaveLength(1);
    await vi.advanceTimersByTimeAsync(FAMILY_REFRESH_MS + 10);
    expect(calls).toHaveLength(2);
    expect(client.family(ROOT)!.find((t) => t.id === DEL)!.status).toBe("completed");
    // updates of top-level threads do not refetch
    (client as any).onShellItem({ kind: "thread.updated", location: "active", thread: row(ROOT, { status: "running" }) });
    await vi.advanceTimersByTimeAsync(FAMILY_REFRESH_MS * 2);
    expect(calls).toHaveLength(2);
    client.wantFamilies([]);
    expect(client.family(ROOT)).toBeNull();
    client.stop();
  });
});

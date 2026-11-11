// Phase 2: effort picker (PROTOCOL D14), open-thread selection (D15), markdown marks (D14).
import { describe, expect, it } from "vitest";
import { executeCommand, type ActionContext } from "../src/actions.js";
import { Bridge } from "../src/bridge.js";
import { markdownToSegs } from "../src/model/markdown.js";
import { DEFAULT_CAPS, RidMap, selectThreads } from "../src/model/snapshot.js";
import { buildModelSelection } from "../src/t3/client.js";
import { FakeT3Client } from "../src/t3/fakeClient.js";
import { effortFromDescriptors, providersFromConfig, resolveEffort } from "../src/t3/project.js";
import type { ModelChoice, ThreadSummary } from "../src/t3/types.js";
import { parseCommand } from "../src/wow/frameCodec.js";
import { parseLuaChunk, toJs } from "./helpers/luaParse.js";

// Shapes VERIFIED against server.getConfig of T3 0.1.8 on 2026-11-11.
const OPUS55 = [
  { id: "effort", label: "Reasoning", type: "select", options: [{ id: "low", label: "Low" }, { id: "medium", label: "Medium", isDefault: true }, { id: "high", label: "High" }, { id: "xhigh", label: "Extra High" }, { id: "max", label: "Max" }, { id: "ultrathink", label: "Ultrathink" }], promptInjectedValues: ["ultrathink"] },
  { id: "ultracode", label: "Ultracode", type: "boolean" },
  { id: "fastMode", label: "Fast Mode", type: "boolean" },
];
const OPUS45 = [{ id: "effort", label: "Reasoning", type: "select", options: [{ id: "low", label: "Low" }, { id: "medium", label: "Medium" }, { id: "high", label: "High", isDefault: true }, { id: "max", label: "Max" }] }, { id: "fastMode", label: "Fast Mode", type: "boolean" }];
const HAIKU45 = [{ id: "thinking", label: "Thinking", type: "boolean", currentValue: true }];

const MODELS: ModelChoice[] = providersFromConfig({ providers: [{ instanceId: "claudeAgent_2", displayName: "Claude", enabled: true, status: "ready", models: [
  { slug: "claude-opus-5-5", name: "Claude Opus 5.5", capabilities: { optionDescriptors: OPUS55 } },
  { slug: "claude-opus-4-5", name: "Claude Opus 4.5", capabilities: { optionDescriptors: OPUS45 } },
  { slug: "claude-haiku-4-5", name: "Claude Haiku 4.5", capabilities: { optionDescriptors: HAIKU45 } },
] }] })[0].models;

describe("effort descriptors", () => {
  it("parses only the effort select: values in order, default from currentValue/isDefault", () => {
    expect(MODELS[0].effort).toEqual({ values: ["low", "medium", "high", "xhigh", "max", "ultrathink"], def: "medium" });
    expect(MODELS[1].effort).toEqual({ values: ["low", "medium", "high", "max"], def: "high" });
    expect(MODELS[2].effort).toBeUndefined(); // Haiku 4.5: only a "thinking" boolean
    expect(effortFromDescriptors([{ id: "effort", type: "select", options: [{ id: "a" }, { id: "b" }], currentValue: "b" }])).toEqual({ values: ["a", "b"], def: "b" });
    expect(effortFromDescriptors([{ id: "effort", type: "select", options: [{ id: "bad id" }] }])).toBeUndefined();
    expect(effortFromDescriptors(undefined)).toBeUndefined();
  });
  it("resolves the thread's effort like T3 (stored, legacy ultracode -> xhigh, else default)", () => {
    const c = MODELS[0].effort;
    expect(resolveEffort(c, [{ id: "effort", value: "high" }, { id: "fastMode", value: false }])).toBe("high");
    expect(resolveEffort(c, [{ id: "effort", value: "ultrathink" }])).toBe("ultrathink");
    expect(resolveEffort(c, [{ id: "effort", value: "ultracode" }])).toBe("xhigh");
    expect(resolveEffort(c, [])).toBe("medium");
    expect(resolveEffort(c, { effort: "low" })).toBe("low"); // legacy object form
    expect(resolveEffort(MODELS[1].effort, [{ id: "effort", value: "xhigh" }])).toBe("high");
    expect(resolveEffort(undefined, [{ id: "effort", value: "high" }])).toBeUndefined();
  });
});

describe("model-selection payload (thread.model-selection.set)", () => {
  const sel = { instanceId: "claudeAgent_2", model: "claude-opus-5-5", options: [{ id: "effort", value: "high" }, { id: "ultracode", value: false }, { id: "fastMode", value: false }] };
  it("effort only: same model, effort replaced in place, other options untouched", () => {
    expect(buildModelSelection(sel, "claudeAgent_2", "claude-opus-5-5", "low", MODELS)).toEqual({
      instanceId: "claudeAgent_2", model: "claude-opus-5-5",
      options: [{ id: "effort", value: "low" }, { id: "ultracode", value: false }, { id: "fastMode", value: false }],
    });
  });
  it("model switch keeps a supported effort and falls back to the new model's default otherwise", () => {
    expect(buildModelSelection(sel, "claudeAgent_2", "claude-opus-4-5", undefined, MODELS).options![0]).toEqual({ id: "effort", value: "high" });
    const x = { ...sel, options: [{ id: "effort", value: "xhigh" }, { id: "fastMode", value: true }] };
    expect(buildModelSelection(x, "claudeAgent_2", "claude-opus-4-5", undefined, MODELS).options).toEqual([{ id: "effort", value: "high" }, { id: "fastMode", value: true }]);
    expect(buildModelSelection(x, "claudeAgent_2", "claude-opus-4-5", "ultrathink", MODELS).options![0]).toEqual({ id: "effort", value: "high" });
  });
  it("adds effort when none is stored; models without effort leave options alone", () => {
    expect(buildModelSelection({ model: "claude-opus-5-5" }, "i", "claude-opus-5-5", "max", MODELS).options).toEqual([{ id: "effort", value: "max" }]);
    expect(buildModelSelection({ model: "claude-opus-5-5" }, "i", "claude-opus-4-5", undefined, MODELS)).toEqual({ instanceId: "i", model: "claude-opus-4-5" });
    expect(buildModelSelection(sel, "claudeAgent_2", "claude-haiku-4-5", "high", MODELS).options).toEqual(sel.options);
    expect(() => buildModelSelection(sel, "claudeAgent_2", "nope", undefined, MODELS)).toThrow(/not offered/);
  });
});

describe("model command with effort (PROTOCOL D14)", () => {
  it("parses the optional 4th field and stays compatible", () => {
    expect(parseCommand("model\ta1b2c3d4\tclaude-sonnet-5-5")).toEqual({ ok: true, cmd: { kind: "model", tid: "a1b2c3d4", modelId: "claude-sonnet-5-5" } });
    expect(parseCommand("model\ta1b2c3d4\tclaude-sonnet-5-5\txhigh")).toEqual({ ok: true, cmd: { kind: "model", tid: "a1b2c3d4", modelId: "claude-sonnet-5-5", effort: "xhigh" } });
    expect(parseCommand("model\ta1b2c3d4\tclaude-sonnet-5-5\t")).toEqual({ ok: true, cmd: { kind: "model", tid: "a1b2c3d4", modelId: "claude-sonnet-5-5" } });
    expect(parseCommand("model\ta1b2c3d4\tm\tbad value").ok).toBe(false);
  });
  it("executes against the fake T3 and the snapshot reports the new effort", async () => {
    const t3 = new FakeT3Client(1794393000_000);
    t3.streamDelayMs = 0;
    const bridge = new Bridge({ t3, onDirty: () => {}, onAck: () => {} });
    const id = t3.threads()[0].id;
    const tid = bridge.tids.tid(id);
    const ctx: ActionContext = { t3, tids: bridge.tids, rids: new RidMap(), focus: bridge.focus, caps: { focusWindow: 40, maxFocusWindow: 120 } };
    await executeCommand(ctx, { kind: "focus", tid });
    await executeCommand(ctx, { kind: "model", tid, modelId: "claude-opus-5-5", effort: "max" });
    let doc = toJs(parseLuaChunk(bridge.render(1, 1794393000)).T3B_IN as any);
    expect(doc.focus.effort).toBe("max");
    expect(t3.calls.at(-1)).toEqual({ method: "setModel", args: [id, "claude-opus-5-5", "max"] });
    await executeCommand(ctx, { kind: "model", tid, modelId: "claude-opus-4-5" }); // max is offered there: kept
    doc = toJs(parseLuaChunk(bridge.render(2, 1794393000)).T3B_IN as any);
    expect([doc.focus.model, doc.focus.effort]).toEqual(["claude-opus-4-5", "max"]);
    await executeCommand(ctx, { kind: "model", tid, modelId: "claude-haiku-4-5" });
    doc = toJs(parseLuaChunk(bridge.render(3, 1794393000)).T3B_IN as any);
    expect(doc.focus.effort).toBeUndefined(); // no effort option: the addon hides the picker
  });
});

const NOW = 1_800_000_000_000;
const th = (id: string, status: string, updatedAt: number, extra: Partial<ThreadSummary> = {}): ThreadSummary => ({
  id, title: id, status, pending: null, startedAt: updatedAt - 1000, completedAt: null, updatedAt, providerInstanceId: "p", modelSlug: "m",
  projectId: "x", isSubagent: false, createdBy: "user", archived: false, settled: false, ...extra,
});

describe("open threads (PROTOCOL D15): every unsettled thread, no 30-minute cutoff", () => {
  it("keeps finished threads of any age, drops settled/archived/subagents, cap 30", () => {
    const all = [
      th("done-3h", "completed", NOW - 180 * 60_000, { completedAt: NOW - 180 * 60_000 }),
      th("done-2d", "failed", NOW - 2 * 86_400_000, { completedAt: NOW - 2 * 86_400_000 }),
      th("settled", "completed", NOW, { settled: true }),
      th("arch", "completed", NOW, { archived: true }),
      th("sub", "running", NOW, { isSubagent: true }),
      th("run", "running", NOW - 10 * 60_000),
    ];
    expect(selectThreads(all, { maxThreads: 30 }).map((t) => t.id)).toEqual(["run", "done-3h", "done-2d"]);
    expect(DEFAULT_CAPS.maxThreads).toBe(30);
    const many = Array.from({ length: 45 }, (_, k) => th(`t${k}`, "idle", NOW - k * 60_000));
    expect(selectThreads(many, { maxThreads: DEFAULT_CAPS.maxThreads })).toHaveLength(30);
  });
  it("the focused (open in WoW) thread is always included, even when settled or old", () => {
    const many = Array.from({ length: 40 }, (_, k) => th(`t${k}`, "idle", NOW - k * 60_000));
    many.push(th("focus-settled", "completed", 1, { settled: true }));
    const out = selectThreads(many, { maxThreads: 30, focusId: "focus-settled" });
    expect(out).toHaveLength(30);
    expect(out.at(-1)!.id).toBe("focus-settled");
    expect(selectThreads(many, { maxThreads: 30, focusId: "t39" }).some((t) => t.id === "t39")).toBe(true);
  });
  it("opening (focusing) a finished thread never removes it from the snapshot", async () => {
    const t3 = new FakeT3Client(1794393000_000);
    const bridge = new Bridge({ t3, onDirty: () => {}, onAck: () => {} });
    const done = t3.threads().find((t) => t.status === "completed")!;
    const before = toJs(parseLuaChunk(bridge.render(1, 1794393000)).T3B_IN as any).threads.map((x: any) => x.id);
    bridge.focus.tid = bridge.tids.tid(done.id);
    await t3.focus(done.id);
    const after = toJs(parseLuaChunk(bridge.render(2, 1794393000 + 7200)).T3B_IN as any).threads.map((x: any) => x.id);
    expect(after).toContain(bridge.tids.tid(done.id));
    expect(after).toEqual(before);
  });
  it("30 threads with long titles fit the snapshot budget easily", () => {
    const t3 = new FakeT3Client(1794393000_000);
    const base = t3.threads()[0];
    const map = (t3 as any).map as Map<string, any>;
    map.clear();
    for (let k = 0; k < 40; k++) {
      const s = { ...base, id: `${k.toString(16).padStart(8, "0")}-0000-4000-8000-0000000000aa`, title: "T".repeat(200), status: "completed", pending: null };
      map.set(s.id, { summary: s, messages: [], pending: null, streaming: false, nextRun: 2 });
    }
    const bridge = new Bridge({ t3, onDirty: () => {}, onAck: () => {} });
    const lua = bridge.render(1, 1794393000);
    const doc = toJs(parseLuaChunk(lua).T3B_IN as any);
    expect(doc.threads).toHaveLength(30);
    expect(Buffer.byteLength(lua)).toBeLessThan(16 * 1024);
  });
});

describe("markdown marks for the addon (PROTOCOL D14)", () => {
  const md = "## Plan\n\nThis is **bold**, __also bold__ and *italic* with `code`.\n* first\n+ second\n1. third";
  it("keepMarks keeps bold and headings, normalises bullets", () => {
    expect(markdownToSegs(md, { keepMarks: true })).toEqual([["p", "# Plan\n\nThis is **bold**, **also bold** and italic with `code`.\n- first\n- second\n1. third"]]);
  });
  it("without keepMarks (tool/system rows, old behaviour) the marks are stripped", () => {
    expect(markdownToSegs(md)).toEqual([["p", "Plan\n\nThis is bold, also bold and italic with `code`.\n- first\n- second\n1. third"]]);
  });
  it("is idempotent (fitSnapshot re-segments already cleaned text)", () => {
    const once = markdownToSegs(md, { keepMarks: true })[0][1];
    expect(markdownToSegs(once, { keepMarks: true })[0][1]).toBe(once);
  });
});

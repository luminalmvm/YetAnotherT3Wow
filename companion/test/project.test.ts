// T3 wire -> domain projections, using the redacted fixtures captured from the live server.
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";
import { buildPending, itemsToMessages, ordinalToIndex, providersFromConfig, shellThreadToSummary } from "../src/t3/project.js";

const fx = (name: string) => {
  const j = JSON.parse(readFileSync(resolve(__dirname, "..", "..", "docs", "fixtures", name), "utf8"));
  return j._note ? j.data : j;
};

describe("ordinalToIndex", () => {
  it("is stable, monotonic and starts at 1", () => {
    expect(ordinalToIndex(1_000_001)).toBe(1);
    expect(ordinalToIndex(1_000_002)).toBe(2);
    expect(ordinalToIndex(2_000_001)).toBe(100_001);
    expect(ordinalToIndex(371_000_004)).toBeGreaterThan(ordinalToIndex(370_000_999));
  });
});

describe("shell + config", () => {
  it("maps a shell thread", () => {
    const t = fx("shell-snapshot.sample.json").threads[0];
    const s = shellThreadToSummary(t);
    expect(s.status).toBe("completed");
    expect(s.modelSlug).toBe("claude-opus-5-5");
    expect(s.isSubagent).toBe(false);
    expect(s.startedAt).toBeGreaterThan(0);
  });
  it("extracts selectable models per provider instance", () => {
    const p = providersFromConfig(fx("server-config.providers.json"));
    const claude = p.find((x) => x.instanceId === "claudeAgent_2")!;
    expect(claude.enabled).toBe(true);
    expect(claude.models.some((m) => m.id === "claude-haiku-4-5")).toBe(true);
    expect(p.find((x) => x.instanceId === "codex")!.enabled).toBe(false);
  });
});

describe("itemsToMessages (bounded snapshot fixture)", () => {
  const b = fx("thread-bounded.json");
  const items = b.projection.visibleTurnItems.map((v: any) => v.item);
  const msgs = itemsToMessages(items);
  it("produces user/assistant messages with stable indexes", () => {
    expect(msgs[0].role).toBe("u");
    expect(msgs[0].i).toBe(1);
    expect(msgs.some((m) => m.role === "a" && m.text.includes("print(1)"))).toBe(true);
    for (let k = 1; k < msgs.length; k++) expect(msgs[k].i).toBeGreaterThan(msgs[k - 1].i);
  });
  it("merges consecutive tool items into one t message", () => {
    const tools = [
      { type: "command_execution", ordinal: 1_000_002, input: "npm test", exitCode: 1, status: "completed" },
      { type: "file_change", ordinal: 1_000_003, fileName: "a.ts", additions: 3, deletions: 1, status: "completed" },
      { type: "dynamic_tool", ordinal: 1_000_004, toolName: "AskUserQuestion", title: { x: 1 }, status: "completed" },
      { type: "assistant_message", ordinal: 1_000_005, text: "ok", streaming: false },
    ];
    const m = itemsToMessages(tools);
    expect(m).toHaveLength(2);
    expect(m[0]).toMatchObject({ i: 2, role: "t" });
    expect(m[0].text).toBe("$ npm test (exit 1)\nedit a.ts (+3 -1)\n[AskUserQuestion]");
  });
});

describe("buildPending (live-captured requests)", () => {
  it("approval: options from the approval_request item, decision ids", () => {
    const a = fx("approval-request.pending.json");
    const p = buildPending(a.requests, a.items)!;
    expect(p.kind).toBe("approval");
    expect(p.t3Kind).toBe("command");
    expect(p.options.map((o) => o.id)).toEqual(expect.arrayContaining(["accept", "decline"]));
    expect(p.requestId.length).toBeGreaterThan(64); // why the companion maps rids
  });
  it("user input: questions with option ids o1..", () => {
    const a = fx("user-input-request.pending.json");
    const p = buildPending(a.requests, a.items)!;
    expect(p.kind).toBe("input");
    expect(p.questions![0].header).toBe("Color");
    expect(p.options).toEqual([{ id: "o1", label: "Red" }, { id: "o2", label: "Blue" }]);
  });
  it("resolved requests are not pending", () => {
    const a = fx("user-input-request.resolved.json");
    expect(buildPending(a.requests, a.items)).toBeNull();
  });
});

// Addon command -> T3 calls, ack/err bookkeeping, using the fake T3 client.
import { describe, expect, it } from "vitest";
import { Bridge } from "../src/bridge.js";
import { resolveAnswer } from "../src/actions.js";
import { FakeT3Client } from "../src/t3/fakeClient.js";
import { framesForMessage, parseFrame, type Frame } from "../src/wow/frameCodec.js";
import { parseLuaChunk, toJs } from "./helpers/luaParse.js";

const SID = Buffer.from("9f3a01c2", "hex");
const frames = (seq: number, msg: string, sid = SID): Frame[] => framesForMessage(sid, seq, Buffer.from(msg)).frames.map((f) => (parseFrame(f) as any).frame);

function setup() {
  const t3 = new FakeT3Client(1794393000_000);
  t3.streamDelayMs = 0;
  let acks = 0, dirty = 0;
  const opened: string[] = [];
  const bridge = new Bridge({ t3, onDirty: () => dirty++, onAck: () => acks++, environmentId: "env-1", openUrl: (u) => opened.push(u) });
  bridge.render(1, 1); // populates the tid map
  const tid = bridge.tids.tid(t3.threads()[0].id);
  const doc = () => toJs(parseLuaChunk(bridge.render(99, 1)).T3B_IN as any);
  return { t3, bridge, tid, doc, acks: () => acks, dirty: () => dirty, opened };
}

describe("Bridge", () => {
  it("focus -> T3 focus; ack + asid set; focus appears in the snapshot", async () => {
    const s = setup();
    for (const f of frames(1, `focus\t${s.tid}`)) s.bridge.onFrame(f);
    await s.bridge.idle();
    expect(s.t3.calls.at(-1)).toMatchObject({ method: "focus" });
    const d = s.doc();
    expect(d.ack).toBe(1);
    expect(d.asid).toBe("9f3a01c2");
    expect(d.focus.id).toBe(s.tid);
    expect(s.acks()).toBeGreaterThanOrEqual(1);
  });
  it("send uses clientMsgId as idempotency key; retransmits are executed once", async () => {
    const s = setup();
    const msg = `send\t${s.tid}\t9f3a01c2-2\thello\twith tab`;
    for (const f of frames(2, msg)) s.bridge.onFrame(f);
    for (const f of frames(2, msg)) s.bridge.onFrame({ ...f, flags: 1 }); // retransmission
    await s.bridge.idle();
    const sends = s.t3.calls.filter((c) => c.method === "sendMessage");
    expect(sends).toHaveLength(1);
    expect(sends[0].args).toEqual([s.t3.threads()[0].id, "hello\twith tab", "9f3a01c2-2"]);
    expect(s.bridge.events.some((e) => e.kind === "duplicate")).toBe(true);
  });
  it("multi-part send is reassembled and executed", async () => {
    const s = setup();
    const text = "long ".repeat(500);
    const fr = frames(3, `send\t${s.tid}\t9f3a01c2-3\t${text}`);
    expect(fr.length).toBe(3);
    for (const f of fr.reverse()) s.bridge.onFrame(f);
    await s.bridge.idle();
    expect(s.t3.calls.find((c) => c.method === "sendMessage")!.args[1]).toBe(text);
  });
  it("model / intr / unknown thread error", async () => {
    const s = setup();
    for (const f of frames(4, `model\t${s.tid}\tclaude-haiku-5-5`)) s.bridge.onFrame(f);
    for (const f of frames(5, `intr\t${s.tid}`)) s.bridge.onFrame(f);
    for (const f of frames(6, `model\tzzzzzzzz\tclaude-haiku-5-5`)) s.bridge.onFrame(f);
    await s.bridge.idle();
    expect(s.t3.calls.map((c) => c.method)).toEqual(["setModel", "interrupt"]);
    const d = s.doc();
    expect(d.ack).toBe(6);
    expect(d.err).toEqual({ seq: 6, text: "Unknown thread zzzzzzzz" });
    // a later success clears err
    for (const f of frames(7, `intr\t${s.tid}`)) s.bridge.onFrame(f);
    await s.bridge.idle();
    expect(s.doc().err).toBeFalsy();
  });
  it("ans: approval option, free text = decline with feedback, input option -> label", async () => {
    const s = setup();
    for (const f of frames(1, `focus\t${s.tid}`)) s.bridge.onFrame(f);
    await s.bridge.idle();
    const rid = s.doc().focus.pending.rid;
    for (const f of frames(2, `ans\t${s.tid}\t${rid}\tacceptForSession`)) s.bridge.onFrame(f);
    await s.bridge.idle();
    expect(s.t3.calls.at(-1)).toMatchObject({ method: "respondApproval", args: [expect.any(String), "req-approval-1", "acceptForSession", undefined] });
    // input thread (3rd)
    const t3id = s.t3.threads()[2].id;
    const tid3 = s.bridge.tids.tid(t3id);
    for (const f of frames(3, `focus\t${tid3}`)) s.bridge.onFrame(f);
    await s.bridge.idle();
    const rid3 = s.doc().focus.pending.rid;
    for (const f of frames(4, `ans\t${tid3}\t${rid3}\to2`)) s.bridge.onFrame(f);
    await s.bridge.idle();
    expect(s.t3.calls.at(-1)!.args[2]).toEqual({ "Which runner image should the workflow use?": "windows-latest" });
  });
  it("new addon session resets ack to the new sid", async () => {
    const s = setup();
    for (const f of frames(5, `intr\t${s.tid}`)) s.bridge.onFrame(f);
    for (const f of frames(1, `hello\t1\t0.2.0\t2\t8`, Buffer.from("00000002", "hex"))) s.bridge.onFrame(f);
    await s.bridge.idle();
    const d = s.doc();
    expect(d.asid).toBe("00000002");
    expect(d.ack).toBe(1);
    expect(s.bridge.addonInfo.addonVersion).toBe("0.2.0");
  });
  it("open builds a thread deep link; garbage payload -> err", async () => {
    const s = setup();
    for (const f of frames(1, `open\t${s.tid}`)) s.bridge.onFrame(f);
    for (const f of frames(2, `bogus`)) s.bridge.onFrame(f);
    await s.bridge.idle();
    expect(s.opened).toEqual([`t3code://threads/env-1/${s.t3.threads()[0].id}`]);
    expect(s.doc().err.seq).toBe(2);
  });
});

describe("resolveAnswer", () => {
  it("multi-question input: one line per question, numbers or ids", () => {
    const detail: any = { pending: { kind: "input", requestId: "q", text: "", options: [], t3Kind: "user_input", questions: [
      { id: "A", header: "", question: "", multiSelect: false, options: [{ id: "o1", label: "Red", value: "Red" }, { id: "o2", label: "Blue", value: "Blue" }] },
      { id: "B", header: "", question: "", multiSelect: false, options: [] },
    ] } };
    expect(resolveAnswer(detail, "q", "2\nfree text")).toEqual({ type: "input", answers: { A: "Blue", B: "free text" } });
  });
  it("unfocused thread: only exact decisions are honoured", () => {
    expect(resolveAnswer(null, "x", "accept")).toEqual({ type: "approval", decision: "accept" });
    expect(() => resolveAnswer(null, "x", "yes please")).toThrow();
  });
});

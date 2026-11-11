import { closeSync, existsSync, linkSync, mkdtempSync, openSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { LiveWriter, MissingLiveFileError, padContent, writeInPlace, writeRename } from "../src/wow/liveWriter.js";
import { parseLuaChunk } from "./helpers/luaParse.js";

const dir = () => mkdtempSync(join(tmpdir(), "t3b-lw-"));
const render = (seq: number, ts: number) => `T3B_IN={v=1,sid="s",seq=${seq},ts=${ts},ack=0,asid="",threads={}}\nT3B_IN_END=${seq}\n`;

describe("padContent", () => {
  it("pads to padBytes with spaces, never shrinks, errors when too big", () => {
    expect(padContent("abc", 8, 0).toString()).toBe("abc     ");
    expect(padContent("abc", 0, 6).toString()).toBe("abc   ");
    expect(padContent("abc", 4, 10).length).toBe(10);
    expect(() => padContent("abcdef", 4, 0)).toThrow();
  });
});

describe("in-place write", () => {
  it("refuses to create a missing file (PROTOCOL 2.3 rule 7)", () => {
    const f = join(dir(), "live.lua");
    expect(() => writeInPlace(f, render(1, 1), 1024)).toThrow(MissingLiveFileError);
    expect(existsSync(f)).toBe(false);
  });
  it("writes at offset 0, keeps the file size fixed, and the result parses", () => {
    const f = join(dir(), "live.lua");
    writeFileSync(f, "");
    writeInPlace(f, render(1, 1) + "-- " + "x".repeat(500) + "\n", 4096);
    expect(statSync(f).size).toBe(4096);
    writeInPlace(f, render(2, 2), 4096);
    expect(statSync(f).size).toBe(4096);
    const env = parseLuaChunk(readFileSync(f));
    expect(env.T3B_IN_END).toBe(2);
  });
  it("keeps the same inode (hard links stay connected)", () => {
    const d = dir();
    const f = join(d, "live.lua");
    writeFileSync(f, "");
    const link = join(d, "slot.lua");
    linkSync(f, link);
    writeInPlace(f, render(7, 7), 2048);
    expect(parseLuaChunk(readFileSync(link)).T3B_IN_END).toBe(7);
  });
  it("works while another handle has the file open for reading (as WoW does)", () => {
    const f = join(dir(), "live.lua");
    writeFileSync(f, "");
    const fd = openSync(f, "r");
    try { writeInPlace(f, render(3, 3), 1024); } finally { closeSync(fd); }
    expect(parseLuaChunk(readFileSync(f)).T3B_IN_END).toBe(3);
  });
});

describe("rename write", () => {
  it("replaces atomically and leaves no temp file", () => {
    const d = dir();
    const f = join(d, "live.lua");
    writeFileSync(f, "old");
    writeRename(f, render(4, 4), 1024);
    expect(statSync(f).size).toBe(1024);
    expect(existsSync(f + ".t3b-tmp")).toBe(false);
    expect(parseLuaChunk(readFileSync(f)).T3B_IN_END).toBe(4);
  });
});

describe("LiveWriter scheduling", () => {
  beforeEach(() => vi.useFakeTimers());
  afterEach(() => vi.useRealTimers());

  function make(opts: Partial<ConstructorParameters<typeof LiveWriter>[0]> = {}) {
    const f = join(dir(), "live.lua");
    writeFileSync(f, "");
    const writes: { seq: number; reason: string; at: number }[] = [];
    const w = new LiveWriter({ file: f, mode: "inplace", padBytes: 4096, debounceMs: 300, minIntervalMs: 250, heartbeatMs: 10_000, render, now: () => Date.now(), onWrite: (i) => writes.push({ seq: i.seq, reason: i.reason, at: Date.now() }), ...opts });
    return { f, w, writes };
  }

  it("seq increases by 1 per write and always equals T3B_IN_END", () => {
    const { f, w, writes } = make();
    w.start();
    w.writeNow("ack");
    w.markDirty();
    vi.advanceTimersByTime(400);
    expect(writes.map((x) => x.seq)).toEqual([1, 2, 3]);
    const env = parseLuaChunk(readFileSync(f));
    expect(env.T3B_IN_END).toBe(3);
    w.stop();
  });
  it("debounces bursts (300 ms) and caps the rate at 4/s during steady streaming", () => {
    const { w, writes } = make();
    w.start();
    const t0 = Date.now();
    for (let k = 0; k < 40; k++) { w.markDirty(); vi.advanceTimersByTime(50); } // 2 s of 20 changes/s
    vi.advanceTimersByTime(1000);
    const changes = writes.filter((x) => x.reason === "change");
    expect(changes.length).toBeGreaterThanOrEqual(2);
    expect(changes.length).toBeLessThanOrEqual(9);
    for (let k = 1; k < writes.length; k++) expect(writes[k].at - writes[k - 1].at).toBeGreaterThanOrEqual(writes[k].reason === "change" ? 250 : 0);
    expect(changes[0].at - t0).toBeLessThanOrEqual(1300); // never starved by a continuous burst
    w.stop();
  });
  it("writes a heartbeat every 10 s without changes", () => {
    const { w, writes } = make();
    w.start();
    vi.advanceTimersByTime(30_500);
    expect(writes.filter((x) => x.reason === "heartbeat").length).toBe(3);
    w.stop();
  });
  it("reports (does not throw) when the live file is missing", () => {
    const f = join(dir(), "nope.lua");
    const w = new LiveWriter({ file: f, mode: "inplace", padBytes: 1024, debounceMs: 1, minIntervalMs: 1, heartbeatMs: 1e6, render });
    expect(w.writeNow()).toBeNull();
    expect(w.lastError).toBeInstanceOf(MissingLiveFileError);
    expect(existsSync(f)).toBe(false);
  });
});

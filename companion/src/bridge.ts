// Ties T3Client state, the outbound decoder and the live.lua writer together.
import { randomBytes } from "node:crypto";
import { ActionError, executeCommand, type ActionContext } from "./actions.js";
import { log } from "./log.js";
import { DEFAULT_CAPS, emptySnapshotLua, fitSnapshot, focusToSnap, RidMap, selectThreads, threadToSnap, TidMap, type Caps, type SnapshotDoc } from "./model/snapshot.js";
import type { T3Client } from "./t3/client.js";
import type { ImageManager } from "./images/manager.js";
import { parseCommand, type Frame } from "./wow/frameCodec.js";
import { decodeUtf8, Reassembler } from "./wow/frameDecoder.js";

export function newCompanionSid(): string {
  const alphabet = "abcdefghijklmnopqrstuvwxyz0123456789";
  return [...randomBytes(6)].map((b) => alphabet[b % alphabet.length]).join("");
}

export interface BridgeOptions {
  t3: T3Client;
  caps?: Partial<Caps>;
  asciiOnly?: boolean;
  environmentId?: string;
  openUrl?: (url: string) => void;
  /** Called when state changed and live.lua should be rewritten (debounced by the writer). */
  onDirty: () => void;
  /** Called when an ack must be written immediately. */
  onAck: () => void;
  now?: () => number;
  /** Image support (PROTOCOL rev 1.3); absent = no images (seg st="off", clip/shot report it). */
  images?: ImageManager;
}

export interface InboundEvent { at: number; kind: "complete" | "duplicate" | "partial" | "error"; seq?: number; cmd?: string; detail?: string; ms?: number }

export class Bridge {
  readonly sid = newCompanionSid();
  readonly tids = new TidMap();
  readonly rids = new RidMap();
  readonly caps: Caps;
  readonly reassembler = new Reassembler();
  private ack = 0;
  private asid = "";
  private err: { seq: number; text: string } | undefined;
  readonly focus: { tid: string | null; windowStart: number | null } = { tid: null, windowStart: null };
  readonly events: InboundEvent[] = [];
  private queue: Promise<void> = Promise.resolve();
  addonInfo: Record<string, string | undefined> = {};

  constructor(private readonly o: BridgeOptions) {
    this.caps = { ...DEFAULT_CAPS, ...(o.caps ?? {}) };
    o.t3.on("change", () => o.onDirty());
  }

  private now(): number { return this.o.now ? this.o.now() : Date.now(); }

  /** Builds the snapshot document for (seq, ts). */
  buildDoc(seq: number, ts: number): SnapshotDoc {
    const t3 = this.o.t3;
    const focusT3Id = this.focus.tid ? this.tids.resolve(this.focus.tid) ?? null : null;
    const list = selectThreads(t3.threads(), { maxThreads: this.caps.maxThreads, focusId: focusT3Id });
    const providers = t3.providers();
    const projects = t3.projects();
    const threads = list.map((t) => threadToSnap(t, this.tids, projects, providers, this.caps));
    const doc: SnapshotDoc = { v: 1, sid: this.sid, seq, ts, ack: this.ack, asid: this.asid, threads };
    if (this.err) doc.err = this.err;
    const img = this.o.images;
    if (img) { img.beginRender(); doc.imgslots = img.slotsInfo(); }
    const detail = t3.focusDetail();
    if (detail && focusT3Id && detail.id === focusT3Id && this.focus.tid) {
      const tid = this.focus.tid;
      doc.focus = focusToSnap({
        detail, windowStart: this.focus.windowStart,
        resolveImage: img ? (ref) => img.resolve(ref, focusT3Id) : undefined,
        imageWindow: this.caps.focusWindow,
        staged: img?.stagedFor(tid).map((s) => ({ aid: s.aid, s: s.slot, ...(s.slot ? { w: s.w, h: s.h } : {}), name: s.name })),
        notice: img?.notice(tid),
      }, this.tids, this.rids, providers, this.caps);
    }
    return doc;
  }

  private closing = false;

  /** From now on render() writes the empty exit snapshot (privacy: no conversation text left on disk). */
  clear(): void { this.closing = true; }

  render(seq: number, ts: number): string {
    if (this.closing) return emptySnapshotLua(this.sid, seq, this.ack, this.asid);
    const doc = this.buildDoc(seq, ts);
    const { lua, shrunk } = fitSnapshot(doc, this.caps.maxSnapshotBytes, { asciiOnly: this.o.asciiOnly });
    if (shrunk) log.debug(`snapshot shrunk ${shrunk} steps to fit ${this.caps.maxSnapshotBytes} B`);
    return lua;
  }

  /** Feed one decoded (CRC-valid) frame. */
  onFrame(f: Frame): void {
    const r = this.reassembler.push(f, this.now());
    if (r.kind === "repeat") return;
    if (r.kind === "partial") { this.events.push({ at: this.now(), kind: "partial", seq: r.seq, detail: `${r.have}/${r.parts}` }); return; }
    if (r.kind === "duplicate") {
      // Retransmit of an executed message: refresh the ack only (3.6 rule 2).
      this.setAck(r.sidHex, r.seq);
      this.events.push({ at: this.now(), kind: "duplicate", seq: r.seq });
      this.o.onAck();
      return;
    }
    const { msg } = r;
    const text = decodeUtf8(msg.payload);
    this.setAck(msg.sidHex, msg.seq);
    const parsed = parseCommand(text);
    const t0 = this.now();
    if (!parsed.ok) {
      this.err = { seq: msg.seq, text: "Companion could not read that command" };
      this.events.push({ at: t0, kind: "error", seq: msg.seq, detail: parsed.reason });
      log.warn(`bad command seq ${msg.seq}: ${parsed.reason}`);
      this.o.onAck();
      return;
    }
    const cmd = parsed.cmd;
    // Ack as soon as the command has run (usually < 100 ms) so ack and err arrive in the same
    // snapshot, but never later than 1 s after receipt (3.6 rule 3; the addon waits 3 s).
    let acked = false;
    const ackNow = () => { if (!acked) { acked = true; this.o.onAck(); } };
    const ackTimer = setTimeout(ackNow, 1000);
    log.info(`addon -> ${cmd.kind} (seq ${msg.seq}${msg.parts > 1 ? `, ${msg.parts} parts` : ""})`);
    this.queue = this.queue.then(async () => {
      const ctx: ActionContext = {
        t3: this.o.t3, tids: this.tids, rids: this.rids, focus: this.focus,
        caps: { focusWindow: this.caps.focusWindow, maxFocusWindow: this.caps.maxFocusWindow },
        environmentId: this.o.environmentId, openUrl: this.o.openUrl,
        onHello: (h) => {
          this.addonInfo = { proto: h.proto, addonVersion: h.addonVersion, cell: h.cell, rows: h.rows, img: h.img };
          log.info(`addon hello: ${JSON.stringify(this.addonInfo)}`);
          // 5th hello field (rev 1.3): "0" = the user marked image slots as not working (/t3 spike img fail).
          if (this.o.images) this.o.images.addonImagesOff = h.img === "0";
        },
        images: this.o.images,
      };
      try {
        await executeCommand(ctx, cmd);
        if (this.err && msg.seq > this.err.seq) this.err = undefined; // a later command succeeded
        this.events.push({ at: this.now(), kind: "complete", seq: msg.seq, cmd: cmd.kind, ms: this.now() - t0 });
      } catch (e) {
        const m = e instanceof ActionError ? e.message : `T3 error: ${(e as Error).message}`.slice(0, 120);
        this.err = { seq: msg.seq, text: m };
        this.events.push({ at: this.now(), kind: "error", seq: msg.seq, cmd: cmd.kind, detail: (e as Error).message });
        log.warn(`command ${cmd.kind} seq ${msg.seq} failed: ${(e as Error).message}`);
      }
      clearTimeout(ackTimer);
      if (acked) this.o.onDirty(); else ackNow();
    });
  }

  private setAck(sidHex: string, seq: number): void {
    if (this.asid !== sidHex) { this.asid = sidHex; this.ack = 0; this.err = undefined; this.o.images?.onAddonSession(sidHex); }
    if (seq > this.ack) this.ack = seq;
  }

  /** Waits for queued commands (tests). */
  idle(): Promise<void> { return this.queue; }
  get ackState() { return { ack: this.ack, asid: this.asid, err: this.err }; }
}

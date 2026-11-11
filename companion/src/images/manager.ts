// Image support for the companion (PROTOCOL rev 1.3, D16-D18):
//   - inline images: T3 message attachments -> decoded, fitted to 512x512, written into a free image slot;
//     the snapshot's "img" segment names the slot once it is written.
//   - staged attachments: `clip` (Windows clipboard), `shot` (newest WoW screenshot), `unstage`; `send`
//     uploads them to T3 and attaches them to the message.
//   - focus.notice: short feedback ("No image on the clipboard").
import { createHash } from "node:crypto";
import { copyFileSync, existsSync, mkdirSync, readdirSync, readFileSync, rmSync, statSync, unlinkSync, writeFileSync } from "node:fs";
import { basename, extname, join } from "node:path";
import { log } from "../log.js";
import type { AttachmentInput, ImageRef } from "../t3/types.js";
import { decodeTga, encodePng, fitSize, resizeRgba, sniffMime, T3_IMAGE_MIMES, T3_MAX_IMAGE_BYTES, type Rgba } from "./codecs.js";
import { readRaw, type ImageTools } from "./helper.js";
import type { CachedSlot, SlotPool } from "./slots.js";
import { CANVAS, slotTga } from "./tga.js";

export type ImgState = "load" | "full" | "off" | "err" | "old";
export interface ImgInfo { s: number; w?: number; h?: number; st?: ImgState }

export interface StagedImage {
  aid: string;
  name: string;
  /** Local copy in the temp folder (deleted after sending or unstaging). */
  file: string;
  mime: string | null;
  bytes: number;
  sha: string;
  slot: number;
  w: number;
  h: number;
}

/** The part of T3Client the image code needs. */
export interface T3ImageApi {
  uploadImage(bytes: Buffer, name: string, mimeType: string): Promise<AttachmentInput>;
  fetchAttachment(ref: ImageRef): Promise<Buffer>;
}

export interface ImageManagerOptions {
  t3: T3ImageApi;
  tools: ImageTools | null;
  pool: SlotPool;
  tmpDir: string;
  screenshotsDir: string;
  onDirty: () => void;
  now?: () => number;
  maxNewPerSnapshot?: number;
  maxStaged?: number;
  maxSourceBytes?: number;
  recentScreenshotMs?: number;
  noticeMs?: number;
  /** "reload" when config images.resetOnReload is on, else "restart" (what frees slots; shown by the addon). */
  resetHint?: "reload" | "restart";
  /** Name of the WoW process (capture.processName). */
  wowProcess?: string;
}

const SHOT_EXT = /\.(jpe?g|tga|png)$/i;

export class ImageManager {
  private readonly staged = new Map<string, StagedImage[]>();
  private readonly notices = new Map<string, { text: string; nid: number; until: number }>();
  private nid = 0;
  private aidCounter = 0;
  private clipCounter = 0;
  private readonly pending = new Set<string>();
  private readonly failed = new Map<string, number>();
  private readonly queue: (() => Promise<void>)[] = [];
  private running = false;
  private newThisRender = 0;
  /** Images just sent from WoW: "name|size" -> their staged slot, so the echo in T3's history reuses it. */
  private readonly recentSent = new Map<string, CachedSlot>();
  private wowCache: { key: string; at: number } | null = null;
  /** The addon reported (hello) that image slots do not work on this client: never write slots. */
  addonImagesOff = false;

  constructor(private readonly o: ImageManagerOptions) {}

  private now(): number { return this.o.now ? this.o.now() : Date.now(); }

  /** Slots usable at all (installed, helper present, addon not opted out). */
  get slotsEnabled(): boolean { return this.o.pool.total > 0 && !!this.o.tools && !this.addonImagesOff; }

  slotsInfo(): { left: number; total: number; reset: "reload" | "restart" } {
    return { left: this.slotsEnabled ? this.o.pool.left : 0, total: this.slotsEnabled ? this.o.pool.total : 0, reset: this.o.resetHint ?? "restart" };
  }

  // ------------------------------------------------------------------------------------------
  // Inline images
  // ------------------------------------------------------------------------------------------

  /**
   * Called once per snapshot build: limits how many new images one build may start, and notices (at most
   * every few seconds, in the background) when WoW was restarted, which frees every slot.
   */
  beginRender(): void {
    this.newThisRender = 0;
    // Slots installed while the companion runs (WoW closed -> installer -> WoW started) are picked up.
    if (this.o.pool.total === 0 && this.o.tools && this.now() - this.lastDiscover >= 10_000) {
      this.lastDiscover = this.now();
      if (this.o.pool.rediscover()) this.o.onDirty();
    }
    if (this.slotsEnabled && !this.wowRefreshing && (!this.wowCache || this.now() - this.wowCache.at >= 5000)) {
      this.wowRefreshing = true;
      void this.syncWow().finally(() => { this.wowRefreshing = false; });
    }
  }
  private wowRefreshing = false;
  private lastDiscover = 0;

  /** Applies the current WoW process to the pool. Returns true when the pool was reset. */
  private async syncWow(): Promise<boolean> {
    if (!this.o.pool.setWow(await this.wowKey())) return false;
    this.o.pool.rediscover(); // a reinstall (more or fewer slots) happens with WoW closed
    this.recentSent.clear();
    this.failed.clear();
    this.o.onDirty();
    return true;
  }

  static cacheKey(ref: ImageRef): string { return `att:${ref.id}:512`; }

  /** Slot info for an attachment (sync; starts preparing it when needed). */
  resolve(ref: ImageRef, threadKey = ""): ImgInfo {
    if (!this.slotsEnabled) return { s: 0, st: "off" };
    const key = ImageManager.cacheKey(ref);
    const c = this.o.pool.get(key);
    if (c) return { s: c.slot, w: c.w, h: c.h };
    const sent = this.recentSent.get(`${threadKey}|${ref.name}|${ref.sizeBytes}`);
    if (sent) { this.o.pool.alias(key, sent); return { s: sent.slot, w: sent.w, h: sent.h }; }
    const failedAt = this.failed.get(key);
    if (failedAt !== undefined) {
      if (failedAt === -1) return { s: 0, st: "full" };
      if (this.now() - failedAt < 5 * 60_000) return { s: 0, st: "err" };
      this.failed.delete(key);
    }
    if (!this.pending.has(key)) {
      if (this.newThisRender >= (this.o.maxNewPerSnapshot ?? 8)) return { s: 0, st: "load" };
      if (this.o.pool.left <= 0) return { s: 0, st: "full" };
      this.newThisRender++;
      this.pending.add(key);
      this.enqueue(async () => {
        try { await this.prepareRemote(ref, key); }
        catch (e) { this.failed.set(key, this.now()); log.warn(`image ${ref.name}: ${(e as Error).message}`); }
        finally { this.pending.delete(key); this.o.onDirty(); }
      });
    }
    return { s: 0, st: "load" };
  }

  private enqueue(job: () => Promise<void>): void {
    this.queue.push(job);
    if (this.running) return;
    this.running = true;
    void (async () => {
      while (this.queue.length) { const j = this.queue.shift()!; await j(); }
      this.running = false;
    })();
  }

  /** Resolves when every queued image job has finished (tests). */
  async idle(): Promise<void> { while (this.running || this.queue.length) await new Promise((r) => setTimeout(r, 5)); }

  private tmpFile(ext: string): string {
    mkdirSync(this.o.tmpDir, { recursive: true });
    return join(this.o.tmpDir, `${Date.now().toString(36)}-${(++this.aidCounter).toString(36)}${ext}`);
  }

  private async prepareRemote(ref: ImageRef, key: string): Promise<void> {
    const bytes = await this.o.t3.fetchAttachment(ref);
    if (bytes.length > (this.o.maxSourceBytes ?? 20 * 1024 * 1024)) throw new Error("image too large");
    const file = this.tmpFile(extname(ref.name) || ".img");
    writeFileSync(file, bytes);
    try {
      const img = await this.decodeFit(file, bytes);
      const slot = await this.allocSlot();
      if (!slot) { this.failed.set(key, -1); return; }
      this.o.pool.write(slot, slotTga(img.data, img.w, img.h), key, img.w, img.h);
    } finally { safeUnlink(file); }
  }

  /** Decodes a file to RGBA fitted into the 512x512 canvas (TGA in TypeScript, everything else in the helper). */
  async decodeFit(file: string, bytes: Buffer): Promise<Rgba> {
    if (!sniffMime(bytes) && (/\.tga$/i.test(file) || looksLikeTga(bytes))) {
      const src = decodeTga(bytes);
      const t = fitSize(src.w, src.h, CANVAS);
      return resizeRgba(src, t.w, t.h);
    }
    if (!this.o.tools) throw new Error("image tools unavailable");
    const raw = this.tmpFile(".rgba");
    try {
      const r = await this.o.tools.decode(file, raw, CANVAS);
      return { data: readRaw(raw, r.w, r.h), w: r.w, h: r.h };
    } finally { safeUnlink(raw); }
  }

  /** WoW process key ("<pid>:<start>" or "none"), cached for a few seconds. */
  private async wowKey(): Promise<string> {
    const now = this.now();
    if (this.wowCache && now - this.wowCache.at < 5000) return this.wowCache.key;
    let key = "none";
    try {
      const list = this.o.tools ? await this.o.tools.procinfo(this.o.wowProcess ?? "Wow") : [];
      if (list.length) { const p = [...list].sort((a, b) => a.startMs - b.startMs)[0]; key = `${p.pid}:${p.startMs}`; }
    } catch { /* treat as not running */ }
    this.wowCache = { key, at: now };
    return key;
  }

  /** A fresh slot for the current WoW process (0 = none left). */
  private async allocSlot(): Promise<number> {
    if (!this.slotsEnabled) return 0;
    await this.syncWow();
    return this.o.pool.alloc();
  }

  /** A new addon session (hello / new asid). */
  onAddonSession(asid: string): void {
    if (this.o.pool.onAddonSession(asid)) { this.recentSent.clear(); this.o.onDirty(); }
  }

  // ------------------------------------------------------------------------------------------
  // Notices
  // ------------------------------------------------------------------------------------------

  notify(tid: string, text: string): void {
    const ms = this.o.noticeMs ?? 6000;
    this.notices.set(tid, { text, nid: ++this.nid, until: this.now() + ms });
    this.o.onDirty();
    setTimeout(() => this.o.onDirty(), ms + 50).unref?.();
  }

  notice(tid: string): { text: string; nid: number } | undefined {
    const n = this.notices.get(tid);
    if (!n) return undefined;
    if (this.now() > n.until) { this.notices.delete(tid); return undefined; }
    return { text: n.text, nid: n.nid };
  }

  // ------------------------------------------------------------------------------------------
  // Staged attachments
  // ------------------------------------------------------------------------------------------

  stagedFor(tid: string): readonly StagedImage[] { return this.staged.get(tid) ?? []; }

  /** `clip <tid> <quiet>`: stage the clipboard image. quiet = silently ignore "no image" (Ctrl+V). */
  async clip(tid: string, quiet: boolean): Promise<void> {
    if (!this.o.tools) { if (!quiet) this.notify(tid, "Image tools missing (rebuild the capture helper)"); return; }
    const out = this.tmpFile(".png");
    let r;
    try { r = await this.o.tools.clipboard(out); }
    catch (e) { safeUnlink(out); if (!quiet) this.notify(tid, "Could not read the clipboard"); log.warn(`clipboard: ${(e as Error).message}`); return; }
    if (!r) { safeUnlink(out); if (!quiet) this.notify(tid, "No image on the clipboard"); return; }
    // The helper always writes PNG; a copied image file keeps its name stem.
    const name = r.name ? `${r.name.replace(/\.[^.]+$/, "")}.png` : `clip-${++this.clipCounter}.png`;
    await this.stageFile(tid, out, name);
  }

  /** `shot <tid>`: stage the newest WoW screenshot if it is recent. */
  async shot(tid: string): Promise<void> {
    const dir = this.o.screenshotsDir;
    let best: { file: string; mtime: number } | null = null;
    try {
      for (const f of readdirSync(dir)) {
        if (!SHOT_EXT.test(f)) continue;
        const p = join(dir, f);
        const m = statSync(p).mtimeMs;
        if (!best || m > best.mtime) best = { file: p, mtime: m };
      }
    } catch { /* no screenshots folder yet */ }
    if (!best || this.now() - best.mtime > (this.o.recentScreenshotMs ?? 15 * 60_000)) {
      this.notify(tid, "No recent screenshot (Print Screen takes one)");
      return;
    }
    const copy = this.tmpFile(extname(best.file).toLowerCase());
    copyFileSync(best.file, copy); // never modify the user's screenshot
    await this.stageFile(tid, copy, basename(best.file));
  }

  /** Stages a temp file (takes ownership of it). */
  async stageFile(tid: string, file: string, name: string): Promise<void> {
    const list = this.staged.get(tid) ?? [];
    const bytes = readFileSync(file);
    if (bytes.length > (this.o.maxSourceBytes ?? 20 * 1024 * 1024)) { safeUnlink(file); this.notify(tid, "Image too large (max 20 MB)"); return; }
    const sha = createHash("sha256").update(bytes).digest("hex");
    if (list.some((s) => s.sha === sha)) { safeUnlink(file); this.notify(tid, "That image is already attached"); return; }
    if (list.length >= (this.o.maxStaged ?? 4)) { safeUnlink(file); this.notify(tid, `At most ${this.o.maxStaged ?? 4} images per message`); return; }
    let slot = 0, w = 0, h = 0;
    try {
      const img = await this.decodeFit(file, bytes);
      w = img.w; h = img.h;
      const key = `stage:${sha}:512`;
      const cached = this.o.pool.get(key);
      if (cached && this.slotsEnabled) slot = cached.slot;
      else {
        slot = await this.allocSlot();
        if (slot) this.o.pool.write(slot, slotTga(img.data, img.w, img.h), key, img.w, img.h);
      }
    } catch (e) {
      log.warn(`staged image ${name}: ${(e as Error).message}`);
      if (!sniffMime(bytes) && !looksLikeTga(bytes)) { safeUnlink(file); this.notify(tid, "That file is not an image"); return; }
    }
    const item: StagedImage = { aid: "k" + (++this.aidCounter).toString(36), name: clipName(name), file, mime: sniffMime(bytes), bytes: bytes.length, sha, slot, w, h };
    list.push(item);
    this.staged.set(tid, list);
    log.info(`staged image ${item.aid} (${item.bytes} B${slot ? `, slot ${slot}` : ""}) for ${tid}`);
    this.o.onDirty();
  }

  unstage(tid: string, aid: string): void {
    const list = this.staged.get(tid) ?? [];
    const k = list.findIndex((s) => s.aid === aid);
    if (k < 0) return;
    safeUnlink(list[k].file);
    list.splice(k, 1);
    if (!list.length) this.staged.delete(tid);
    this.o.onDirty();
  }

  /**
   * Uploads the staged images of tid to T3 (for `send`). Returns the attachment inputs and a commit()
   * that clears the staged list after the message was dispatched. On failure nothing is cleared.
   */
  async prepareSend(tid: string, threadKey: string): Promise<{ attachments: AttachmentInput[]; commit: () => void }> {
    const list = [...(this.staged.get(tid) ?? [])];
    const attachments: AttachmentInput[] = [];
    for (const s of list) {
      const up = await this.uploadBytes(s);
      attachments.push(await this.o.t3.uploadImage(up.bytes, up.name, up.mime));
    }
    return {
      attachments,
      commit: () => {
        for (const [k, s] of list.entries()) {
          if (s.slot) this.recentSent.set(`${threadKey}|${attachments[k].name}|${attachments[k].sizeBytes}`, { slot: s.slot, w: s.w, h: s.h });
          safeUnlink(s.file);
        }
        const rest = (this.staged.get(tid) ?? []).filter((s) => !list.includes(s));
        if (rest.length) this.staged.set(tid, rest); else this.staged.delete(tid);
        this.o.onDirty();
      },
    };
  }

  /** The bytes to upload: the original when T3 accepts it, else PNG (TGA) or JPEG (everything else / too big). */
  private async uploadBytes(s: StagedImage): Promise<{ bytes: Buffer; name: string; mime: string }> {
    const orig = readFileSync(s.file);
    const stem = s.name.replace(/\.[A-Za-z0-9]{1,5}$/, "");
    if (s.mime && T3_IMAGE_MIMES.has(s.mime) && orig.length <= T3_MAX_IMAGE_BYTES) return { bytes: orig, name: s.name, mime: s.mime };
    if (!s.mime && looksLikeTga(orig)) {
      const png = encodePng(decodeTga(orig));
      if (png.length <= T3_MAX_IMAGE_BYTES) return { bytes: png, name: `${stem}.png`, mime: "image/png" };
      const pngFile = this.tmpFile(".png");
      writeFileSync(pngFile, png);
      try { return await this.toJpeg(pngFile, stem); } finally { safeUnlink(pngFile); }
    }
    return this.toJpeg(s.file, stem);
  }

  private async toJpeg(file: string, stem: string): Promise<{ bytes: Buffer; name: string; mime: string }> {
    if (!this.o.tools) throw new Error("image tools unavailable");
    for (const [edge, q] of [[4096, 90], [2560, 85], [1600, 80]] as const) {
      const out = this.tmpFile(".jpg");
      try {
        await this.o.tools.convert(file, out, edge, q);
        const b = readFileSync(out);
        if (b.length <= T3_MAX_IMAGE_BYTES) return { bytes: b, name: `${stem}.jpg`, mime: "image/jpeg" };
      } finally { safeUnlink(out); }
    }
    throw new Error("image too large to upload");
  }

  // ------------------------------------------------------------------------------------------
  // Shutdown
  // ------------------------------------------------------------------------------------------

  /** Privacy on stop: blank every used slot and delete temp files. */
  stop(): number {
    const n = this.o.pool.blankUsed();
    for (const list of this.staged.values()) for (const s of list) safeUnlink(s.file);
    this.staged.clear();
    try { rmSync(this.o.tmpDir, { recursive: true, force: true }); } catch { /* ignore */ }
    return n;
  }
}

function safeUnlink(f: string): void { try { if (existsSync(f)) unlinkSync(f); } catch { /* ignore */ } }

/** True when the bytes plausibly start with an uncompressed/RLE true-colour or grey TGA header. */
export function looksLikeTga(b: Uint8Array): boolean {
  if (b.length < 18) return false;
  return [2, 3, 10, 11].includes(b[2]) && b[1] === 0 && [8, 24, 32].includes(b[16]) && (b[12] | (b[13] << 8)) > 0 && (b[14] | (b[15] << 8)) > 0;
}

/** File name shown in WoW and sent to T3: no path, safe characters, at most 64 bytes. */
export function clipName(name: string): string {
  const n = basename(name).replace(/[^\w.\- ()]+/g, "_").trim() || "image";
  return n.length > 64 ? n.slice(0, 64) : n;
}

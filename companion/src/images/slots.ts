// Image slot pool (PROTOCOL rev 1.3, D16). The installer creates <AddOns>\T3Bridge_Img\i0001.tga ... iNNNN.tga
// (fixed-size transparent TGAs) before WoW starts. WoW caches a texture the first time it loads it, so each
// slot shows ONE image per WoW session: slots are "burned" per WoW process (pid + start time). A new WoW
// process frees them all; optionally (config images.resetOnReload, only if `/t3 spike img` showed that
// /reload frees textures) so does a new addon session.
//
// Rules: never create slot files (WoW would not see them), overwrite in place at the same size, write a
// slot completely before any snapshot names it, and blank every used slot on stop (privacy).
import { closeSync, existsSync, mkdirSync, openSync, readFileSync, statSync, writeFileSync, writeSync } from "node:fs";
import { dirname, join } from "node:path";
import { log } from "../log.js";
import { blankSlot, SLOT_BYTES } from "./tga.js";

export interface CachedSlot { slot: number; w: number; h: number }

interface PoolState {
  /** WoW process the burned slots belong to ("<pid>:<startMs>", or "none" when WoW was not running). */
  key: string;
  /** Last addon session id seen (asid), for resetOnReload. */
  asid: string;
  /** Next never-used slot (1-based). */
  next: number;
  /** Slots written in this pool (to blank them on stop). */
  used: number[];
  /** Cache key (attachment id + variant, or staged hash) -> slot. Valid only while the slot holds that image. */
  cache: Record<string, CachedSlot>;
}

export interface SlotPoolOptions {
  /** <AddOns>\T3Bridge_Img, or null when image slots are not installed. */
  dir: string | null;
  /** %LOCALAPPDATA%\T3Bridge\imgslots.json */
  stateFile: string;
  resetOnReload: boolean;
  /** Overridable for tests. */
  writeSlotFile?: (file: string, data: Buffer) => void;
}

export const slotName = (n: number) => `i${String(n).padStart(4, "0")}.tga`;

/** Overwrites an existing file in place (offset 0, same size). Never creates it. Retries while WoW holds it. */
export function writeSlotInPlace(file: string, data: Buffer): void {
  if (!existsSync(file)) throw new Error(`slot file missing: ${file}`);
  let lastErr: unknown;
  for (let attempt = 0; attempt < 10; attempt++) {
    try {
      const fd = openSync(file, "r+");
      try {
        let off = 0;
        while (off < data.length) off += writeSync(fd, data, off, data.length - off, off);
      } finally { closeSync(fd); }
      return;
    } catch (e) {
      lastErr = e;
      const t = Date.now(); while (Date.now() - t < 50) { /* short busy wait: WoW reads slots quickly */ }
    }
  }
  throw lastErr;
}

export class SlotPool {
  total = 0;
  private st: PoolState = { key: "", asid: "", next: 1, used: [], cache: {} };

  constructor(private readonly o: SlotPoolOptions) {
    this.total = this.discover();
    this.load();
  }

  /**
   * Counts the slots again (the folder may have been installed while the companion ran: the user closes WoW,
   * runs the installer, starts WoW). Returns true when the count changed.
   */
  rediscover(): boolean {
    const n = this.discover();
    if (n === this.total) return false;
    log.info(`image slots: ${n} installed (was ${this.total})`);
    this.total = n;
    if (this.st.next > n + 1) this.st.next = n + 1;
    return true;
  }

  /** Number of consecutive valid slot files i0001.. in the slot folder. */
  discover(): number {
    if (!this.o.dir || !existsSync(this.o.dir)) return 0;
    let n = 0;
    for (;;) {
      const f = join(this.o.dir, slotName(n + 1));
      try { if (!existsSync(f) || statSync(f).size !== SLOT_BYTES) break; } catch { break; }
      n++;
      if (n >= 9999) break;
    }
    return n;
  }

  private load(): void {
    try {
      if (existsSync(this.o.stateFile)) {
        const j = JSON.parse(readFileSync(this.o.stateFile, "utf8"));
        if (j && typeof j.key === "string" && Number.isInteger(j.next)) {
          this.st = { key: j.key, asid: String(j.asid ?? ""), next: j.next, used: Array.isArray(j.used) ? j.used.filter(Number.isInteger) : [], cache: j.cache && typeof j.cache === "object" ? j.cache : {} };
        }
      }
    } catch (e) { log.warn(`image slot state unreadable, starting fresh: ${(e as Error).message}`); }
  }

  private save(): void {
    try {
      mkdirSync(dirname(this.o.stateFile), { recursive: true });
      writeFileSync(this.o.stateFile, JSON.stringify(this.st));
    } catch (e) { log.warn(`could not save image slot state: ${(e as Error).message}`); }
  }

  get key(): string { return this.st.key; }
  get left(): number { return Math.max(0, this.total - this.st.next + 1); }
  get usedSlots(): readonly number[] { return this.st.used; }

  private reset(why: string): void {
    // Blank what the previous pool wrote (it may still hold images after a crash), then start over.
    this.blankUsed();
    this.st.next = 1;
    this.st.used = [];
    this.st.cache = {};
    log.info(`image slots reset (${why}): ${this.total} free`);
  }

  /** The WoW process changed (or appeared): every slot is fresh again for that process. */
  setWow(key: string): boolean {
    if (key === this.st.key) return false;
    const first = this.st.key === "";
    this.reset(first ? "first run" : `WoW process ${key === "none" ? "ended" : "changed"}`);
    this.st.key = key;
    this.save();
    return true;
  }

  /** A new addon session (asid). Resets the pool only when /reload frees textures (config). */
  onAddonSession(asid: string): boolean {
    if (!asid || asid === this.st.asid) return false;
    const had = this.st.asid !== "";
    this.st.asid = asid;
    if (had && this.o.resetOnReload) { this.reset("addon reloaded"); this.save(); return true; }
    this.save();
    return false;
  }

  get(cacheKey: string): CachedSlot | undefined { return this.st.cache[cacheKey]; }

  /** Takes the next never-used slot; 0 when the pool is empty. */
  alloc(): number {
    if (this.st.next > this.total) return 0;
    const s = this.st.next++;
    this.st.used.push(s);
    this.save();
    return s;
  }

  /** Writes a slot file (in place) and records what it holds. */
  write(slot: number, tga: Buffer, cacheKey: string, w: number, h: number): void {
    if (!this.o.dir) throw new Error("no image slots installed");
    if (tga.length !== SLOT_BYTES) throw new Error(`slot data must be ${SLOT_BYTES} bytes`);
    (this.o.writeSlotFile ?? writeSlotInPlace)(join(this.o.dir, slotName(slot)), tga);
    this.st.cache[cacheKey] = { slot, w, h };
    this.save();
  }

  /** Alias an existing cached slot under another key (the same image under its final attachment id). */
  alias(cacheKey: string, c: CachedSlot): void { this.st.cache[cacheKey] = c; this.save(); }

  /**
   * Overwrites every used slot with the transparent placeholder (privacy, on stop). The burned counter is
   * kept (WoW may have cached those slots), the cache is dropped (the files no longer hold the images).
   */
  blankUsed(): number {
    if (!this.o.dir || !this.st.used.length) { this.st.cache = {}; return 0; }
    const blank = blankSlot();
    let n = 0;
    for (const s of this.st.used) {
      try { (this.o.writeSlotFile ?? writeSlotInPlace)(join(this.o.dir, slotName(s)), blank); n++; }
      catch (e) { log.warn(`could not blank image slot ${s}: ${(e as Error).message}`); }
    }
    this.st.cache = {};
    this.save();
    return n;
  }
}

// SECONDARY outbound channel (fallback only): watch WoW's Screenshots folder for new files and decode the
// matrix from their top-left region. The primary channel is live window capture (captureClient.ts);
// screenshots make the game hitch and flash, which the user does not want.
// Safety: never creates the folder, never deletes or modifies existing screenshots (deleting a
// decoded matrix screenshot is opt-in via config and only ever applies to files that contained a valid frame).
import { existsSync, readdirSync, readFileSync, statSync, unlinkSync, watch, type FSWatcher } from "node:fs";
import { join } from "node:path";
import { log } from "../log.js";
import { decodeImage, type DecodeResult } from "./frameDecoder.js";
import { decodeImageFileRegion } from "./imageDecode.js";
import type { Frame } from "./frameCodec.js";

export interface ScreenshotWatcherOptions {
  dir: string;
  regionW: number;
  regionH: number;
  deleteDecoded: boolean;
  onFrame: (f: Frame, file: string) => void;
}

const IMG = /\.(png|tga|bmp|jpe?g)$/i;

export class ScreenshotWatcher {
  private watcher?: FSWatcher;
  private seen = new Set<string>();
  private pollTimer?: NodeJS.Timeout;
  private started = Date.now();

  constructor(private readonly o: ScreenshotWatcherOptions) {}

  start(): void {
    this.started = Date.now();
    if (!existsSync(this.o.dir)) {
      log.info(`Screenshots folder ${this.o.dir} does not exist yet; waiting for WoW to create it`);
      this.pollTimer = setInterval(() => { if (existsSync(this.o.dir)) { clearInterval(this.pollTimer); this.start(); } }, 5000);
      return;
    }
    // Pre-existing screenshots are never processed.
    for (const f of readdirSync(this.o.dir)) this.seen.add(f);
    this.watcher = watch(this.o.dir, (_ev, name) => { if (name && IMG.test(name) && !this.seen.has(name)) void this.handle(String(name)); });
    log.info(`watching ${this.o.dir} for matrix screenshots (fallback channel)`);
  }

  stop(): void { this.watcher?.close(); if (this.pollTimer) clearInterval(this.pollTimer); }

  private async waitStable(path: string): Promise<boolean> {
    let last = -1;
    for (let k = 0; k < 40; k++) {
      try {
        const s = statSync(path);
        if (s.size > 0 && s.size === last && s.mtimeMs >= this.started - 1000) return true;
        last = s.size;
      } catch { /* not there yet */ }
      await new Promise((r) => setTimeout(r, 75));
    }
    return false;
  }

  private async handle(name: string): Promise<void> {
    this.seen.add(name);
    const path = join(this.o.dir, name);
    if (/\.jpe?g$/i.test(name)) { log.warn(`screenshot ${name} is JPEG; the matrix needs lossless screenshots (/console screenshotFormat png)`); return; }
    if (!(await this.waitStable(path))) return;
    let res: DecodeResult;
    try {
      const img = decodeImageFileRegion(name, readFileSync(path), this.o.regionW, this.o.regionH);
      res = decodeImage(img);
    } catch (e) { log.debug(`screenshot ${name}: ${(e as Error).message}`); return; }
    if (!res.ok) { log.debug(`screenshot ${name}: no frame (${res.reason})`); return; }
    this.o.onFrame(res.frame, path);
    if (this.o.deleteDecoded) {
      try { unlinkSync(path); } catch (e) { log.warn(`could not delete ${name}: ${(e as Error).message}`); }
    }
  }
}

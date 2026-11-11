// Runs the capture helper's one-shot image tools (capture-helper/T3Capture/Tools.cs): clipboard, decode,
// convert, procinfo. An older helper build without these tools is detected (`version` fails) and the next
// candidate is tried, so a stale copy in %LOCALAPPDATA%\T3Bridge\capture does not break images.
import { execFile } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { log } from "../log.js";

export interface ToolResult { code: number; json: any }

export interface ImageTools {
  /** Image on the clipboard -> PNG at outPng. null = no image on the clipboard. */
  clipboard(outPng: string): Promise<{ source: string; bytes: number; name?: string } | null>;
  /** Decode + EXIF-rotate + fit into max x max -> raw RGBA file. */
  decode(inFile: string, outRaw: string, max: number): Promise<{ w: number; h: number; srcW: number; srcH: number }>;
  /** Re-encode as JPEG (uploads over T3's size limit, or formats T3 does not accept). */
  convert(inFile: string, outJpg: string, maxEdge: number, quality: number): Promise<{ w: number; h: number; bytes: number }>;
  /** Running processes with this name: pid and start time. */
  procinfo(name: string): Promise<{ pid: number; startMs: number }[]>;
}

export function helperCandidates(configured?: string): string[] {
  const here = dirname(fileURLToPath(import.meta.url));
  return [
    configured,
    process.env.T3B_CAPTURE_HELPER,
    join(process.env.LOCALAPPDATA ?? "", "T3Bridge", "capture", "T3Capture.exe"),
    resolve(here, "..", "..", "..", "capture-helper", "T3Capture", "bin", "Release", "net7.0-windows10.0.22621.0", "T3Capture.exe"),
  ].filter((p): p is string => !!p && existsSync(p));
}

function run(exe: string, args: string[], timeoutMs: number): Promise<ToolResult> {
  return new Promise((res) => {
    execFile(exe, args, { windowsHide: true, timeout: timeoutMs, maxBuffer: 1024 * 1024 }, (err, stdout) => {
      const code = err ? (typeof (err as any).code === "number" ? (err as any).code : 1) : 0;
      let json: any = null;
      const line = String(stdout ?? "").trim().split(/\r?\n/).pop() ?? "";
      try { json = line ? JSON.parse(line) : null; } catch { json = null; }
      res({ code, json });
    });
  });
}

export class HelperImageTools implements ImageTools {
  private exe: Promise<string | null> | undefined;
  constructor(private readonly configured?: string, private readonly timeoutMs = 20000) {}

  /** The first helper that supports the image tools, or null. */
  resolveExe(): Promise<string | null> {
    // One lookup, shared by concurrent callers.
    this.exe ??= (async () => {
      for (const c of helperCandidates(this.configured)) {
        const r = await run(c, ["version"], 10000);
        if (r.code === 0 && r.json && r.json.version >= 2) { log.info(`image tools: ${c}`); return c; }
      }
      log.warn("image tools unavailable: no T3Capture.exe with image support (rebuild: dotnet build -c Release capture-helper/T3Capture)");
      return null;
    })();
    return this.exe;
  }

  private async tool(args: string[]): Promise<ToolResult> {
    const exe = await this.resolveExe();
    if (!exe) throw new Error("image tools unavailable");
    return run(exe, args, this.timeoutMs);
  }

  async clipboard(outPng: string) {
    const r = await this.tool(["clipboard", "--out", outPng]);
    if (r.code === 2) return null;
    if (r.code !== 0) throw new Error(r.json?.error ?? `clipboard tool failed (${r.code})`);
    return { source: String(r.json?.source ?? ""), bytes: Number(r.json?.bytes ?? 0), ...(r.json?.name ? { name: String(r.json.name) } : {}) };
  }

  async decode(inFile: string, outRaw: string, max: number) {
    const r = await this.tool(["decode", "--in", inFile, "--out", outRaw, "--max", String(max)]);
    if (r.code !== 0 || !r.json) throw new Error(r.json?.error ?? `decode failed (${r.code})`);
    return { w: Number(r.json.w), h: Number(r.json.h), srcW: Number(r.json.srcW), srcH: Number(r.json.srcH) };
  }

  async convert(inFile: string, outJpg: string, maxEdge: number, quality: number) {
    const r = await this.tool(["convert", "--in", inFile, "--out", outJpg, "--max-edge", String(maxEdge), "--quality", String(quality)]);
    if (r.code !== 0 || !r.json) throw new Error(r.json?.error ?? `convert failed (${r.code})`);
    return { w: Number(r.json.w), h: Number(r.json.h), bytes: Number(r.json.bytes) };
  }

  async procinfo(name: string) {
    const r = await this.tool(["procinfo", "--process", name]);
    if (r.code !== 0 || !Array.isArray(r.json)) return [];
    return r.json.map((p: any) => ({ pid: Number(p.pid), startMs: Number(p.startMs) }));
  }
}

/** Reads a raw RGBA file written by `decode`. */
export function readRaw(file: string, w: number, h: number): Uint8Array {
  const b = readFileSync(file);
  if (b.length !== w * h * 4) throw new Error(`raw image is ${b.length} bytes, expected ${w * h * 4}`);
  return new Uint8Array(b.buffer, b.byteOffset, b.length);
}

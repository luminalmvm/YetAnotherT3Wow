// Minimal logger with secret redaction. Never pass raw tokens to it; redaction is a second line of defence.
import { appendFileSync, mkdirSync, renameSync, statSync } from "node:fs";
import { dirname } from "node:path";

export type Level = "debug" | "info" | "warn" | "error";
const ORDER: Record<Level, number> = { debug: 10, info: 20, warn: 30, error: 40 };

let minLevel: Level = (process.env.T3B_LOG_LEVEL as Level) || "info";
let logFile: string | undefined;
let quiet = false;

export function configureLog(opts: { level?: Level; file?: string; quiet?: boolean }): void {
  if (opts.level) minLevel = opts.level;
  if (opts.file) {
    logFile = opts.file;
    try { mkdirSync(dirname(logFile), { recursive: true }); } catch { /* ignore */ }
    // Keep at most ~2 x 2 MB: rotate to companion.log.1 at start-up.
    try { if (statSync(logFile).size > 2 * 1024 * 1024) renameSync(logFile, logFile + ".1"); } catch { /* missing or busy */ }
  }
  if (opts.quiet !== undefined) quiet = opts.quiet;
}

/** Redacts bearer tokens, tickets, pairing tokens and long opaque secrets from a log line. */
export function redact(s: string): string {
  return s
    .replace(/(bearer\s+)[A-Za-z0-9._~+/=-]+/gi, "$1<redacted>")
    .replace(/((?:wsTicket|token|ticket|credential|access_token|subject_token|authorization)["']?\s*[:=]\s*["']?)[^"'&\s,}]+/gi, "$1<redacted>")
    .replace(/(#token=)[^&\s]+/gi, "$1<redacted>")
    .replace(/\b[A-Za-z0-9_-]{40,}\.[A-Za-z0-9_-]{10,}(\.[A-Za-z0-9_-]+)?\b/g, "<redacted-jwt>");
}

function emit(level: Level, msg: string, extra?: unknown): void {
  if (ORDER[level] < ORDER[minLevel]) return;
  let line = `${new Date().toISOString()} ${level.toUpperCase().padEnd(5)} ${msg}`;
  if (extra !== undefined) {
    let e: string;
    if (extra instanceof Error) e = extra.stack ?? extra.message;
    else { try { e = JSON.stringify(extra); } catch { e = String(extra); } }
    line += " " + e;
  }
  line = redact(line);
  if (!quiet) (level === "error" || level === "warn" ? process.stderr : process.stdout).write(line + "\n");
  if (logFile) { try { appendFileSync(logFile, line + "\n"); } catch { /* ignore */ } }
}

export const log = {
  debug: (m: string, e?: unknown) => emit("debug", m, e),
  info: (m: string, e?: unknown) => emit("info", m, e),
  warn: (m: string, e?: unknown) => emit("warn", m, e),
  error: (m: string, e?: unknown) => emit("error", m, e),
};

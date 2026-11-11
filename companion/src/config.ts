// Companion configuration: %LOCALAPPDATA%\T3Bridge\config.json (merged over defaults).
// The WoW folder defaults to $T3B_WOW_PATH, then the first "World of Warcraft\<flavor>" found in common
// folders on drives C: to Z:. Set "wowRoot" in config.json (scripts\install-companion.ps1 does) to pin it.
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

export type WriteMode = "inplace" | "rename";
export type CaptureMode = "wgc" | "screenshot" | "off";

export interface CompanionConfig {
  /** WoW flavor folder (contains Interface\AddOns), e.g. <WoW dir>\_forever_ */
  wowRoot: string;
  /** Overrides; default derived from wowRoot. */
  addonsDir?: string;
  liveFile?: string;
  inboxFile?: string;
  /** PROTOCOL.md 2.3: in place is required for hard-link slots (variant B). */
  writeMode: WriteMode;
  /** Pad live.lua to exactly this many bytes (PROTOCOL.md D6). 0 = no padding. */
  padBytes: number;
  /** Escape every byte >= 0x80 as \ddd (produces identical Lua strings; larger file). PROTOCOL.md default: raw UTF-8. */
  asciiOnly: boolean;
  /** Transliterate characters the WoW fonts lack (smart quotes, dashes, emoji) to ASCII. */
  transliterate: boolean;
  debounceMs: number;
  minWriteIntervalMs: number;
  heartbeatMs: number;
  inboxIntervalMs: number;
  maxThreads: number;
  focusWindow: number;
  maxFocusWindow: number;
  maxMessageBytes: number;
  maxSnapshotBytes: number;
  t3: {
    /** server-runtime.json path */
    runtimeFile: string;
    /** t3.cmd path */
    cliPath: string;
    /** Bearer TTL requested from `t3 auth session issue`. */
    tokenTtl: string;
    /** Poll interval for the shell snapshot when the WebSocket subscription is not available. */
    pollMs: number;
  };
  capture: {
    mode: CaptureMode;
    helperPath: string;
    processName: string;
    regionWidth: number;
    regionHeight: number;
    idleFps: number;
    activeFps: number;
    activeHoldMs: number;
    /** Screenshot fallback directory. */
    screenshotsDir: string;
    /** Screenshot fallback: delete a screenshot after decoding only if it contained a T3 frame. Default false: never delete. */
    deleteDecodedScreenshots: boolean;
  };
}

export function appDataDir(): string {
  const base = process.env.LOCALAPPDATA || join(homedir(), "AppData", "Local");
  return join(base, "T3Bridge");
}

export function configPath(): string { return process.env.T3B_CONFIG || join(appDataDir(), "config.json"); }

const WOW_PARENTS = ["", "Program Files (x86)", "Program Files", "Games", "Blizzard", "Battle.net"];

/** Best guess for the WoW flavor folder: $T3B_WOW_PATH, else a search of common folders on C: to Z:. */
export function detectWowRoot(flavor = process.env.T3B_WOW_FLAVOR || "_forever_"): string {
  const env = process.env.T3B_WOW_PATH;
  if (env) return existsSync(join(env, flavor, "Interface")) ? join(env, flavor) : env;
  if (process.platform === "win32") {
    for (let c = 67; c <= 90; c++) {
      const drive = String.fromCharCode(c) + ":\\";
      if (!existsSync(drive)) continue;
      for (const parent of WOW_PARENTS) {
        const dir = join(drive, parent, "World of Warcraft", flavor);
        if (existsSync(join(dir, "Interface")) || existsSync(join(dir, "WTF"))) return dir;
      }
    }
  }
  return join("C:\\", "Program Files (x86)", "World of Warcraft", flavor);
}

export function defaultConfig(): CompanionConfig {
  const home = homedir();
  const wowRoot = detectWowRoot();
  return {
    wowRoot,
    writeMode: "inplace",
    padBytes: 524288,
    asciiOnly: false,
    transliterate: true,
    debounceMs: 300,
    minWriteIntervalMs: 250,
    heartbeatMs: 10000,
    inboxIntervalMs: 5000,
    maxThreads: 30,
    focusWindow: 40,
    maxFocusWindow: 120,
    maxMessageBytes: 8000,
    maxSnapshotBytes: 480 * 1024,
    t3: {
      runtimeFile: join(home, ".t3", "userdata", "server-runtime.json"),
      cliPath: join(home, ".t3", "bin", "t3.cmd"),
      tokenTtl: "90d",
      pollMs: 3000,
    },
    capture: {
      mode: "wgc",
      helperPath: "",
      processName: "Wow",
      regionWidth: 1100,
      regionHeight: 200,
      idleFps: 10,
      activeFps: 30,
      activeHoldMs: 3000,
      screenshotsDir: join(wowRoot, "Screenshots"),
      deleteDecodedScreenshots: false,
    },
  };
}

function deepMerge<T>(base: T, over: unknown): T {
  if (over === null || typeof over !== "object" || Array.isArray(over)) return base;
  const out: any = Array.isArray(base) ? [...(base as any)] : { ...(base as any) };
  for (const [k, v] of Object.entries(over as Record<string, unknown>)) {
    const b = (base as any)[k];
    out[k] = b && typeof b === "object" && !Array.isArray(b) && v && typeof v === "object" && !Array.isArray(v) ? deepMerge(b, v) : v;
  }
  return out;
}

export function loadConfig(path = configPath()): CompanionConfig {
  const def = defaultConfig();
  if (!existsSync(path)) return def;
  const raw = JSON.parse(readFileSync(path, "utf8").replace(/^\uFEFF/, ""));
  return deepMerge(def, raw);
}

export function saveConfig(cfg: Partial<CompanionConfig>, path = configPath()): void {
  mkdirSync(join(path, ".."), { recursive: true });
  writeFileSync(path, JSON.stringify(cfg, null, 2) + "\n", "utf8");
}

export function resolvePaths(cfg: CompanionConfig) {
  const addonsDir = cfg.addonsDir ?? join(cfg.wowRoot, "Interface", "AddOns");
  return {
    addonsDir,
    liveFile: cfg.liveFile ?? join(addonsDir, "T3Bridge_Live", "live.lua"),
    inboxFile: cfg.inboxFile ?? join(addonsDir, "T3Bridge", "Inbox.lua"),
  };
}

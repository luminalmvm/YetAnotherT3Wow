// T3Bridge companion entry point.
//
//   node dist/main.js                 run the bridge (T3 <-> live.lua, outbound capture)
//   node dist/main.js --demo [--out <file>] [--no-capture]   demo data, no T3 needed (reacts to addon commands)
//   node dist/main.js --selftest      decoder self-test against synthetic frames
//   node dist/main.js --status        discovery + credential + paths check (no writes)
//   node dist/main.js --login         issue/refresh the scoped T3 credential (DPAPI-stored)
//   node dist/main.js --pair          read a one-time pairing token from stdin and exchange it
//   node dist/main.js --once [--out <file>]   write one snapshot from live T3 data and exit
//   node dist/main.js --clear         overwrite live.lua/Inbox.lua with an empty snapshot and blank used image slots
//   Stop a running bridge cleanly: create %LOCALAPPDATA%\T3Bridge\stop.request (scripts/stop-bridge.ps1 does).
//   --config <path>  --capture wgc|screenshot|off  --log-level debug|info|warn
import { closeSync, existsSync, mkdirSync, openSync, readFileSync, unlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { appDataDir, configPath, loadConfig, resolvePaths, type CompanionConfig } from "./config.js";
import { configureLog, log, type Level } from "./log.js";
import { Bridge, newCompanionSid } from "./bridge.js";
import { emptySnapshotLua } from "./model/snapshot.js";
import { RpcT3Client, type T3Client } from "./t3/client.js";
import { FakeT3Client } from "./t3/fakeClient.js";
import { discover } from "./t3/discovery.js";
import { ensureAuth, exchangePairingCredential, getSession, TokenStore } from "./t3/auth.js";
import { LiveWriter, writeInPlace, writeRename } from "./wow/liveWriter.js";
import { CaptureHelper, defaultHelperPath, helperArgs } from "./wow/captureClient.js";
import { decodeImage } from "./wow/frameDecoder.js";
import { ScreenshotWatcher } from "./wow/screenshotWatcher.js";
import { runSelftest } from "./selftest.js";
import { HelperImageTools } from "./images/helper.js";
import { ImageManager } from "./images/manager.js";
import { SlotPool } from "./images/slots.js";

const argv = process.argv.slice(2);
const flag = (k: string) => argv.includes(k);
const opt = (k: string) => { const i = argv.indexOf(k); return i >= 0 ? argv[i + 1] : undefined; };

function acquireLock(): () => void {
  const dir = appDataDir();
  mkdirSync(dir, { recursive: true });
  const lock = join(dir, "companion.lock");
  if (existsSync(lock)) {
    const pid = Number(readFileSync(lock, "utf8").trim());
    let alive = false;
    try { if (pid > 0) { process.kill(pid, 0); alive = true; } } catch (e: any) { alive = e?.code === "EPERM"; }
    if (alive && pid !== process.pid) { log.error(`another companion is already running (pid ${pid})`); process.exit(3); }
    try { unlinkSync(lock); } catch { /* stale */ }
  }
  const fd = openSync(lock, "wx");
  writeFileSync(fd, String(process.pid));
  closeSync(fd);
  return () => { try { if (readFileSync(lock, "utf8").trim() === String(process.pid)) unlinkSync(lock); } catch { /* ignore */ } };
}

function startOutbound(cfg: CompanionConfig, bridge: Bridge): () => void {
  const mode = (opt("--capture") as CompanionConfig["capture"]["mode"]) ?? cfg.capture.mode;
  if (mode === "off") { log.info("outbound capture disabled"); return () => {}; }
  if (mode === "screenshot") {
    const w = new ScreenshotWatcher({ dir: cfg.capture.screenshotsDir, regionW: cfg.capture.regionWidth, regionH: cfg.capture.regionHeight, deleteDecoded: cfg.capture.deleteDecodedScreenshots, onFrame: (f) => bridge.onFrame(f) });
    w.start();
    return () => w.stop();
  }
  const exe = cfg.capture.helperPath || defaultHelperPath();
  if (!exe || !existsSync(exe)) { log.error("capture helper T3Capture.exe not found; build it (dotnet build -c Release capture-helper/T3Capture) or set capture.helperPath"); return () => {}; }
  const helper = new CaptureHelper({ exe, args: helperArgs(cfg.capture), restartOnExit: true });
  let frames = 0, failures = 0;
  helper.on("record", (r) => {
    const res = decodeImage(r.image);
    if (res.ok) { frames++; bridge.onFrame(res.frame); } else failures++;
  });
  helper.on("status", (s) => {
    if (s.ev === "attached") log.info(`capture attached to ${s.Process} "${s.Title}" ${s.ClientW}x${s.ClientH} (client origin ${s.originX},${s.originY}, border ${s.borderOff ? "off" : "on"})`);
    else if (s.ev === "detached" || s.ev === "error" || s.ev === "warn") log.warn(`capture: ${s.ev} ${s.message ?? s.reason ?? ""}`);
    else if (s.ev === "stats") log.debug(`capture stats ${JSON.stringify(s)} decoded=${frames} failed=${failures}`);
  });
  helper.start();
  log.info(`outbound: live window capture via ${exe}`);
  return () => helper.stop();
}

async function makeRealClient(cfg: CompanionConfig, allowIssue: boolean): Promise<{ t3: RpcT3Client; environmentId?: string }> {
  const srv = await discover(cfg.t3.runtimeFile);
  log.info(`T3 server ${srv.descriptor?.serverVersion ?? "?"} at ${srv.origin} (protocol ${srv.descriptor?.orchestrationProtocolVersion})`);
  const store = new TokenStore(appDataDir());
  let auth = await ensureAuth({ origin: srv.origin, store, cliPath: cfg.t3.cliPath, ttl: cfg.t3.tokenTtl, allowIssue });
  const t3 = new RpcT3Client({
    origin: srv.origin,
    getBearer: async () => {
      // Re-validate lazily if the token was revoked/expired while running.
      return auth.token;
    },
  });
  t3.on("connection", async (up: boolean) => {
    if (up) return;
    try { const s = await getSession(srv.origin, auth.token); if (!s.authenticated) auth = await ensureAuth({ origin: srv.origin, store, cliPath: cfg.t3.cliPath, ttl: cfg.t3.tokenTtl, allowIssue }); } catch { /* server down; reconnect loop retries */ }
  });
  return { t3, environmentId: srv.descriptor?.environmentId };
}

async function runBridge(cfg: CompanionConfig, demo: boolean): Promise<void> {
  const release = demo && opt("--out") ? () => {} : acquireLock();
  const paths = resolvePaths(cfg);
  const liveFile = opt("--out") ?? paths.liveFile;
  let t3: T3Client;
  let environmentId: string | undefined;
  if (demo) {
    t3 = new FakeT3Client();
    log.info("DEMO mode: fake T3 data");
  } else {
    // T3 Code may not be running yet (autostart at logon): keep retrying instead of exiting.
    let delay = 5000;
    for (;;) {
      try {
        const r = await makeRealClient(cfg, true);
        t3 = r.t3; environmentId = r.environmentId;
        break;
      } catch (e) {
        log.warn(`T3 Code not reachable (${(e as Error).message}); retrying in ${delay / 1000} s`);
        await new Promise((res) => setTimeout(res, delay));
        delay = Math.min(delay * 2, 60_000);
      }
    }
  }
  let writer: LiveWriter;
  const images = makeImages(cfg, t3!, () => writer?.markDirty());
  const bridge = new Bridge({
    t3, environmentId, asciiOnly: cfg.asciiOnly, images,
    caps: { maxThreads: cfg.maxThreads, focusWindow: cfg.focusWindow, maxFocusWindow: cfg.maxFocusWindow, maxMessageBytes: cfg.maxMessageBytes, maxSnapshotBytes: cfg.maxSnapshotBytes, transliterate: cfg.transliterate },
    onDirty: () => writer?.markDirty(),
    onAck: () => writer?.writeNow("ack"),
  });
  writer = new LiveWriter({
    file: liveFile, mode: cfg.writeMode, padBytes: cfg.padBytes, debounceMs: cfg.debounceMs, minIntervalMs: cfg.minWriteIntervalMs,
    heartbeatMs: cfg.heartbeatMs, render: (seq, ts) => bridge.render(seq, ts),
    secondaryFile: opt("--out") ? undefined : paths.inboxFile, secondaryIntervalMs: cfg.inboxIntervalMs,
    allowCreate: demo && !!opt("--out"),
    onWrite: (i) => log.debug(`live.lua seq ${i.seq} ${i.contentBytes} B (${i.reason}, ${i.ms.toFixed(1)} ms)`),
  });
  if (demo) {
    // Demo: focus the first thread so the chat view has content immediately.
    const first = t3.threads()[0];
    if (first) { bridge.focus.tid = bridge.tids.tid(first.id); await t3.focus(first.id); }
  }
  for (let delay = 5000; ; delay = Math.min(delay * 2, 60_000)) {
    try { await t3.start(); break; }
    catch (e) { log.warn(`T3 connection failed (${(e as Error).message}); retrying in ${delay / 1000} s`); await new Promise((res) => setTimeout(res, delay)); }
  }
  writer.start();
  if (writer.lastError) log.error(writer.lastError.message);
  log.info(`writing ${liveFile} (${cfg.writeMode}, pad ${cfg.padBytes} B); companion sid ${bridge.sid}`);
  const stopOutbound = flag("--no-capture") ? () => {} : startOutbound(cfg, bridge);
  let shuttingDown = false;
  const shutdown = (why: string, code = 0) => {
    if (shuttingDown) return;
    shuttingDown = true;
    log.info(`shutting down (${why})`);
    try { stopOutbound(); } catch { /* ignore */ }
    writer.stop();
    // Privacy: leave no conversation text in live.lua / Inbox.lua after exit.
    bridge.clear();
    const w = writer.writeNow("exit", true);
    log.info(w ? `cleared ${liveFile} (seq ${w.seq})` : `could not clear ${liveFile}: ${writer.lastError?.message}`);
    // Privacy: no image stays in the slot textures either.
    if (images) { try { log.info(`blanked ${images.stop()} image slots`); } catch (e) { log.warn(`could not blank image slots: ${(e as Error).message}`); } }
    try { t3.stop(); } catch { /* ignore */ }
    release();
    process.exit(code);
  };
  for (const sig of ["SIGINT", "SIGTERM", "SIGHUP", "SIGBREAK"] as const) process.on(sig, () => shutdown(sig));
  process.on("uncaughtException", (e) => { log.error(`uncaught: ${e.stack ?? e.message}`); shutdown("error", 1); });
  // scripts/stop-bridge.ps1 asks for a clean stop by creating this file (a hidden process gets no Ctrl+C).
  const stopFile = stopRequestPath();
  try { if (existsSync(stopFile)) unlinkSync(stopFile); } catch { /* ignore */ }
  setInterval(() => {
    if (existsSync(stopFile)) { try { unlinkSync(stopFile); } catch { /* ignore */ } shutdown("stop requested"); }
  }, 500).unref();
}

export function stopRequestPath(): string { return join(appDataDir(), "stop.request"); }

function slotPool(cfg: CompanionConfig): SlotPool {
  return new SlotPool({ dir: resolvePaths(cfg).imageSlotsDir, stateFile: join(appDataDir(), "imgslots.json"), resetOnReload: !!cfg.images.resetOnReload });
}

/** Image support (PROTOCOL rev 1.3), or undefined when disabled in config. Never creates slot files. */
function makeImages(cfg: CompanionConfig, t3: T3Client, onDirty: () => void): ImageManager | undefined {
  if (!cfg.images.enabled) { log.info("images: disabled in config"); return undefined; }
  const pool = slotPool(cfg);
  const tools = new HelperImageTools(cfg.capture.helperPath || undefined);
  const images = new ImageManager({
    t3, tools, pool, tmpDir: join(appDataDir(), "tmp"), screenshotsDir: cfg.capture.screenshotsDir, onDirty,
    maxNewPerSnapshot: cfg.images.maxNewPerSnapshot, maxStaged: cfg.images.maxStaged,
    recentScreenshotMs: cfg.images.recentScreenshotMinutes * 60_000,
    resetHint: cfg.images.resetOnReload ? "reload" : "restart", wowProcess: cfg.capture.processName,
  });
  void tools.resolveExe().then((exe) => { if (!exe) onDirty(); });
  log.info(pool.total ? `images: ${pool.total} slots in ${resolvePaths(cfg).imageSlotsDir} (${pool.left} free for this WoW session)` : "images: no image slots installed (install-addon.ps1 -ImageSlots 100, with WoW closed); attachments still work");
  return images;
}

/** --clear: overwrite live.lua (and Inbox.lua) in place with an empty snapshot, e.g. after a crash. */
function clearFiles(cfg: CompanionConfig): boolean {
  const p = resolvePaths(cfg);
  let ok = true;
  const sid = newCompanionSid();
  for (const file of [p.liveFile, p.inboxFile]) {
    if (!existsSync(file)) { console.log(`skip ${file} (missing)`); continue; }
    try {
      const r = (cfg.writeMode === "rename" && file === p.liveFile ? writeRename : writeInPlace)(file, emptySnapshotLua(sid, 1), cfg.padBytes);
      console.log(`cleared ${file} (${r.bytes} B)`);
    } catch (e) { ok = false; console.log(`could not clear ${file}: ${(e as Error).message}`); }
  }
  try { console.log(`blanked ${slotPool(cfg).blankUsed()} image slots`); } catch (e) { ok = false; console.log(`could not blank image slots: ${(e as Error).message}`); }
  return ok;
}

async function main(): Promise<void> {
  const cfgFile = opt("--config") ?? configPath();
  const cfg = loadConfig(cfgFile);
  configureLog({ level: (opt("--log-level") as Level) ?? (process.env.T3B_LOG_LEVEL as Level) ?? "info", file: join(appDataDir(), "companion.log") });

  if (flag("--selftest")) { process.exit(runSelftest() ? 0 : 1); }
  if (flag("--clear")) { process.exit(clearFiles(cfg) ? 0 : 1); }
  if (flag("--status")) {
    const p = resolvePaths(cfg);
    console.log(JSON.stringify({ config: cfgFile, configExists: existsSync(cfgFile), liveFile: p.liveFile, liveFileExists: existsSync(p.liveFile), inboxFile: p.inboxFile, helper: cfg.capture.helperPath || defaultHelperPath() }, null, 2));
    try {
      const srv = await discover(cfg.t3.runtimeFile);
      const auth = await new TokenStore(appDataDir()).load();
      const s = auth ? await getSession(srv.origin, auth.token) : null;
      console.log(JSON.stringify({ server: srv.origin, version: srv.descriptor?.serverVersion, credential: auth ? { source: auth.source, sessionId: auth.sessionId, expiresAt: auth.expiresAt, valid: s?.authenticated, scopes: s?.scopes } : null }, null, 2));
    } catch (e) { console.log(`T3: ${(e as Error).message}`); }
    return;
  }
  if (flag("--login")) {
    const srv = await discover(cfg.t3.runtimeFile);
    const a = await ensureAuth({ origin: srv.origin, store: new TokenStore(appDataDir()), cliPath: cfg.t3.cliPath, ttl: cfg.t3.tokenTtl, allowIssue: true });
    console.log(`credential OK (session ${a.sessionId ?? "?"}, expires ${a.expiresAt ?? "?"})`);
    return;
  }
  if (flag("--pair")) {
    const srv = await discover(cfg.t3.runtimeFile);
    process.stderr.write("Paste the one-time pairing token from `t3 pair` and press Enter (input is not echoed to logs):\n");
    const token = await new Promise<string>((res) => { let s = ""; process.stdin.on("data", (d) => { s += d; if (s.includes("\n")) res(s.trim()); }); });
    const a = await exchangePairingCredential(srv.origin, token.replace(/^.*#token=/, ""));
    await new TokenStore(appDataDir()).save(a);
    console.log(`credential stored (expires ${a.expiresAt ?? "?"})`);
    process.exit(0);
  }
  if (flag("--once")) {
    const { t3 } = await makeRealClient(cfg, true);
    await t3.start();
    await new Promise((r) => setTimeout(r, 1500));
    const bridge = new Bridge({ t3, onDirty: () => {}, onAck: () => {}, asciiOnly: cfg.asciiOnly });
    const out = opt("--out") ?? resolvePaths(cfg).liveFile;
    const w = new LiveWriter({ file: out, mode: cfg.writeMode, padBytes: cfg.padBytes, debounceMs: 0, minIntervalMs: 0, heartbeatMs: 1e9, render: (s, ts) => bridge.render(s, ts), allowCreate: !!opt("--out") });
    const info = w.writeNow("once");
    console.log(info ? `wrote ${out}: seq ${info.seq}, ${info.contentBytes} B content, ${info.bytes} B file` : `write failed: ${w.lastError?.message}`);
    t3.stop();
    process.exit(info ? 0 : 1);
  }
  await runBridge(cfg, flag("--demo"));
}

main().catch((e) => { log.error(`fatal: ${(e as Error).message}`); process.exit(1); });

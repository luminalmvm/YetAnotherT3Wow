// Bearer credential for the local T3 server.
//
// Primary: `t3 auth session issue --scope orchestration:read --scope orchestration:operate --json`
//   (T3's documented "headless client" path; scoped, labelled, revocable with `t3 auth session revoke <id>`).
// Alternative: a one-time pairing credential (from `t3 pair` / `t3 auth pairing create`) exchanged at
//   POST /oauth/token (RFC 8693 token exchange).
// The token is stored DPAPI-protected (CurrentUser) at %LOCALAPPDATA%\T3Bridge\bearer.dat and is never logged.
import { spawn } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { dpapiProtect, dpapiUnprotect } from "./dpapi.js";
import { log } from "../log.js";

export const REQUIRED_SCOPES = ["orchestration:read", "orchestration:operate"] as const;
export const GRANT_TYPE = "urn:ietf:params:oauth:grant-type:token-exchange";
export const BOOTSTRAP_TOKEN_TYPE = "urn:t3:params:oauth:token-type:environment-bootstrap";
export const ACCESS_TOKEN_TYPE = "urn:ietf:params:oauth:token-type:access_token";

export interface StoredAuth {
  token: string;
  sessionId?: string;
  expiresAt?: string;
  scopes?: string[];
  source: "cli-session" | "pairing-exchange";
}

export interface SessionState {
  authenticated: boolean;
  scopes?: string[];
  expiresAt?: string;
  sessionMethod?: string;
}

export class TokenStore {
  constructor(private readonly dir: string) {}
  get file(): string { return join(this.dir, "bearer.dat"); }
  get metaFile(): string { return join(this.dir, "auth-meta.json"); }

  async load(): Promise<StoredAuth | null> {
    if (!existsSync(this.file)) return null;
    try {
      const plain = await dpapiUnprotect(readFileSync(this.file));
      const v = JSON.parse(plain.toString("utf8"));
      return typeof v?.token === "string" ? (v as StoredAuth) : null;
    } catch (e) {
      log.warn("Stored T3 credential could not be decrypted; a new one will be issued", (e as Error).message);
      return null;
    }
  }

  async save(a: StoredAuth): Promise<void> {
    mkdirSync(this.dir, { recursive: true });
    const blob = await dpapiProtect(Buffer.from(JSON.stringify(a), "utf8"));
    writeFileSync(this.file, blob);
    // Non-secret metadata so the user can see/revoke the session.
    writeFileSync(this.metaFile, JSON.stringify({ sessionId: a.sessionId, expiresAt: a.expiresAt, scopes: a.scopes, source: a.source,
      revoke: a.sessionId ? `t3 auth session revoke ${a.sessionId}` : undefined }, null, 2));
  }
}

export async function getSession(origin: string, token: string | undefined): Promise<SessionState> {
  const res = await fetch(`${origin}/api/auth/session`, {
    headers: token ? { authorization: `Bearer ${token}` } : {},
    signal: AbortSignal.timeout(5000),
  });
  if (!res.ok) throw new Error(`GET /api/auth/session -> HTTP ${res.status}`);
  const j: any = await res.json();
  return { authenticated: !!j.authenticated, scopes: j.scopes, expiresAt: j.expiresAt, sessionMethod: j.sessionMethod };
}

function hasScopes(s: SessionState): boolean {
  const have = new Set(s.scopes ?? []);
  return REQUIRED_SCOPES.every((x) => have.has(x));
}

/** Runs `t3 auth session issue ... --json` and returns the parsed result. stdout is never logged. */
export function issueViaCli(cliPath: string, opts: { ttl: string; label: string }): Promise<StoredAuth> {
  return new Promise((resolve, reject) => {
    const args = ["auth", "session", "issue", ...REQUIRED_SCOPES.flatMap((s) => ["--scope", s]), "--ttl", opts.ttl, "--label", opts.label, "--json"];
    // .cmd needs cmd.exe; every argument is a fixed safe literal (label is validated below).
    if (!/^[A-Za-z0-9 ._()-]{1,64}$/.test(opts.label) || !/^[0-9a-z ]{1,16}$/i.test(opts.ttl)) return reject(new Error("bad label/ttl"));
    const cmdline = [`"${cliPath}"`, ...args.map((a) => (a.includes(" ") ? `"${a}"` : a))].join(" ");
    const child = spawn("cmd.exe", ["/d", "/s", "/c", `"${cmdline}"`], { windowsHide: true, windowsVerbatimArguments: true, cwd: process.env.TEMP });
    let out = "";
    let err = "";
    child.stdout.on("data", (d) => (out += d.toString("utf8")));
    child.stderr.on("data", (d) => (err += d.toString("utf8")));
    child.on("error", reject);
    child.on("close", (code) => {
      if (code !== 0) return reject(new Error(`t3 auth session issue failed (exit ${code}): ${err.trim().split(/\r?\n/).slice(-1)[0] ?? ""}`));
      try {
        const start = out.indexOf("{");
        const j = JSON.parse(out.slice(start));
        if (typeof j.token !== "string" || j.token.length < 16) throw new Error("no token in output");
        resolve({ token: j.token, sessionId: j.sessionId, expiresAt: j.expiresAt, scopes: j.scopes, source: "cli-session" });
      } catch (e) {
        reject(new Error(`could not parse t3 auth session issue output: ${(e as Error).message}`));
      } finally {
        out = "";
      }
    });
  });
}

/** Exchanges a one-time pairing credential for a bearer (POST /oauth/token, form-encoded). */
export async function exchangePairingCredential(origin: string, credential: string, label = "T3Bridge companion"): Promise<StoredAuth> {
  const body = new URLSearchParams({
    grant_type: GRANT_TYPE,
    subject_token: credential,
    subject_token_type: BOOTSTRAP_TOKEN_TYPE,
    requested_token_type: ACCESS_TOKEN_TYPE,
    scope: REQUIRED_SCOPES.join(" "),
    client_label: label,
    client_device_type: "desktop",
    client_os: "windows",
  });
  const res = await fetch(`${origin}/oauth/token`, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body,
    signal: AbortSignal.timeout(10000),
  });
  const j: any = await res.json().catch(() => ({}));
  if (!res.ok || typeof j.access_token !== "string") throw new Error(`token exchange failed: HTTP ${res.status} ${j?._tag ?? j?.error ?? ""} ${j?.reason ?? ""}`);
  const expiresAt = typeof j.expires_in === "number" ? new Date(Date.now() + j.expires_in * 1000).toISOString() : undefined;
  return { token: j.access_token, expiresAt, scopes: String(j.scope ?? "").split(/\s+/).filter(Boolean), source: "pairing-exchange" };
}

export interface EnsureAuthOptions {
  origin: string;
  store: TokenStore;
  cliPath: string;
  ttl: string;
  /** If false, never mint a credential automatically (report instead). */
  allowIssue: boolean;
}

/** Returns a valid bearer, issuing one through the T3 CLI if needed. */
export async function ensureAuth(o: EnsureAuthOptions): Promise<StoredAuth> {
  const cur = await o.store.load();
  if (cur) {
    try {
      const s = await getSession(o.origin, cur.token);
      if (s.authenticated && hasScopes(s)) return cur;
      log.warn("Stored T3 credential is no longer valid (expired, revoked or missing scopes)");
    } catch (e) {
      throw new Error(`Could not validate the T3 credential: ${(e as Error).message}`);
    }
  }
  if (!o.allowIssue) throw new Error("No valid T3 credential. Run: node dist/main.js --login");
  if (!existsSync(o.cliPath)) throw new Error(`T3 CLI not found at ${o.cliPath}. Open T3 Code once, or run 'node dist/main.js --pair' with a pairing token.`);
  log.info("Issuing a scoped T3 bearer session (orchestration:read, orchestration:operate) via the T3 CLI");
  const issued = await issueViaCli(o.cliPath, { ttl: o.ttl, label: "T3Bridge companion" });
  const s = await getSession(o.origin, issued.token);
  if (!s.authenticated) throw new Error("Issued T3 credential was rejected by the server");
  await o.store.save(issued);
  log.info(`T3 credential stored (DPAPI). Session ${issued.sessionId ?? "?"}, expires ${issued.expiresAt ?? "?"}`);
  return issued;
}

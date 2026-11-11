// Finds the local T3 Code server from %USERPROFILE%\.t3\userdata\server-runtime.json.
// SECURITY: the server may bind 0.0.0.0; we always connect to 127.0.0.1 on the advertised port.
import { readFileSync } from "node:fs";

export interface ServerRuntime {
  version: number;
  pid: number;
  host: string;
  port: number;
  origin: string;
  startedAt?: string;
  serverVersion?: string;
}

export interface DiscoveredServer {
  /** Always loopback: http://127.0.0.1:<port> */
  origin: string;
  wsOrigin: string;
  port: number;
  pid: number;
  serverVersion?: string;
  pidAlive: boolean;
  /** From GET /.well-known/t3/environment (unauthenticated). */
  descriptor?: { environmentId: string; label?: string; serverVersion: string; orchestrationProtocolVersion: number };
}

export function readRuntime(file: string): ServerRuntime {
  const raw = JSON.parse(readFileSync(file, "utf8").replace(/^﻿/, ""));
  if (typeof raw.port !== "number" || raw.port <= 0 || raw.port > 65535) throw new Error(`server-runtime.json has no valid port`);
  return raw as ServerRuntime;
}

export function isPidAlive(pid: number): boolean {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try { process.kill(pid, 0); return true; } catch (e: any) { return e?.code === "EPERM"; }
}

export function loopbackOrigin(port: number): string { return `http://127.0.0.1:${port}`; }

export async function discover(runtimeFile: string, opts: { probe?: boolean; timeoutMs?: number } = {}): Promise<DiscoveredServer> {
  const rt = readRuntime(runtimeFile);
  const origin = loopbackOrigin(rt.port);
  const out: DiscoveredServer = {
    origin,
    wsOrigin: origin.replace(/^http/, "ws"),
    port: rt.port,
    pid: rt.pid,
    serverVersion: rt.serverVersion,
    pidAlive: isPidAlive(rt.pid),
  };
  if (opts.probe !== false) {
    const res = await fetch(`${origin}/.well-known/t3/environment`, { signal: AbortSignal.timeout(opts.timeoutMs ?? 3000) });
    if (!res.ok) throw new Error(`T3 descriptor probe failed: HTTP ${res.status}`);
    const d: any = await res.json();
    out.descriptor = {
      environmentId: d.environmentId,
      label: d.label,
      serverVersion: d.serverVersion,
      orchestrationProtocolVersion: d.orchestrationProtocolVersion,
    };
    if (d.orchestrationProtocolVersion !== 2) throw new Error(`Unsupported orchestration protocol ${d.orchestrationProtocolVersion} (companion speaks 2)`);
  }
  return out;
}

// Minimal client for T3's WebSocket RPC (Effect RPC, JSON serialization) at /ws.
//
// Wire format (VERIFIED against server 0.1.8-nightly, see docs/t3-api-notes.md):
//   client -> {"_tag":"Request","id":"<n>","tag":"<method>","payload":{...},"headers":[]}
//   server -> {"_tag":"Exit","requestId":"<n>","exit":{"_tag":"Success","value":...}}      (unary)
//   server -> {"_tag":"Chunk","requestId":"<n>","values":[...]}                            (stream)
//   client -> {"_tag":"Ack","requestId":"<n>"}  after every Chunk (backpressure)
//   client -> {"_tag":"Interrupt","requestId":"<n>","interruptors":[]}  to cancel a stream
//   client -> {"_tag":"Ping"}  server -> {"_tag":"Pong"}
// Authentication: a short-lived ticket from POST /api/auth/websocket-ticket/rpc (Bearer), passed as ?wsTicket=.
import { log } from "../log.js";

export class RpcError extends Error {
  constructor(message: string, readonly tag: string, readonly rpcCause?: unknown) { super(message); }
}

type Pending =
  | { kind: "unary"; tag: string; resolve: (v: any) => void; reject: (e: Error) => void }
  | { kind: "stream"; tag: string; onItem: (v: any) => void; onEnd: (err?: Error) => void };

export interface RpcSocketOptions {
  origin: string; // http://127.0.0.1:port
  getBearer: () => Promise<string>;
  pingMs?: number;
  requestTimeoutMs?: number;
}

export async function mintWsTicket(origin: string, bearer: string): Promise<string> {
  const res = await fetch(`${origin}/api/auth/websocket-ticket/rpc`, {
    method: "POST",
    headers: { authorization: `Bearer ${bearer}` },
    signal: AbortSignal.timeout(5000),
  });
  if (!res.ok) throw new Error(`websocket ticket: HTTP ${res.status}`);
  const j: any = await res.json();
  if (typeof j.ticket !== "string") throw new Error("websocket ticket: no ticket in response");
  return j.ticket;
}

/** Short human description of an Effect Cause (never includes request payloads). */
export function describeCause(cause: unknown): string {
  try {
    const s = JSON.stringify(cause);
    const m = /"message":"([^"]{1,300})"/.exec(s);
    const t = /"_tag":"([A-Za-z0-9]+Error)"/.exec(s);
    return [t?.[1], m?.[1]].filter(Boolean).join(": ") || s.slice(0, 300);
  } catch { return String(cause); }
}

export class RpcSocket {
  private ws?: WebSocket;
  private nextId = 1;
  private pending = new Map<string, Pending>();
  private pingTimer?: NodeJS.Timeout;
  private closedListeners: ((reason: string) => void)[] = [];
  private closed = false;
  lastMessageAt = 0;

  constructor(private readonly o: RpcSocketOptions) {}

  get isOpen(): boolean { return this.ws?.readyState === WebSocket.OPEN; }

  onClose(fn: (reason: string) => void): void { this.closedListeners.push(fn); }

  async connect(): Promise<void> {
    const ticket = await mintWsTicket(this.o.origin, await this.o.getBearer());
    const u = new URL("/ws", this.o.origin.replace(/^http/, "ws"));
    u.searchParams.set("orchestrationProtocol", "2");
    u.searchParams.set("wsTicket", ticket);
    const ws = new WebSocket(u.toString());
    this.ws = ws;
    await new Promise<void>((resolve, reject) => {
      const t = setTimeout(() => reject(new Error("WebSocket connect timeout")), 8000);
      ws.addEventListener("open", () => { clearTimeout(t); resolve(); }, { once: true });
      ws.addEventListener("error", () => { clearTimeout(t); reject(new Error("WebSocket connect error")); }, { once: true });
    });
    ws.addEventListener("message", (ev) => { void this.onMessage(ev.data); });
    ws.addEventListener("close", (ev) => this.onClosed(`close ${ev.code} ${ev.reason || ""}`.trim()));
    this.pingTimer = setInterval(() => this.sendRaw({ _tag: "Ping" }), this.o.pingMs ?? 15000);
    this.lastMessageAt = Date.now();
  }

  close(): void {
    try { this.ws?.close(1000, "bye"); } catch { /* ignore */ }
    this.onClosed("closed by client");
  }

  private onClosed(reason: string): void {
    if (this.closed) return;
    this.closed = true;
    if (this.pingTimer) clearInterval(this.pingTimer);
    this.pingTimer = undefined;
    const err = new Error(`WebSocket closed: ${reason}`);
    for (const p of this.pending.values()) { if (p.kind === "unary") p.reject(err); else p.onEnd(err); }
    this.pending.clear();
    const ls = this.closedListeners;
    this.closedListeners = [];
    for (const l of ls) l(reason);
  }

  private sendRaw(msg: unknown): void {
    if (this.ws?.readyState === WebSocket.OPEN) this.ws.send(JSON.stringify(msg));
  }

  private async onMessage(data: unknown): Promise<void> {
    this.lastMessageAt = Date.now();
    let text: string;
    if (typeof data === "string") text = data;
    else if (data instanceof ArrayBuffer) text = Buffer.from(data).toString("utf8");
    else if (typeof Blob !== "undefined" && data instanceof Blob) text = await data.text();
    else text = String(data);
    let parsed: any;
    try { parsed = JSON.parse(text); } catch { log.warn("RPC: non-JSON message ignored"); return; }
    for (const m of Array.isArray(parsed) ? parsed : [parsed]) this.dispatch(m);
  }

  private dispatch(m: any): void {
    switch (m?._tag) {
      case "Pong": return;
      case "Chunk": {
        const p = this.pending.get(String(m.requestId));
        if (!p || p.kind !== "stream") return;
        for (const v of m.values ?? []) {
          try { p.onItem(v); } catch (e) { log.error(`RPC stream handler (${p.tag}) threw`, e); }
        }
        this.sendRaw({ _tag: "Ack", requestId: m.requestId });
        return;
      }
      case "Exit": {
        const id = String(m.requestId);
        const p = this.pending.get(id);
        if (!p) return;
        this.pending.delete(id);
        const ok = m.exit?._tag === "Success";
        if (p.kind === "unary") {
          if (ok) p.resolve(m.exit.value);
          else p.reject(new RpcError(`${p.tag} failed: ${describeCause(m.exit?.cause)}`, p.tag, m.exit?.cause));
        } else {
          p.onEnd(ok ? undefined : new RpcError(`${p.tag} stream failed: ${describeCause(m.exit?.cause)}`, p.tag, m.exit?.cause));
        }
        return;
      }
      case "Defect":
      case "ClientProtocolError":
        log.warn(`RPC ${m._tag}`, describeCause(m.defect ?? m.error ?? m));
        return;
      default:
        return;
    }
  }

  request<T = any>(tag: string, payload: unknown, timeoutMs = this.o.requestTimeoutMs ?? 15000): Promise<T> {
    if (!this.isOpen) return Promise.reject(new Error("RPC socket not open"));
    const id = String(this.nextId++);
    return new Promise<T>((resolve, reject) => {
      const t = setTimeout(() => { this.pending.delete(id); reject(new Error(`${tag} timed out`)); }, timeoutMs);
      this.pending.set(id, {
        kind: "unary", tag,
        resolve: (v) => { clearTimeout(t); resolve(v); },
        reject: (e) => { clearTimeout(t); reject(e); },
      });
      this.sendRaw({ _tag: "Request", id, tag, payload, headers: [] });
    });
  }

  stream(tag: string, payload: unknown, onItem: (v: any) => void, onEnd: (err?: Error) => void): { cancel: () => void } {
    if (!this.isOpen) { onEnd(new Error("RPC socket not open")); return { cancel: () => {} }; }
    const id = String(this.nextId++);
    this.pending.set(id, { kind: "stream", tag, onItem, onEnd });
    this.sendRaw({ _tag: "Request", id, tag, payload, headers: [] });
    return {
      cancel: () => {
        if (!this.pending.delete(id)) return;
        this.sendRaw({ _tag: "Interrupt", requestId: id, interruptors: [] });
      },
    };
  }
}

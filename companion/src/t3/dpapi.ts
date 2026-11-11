// DPAPI (CurrentUser) protect/unprotect through Windows PowerShell 5.1, no native modules.
// Secrets travel over stdin/stdout of the child only; they are never placed on a command line.
import { spawn } from "node:child_process";

const ENTROPY_B64 = Buffer.from("T3Bridge.bearer.v1").toString("base64");

function psScript(op: "protect" | "unprotect"): string {
  const call = op === "protect"
    ? `$out=[Security.Cryptography.ProtectedData]::Protect($in,$ent,'CurrentUser')`
    : `$out=[Security.Cryptography.ProtectedData]::Unprotect($in,$ent,'CurrentUser')`;
  return [
    `$ErrorActionPreference='Stop'`,
    `Add-Type -AssemblyName System.Security`,
    `$txt=[Console]::In.ReadToEnd().Trim()`,
    `$in=[Convert]::FromBase64String($txt)`,
    `$ent=[Convert]::FromBase64String('${ENTROPY_B64}')`,
    call,
    `[Console]::Out.Write([Convert]::ToBase64String($out))`,
  ].join("; ");
}

function runPs(script: string, stdin: string): Promise<string> {
  return new Promise((resolve, reject) => {
    const enc = Buffer.from(script, "utf16le").toString("base64");
    const child = spawn("powershell.exe", ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-EncodedCommand", enc], {
      stdio: ["pipe", "pipe", "pipe"],
      windowsHide: true,
    });
    let out = "";
    let err = "";
    child.stdout.on("data", (d) => (out += d.toString("utf8")));
    child.stderr.on("data", (d) => (err += d.toString("utf8")));
    child.on("error", reject);
    child.on("close", (code) => {
      if (code === 0) resolve(out.trim());
      else reject(new Error(`DPAPI helper failed (exit ${code}): ${err.split(/\r?\n/)[0] ?? ""}`));
    });
    child.stdin.end(stdin);
  });
}

export async function dpapiProtect(plain: Buffer): Promise<Buffer> {
  return Buffer.from(await runPs(psScript("protect"), plain.toString("base64")), "base64");
}

export async function dpapiUnprotect(blob: Buffer): Promise<Buffer> {
  return Buffer.from(await runPs(psScript("unprotect"), blob.toString("base64")), "base64");
}

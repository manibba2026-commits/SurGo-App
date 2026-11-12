// Shared access to the hosted project's admin SQL channel.
//
// Both tools talk to the Supabase Management API query endpoint, which is what
// stands in for the MCP execute_sql tool when no Supabase MCP server is
// connected. The credential is read into process memory only and never printed
// or written to disk.

import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

// The project ref is public. The operator's real account identifiers are not
// committed: supply them through the environment when running the tools that
// need them (apply_demo_data preflight/verify, audit_hosted). Empty defaults keep
// the literals out of source control; callers guard on the empty case.
export const REF = 'lrhgktxmavnhjatqzbzr';
export const REAL_USER_EMAIL = process.env.SURGO_REAL_USER_EMAIL ?? '';
export const REAL_USER_ID = process.env.SURGO_REAL_USER_ID ?? '';

// The generic credential the Supabase CLI writes is read with explicit byte
// offsets because the documented CREDENTIALW field order does not match what
// CredRead returns on this Windows build. Offsets are validated before use: the
// name pointer must resolve back to the credential target, so a layout change
// fails loudly instead of sending a garbage Authorization header.
function getToken() {
  const ps = `Add-Type -AssemblyName System.Runtime.InteropServices
$sig = @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class SupaCred {
  [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
  public static extern bool CredRead(string target, int type, int reserved, out IntPtr cred);
  [DllImport("advapi32.dll")] public static extern void CredFree(IntPtr cred);
  [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
  [DllImport("kernel32.dll")] static extern bool ReadProcessMemory(IntPtr h, IntPtr addr, byte[] buf, int size, out int read);
  static byte[] Peek(IntPtr addr, int size) {
    if (addr == IntPtr.Zero || size <= 0 || size > 65536) return null;
    byte[] buf = new byte[size]; int n;
    return ReadProcessMemory(GetCurrentProcess(), addr, buf, size, out n) && n == size ? buf : null;
  }
  public static string Read(string target) {
    IntPtr ptr;
    if (!CredRead(target, 1, 0, out ptr))
      throw new Exception("CredRead failed (win32 " + Marshal.GetLastWin32Error() + ")");
    try {
      byte[] head = Peek(ptr, 96);
      if (head == null) throw new Exception("credential block unreadable");
      string name = Encoding.Unicode.GetString(
        Peek((IntPtr)BitConverter.ToInt64(head, 8), (target.Length + 1) * 2)).TrimEnd('\\0');
      if (name != target) throw new Exception("credential layout mismatch");
      byte[] blob = Peek(
        (IntPtr)BitConverter.ToInt64(head, 40), BitConverter.ToInt32(head, 32));
      if (blob == null) throw new Exception("credential blob unreadable");
      string token = (blob.Length > 1 && blob[1] == 0)
        ? Encoding.Unicode.GetString(blob).TrimEnd('\\0')
        : Encoding.UTF8.GetString(blob).TrimEnd('\\0');
      if (token.Length < 20 || token.Length > 4096)
        throw new Exception("credential token length invalid");
      foreach (char ch in token) if (ch <= ' ')
        throw new Exception("credential token contains control characters");
      return token;
    } finally { CredFree(ptr); }
  }
}
"@
Add-Type -TypeDefinition $sig
[SupaCred]::Read("Supabase CLI:supabase")
`;
  const dir = fs.mkdtempSync(path.join(process.env.TEMP ?? process.env.TMP ?? '.', 'sgcred'));
  const tmp = path.join(dir, 'read.ps1');
  try {
    fs.writeFileSync(tmp, ps);
    const out = execFileSync(
      'powershell.exe',
      ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', tmp],
      { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] },
    );
    const token = out.trim();
    if (!token) throw new Error('empty token');
    return token;
  } catch (e) {
    const detail = String(e.stderr ?? e.message).trim().split('\n');
    throw new Error(`credential read failed: ${detail[detail.length - 1] ?? 'unknown'}`);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

let cachedToken;

/// Call the Management API with the CLI's stored token. The token never leaves
/// process memory and is never logged.
export async function api(pathname, init = {}) {
  cachedToken ??= getToken();
  const res = await fetch(`https://api.supabase.com${pathname}`, {
    ...init,
    headers: {
      Authorization: `Bearer ${cachedToken}`,
      'Content-Type': 'application/json',
      ...(init.headers ?? {}),
    },
  });
  const text = await res.text();
  if (!res.ok) throw new Error(`HTTP ${res.status}: ${text.slice(0, 400)}`);
  const ct = res.headers.get('content-type') ?? '';
  return ct.includes('json') ? JSON.parse(text) : text;
}

export async function sql(query) {
  return api(`/v1/projects/${REF}/database/query`, {
    method: 'POST',
    body: JSON.stringify({ query }),
  });
}

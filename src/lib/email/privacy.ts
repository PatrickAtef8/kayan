import { createHash } from "node:crypto";

/** "john.smith@example.com" → "j***@e***.com". Enough to recognise an address in a log, not enough to use it. */
export function maskEmail(email: string): string {
  const e = String(email ?? "").trim();
  const at = e.lastIndexOf("@");
  if (at < 1) return "***";
  const local = e.slice(0, at);
  const domain = e.slice(at + 1);
  const dot = domain.lastIndexOf(".");
  const host = dot > 0 ? domain.slice(0, dot) : domain;
  const tld = dot > 0 ? domain.slice(dot) : "";
  return `${local[0]}***@${host[0] ?? ""}***${tld}`.slice(0, 80);
}

export function hashRecipient(email: string): string {
  return createHash("sha256").update(String(email).trim().toLowerCase()).digest("hex");
}

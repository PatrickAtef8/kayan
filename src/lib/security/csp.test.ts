import { test } from "node:test";
import assert from "node:assert/strict";
import { buildCsp, generateNonce } from "./csp.ts";

test("nonces are unique, unguessable-looking and header-safe", () => {
  const a = generateNonce(), b = generateNonce();
  assert.notEqual(a, b);
  assert.match(a, /^[A-Za-z0-9+/]+=*$/);
  assert.ok(a.length >= 22);
});
test("script-src uses the nonce + strict-dynamic and never 'unsafe-inline' or 'unsafe-eval' in production", () => {
  const csp = buildCsp({ nonce: "abc123", supabaseUrl: "https://x.supabase.co" });
  const script = csp.split("; ").find((d) => d.startsWith("script-src"))!;
  assert.ok(script.includes("'nonce-abc123'") && script.includes("'strict-dynamic'"));
  assert.ok(!script.includes("unsafe-inline") && !script.includes("unsafe-eval"));
  assert.ok(csp.includes("connect-src 'self' https://x.supabase.co wss://x.supabase.co"));
  assert.ok(csp.includes("frame-ancestors 'none'") && csp.includes("object-src 'none'"));
});
test("dev adds unsafe-eval only; extra connect hosts (e.g. Sentry ingest) can be added", () => {
  assert.ok(buildCsp({ nonce: "n", isDev: true }).includes("'unsafe-eval'"));
  assert.ok(buildCsp({ nonce: "n", extraConnect: ["https://o1.ingest.sentry.io"] }).includes("https://o1.ingest.sentry.io"));
});

import { test } from "node:test";
import assert from "node:assert/strict";
import { parseAuthLink, explainLinkError } from "./auth-link.ts";

test("invitation link: session in the hash", () => {
  const r = parseAuthLink("", "#access_token=AAA&expires_in=3600&refresh_token=RRR&token_type=bearer&type=invite");
  assert.deepEqual(r, { kind: "session", accessToken: "AAA", refreshToken: "RRR", type: "invite" });
});
test("expired link: error in the hash", () => {
  const r = parseAuthLink("", "#error=access_denied&error_code=otp_expired&error_description=Email+link+is+invalid+or+has+expired");
  assert.equal(r.kind, "error");
  if (r.kind === "error") { assert.equal(r.code, "otp_expired"); assert.match(explainLinkError(r.code, r.message), /انتهت صلاحية/); }
});
test("token_hash style link", () => {
  assert.deepEqual(parseAuthLink("?token_hash=abc&type=invite", ""), { kind: "token_hash", tokenHash: "abc", type: "invite" });
});
test("unknown otp type is ignored", () => {
  assert.equal(parseAuthLink("?token_hash=abc&type=evil", "").kind, "none");
});
test("nothing special", () => {
  assert.equal(parseAuthLink("", "").kind, "none");
  assert.equal(parseAuthLink("?code=xyz", "").kind, "none"); // PKCE ?code= is handled by the Supabase client itself
});

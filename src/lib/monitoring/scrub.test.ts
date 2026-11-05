import { test } from "node:test";
import assert from "node:assert/strict";
import { scrubEvent, scrubText } from "./scrub.ts";

test("reports carry no cookies, auth headers, query strings, bodies or e-mail addresses", () => {
  const e = scrubEvent({ request: { cookies: { a: "b" }, data: { password: "x" }, query_string: "token_hash=abc", headers: { cookie: "s=1", Authorization: "Bearer x", "xpay-signature": "t=1", accept: "*/*" } }, user: { id: "u1", email: "a@b.com", ip_address: "1.2.3.4" }, message: "failed for john@example.com" });
  assert.equal(e.request?.cookies, undefined); assert.equal(e.request?.data, undefined); assert.equal(e.request?.query_string, undefined);
  assert.deepEqual(Object.keys(e.request?.headers ?? {}), ["accept"]);
  assert.deepEqual(e.user, { id: "u1" });
  assert.equal(e.message, "failed for [email]");
});
test("keys and JWT-looking tokens in text are masked", () => {
  assert.equal(scrubText("key sk_live_abcdefghijklmnopqrstuv failed"), "key [secret] failed");
  assert.equal(scrubText("jwt eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9 here"), "jwt [secret] here");
});

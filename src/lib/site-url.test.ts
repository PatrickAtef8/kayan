import { test } from "node:test";
import assert from "node:assert/strict";
import { getSiteUrl, explainInviteError } from "./site-url.ts";

test("explicit address wins and is cleaned", () => {
  assert.equal(getSiteUrl({ NEXT_PUBLIC_SITE_URL: "https://app.example.com/" }), "https://app.example.com");
  assert.equal(getSiteUrl({ NEXT_PUBLIC_SITE_URL: "app.example.com", NODE_ENV: "production" }), "https://app.example.com");
});
test("falls back to Vercel's production URL", () => {
  assert.equal(getSiteUrl({ VERCEL_PROJECT_PRODUCTION_URL: "kayan.vercel.app", NODE_ENV: "production" }), "https://kayan.vercel.app");
});
test("localhost only outside production", () => {
  assert.equal(getSiteUrl({ NODE_ENV: "development" }), "http://localhost:3000");
  assert.equal(getSiteUrl({}), "http://localhost:3000");
});
test("production without an address fails loudly instead of emailing a localhost link", () => {
  assert.throws(() => getSiteUrl({ NODE_ENV: "production" }), /NEXT_PUBLIC_SITE_URL/);
});
test("email errors are explained", () => {
  assert.match(explainInviteError("email rate limit exceeded"), /SMTP/);
  assert.match(explainInviteError("Email address not authorized"), /Custom SMTP/);
  assert.equal(explainInviteError("something else"), "something else");
});

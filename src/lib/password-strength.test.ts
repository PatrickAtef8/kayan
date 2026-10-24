import { test } from "node:test";
import assert from "node:assert/strict";
import { passwordStrength, isPasswordAcceptable, passwordChecks } from "./password-strength.ts";

test("empty has no strength", () => assert.equal(passwordStrength("").score, 0));
test("short is weak and not acceptable", () => {
  assert.equal(passwordStrength("abc123").score, 1);
  assert.equal(isPasswordAcceptable("abc123"), false);
});
test("common passwords stay weak", () => assert.equal(passwordStrength("12345678").score, 1));
test("long plain lowercase is acceptable but only fair", () => {
  assert.equal(isPasswordAcceptable("abcdefghij"), true);
  assert.equal(passwordStrength("abcdefghij").score, 1 + 0);
});
test("mixed case + number + symbol is strong", () => assert.equal(passwordStrength("Kayan#2026x").score, 4));
test("only length is required", () => assert.deepEqual(passwordChecks("x").filter((c) => c.required).map((c) => c.id), ["length"]));

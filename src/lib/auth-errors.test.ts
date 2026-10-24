import { test } from "node:test";
import assert from "node:assert/strict";
import { translateAuthError, isWeakPasswordError } from "./auth-errors.ts";

test("same password is explained, not generic", () => {
  assert.match(translateAuthError("New password should be different from the old password.", "same_password"), /مطابقة/);
});
test("missing session is explained", () => {
  assert.match(translateAuthError("Auth session missing!"), /انتهت/);
});
test("character-class policy is explained", () => {
  assert.match(translateAuthError("Password should contain at least one character of each: abc, ABC, 123"), /حروف كبيرة/);
});
test("unknown errors keep the original text so the cause is visible", () => {
  const t = translateAuthError("Something odd");
  assert.match(t, /حدث خطأ غير متوقع/);
  assert.match(t, /Something odd/);
});

test("weak_password with reason=length is NOT reported as leaked", () => {
  const t = translateAuthError("Password should be at least 12 characters.", "weak_password", ["length"]);
  assert.match(t, /أقصر/);
  assert.match(t, /12/);
  assert.doesNotMatch(t, /تسريبات/);
});
test("weak_password with reason=pwned explains the breach check", () => {
  const t = translateAuthError("Password is known to be weak and easy to guess, please choose a different one.", "weak_password", ["pwned"]);
  assert.match(t, /تسريبات/);
});
test("weak_password with no reasons falls back to the message text", () => {
  assert.match(translateAuthError("Password should be at least 10 characters.", "weak_password"), /10/);
  assert.match(translateAuthError("Password is known to be weak and easy to guess", "weak_password"), /تسريبات/);
});
test("multiple reasons are all listed", () => {
  const t = translateAuthError("", "weak_password", ["length", "pwned"]);
  assert.match(t, /أقصر/);
  assert.match(t, /تسريبات/);
});
test("isWeakPasswordError detects the code", () => {
  assert.equal(isWeakPasswordError("x", "weak_password"), true);
  assert.equal(isWeakPasswordError("Invalid login credentials", "invalid_credentials"), false);
});

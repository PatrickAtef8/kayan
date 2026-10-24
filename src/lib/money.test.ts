import { test } from "node:test";
import assert from "node:assert/strict";
import { formatMoney, isNegativeMoney } from "./money.ts";

test("negative amounts: Arabic digits with the minus sign first and no bidi marks", () => {
  assert.equal(formatMoney(-1234.5), "-١٬٢٣٤٫٥٠");
  assert.equal(formatMoney(-5), "-٥٫٠٠");
  assert.ok(!/[\u200e\u200f\u061c]/.test(formatMoney(-1234.5)), "no hidden direction marks in front of the sign");
});

test("positive and zero amounts have no sign", () => {
  assert.equal(formatMoney(1234.5), "١٬٢٣٤٫٥٠");
  assert.equal(formatMoney(0), "٠٫٠٠");
});

test("amounts that round to zero are not negative (no '-٠٫٠٠', no red)", () => {
  assert.equal(isNegativeMoney(-0.004), false);
  assert.equal(formatMoney(-0.004), "٠٫٠٠");
  assert.equal(formatMoney(-0), "٠٫٠٠");
  assert.equal(isNegativeMoney(-0.01), true);
});

test("non-finite input never prints NaN", () => {
  assert.equal(formatMoney(NaN), "٠٫٠٠");
  assert.equal(isNegativeMoney(NaN), false);
});

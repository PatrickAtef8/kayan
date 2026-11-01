import { test } from "node:test";
import assert from "node:assert/strict";
import { formatMoney, isNegativeMoney } from "./money.ts";

// formatMoney wraps every amount in a left-to-right isolate (U+2066 … U+2069) so surrounding Arabic text can never move it (see money.ts)
const iso = (s: string) => `\u2066${s}\u2069`;

test("negative amounts: Arabic digits with the minus sign first and no LRM / RLM / ALM marks", () => {
  assert.equal(formatMoney(-1234.5), iso("-١٬٢٣٤٫٥٠"));
  assert.equal(formatMoney(-5), iso("-٥٫٠٠"));
  assert.ok(!/[\u200e\u200f\u061c]/.test(formatMoney(-1234.5)), "no hidden direction marks in front of the sign");
});

test("positive and zero amounts have no sign", () => {
  assert.equal(formatMoney(1234.5), iso("١٬٢٣٤٫٥٠"));
  assert.equal(formatMoney(0), iso("٠٫٠٠"));
});

test("amounts that round to zero are not negative (no '-٠٫٠٠', no red)", () => {
  assert.equal(isNegativeMoney(-0.004), false);
  assert.equal(formatMoney(-0.004), iso("٠٫٠٠"));
  assert.equal(formatMoney(-0), iso("٠٫٠٠"));
  assert.equal(isNegativeMoney(-0.01), true);
});

test("non-finite input never prints NaN", () => {
  assert.equal(formatMoney(NaN), iso("٠٫٠٠"));
  assert.equal(isNegativeMoney(NaN), false);
});

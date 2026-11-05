import { test, mock } from "node:test";
import assert from "node:assert/strict";
import { cairoDate } from "./report-period.ts";

// cairoDate() is what every "today" in the app now uses (it replaced toISOString().slice(0,10), which is the UTC date).
const at = (iso: string) => { mock.timers.enable({ apis: ["Date"], now: new Date(iso) }); try { return cairoDate(); } finally { mock.timers.reset(); } };

test("Cairo midnight boundary, winter (UTC+2): the UTC date is still yesterday for the first two hours", () => {
  assert.equal(at("2026-01-10T21:59:59Z"), "2026-01-10");
  assert.equal(at("2026-01-10T22:00:00Z"), "2026-01-11");   // toISOString().slice(0,10) would say 2026-01-10 here — the bug
  assert.equal(at("2026-01-10T23:30:00Z"), "2026-01-11");
});
test("Cairo midnight boundary, summer (UTC+3)", () => {
  assert.equal(at("2026-07-10T20:59:59Z"), "2026-07-10");
  assert.equal(at("2026-07-10T21:00:00Z"), "2026-07-11");
});
test("month and year ends roll over on the Cairo calendar", () => {
  assert.equal(at("2026-12-31T22:00:00Z"), "2027-01-01");
  assert.equal(at("2026-02-28T22:30:00Z"), "2026-03-01");
});

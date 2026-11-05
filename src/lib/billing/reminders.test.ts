import { test } from "node:test";
import assert from "node:assert/strict";
import { planReminder, cairoDayOf, daysBetween } from "./reminders.ts";

const ORG = "11111111-1111-1111-1111-111111111111";
const at = (iso: string) => new Date(iso);

test("Cairo day boundaries: 23:30 UTC is already tomorrow in Cairo (winter UTC+2, summer UTC+3)", () => {
  assert.equal(cairoDayOf(at("2026-01-10T21:59:59Z")), "2026-01-10");   // 23:59:59 Cairo (winter)
  assert.equal(cairoDayOf(at("2026-01-10T22:00:00Z")), "2026-01-11");   // midnight Cairo (winter)
  assert.equal(cairoDayOf(at("2026-07-10T20:59:59Z")), "2026-07-10");   // 23:59:59 Cairo (summer, UTC+3)
  assert.equal(cairoDayOf(at("2026-07-10T21:00:00Z")), "2026-07-11");   // midnight Cairo (summer)
  assert.equal(daysBetween("2026-12-01", "2026-12-08"), 7);
  assert.equal(daysBetween("2026-02-27", "2026-03-02"), 3);
});

test("a licence ending late on the 10th Cairo time is 'ending today' for the whole 10th, not already ended", () => {
  const end = "2026-01-10T21:00:00Z"; // 23:00 Cairo on the 10th
  assert.equal(planReminder(ORG, end, at("2026-01-09T22:30:00Z"))?.daysLeft, 0);  // 00:30 Cairo on the 10th
  assert.equal(planReminder(ORG, end, at("2026-01-10T20:00:00Z"))?.threshold, 0); // 22:00 Cairo on the 10th
  assert.equal(planReminder(ORG, end, at("2026-01-10T22:30:00Z"))?.threshold, "ended"); // 00:30 Cairo on the 11th → ended
});

test("thresholds: 7, 3, 1 days before and the day itself; nothing earlier than 7 days", () => {
  const end = "2026-12-20T10:00:00Z";
  const th = (nowIso: string) => planReminder(ORG, end, at(nowIso))?.threshold ?? null;
  assert.equal(th("2026-12-10T10:00:00Z"), null);  // 10 days
  assert.equal(th("2026-12-13T10:00:00Z"), 7);     // 7
  assert.equal(th("2026-12-15T10:00:00Z"), 7);     // 5: catches up the 7-day reminder if the job missed a day
  assert.equal(th("2026-12-17T10:00:00Z"), 3);
  assert.equal(th("2026-12-18T10:00:00Z"), 3);     // 2
  assert.equal(th("2026-12-19T10:00:00Z"), 1);
  assert.equal(th("2026-12-20T05:00:00Z"), 0);
});

test("after the end: one 'ended' notice for a week, then silence", () => {
  const end = "2026-12-20T10:00:00Z";
  assert.equal(planReminder(ORG, end, at("2026-12-21T10:00:00Z"))?.threshold, "ended");
  assert.equal(planReminder(ORG, end, at("2026-12-27T10:00:00Z"))?.threshold, "ended");
  assert.equal(planReminder(ORG, end, at("2026-12-28T10:00:00Z")), null);
});

test("the key changes when the licence is renewed, so a new cycle sends again; and never repeats within a cycle", () => {
  const a = planReminder(ORG, "2026-12-20T10:00:00Z", at("2026-12-18T10:00:00Z"));
  const b = planReminder(ORG, "2026-12-20T10:00:00Z", at("2026-12-18T20:00:00Z"));
  assert.equal(a?.dedupeKey, b?.dedupeKey);
  const renewed = planReminder(ORG, "2027-01-20T10:00:00Z", at("2027-01-18T10:00:00Z"));
  assert.notEqual(renewed?.dedupeKey, a?.dedupeKey);
  assert.equal(planReminder(ORG, "2027-01-20T10:00:00Z", at("2026-12-18T10:00:00Z")), null); // renewed: nothing due now
});

test("no end date / garbage date: no reminder", () => {
  assert.equal(planReminder(ORG, null, new Date()), null);
  assert.equal(planReminder(ORG, "not a date", new Date()), null);
});

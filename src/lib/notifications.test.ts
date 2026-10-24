// Unit tests for the notification helpers.  Run:  npm run test:notifications
// (node's built-in runner; no extra dependency — excluded from tsc because of the explicit ".ts" import).
import test from "node:test";
import assert from "node:assert/strict";
import {
  appendPage, badgeText, describeNotification, markAllRead, markRead, mergeFirstPage, money, qty, timeAgo, type AppNotification,
} from "./notifications.ts";

const n = (id: string, over: Partial<AppNotification> = {}): AppNotification => ({
  id, type: "customer_payment", title: "t", href: "/dashboard", payload: {},
  created_at: `2026-02-${String(10 + Number(id.replace(/\D/g, "") || 0)).padStart(2, "0")}T10:00:00Z`, read_at: null, resolved_at: null, ...over,
});

test("money has exactly two decimals and the currency, quantities drop trailing zeros", () => {
  assert.ok(money(10).includes("١٠٫٠٠"));
  assert.ok(money(10).endsWith("ج.م"));
  assert.equal(money("abc"), "");
  assert.equal(qty(3), "٣");
  assert.equal(qty(2.5), "٢٫٥");
});

test("badge caps at 99+", () => {
  assert.equal(badgeText(3), "٣");
  assert.equal(badgeText(99), "٩٩");
  assert.equal(badgeText(100), "٩٩+");
});

test("reading one notification only touches that one, and only once", () => {
  const list = [n("1"), n("2"), n("3", { read_at: "2026-01-01T00:00:00Z" })];
  const after = markRead(list, "2", "2026-03-01T00:00:00Z");
  assert.equal(after[0].read_at, null);
  assert.equal(after[1].read_at, "2026-03-01T00:00:00Z");
  assert.equal(markRead(after, "3", "2030-01-01T00:00:00Z")[2].read_at, "2026-01-01T00:00:00Z", "an already-read row keeps its original time");
  assert.equal(list[1].read_at, null, "the input is not mutated");
});

test("mark all read leaves nothing unread and never changes resolved state", () => {
  const list = [n("1", { resolved_at: null }), n("2", { resolved_at: "2026-02-01T00:00:00Z" })];
  const after = markAllRead(list, "2026-03-01T00:00:00Z");
  assert.ok(after.every((x) => x.read_at));
  assert.equal(after[0].resolved_at, null, "read is not done");
  assert.equal(after[1].resolved_at, "2026-02-01T00:00:00Z");
});

test("a refreshed first page keeps older pages that were already loaded, without duplicates", () => {
  const page = 3;
  const all = [n("9"), n("8"), n("7"), n("6"), n("5")];            // newest first
  const prev = all;                                                 // user had loaded 5
  const fresh = [n("10"), n("9"), n("8")];                          // a new one arrived
  const merged = mergeFirstPage(prev, fresh, page);
  assert.deepEqual(merged.map((x) => x.id), ["10", "9", "8", "7", "6", "5"]);
  assert.deepEqual(mergeFirstPage(prev, [n("9")], page).map((x) => x.id), ["9"], "a short first page IS the whole history");
  assert.deepEqual(appendPage([n("1")], [n("1"), n("2")]).map((x) => x.id), ["1", "2"]);
});

test("a storekeeper task shows items and quantities, never money, and the remaining quantity after a partial dispatch", () => {
  const open = describeNotification(n("1", {
    type: "warehouse_dispatch_needed",
    payload: { invoice_number: "S-1", warehouse: "الرئيسي", status: "partial", lines: [
      { name: "صنف أ", unit: "قطعة", ordered: 5, remaining: 2 }, { name: "صنف ب", unit: "كرتونة", ordered: 2, remaining: 0 }] },
  }));
  assert.equal(open.rows.length, 2);
  assert.ok(open.rows[0].text.includes("المتبقي"), "partial line shows what is left");
  assert.ok(!open.rows[1].text.includes("المتبقي") || open.rows[1].text.includes("٠"));
  assert.deepEqual(open.chip, { label: "بانتظار التنفيذ", done: false });
  assert.ok(![open.summary, open.meta, ...open.rows.map((r) => r.text)].join(" ").includes("ج.م"));
  const done = describeNotification(n("1", { type: "warehouse_dispatch_needed", resolved_at: "2026-02-02T00:00:00Z", payload: { lines: [] } }));
  assert.deepEqual(done.chip, { label: "تم", done: true });
});

test("owner notifications read naturally", () => {
  const v = describeNotification(n("1", { type: "sales_invoice_created", payload: { customer: "عميل", total: 200, amount_paid: 100, by: "مندوب ١" } }));
  assert.ok(v.summary?.includes("عميل") && v.summary.includes("ج.م"));
  assert.ok(v.meta?.includes("مندوب ١") && v.meta.includes("مدفوع"));
  assert.equal(v.chip, null, "an invoice event is not a task");
  const sh = describeNotification(n("1", { type: "shortage_reported", payload: { rep: "م", needed: 900, available: 10, unit: "قطعة" } }));
  assert.deepEqual(sh.chip, { label: "بانتظار التنفيذ", done: false });
  const unknown = describeNotification(n("1", { type: "something_new", payload: {} }));
  assert.equal(unknown.summary, null, "an unknown type degrades to just its title");
});

test("relative time", () => {
  const now = Date.parse("2026-02-10T12:00:00Z");
  assert.equal(timeAgo("2026-02-10T11:59:40Z", now), "الآن");
  assert.ok(timeAgo("2026-02-10T11:00:00Z", now).length > 0);
  assert.ok(timeAgo("2026-01-01T00:00:00Z", now).length > 0);
  assert.equal(timeAgo("garbage", now), "");
});

test("0049: assignment cards show who and what, with names beside emails", () => {
  const rep = describeNotification(n("1", { type: "rep_customer_assigned", payload: { customer: "محل الأمل", by: "المالك (owner@x.com)" } }));
  assert.equal(rep.icon, "assign");
  assert.ok(rep.summary?.includes("محل الأمل"));
  assert.equal(rep.meta, "بواسطة المالك (owner@x.com)");

  const owner = describeNotification(n("2", { type: "assignment_made", payload: { customer: "محل الأمل", rep: "أحمد (a@x.com)", old_rep: "سعيد (s@x.com)", by: "مالك آخر (o2@x.com)" } }));
  assert.ok(owner.summary?.includes("أحمد (a@x.com)") && owner.summary?.includes("كان عند سعيد (s@x.com)"));

  const none = describeNotification(n("3", { type: "assignment_made", payload: { customer: "محل الأمل", rep: null } }));
  assert.ok(none.summary?.includes("بدون مندوب"));
});

test("0049: team and role cards", () => {
  const role = describeNotification(n("1", { type: "role_changed", payload: { from: "مندوب", to: "أمين مخزن", by: "المالك (o@x.com)" } }));
  assert.equal(role.icon, "team");
  assert.ok(role.summary?.includes("من مندوب") && role.summary?.includes("إلى أمين مخزن"));
  const joined = describeNotification(n("2", { type: "team_activity", payload: { action: "joined", member: "محمود (m@x.com)", role: "مندوب", by: "محمود (m@x.com)" } }));
  assert.ok(joined.summary?.includes("محمود (m@x.com)") && joined.summary?.includes("الدور مندوب"));
  const rec = describeNotification(n("3", { type: "rep_record_update", payload: { action: "linked", by: "المالك (o@x.com)" } }));
  assert.ok(rec.summary?.includes("تم ربط حسابك"));
  assert.equal(describeNotification(n("4", { type: "rep_record_update", payload: { action: "weird" } })).summary, null);
});

test("0049: a cancelled warehouse task lists quantities only", () => {
  const v = describeNotification(n("1", { type: "warehouse_task_cancelled", payload: { warehouse: "الرئيسي", released: [{ name: "صنف", unit: "قطعة", qty: 4 }] } }));
  assert.equal(v.rows.length, 1);
  assert.ok(v.rows[0].text.includes("أُلغي") && v.rows[0].text.includes("٤"));
  assert.equal(v.chip, null, "it is information, not a task with a done state");
});

test("0049: customer edits list the changed fields, never values", () => {
  const u = describeNotification(n("1", { type: "rep_customer_updated", payload: { customer: "محل الأمل", fields: ["الهاتف", "شريحة السعر"], deleted: false, by: "المالك (o@x.com)" } }));
  assert.ok(u.summary?.includes("الهاتف، شريحة السعر"));
  const d = describeNotification(n("2", { type: "rep_customer_updated", payload: { customer: "محل الأمل", fields: [], deleted: true } }));
  assert.ok(d.summary?.includes("تم حذفه"));
});

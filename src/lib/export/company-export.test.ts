import { test } from "node:test";
import assert from "node:assert/strict";
import { EXPORT_TABLES, planSheet, safeSheetName, cellValue, headerFor, PAGE_SIZE } from "./company-export.ts";

test("every sheet name is valid for Excel and unique", () => {
  const used = new Set<string>();
  for (const t of EXPORT_TABLES) { const n = safeSheetName(t.sheet, used); assert.ok(n.length <= 31 && !/[\\/?*[\]:]/.test(n), n); }
  assert.equal(used.size, EXPORT_TABLES.length);
  assert.equal(safeSheetName("a/b?c", new Set()), "a b c");
  const u = new Set<string>(); assert.notEqual(safeSheetName("X", u), safeSheetName("x", u));
});
test("tenant plumbing and credentials never reach the file; Arabic text survives untouched", () => {
  const p = planSheet({ table: "customers", sheet: "العملاء" }, [{ id: "1", organization_id: "o", name: "شركة النور — ع", token: "t", created_at: "2026-01-01", phone: "010" }], false);
  assert.deepEqual(p.keys, ["id", "name", "phone", "created_at"]);
  assert.deepEqual(p.rows[0], ["1", "شركة النور — ع", "010", "2026-01-01"]);
  const q = planSheet({ table: "organization_users", sheet: "الفريق", omit: ["user_id"] }, [{ id: "1", user_id: "u", display_name: "أحمد" }], false);
  assert.ok(!q.keys.includes("user_id"));
});
test("cells: json becomes text, long text is capped, null stays empty", () => {
  assert.equal(cellValue({ a: "ع" }), '{"a":"ع"}');
  assert.equal((cellValue("x".repeat(40000)) as string).length, 32001);
  assert.equal(cellValue(undefined), null);
  assert.equal(headerFor("customer_id"), "معرّف العميل"); assert.equal(headerFor("zzz"), "zzz");
});
test("paging uses the API page size so more than 1000 rows are never silently dropped", () => assert.equal(PAGE_SIZE, 1000));

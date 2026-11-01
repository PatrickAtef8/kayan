import { test } from "node:test";
import assert from "node:assert/strict";
import { fallbackOrFilter, idsOrNone, safeSearchText, sortByIds } from "./entity-search.ts";

test("safeSearchText removes everything that could change a filter", () => {
  assert.equal(safeSearchText("شركة (النور)"), "شركة النور");
  assert.equal(safeSearchText("a,id.neq.0"), "a id.neq.0");
  assert.equal(safeSearchText('50%_off\\"'), "50 off");
  assert.equal(safeSearchText("   "), "");
  assert.equal(safeSearchText("x".repeat(200)).length, 80);
});

test("fallbackOrFilter builds one clause per column, or null", () => {
  assert.equal(fallbackOrFilter(["name", "phone"], "010"), "name.ilike.%010%,phone.ilike.%010%");
  assert.equal(fallbackOrFilter(["name"], "(,)"), null);
});

test("sortByIds keeps the database ranking; idsOrNone never returns an empty list", () => {
  assert.deepEqual(sortByIds([{ id: "b" }, { id: "c" }, { id: "a" }], ["a", "b", "c"]).map((r) => r.id), ["a", "b", "c"]);
  assert.equal(idsOrNone([]).length, 1);
  assert.deepEqual(idsOrNone(["x"]), ["x"]);
});

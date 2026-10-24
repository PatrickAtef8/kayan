import { test } from "node:test";
import assert from "node:assert/strict";
import { containsPattern, escapeLike, invoiceHref, invoiceParam, isUuid } from "./doc-search.ts";

const ID = "3f2a9c1e-5b7d-4e0a-9d63-0a1b2c3d4e5f";

test("isUuid accepts ids only", () => {
  assert.equal(isUuid(ID), true);
  assert.equal(isUuid(ID.toUpperCase()), true);
  for (const bad of ["", "12", "97541990", `${ID}x`, `${ID}'; drop table x;--`, undefined, null, 5]) assert.equal(isUuid(bad), false, String(bad));
});

test("invoiceParam: valid id → lower-cased id; anything else → null (never reaches the database)", () => {
  assert.equal(invoiceParam(ID.toUpperCase()), ID);
  assert.equal(invoiceParam(` ${ID} `), ID);
  assert.equal(invoiceParam([ID, "x"]), ID);
  assert.equal(invoiceParam("S-000001"), null);
  assert.equal(invoiceParam(undefined), null);
  assert.equal(invoiceParam(""), null);
});

test("escapeLike makes % _ \\ literal", () => {
  assert.equal(escapeLike("50%_off\\"), "50\\%\\_off\\\\");
  assert.equal(containsPattern("S-1_"), "%S-1\\_%");
  assert.equal(containsPattern("12"), "%12%");
});

test("invoiceHref points at the invoice id for each kind", () => {
  assert.equal(invoiceHref("sales", ID), `/dashboard/sales?inv=${ID}`);
  assert.equal(invoiceHref("purchase", ID), `/dashboard/purchases?inv=${ID}`);
});

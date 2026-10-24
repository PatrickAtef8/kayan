import { test } from "node:test";
import assert from "node:assert/strict";
import { requiredUnits, findShortages } from "./stock-requirements.ts";

const A = "a", B = "b", S = "svc";
const stock = { [A]: { tracked: true, available: 10 }, [B]: { tracked: true, available: 0 }, [S]: { tracked: false, available: null } };

test("paid quantity only", () => {
  const r = requiredUnits([{ product_id: A, quantity: 4 }], [], []);
  assert.deepEqual(r.get(A), { paid: 4, bonus: 0, total: 4 });
});

test("the same product on two lines counts together", () => {
  const r = requiredUnits([{ product_id: A, quantity: 4 }, { product_id: A, quantity: 5 }], [], null);
  assert.equal(r.get(A)?.total, 9);
});

test("a bonus of the SAME product adds to the paid units", () => {
  const r = requiredUnits([{ product_id: A, quantity: 8 }], [], [{ product: A, qty: 3 }]);
  assert.deepEqual(r.get(A), { paid: 8, bonus: 3, total: 11 });
  assert.deepEqual(findShortages(r, stock).map((s) => [s.productId, s.required, s.available]), [[A, 11, 10]]);
});

test("a bonus of ANOTHER product is required even though that product is not on any paid line", () => {
  const r = requiredUnits([{ product_id: A, quantity: 1 }], [], [{ product: B, qty: 2 }]);
  assert.equal(r.get(B)?.total, 2);
  const sh = findShortages(r, stock);
  assert.equal(sh.length, 1);
  assert.equal(sh[0].productId, B);
  assert.equal(sh[0].available, 0);
});

test("engine bonus (e.g. from a promotion rule) is counted even when no manual bonus row exists", () => {
  const r = requiredUnits([{ product_id: A, quantity: 9 }], [], [{ product: A, qty: 2 }]);
  assert.equal(r.get(A)?.total, 11);
  assert.equal(findShortages(r, stock).length, 1);
});

test("manual bonus rows count immediately, before the engine has answered", () => {
  const r = requiredUnits([{ product_id: A, quantity: 9 }], [{ product_id: A, quantity: 2 }], null);
  assert.equal(r.get(A)?.total, 11);
});

test("manual and engine bonus describe the SAME units: they are not added twice", () => {
  const r = requiredUnits([{ product_id: A, quantity: 5 }], [{ product_id: A, quantity: 3 }], [{ product: A, qty: 3 }]);
  assert.deepEqual(r.get(A), { paid: 5, bonus: 3, total: 8 });
  assert.equal(findShortages(r, stock).length, 0);
});

test("a stale engine answer can only make the screen stricter, never laxer", () => {
  // the user just raised the manual bonus from 1 to 4; the engine still reports 1
  const r = requiredUnits([{ product_id: A, quantity: 7 }], [{ product_id: A, quantity: 4 }], [{ product: A, qty: 1 }]);
  assert.equal(r.get(A)?.bonus, 4);
});

test("exactly the available quantity is fine; one more is a shortage", () => {
  assert.equal(findShortages(requiredUnits([{ product_id: A, quantity: 7 }], [], [{ product: A, qty: 3 }]), stock).length, 0);
  assert.equal(findShortages(requiredUnits([{ product_id: A, quantity: 7 }], [], [{ product: A, qty: 3.001 }]), stock).length, 1);
});

test("products without stock tracking and products with unknown stock are never blocked on screen", () => {
  const r = requiredUnits([{ product_id: S, quantity: 1000 }, { product_id: "unknown", quantity: 5 }], [], []);
  assert.equal(findShortages(r, stock).length, 0);
});

test("junk quantities (NaN, negative, empty ids) are ignored", () => {
  const r = requiredUnits([{ product_id: A, quantity: NaN }, { product_id: "", quantity: 3 }, { product_id: A, quantity: -2 }], [], [{ product: A, qty: Number("x") }]);
  assert.equal(r.get(A)?.total ?? 0, 0);
});

// How many units of each product an invoice needs in total — paid lines PLUS every bonus unit.
//
// The bonus comes from the pricing engine's own answer (`preview.bonus`: the same list the invoice RPC will
// post, whether the units were typed by hand or produced by a promotion rule), so the screen and the database
// count the same units. The hand-typed bonus rows are counted as well, because the engine's answer arrives a
// moment after each keystroke; for each product the larger of the two is used, so the screen can only ever be
// too strict for a split second — never too lax. The database re-checks everything when the invoice is saved.

export type QtyLine = { product_id: string; quantity: number };
export type EngineBonus = { product: string; qty: number };

const num = (v: unknown) => {
  const n = Number(v);
  return Number.isFinite(n) && n > 0 ? n : 0;
};

function sumBy<T>(list: T[], id: (x: T) => string | undefined, qty: (x: T) => number) {
  const m = new Map<string, number>();
  for (const x of list) {
    const k = id(x);
    if (k) m.set(k, (m.get(k) ?? 0) + num(qty(x)));
  }
  return m;
}

export type Required = { paid: number; bonus: number; total: number };

export function requiredUnits(items: QtyLine[], manualBonus: QtyLine[], engineBonus: EngineBonus[] | null | undefined): Map<string, Required> {
  const paid = sumBy(items, (x) => x.product_id, (x) => x.quantity);
  const manual = sumBy(manualBonus, (x) => x.product_id, (x) => x.quantity);
  const engine = sumBy(engineBonus ?? [], (x) => x.product, (x) => x.qty);
  const out = new Map<string, Required>();
  for (const id of new Set([...paid.keys(), ...manual.keys(), ...engine.keys()])) {
    const p = paid.get(id) ?? 0;
    const b = Math.max(manual.get(id) ?? 0, engine.get(id) ?? 0);
    out.set(id, { paid: p, bonus: b, total: Math.round((p + b) * 1000) / 1000 });
  }
  return out;
}

export type Shortage = { productId: string; required: number; paid: number; bonus: number; available: number };

// `stock[id].available === null` / `tracked === false` means "no stock limit" (services).
export function findShortages(required: Map<string, Required>, stock: Record<string, { tracked: boolean; available: number | null }>): Shortage[] {
  const out: Shortage[] = [];
  for (const [productId, r] of required) {
    const s = stock[productId];
    if (!s || !s.tracked || s.available == null) continue;
    if (r.total > s.available) out.push({ productId, required: r.total, paid: r.paid, bonus: r.bonus, available: s.available });
  }
  return out;
}

"use client";

import { useCallback, useRef, useState } from "react";
import type { SearchOption } from "./async-search-select";

/**
 * Glue between AsyncSearchSelect (which only knows {value,label}) and a form that needs the FULL record of whatever was picked
 * (a customer's price tier, a product's prices). Every search result is remembered, so by the time the person selects one, the form
 * already holds its data. `seed` pre-loads records (e.g. a product chosen by a stock-shortage link).
 */
export function useKnownPicks<T extends { id: string; name: string }>(searchAction: (q: string) => Promise<T[]>, seed: T[] = []) {
  const [known, setKnown] = useState<Map<string, T>>(() => new Map(seed.map((s) => [s.id, s])));
  const action = useRef(searchAction);
  const search = useCallback(async (q: string): Promise<SearchOption[]> => {
    const rows = await action.current(q);
    setKnown((m) => { const n = new Map(m); for (const r of rows) n.set(r.id, r); return n; });
    return rows.map((r) => ({ value: r.id, label: r.name }));
  }, []);
  return { known, search };
}

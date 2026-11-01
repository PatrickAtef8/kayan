// Server-side text search for the customers / suppliers / products lists.
//
// The database finds ONE page of ids (Arabic spelling variants treated alike, "%" and "_" taken literally, indexed): migration 0069,
// search_entity_page. The page then reads those few rows with all its usual joins. If the function is not installed yet (migration not
// applied) or fails, the page falls back to a plain, SAFE contains-filter instead of an empty list.
import type { SupabaseClient } from "@supabase/supabase-js";

export type EntitySearch = { ids: string[]; total: number };

const NIL = "00000000-0000-0000-0000-000000000000";

export async function searchEntityPage(
  supabase: Pick<SupabaseClient, "rpc">,
  orgId: string,
  entity: "customers" | "suppliers" | "products",
  q: string,
  page: number,
  pageSize: number,
): Promise<EntitySearch | null> {
  const { data, error } = await supabase.rpc("search_entity_page", { p_org: orgId, p_entity: entity, p_query: q, p_limit: pageSize, p_offset: (page - 1) * pageSize });
  if (error || !data) {
    console.error("search: search_entity_page unavailable, using the plain filter", error?.message);
    return null;
  }
  const r = data as { total?: number; ids?: string[] };
  return { total: Number(r.total) || 0, ids: Array.isArray(r.ids) ? r.ids : [] };
}

/** `.in("id", …)` needs at least one value; an empty page must match nothing. */
export const idsOrNone = (ids: string[]): string[] => (ids.length ? ids : [NIL]);

/** Rows come back in any order from `.in()`: put them in the order the database ranked them. */
export function sortByIds<T extends { id: string }>(rows: T[], ids: string[]): T[] {
  const rank = new Map(ids.map((id, i) => [id, i]));
  return [...rows].sort((a, b) => (rank.get(a.id) ?? 0) - (rank.get(b.id) ?? 0));
}

/**
 * The fallback: what the user typed made safe to place inside a PostgREST `or(...)` filter. Characters that have a meaning there
 * (",", "(", ")", quotes, "*", "\\") or in LIKE ("%", "_") become spaces, so a name like «شركة (النور)» can never break the request.
 */
export function safeSearchText(q: string): string {
  return q.replace(/[%_,()*"\\]/g, " ").replace(/\s+/g, " ").trim().slice(0, 80);
}

/** `col.ilike.%text%` for each column, joined for `.or()`; null when nothing searchable is left. */
export function fallbackOrFilter(columns: string[], q: string): string | null {
  const t = safeSearchText(q);
  return t ? columns.map((c) => `${c}.ilike.%${t}%`).join(",") : null;
}

import type { SupabaseClient } from "@supabase/supabase-js";

// Bulk writes for the import actions. One INSERT per row costs one network round trip per row (2000 rows = minutes,
// longer than a serverless function may run); a chunk of rows is ONE request. If a chunk is refused (a single bad row
// fails the whole statement) the chunk is retried row by row, so every row still gets its own accept / error message
// exactly as it did when everything was inserted one at a time.

export const BULK_CHUNK = 200;

export type BulkItem = { row: number; data: Record<string, unknown> & { name: string } };
export type BulkInserted = { row: number; id: string };
export type BulkFailed = { row: number; error: string };

// Inserts `items` into `table` and returns the new ids. Rows are matched back to their ids by `name` (names are
// unique within one import: callers drop duplicates first), so the result never depends on the order of the response.
export async function insertChunked(supabase: SupabaseClient, table: string, items: BulkItem[], fallbackError: string): Promise<{ inserted: BulkInserted[]; failed: BulkFailed[] }> {
  const inserted: BulkInserted[] = [];
  const failed: BulkFailed[] = [];

  for (let i = 0; i < items.length; i += BULK_CHUNK) {
    const chunk = items.slice(i, i + BULK_CHUNK);
    const { data, error } = await supabase.from(table).insert(chunk.map((c) => c.data)).select("id, name");

    if (!error && data) {
      const idByName = new Map((data as { id: string; name: string }[]).map((r) => [r.name, r.id]));
      for (const item of chunk) {
        const id = idByName.get(item.data.name);
        if (id) inserted.push({ row: item.row, id });
        else failed.push({ row: item.row, error: fallbackError });
      }
      continue;
    }

    // The whole chunk was rejected (nothing was written): find out which rows are at fault, one by one.
    for (const item of chunk) {
      const one = await supabase.from(table).insert(item.data).select("id").single();
      if (one.error || !one.data) failed.push({ row: item.row, error: one.error?.message ?? fallbackError });
      else inserted.push({ row: item.row, id: (one.data as { id: string }).id });
    }
  }
  return { inserted, failed };
}

// Upserts rows in chunks; returns the error of every chunk that failed (the caller decides how to report it).
export async function upsertChunked(supabase: SupabaseClient, table: string, rows: Record<string, unknown>[], onConflict: string): Promise<{ error: string | null }[]> {
  const results: { error: string | null }[] = [];
  for (let i = 0; i < rows.length; i += 500) {
    const { error } = await supabase.from(table).upsert(rows.slice(i, i + 500), { onConflict });
    results.push({ error: error ? error.message : null });
  }
  return results;
}

// Plain (non-returning) chunked insert, for child rows whose failure must not undo the parent (e.g. a product's price).
export async function insertManyChunked(supabase: SupabaseClient, table: string, rows: Record<string, unknown>[]): Promise<{ error: string | null }[]> {
  const results: { error: string | null }[] = [];
  for (let i = 0; i < rows.length; i += BULK_CHUNK) {
    const { error } = await supabase.from(table).insert(rows.slice(i, i + BULK_CHUNK));
    results.push({ error: error ? error.message : null });
  }
  return results;
}

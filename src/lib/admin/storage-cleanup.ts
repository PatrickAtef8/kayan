// Removes a deleted company's files from Supabase Storage. SQL cannot do this (deleting storage.objects rows would leave the real files
// behind), so it runs in the application AFTER the database deletion committed: if the database step fails, nothing was touched here.
// Pure with respect to Supabase — it talks to a tiny `StorageLike` interface so the walk can be tested with a fake bucket.

export interface StorageLike {
  list(prefix: string, opts: { limit: number; offset: number }): Promise<{ data: { name: string; id: string | null }[] | null; error: { message: string } | null }>;
  remove(paths: string[]): Promise<{ error: { message: string } | null }>;
}

export type CleanupReport = { found: number; removed: number; failed: number; errors: string[] };

/** Every file path under `<orgId>/` (folders have id === null and are walked). Bounded so a bad bucket cannot loop forever. */
export async function listCompanyFiles(storage: StorageLike, orgId: string, maxFiles = 20000): Promise<{ paths: string[]; error: string | null }> {
  const paths: string[] = [];
  const stack: string[] = [orgId];
  while (stack.length > 0 && paths.length < maxFiles) {
    const dir = stack.pop() as string;
    for (let offset = 0; ; offset += 1000) {
      const { data, error } = await storage.list(dir, { limit: 1000, offset });
      if (error) return { paths, error: error.message };
      for (const e of data ?? []) {
        if (e.id === null) stack.push(`${dir}/${e.name}`);
        else paths.push(`${dir}/${e.name}`);
      }
      if (!data || data.length < 1000) break;
    }
  }
  return { paths, error: null };
}

export async function removeCompanyFiles(storage: StorageLike, orgId: string, knownPaths: string[] = []): Promise<CleanupReport> {
  const listed = await listCompanyFiles(storage, orgId);
  // only ever delete inside this company's own folder, whatever the archive or the listing says
  const all = [...new Set([...listed.paths, ...knownPaths])].filter((p) => p.startsWith(`${orgId}/`) && !p.includes(".."));
  const report: CleanupReport = { found: all.length, removed: 0, failed: 0, errors: listed.error ? [`list: ${listed.error}`] : [] };
  for (let i = 0; i < all.length; i += 100) {
    const batch = all.slice(i, i + 100);
    const { error } = await storage.remove(batch);
    if (error) { report.failed += batch.length; report.errors.push(error.message); } else report.removed += batch.length;
  }
  return report;
}

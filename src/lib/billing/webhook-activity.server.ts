import "server-only";
import type { SupabaseClient } from "@supabase/supabase-js";
import type { WebhookRow } from "./webhook-activity";

/** The latest webhook deliveries (for the list) and the last seven days (for the counters). Service role only: the table has no browser access. null = could not read. */
export async function loadWebhookActivity(admin: SupabaseClient): Promise<{ recent: WebhookRow[]; week: WebhookRow[]; nowMs: number } | null> {
  try {
    const nowMs = Date.now();   // read here, not while rendering, so the panel is a pure function of its props
    const since = new Date(nowMs - 7 * 86_400_000).toISOString();
    const [recent, week] = await Promise.all([
      admin.from("billing_webhook_events").select("event_type, outcome, received_at, processed_at, attempts").order("received_at", { ascending: false }).limit(8),
      admin.from("billing_webhook_events").select("event_type, outcome, received_at, processed_at, attempts").gte("received_at", since).order("received_at", { ascending: false }).limit(1000),
    ]);
    if (recent.error || week.error) return null;
    return { recent: (recent.data ?? []) as WebhookRow[], week: (week.data ?? []) as WebhookRow[], nowMs };
  } catch {
    return null;
  }
}

import { NextResponse } from "next/server";
import { createAdminClient } from "@/lib/supabase/admin";

// GET /api/health — for uptime monitors (UptimeRobot, Better Stack, Vercel checks…).
// Public on purpose and therefore boring: it says whether the app is up and whether the database answers. It never reveals
// configuration, versions, keys or any company data. 200 = healthy, 503 = the database could not be reached.
export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function GET() {
  const started = Date.now();
  let db: "ok" | "down" | "unconfigured" = "unconfigured";
  try {
    const admin = createAdminClient();
    // a one-row read of a tiny table: proves DNS, TLS, the key and PostgREST in one go
    const { error } = await Promise.race([
      admin.from("roles").select("id", { head: true, count: "exact" }).limit(1),
      new Promise<{ error: { message: string } }>((resolve) => setTimeout(() => resolve({ error: { message: "timeout" } }), 4000)),
    ]);
    db = error ? "down" : "ok";
  } catch {
    db = "unconfigured";
  }
  const healthy = db === "ok";
  return NextResponse.json(
    { status: healthy ? "ok" : "degraded", db, latencyMs: Date.now() - started, time: new Date().toISOString() },
    { status: healthy ? 200 : 503, headers: { "Cache-Control": "no-store" } },
  );
}

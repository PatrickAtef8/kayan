import { NextResponse, type NextRequest } from "next/server";
import { timingSafeEqual } from "node:crypto";
import { createAdminClient } from "@/lib/supabase/admin";
import { getSiteUrl } from "@/lib/site-url";
import { sendEmail, isEmailConfigured } from "@/lib/email/service.server";
import { ownerEmails, packageLabel } from "@/lib/billing/notify.server";
import { planReminder } from "@/lib/billing/reminders";

// Daily job (vercel.json → crons): emails each company's owner(s) before the subscription ends (7, 3, 1 days, the day itself) and once after.
// Renewal stays MANUAL — the email only links to the billing page; nothing is charged. Authenticated with CRON_SECRET (Vercel sends it as
// `Authorization: Bearer <CRON_SECRET>`); without that variable the route refuses every request instead of being open to the internet.
export const runtime = "nodejs";
export const dynamic = "force-dynamic";
export const maxDuration = 60;

function authorized(request: NextRequest): boolean {
  const secret = process.env.CRON_SECRET?.trim();
  if (!secret) return false;
  const given = request.headers.get("authorization") ?? "";
  const expected = `Bearer ${secret}`;
  const a = Buffer.from(given);
  const b = Buffer.from(expected);
  return a.length === b.length && timingSafeEqual(a, b);
}

export async function GET(request: NextRequest) {
  if (!process.env.CRON_SECRET?.trim()) return NextResponse.json({ error: "CRON_SECRET is not configured" }, { status: 500 });
  if (!authorized(request)) return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  if (!isEmailConfigured()) return NextResponse.json({ error: "email service not configured (RESEND_API_KEY / RESEND_FROM_EMAIL)" }, { status: 500 });

  let origin: string;
  try { origin = getSiteUrl(); } catch (e) { return NextResponse.json({ error: e instanceof Error ? e.message : "site url" }, { status: 500 }); }

  const admin = createAdminClient();
  const now = new Date();
  // only licences whose end date is within ±8 days can need a mail; complimentary (free) licences and licences without an end date never do
  const from = new Date(now.getTime() - 9 * 86_400_000).toISOString();
  const to = new Date(now.getTime() + 9 * 86_400_000).toISOString();
  const { data, error } = await admin
    .from("organization_licenses")
    .select("organization_id, package_key, access_paid_through, complimentary, organizations(name)")
    .eq("complimentary", false)
    .not("access_paid_through", "is", null)
    .gte("access_paid_through", from)
    .lte("access_paid_through", to)
    .limit(1000);
  if (error) {
    console.error("subscription reminders: query failed", error.message);
    return NextResponse.json({ error: "query failed" }, { status: 500 });
  }

  const stats = { checked: 0, due: 0, sent: 0, duplicate: 0, failed: 0, no_owner: 0 };
  for (const row of (data ?? []) as unknown as { organization_id: string; package_key: string; access_paid_through: string; organizations: { name: string } | { name: string }[] | null }[]) {
    stats.checked++;
    const plan = planReminder(row.organization_id, row.access_paid_through, now);
    if (!plan) continue;
    stats.due++;
    const orgName = (Array.isArray(row.organizations) ? row.organizations[0]?.name : row.organizations?.name) ?? "—";
    const owners = await ownerEmails(row.organization_id);
    if (owners.length === 0) { stats.no_owner++; continue; }
    for (const to of owners) {
      const r = await sendEmail({
        template: "subscription_reminder",
        to,
        organizationId: row.organization_id,
        dedupeKey: plan.dedupeKey,
        data: { orgName, daysLeft: plan.daysLeft, endsOn: plan.endsOn, packageName: packageLabel(row.package_key), renewUrl: `${origin}/dashboard/billing` },
      });
      if (!r.ok) stats.failed++;
      else if (r.skipped) stats.duplicate++;
      else stats.sent++;
    }
  }
  return NextResponse.json({ ok: true, ...stats });
}

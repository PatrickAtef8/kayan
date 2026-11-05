import "server-only";
import { createAdminClient } from "@/lib/supabase/admin";
import { getSiteUrl } from "@/lib/site-url";
import { sendEmail } from "@/lib/email/service.server";
import { PRICING_CONFIG } from "@/config/pricing.config";

/** The owner emails of a company (the people who pay and renew). Read with the service role; never exposed to the browser. */
export async function ownerEmails(orgId: string): Promise<string[]> {
  const admin = createAdminClient();
  const { data: members } = await admin
    .from("organization_users")
    .select("user_id, roles!inner(key)")
    .eq("organization_id", orgId)
    .eq("status", "active")
    .eq("roles.key", "owner");
  const emails: string[] = [];
  for (const m of (members ?? []) as { user_id: string }[]) {
    const { data } = await admin.auth.admin.getUserById(m.user_id);
    const e = data?.user?.email;
    if (e) emails.push(e);
  }
  return [...new Set(emails.map((e) => e.toLowerCase()))];
}

export function packageLabel(key: string): string {
  const pk = (PRICING_CONFIG.packages as readonly { key: string; name: string }[]).find((p) => p.key === key);
  return pk?.name ?? key;
}

/**
 * Tells the company's owner(s) that a payment was confirmed (or is parked for review). Called once the payment is recorded, from the
 * webhook and from the return page; the email log's unique key makes the second caller a no-op, so the owner gets exactly one email per order.
 * Never throws: a mail problem must not turn a recorded payment into an error.
 */
export async function notifyPaymentRecorded(orderId: string, result: "applied" | "amount_mismatch"): Promise<void> {
  try {
    const admin = createAdminClient();
    const { data: o } = await admin
      .from("billing_orders")
      .select("id, organization_id, status, package_key, amount_total, paid_at, period_end, needs_review, organizations(name)")
      .eq("id", orderId)
      .maybeSingle();
    if (!o) return;
    const order = o as unknown as { id: string; organization_id: string; status: string; package_key: string; amount_total: number; paid_at: string | null; period_end: string | null; needs_review: boolean; organizations: { name: string } | { name: string }[] | null };
    const orgName = (Array.isArray(order.organizations) ? order.organizations[0]?.name : order.organizations?.name) ?? "—";
    const base = getSiteUrl();
    const billingUrl = `${base}/dashboard/billing`;
    const reference = order.id.slice(0, 8).toUpperCase();
    const amountLabel = `${(order.amount_total / 100).toLocaleString("en-US", { maximumFractionDigits: 2 })} ج.م`;
    const day = (iso: string | null) => (iso ? new Date(iso).toLocaleDateString("en-CA", { timeZone: "Africa/Cairo" }) : null);

    for (const to of await ownerEmails(order.organization_id)) {
      if (order.status === "paid" && result === "applied") {
        await sendEmail({ template: "payment_receipt", to, organizationId: order.organization_id, dedupeKey: `payment:${order.id}`, data: { orgName, packageName: packageLabel(order.package_key), amountLabel, paidOn: day(order.paid_at) ?? day(new Date().toISOString())!, reference, periodEnd: day(order.period_end), billingUrl } });
        if (order.needs_review) await sendEmail({ template: "payment_needs_review", to, organizationId: order.organization_id, dedupeKey: `payment-review:${order.id}`, data: { orgName, amountLabel, reference, billingUrl } });
      } else if (order.needs_review) {
        await sendEmail({ template: "payment_needs_review", to, organizationId: order.organization_id, dedupeKey: `payment-review:${order.id}`, data: { orgName, amountLabel, reference, billingUrl } });
      }
    }
  } catch (e) {
    console.error("payment notification failed", e instanceof Error ? e.message : "unknown");
  }
}

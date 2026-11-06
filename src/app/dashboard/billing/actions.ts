"use server";

import { headers } from "next/headers";
import { createClient } from "@/lib/supabase/server";
import { loadAcceptableVersions } from "@/lib/legal/legal.server";
import { ACCEPTANCE_MESSAGE, checkAcceptance, type AcceptanceInput } from "@/lib/legal/acceptance";
import { startCheckout, type Acceptance } from "@/lib/billing/checkout.server";
import { isPlanKey } from "@/lib/billing/pricing";
import { AUTH_ERROR } from "@/lib/action-result";
import { isSuperAdminSession } from "@/lib/admin/auth.server";
import { startTrialForOwner } from "@/lib/billing/trial.server";
import { revalidatePath } from "next/cache";

// Server-side authorization for every billing action: the caller must be signed in AND be an active OWNER of their
// organization (checked again inside billing_begin_order). The browser only says WHICH plan it wants ("monthly" or "one_time")
// — never an amount, never an organization id.
export type CheckoutActionResult = { error: string | null; url?: string };

async function ownerContext() {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return { ok: false, error: AUTH_ERROR } as const;
  // a platform administrator's account is never charged for anything (demos / testing before production)
  if (await isSuperAdminSession(user)) return { ok: false, error: "حسابات إدارة المنصة لا تخضع لأي دفع." } as const;
  const { data: membership } = await supabase
    .from("organization_users").select("organization_id").eq("user_id", user.id).eq("status", "active")
    .order("created_at", { ascending: true }).limit(1).maybeSingle();
  if (!membership) return { ok: false, error: "غير مصرح" } as const;
  const { data: role } = await supabase.rpc("my_role_key", { target_org: membership.organization_id });
  if (role !== "owner") return { ok: false, error: "هذه العملية متاحة لمالك الحساب فقط." } as const;
  return { ok: true, supabase, userId: user.id, organizationId: membership.organization_id as string } as const;
}

// Every payment start needs the owner's acceptance of the CURRENT legal documents. The browser says which versions it displayed; the
// server compares them with the database and records what the SERVER read (never what the browser sent), plus the time (database clock),
// the network address and the browser type.
async function acceptanceFor(accept: AcceptanceInput): Promise<{ acceptance: Acceptance } | { error: string }> {
  const check = checkAcceptance(accept, await loadAcceptableVersions());
  if (!check.ok) return { error: ACCEPTANCE_MESSAGE[check.reason] };
  const h = await headers();
  const ip = h.get("x-forwarded-for")?.split(",")[0]?.trim() || h.get("x-real-ip") || null;
  return { acceptance: { versions: check.versions, locale: "ar", ip, userAgent: h.get("user-agent") } };
}

/** Buy a plan for the first time. */
export async function startPurchase(input: { plan: string; accept: AcceptanceInput }): Promise<CheckoutActionResult> {
  const ctx = await ownerContext();
  if (!ctx.ok) return { error: ctx.error };
  if (!isPlanKey(input?.plan)) return { error: "طلب غير صالح." };
  const a = await acceptanceFor(input.accept);
  if ("error" in a) return { error: a.error };
  const r = await startCheckout({ userId: ctx.userId, organizationId: ctx.organizationId, plan: input.plan, purpose: "initial", acceptance: a.acceptance });
  return r.ok ? { error: null, url: r.url } : { error: r.error };
}

/** Pay the next month of hosting & maintenance (option A) or of the subscription (option B). */
export async function startRenewal(input: { accept: AcceptanceInput }): Promise<CheckoutActionResult> {
  const ctx = await ownerContext();
  if (!ctx.ok) return { error: ctx.error };
  const a = await acceptanceFor(input?.accept);
  if ("error" in a) return { error: a.error };
  // what is renewed is read from the organization's own license, not taken from the browser
  const { data: license } = await ctx.supabase.from("organization_licenses").select("payment_option").eq("organization_id", ctx.organizationId).maybeSingle();
  if (!license) return { error: "لا توجد باقة مفعّلة لتجديدها." };
  const r = await startCheckout({ userId: ctx.userId, organizationId: ctx.organizationId, plan: license.payment_option, purpose: "renewal", acceptance: a.acceptance });
  return r.ok ? { error: null, url: r.url } : { error: r.error };
}

/**
 * Start the free trial of the caller's company. Nothing comes from the browser: the company is the caller's own, and the database
 * (billing_start_trial) re-checks that they are its owner, that trials are on, that the company has no license / earlier trial and
 * that this account has not already used its one trial. The length is the Super Admin's current setting.
 */
export async function startFreeTrial(): Promise<{ error: string | null }> {
  const ctx = await ownerContext();
  if (!ctx.ok) return { error: ctx.error };
  const r = await startTrialForOwner({ userId: ctx.userId, organizationId: ctx.organizationId });
  if (!r.ok) return { error: r.error };
  revalidatePath("/dashboard", "layout");
  return { error: null };
}

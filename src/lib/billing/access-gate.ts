// The payment gate: may THIS person open THIS company's dashboard? Pure (no I/O) so the layout, the billing page and the tests
// share one answer. The subscription state itself comes from the DATABASE (my_org_access → billing_access_state, database clock,
// platform grace settings); the database enforces the same rule on every table and RPC (migration 0063), so this is the friendly
// front door, not the only lock.
//
//   open   → a platform administrator (always, with no database call) · state trial / free / license_only / active / grace
//   closed → state none (never paid, no trial), trial_expired (the free trial is over) or expired (paid period + grace are over)
//
// A company owned by an administrator is NOT exempt as a whole: its members follow the company's real subscription. The platform
// gives the administrator's own demo company free access (a complimentary license, see ensureAdminDemoLicense), so the demo team
// works, and revoking that access locks them like anyone else.
import { isOpenState, parseDbAccess, type DbAccess } from "./license-status.ts";

export type GateLicense = { complimentary?: boolean | null; access_paid_through: string | null; payment_option?: string | null; package_key?: string | null } | null;
export type GateOwner = { id: string; email?: string | null; confirmed?: boolean | null };
/** Whether this company may start a free trial right now (computed by the database for the caller). */
export type TrialOffer = { enabled: boolean; days: number; eligible: boolean };
export type GateAccess = { orgName: string | null; license: GateLicense; owners: GateOwner[]; access: DbAccess | null; trialOffer: TrialOffer };

export type GateDecision =
  | { open: true; reason: "platform_admin" | "free" | "paid" | "grace" | "trial" }
  | { open: false; reason: "never_paid" | "expired" | "trial_expired" };

export function decideAccess(input: { isPlatformAdmin: boolean; access: DbAccess | null }): GateDecision {
  if (input.isPlatformAdmin) return { open: true, reason: "platform_admin" };
  const s = input.access?.state ?? "none";
  if (s === "grace") return { open: true, reason: "grace" };
  if (s === "trial") return { open: true, reason: "trial" };
  if (s === "free") return { open: true, reason: "free" };
  if (isOpenState(s)) return { open: true, reason: "paid" };
  return { open: false, reason: s === "expired" ? "expired" : s === "trial_expired" ? "trial_expired" : "never_paid" };
}

/** Is the path one an UNPAID owner must still reach (to choose a package, pay, and come back from XPay)? */
export function isBillingPath(pathname: string | null | undefined): boolean {
  if (!pathname) return false;
  return pathname === "/dashboard/billing" || pathname.startsWith("/dashboard/billing/");
}

/** Reads what my_org_access() returned, defensively: anything unexpected is treated as "no information". */
export function parseAccess(raw: unknown): GateAccess | null {
  if (!raw || typeof raw !== "object") return null;
  const r = raw as { org_name?: unknown; license?: unknown; owners?: unknown; access?: unknown; trial_offer?: unknown };
  const offer = r.trial_offer && typeof r.trial_offer === "object" ? (r.trial_offer as Record<string, unknown>) : {};
  const lic = r.license && typeof r.license === "object" ? (r.license as Record<string, unknown>) : null;
  const owners = Array.isArray(r.owners) ? r.owners : [];
  return {
    orgName: typeof r.org_name === "string" ? r.org_name : null,
    license: lic ? {
      complimentary: lic.complimentary === true,
      access_paid_through: typeof lic.access_paid_through === "string" ? lic.access_paid_through : null,
      payment_option: typeof lic.payment_option === "string" ? lic.payment_option : null,
      package_key: typeof lic.package_key === "string" ? lic.package_key : null,
    } : null,
    owners: owners.filter((o): o is GateOwner => !!o && typeof (o as GateOwner).id === "string").map((o) => ({ id: o.id, email: typeof o.email === "string" ? o.email : null, confirmed: o.confirmed === true })),
    access: parseDbAccess(r.access),
    // anything unexpected means "no offer": a trial is never offered by mistake
    trialOffer: {
      enabled: offer.enabled === true,
      days: typeof offer.days === "number" && Number.isFinite(offer.days) ? offer.days : 15,
      eligible: offer.eligible === true,
    },
  };
}

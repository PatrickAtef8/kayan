// A plan chosen on /pricing by someone who is not signed in yet, carried through sign-up (or login) to /checkout.
//
// Nothing here is trusted: the plan that arrives in a URL, a form or the account's own metadata is only a REQUEST. It is re-validated
// against the live configuration wherever it is used (this file), and /checkout rebuilds the quote — the price, the lines, the months —
// from the server's configuration again before anything is charged. A price is never part of a selection.
// There are two plans: "monthly" and "one_time". Links and account metadata written when there were three packages carried
// `package=…&option=…`; the option was always one of those two words, so it is still understood as the plan.
import { getPackage, isPlanKey, type PricingConfig } from "./pricing.ts";
import type { PackageKey } from "../../config/pricing.config.ts";

export type PlanSelection = { plan: PackageKey };

/** Accepts only a plan that exists in the configuration; anything else is "no selection". */
export function parseSelection(
  raw: { plan?: unknown; option?: unknown; package?: unknown } | null | undefined,
  cfg: Pick<PricingConfig, "packages">,
): PlanSelection | null {
  if (!raw) return null;
  const candidate = raw.plan !== undefined ? raw.plan : raw.option;   // `option` = the old two-field link
  if (typeof candidate !== "string" || candidate.length > 20 || !isPlanKey(candidate)) return null;
  const pkg = getPackage(candidate, cfg as PricingConfig);
  return pkg ? { plan: pkg.key } : null;
}

/** The selection stored in the account's metadata at sign-up (user-editable data: validated like any other input). */
export function selectionFromMetadata(meta: unknown, cfg: Pick<PricingConfig, "packages">): PlanSelection | null {
  const s = meta && typeof meta === "object" ? (meta as { plan_selection?: unknown }).plan_selection : null;
  if (!s || typeof s !== "object") return null;
  const o = s as { plan?: unknown; option?: unknown };
  return parseSelection({ plan: o.plan, option: o.option }, cfg);
}

const q = (s: PlanSelection) => `plan=${encodeURIComponent(s.plan)}`;
export const checkoutPath = (s: PlanSelection) => `/checkout?${q(s)}`;
export const signupPath = (s: PlanSelection | null) => (s ? `/signup?${q(s)}` : "/signup");
export const loginPath = (s: PlanSelection | null) => (s ? `/login?${q(s)}` : "/login");

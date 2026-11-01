// A package chosen on /pricing by someone who is not signed in yet, carried through sign-up (or login) to /checkout.
//
// Nothing here is trusted: the key and option that arrive in a URL, a form or the account's own metadata are only a REQUEST. They are
// re-validated against the live package configuration wherever they are used (this file), and /checkout rebuilds the quote — the price,
// the lines, the months — from the server's configuration again before anything is charged. A price is never part of a selection.
import { getPackage, isPaymentOption, type PricingConfig } from "./pricing.ts";
import type { PaymentOption } from "../../config/pricing.config.ts";

export type PlanSelection = { packageKey: string; option: PaymentOption };

/** Accepts only a package that exists in the configuration and one of the two payment options; anything else is "no selection". */
export function parseSelection(
  raw: { package?: unknown; option?: unknown } | null | undefined,
  cfg: Pick<PricingConfig, "packages">,
): PlanSelection | null {
  if (!raw || typeof raw.package !== "string" || typeof raw.option !== "string") return null;
  if (raw.package.length > 40 || !/^[a-z0-9_-]+$/i.test(raw.package)) return null;
  const pkg = getPackage(raw.package, cfg as PricingConfig);
  if (!pkg || !isPaymentOption(raw.option)) return null;
  return { packageKey: pkg.key, option: raw.option };
}

/** The selection stored in the account's metadata at sign-up (user-editable data: validated like any other input). */
export function selectionFromMetadata(meta: unknown, cfg: Pick<PricingConfig, "packages">): PlanSelection | null {
  const s = meta && typeof meta === "object" ? (meta as { plan_selection?: unknown }).plan_selection : null;
  if (!s || typeof s !== "object") return null;
  const o = s as { packageKey?: unknown; package?: unknown; option?: unknown };
  return parseSelection({ package: o.packageKey ?? o.package, option: o.option }, cfg);
}

const q = (s: PlanSelection) => `package=${encodeURIComponent(s.packageKey)}&option=${s.option}`;
export const checkoutPath = (s: PlanSelection) => `/checkout?${q(s)}`;
export const signupPath = (s: PlanSelection | null) => (s ? `/signup?${q(s)}` : "/signup");
export const loginPath = (s: PlanSelection | null) => (s ? `/login?${q(s)}` : "/login");

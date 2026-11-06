// Pure pricing logic (no I/O, no server-only imports) so it can be unit-tested and used by both the server (which
// decides what is charged) and the screens (which show it). The server NEVER trusts an amount from the browser: it
// calls buildQuote() itself from the plan the browser asked for.
//
// There are exactly TWO plans and a plan is a way of paying: "monthly" (one all-inclusive monthly price) and "one_time" (a perpetual
// license paid once + hosting & maintenance paid separately each month). A plan key and its payment option are the same word.
import {
  PRICING_CONFIG,
  MODULE_FEATURES,
  PLAN_KEYS,
  type PackageConfig,
  type PackageKey,
  type PaymentOption,
  type PackageModuleKey,
} from "../../config/pricing.config.ts";

export type PricingConfig = Omit<typeof PRICING_CONFIG, "packages"> & { packages: PackageConfig[] };
export type Purpose = "initial" | "renewal";

export type Entitlements = { modules: string[]; max_members: number | null; max_warehouses: number | null };

export type QuoteLine = { id: "license" | "hosting" | "subscription"; label: string; amount: number };

export type Quote = {
  /** the plan bought; `packageKey` and `option` carry the same value (kept so the database call and receipts read as before) */
  plan: PackageKey;
  packageKey: PackageKey;
  packageName: string;
  option: PaymentOption;
  purpose: Purpose;
  currency: string;
  /** what is charged by this checkout, in piasters */
  lines: QuoteLine[];
  dueToday: number;
  /** what will be due again, and whether the card is charged for it automatically (it is not — see config) */
  recurring: { amount: number; periodMonths: 1; autoCharged: boolean; label: string } | null;
  /** months of hosting / subscription access this payment buys */
  grantsMonths: number;
  /** the perpetual license's hosting & maintenance costs nothing (price 0): there is nothing to pay after the license, and nothing to renew */
  hostingFree: boolean;
  entitlements: Entitlements;
};

export const PACKAGE_KEY_PATTERN = /^[a-z][a-z0-9_]{1,31}$/;

export function toPiasters(egp: number): number {
  return Math.round(egp * 100);
}
export function fromPiasters(piasters: number): number {
  return piasters / 100;
}

export function getPackages(config: PricingConfig = PRICING_CONFIG as PricingConfig): PackageConfig[] {
  return config.packages;
}

export function getPackage(key: string, config: PricingConfig = PRICING_CONFIG as PricingConfig): PackageConfig | null {
  return config.packages.find((p) => p.key === key) ?? null;
}

/** "monthly" | "one_time" — the only two plans there are. */
export function isPlanKey(v: unknown): v is PackageKey {
  return typeof v === "string" && (PLAN_KEYS as readonly string[]).includes(v);
}
export function isPaymentOption(v: unknown): v is PaymentOption {
  return isPlanKey(v);
}

export function entitlementsOf(pkg: PackageConfig): Entitlements {
  return { modules: [...pkg.modules], max_members: pkg.limits.maxMembers, max_warehouses: pkg.limits.maxWarehouses };
}

/** Hosting & maintenance costs nothing when the perpetual-license plan's monthly hosting price is 0 (the Super Admin sets it). */
export function isHostingFree(config: PricingConfig = PRICING_CONFIG as PricingConfig): boolean {
  const p = getPackage("one_time", config);
  return !!p && p.key === "one_time" && toPiasters(p.pricing.hostingMonthlyEgp) === 0;
}

/** Throws on an unknown plan: callers turn it into a plain "invalid request". Only the plan comes from the browser; everything else is the server's.
 *  Also throws for a RENEWAL of the perpetual license while its hosting is free: there is nothing to charge. */
export function buildQuote(
  input: { plan: string; purpose: Purpose },
  config: PricingConfig = PRICING_CONFIG as PricingConfig,
): Quote {
  const pkg = getPackage(input.plan, config);
  if (!pkg) throw new Error("unknown plan");
  const auto = !!config.terms.automaticRenewal;
  const lines: QuoteLine[] = [];
  let recurring: Quote["recurring"] = null;
  let grantsMonths = 0;
  let hostingFree = false;

  if (pkg.key === "one_time") {
    const { licenseEgp, hostingMonthlyEgp } = pkg.pricing;
    const hosting = toPiasters(hostingMonthlyEgp);
    hostingFree = hosting === 0;
    if (hostingFree && input.purpose === "renewal") throw new Error("hosting is free: nothing to renew");
    // free hosting: the license is the only charge, there is no hosting line, no paid month and no monthly payment afterwards
    const withHosting = !hostingFree && (input.purpose === "renewal" || config.terms.includeFirstHostingWithLicense);
    if (input.purpose === "initial") lines.push({ id: "license", label: `${pkg.name}`, amount: toPiasters(licenseEgp) });
    if (withHosting) {
      lines.push({ id: "hosting", label: "استضافة وصيانة — شهر", amount: hosting });
      grantsMonths = 1;
    }
    recurring = hostingFree ? null : { amount: hosting, periodMonths: 1, autoCharged: auto, label: "استضافة وصيانة" };
  } else {
    const price = toPiasters(pkg.pricing.subscriptionMonthlyEgp);
    lines.push({ id: "subscription", label: `${pkg.name} — شهر`, amount: price });
    grantsMonths = 1;
    recurring = { amount: price, periodMonths: 1, autoCharged: auto, label: "اشتراك شهري" };
  }

  return {
    plan: pkg.key,
    packageKey: pkg.key,
    packageName: pkg.name,
    option: pkg.key,
    purpose: input.purpose,
    currency: config.currency,
    lines,
    dueToday: lines.reduce((s, l) => s + l.amount, 0),
    recurring,
    grantsMonths,
    hostingFree,
    entitlements: entitlementsOf(pkg),
  };
}

/** Everything wrong with a pricing config, as readable sentences (empty = fine). Run by the unit tests and at checkout. */
export function validatePricingConfig(config: PricingConfig = PRICING_CONFIG as PricingConfig): string[] {
  const errors: string[] = [];
  const seen = new Set<string>();
  const decimals = (n: number) => Math.abs(n * 100 - Math.round(n * 100)) < 1e-6;
  if (config.currency !== "EGP") errors.push("currency must be EGP");
  // exactly the two plans, each once
  for (const k of PLAN_KEYS) if (!config.packages.some((p) => p.key === k)) errors.push(`plan "${k}" is missing`);
  for (const p of config.packages) {
    if (!isPlanKey(p.key)) { errors.push(`plan key "${p.key}" is not allowed (only monthly and one_time exist)`); continue; }
    if (seen.has(p.key)) errors.push(`plan "${p.key}" is duplicated`);
    seen.add(p.key);
    if (!p.name.trim()) errors.push(`${p.key}: name is empty`);
    for (const m of p.modules) if (!(m in MODULE_FEATURES)) errors.push(`${p.key}: unknown module "${m}"`);
    if (new Set(p.modules).size !== p.modules.length) errors.push(`${p.key}: a module is listed twice`);
    for (const [k, v] of [["maxMembers", p.limits.maxMembers], ["maxWarehouses", p.limits.maxWarehouses]] as const) {
      if (v !== null && (!Number.isInteger(v) || v < 1)) errors.push(`${p.key}: ${k} must be a whole number ≥ 1 or null`);
    }
    // the license and the monthly subscription must cost something; hosting & maintenance may be 0 (= free: nothing to pay after the license)
    const prices: [string, number, boolean][] = p.key === "one_time"
      ? [["licenseEgp", p.pricing.licenseEgp, false], ["hostingMonthlyEgp", p.pricing.hostingMonthlyEgp, true]]
      : [["subscriptionMonthlyEgp", p.pricing.subscriptionMonthlyEgp, false]];
    for (const [k, v, allowZero] of prices) {
      if (!Number.isFinite(v) || v < 0 || (v === 0 && !allowZero)) errors.push(`${p.key}: ${k} must be ${allowZero ? "zero or more" : "greater than zero"}`);
      else if (!decimals(v)) errors.push(`${p.key}: ${k} has more than two decimals`);
    }
  }
  return errors;
}

/** Arabic sentences for a "does not fit" report returned by the database (billing_fit_report). */
export type FitViolation =
  | { kind: "modules"; keys: string[] }
  | { kind: "members"; current: number; max: number }
  | { kind: "warehouses"; current: number; max: number };

export function describeFitViolations(violations: FitViolation[]): string[] {
  return violations.map((v) => {
    if (v.kind === "modules") {
      const names = v.keys.map((k) => MODULE_FEATURES[k as PackageModuleKey]?.label ?? k).join("، ");
      return `لديك وحدات مفعّلة غير مشمولة في هذه الباقة: ${names}. عطّلها من الإعدادات أو اختر الخيار الآخر.`;
    }
    if (v.kind === "members") return `عدد أعضاء الفريق النشطين (${v.current}) أكبر من الحد الذي تتيحه الباقة (${v.max}).`;
    return `عدد المخازن النشطة (${v.current}) أكبر من الحد الذي تتيحه الباقة (${v.max}).`;
  });
}

// ---------------------------------------------------------------------------------------------------------------------
// Admin-managed overrides (migration 0061). The values in src/config/pricing.config.ts are the SHIPPED configuration and
// the fallback for everything: with no override stored, Kayan behaves exactly as shipped. An override replaces only the
// editable parts of a plan — its prices, modules, limits — never its name, tagline or the payment terms. A stored override
// that is malformed or would produce an invalid config is ignored as a whole (the defaults win) rather than breaking pricing.
// Overrides saved while there were three packages (keys basic / professional / complete) match no plan and are ignored.
// ---------------------------------------------------------------------------------------------------------------------
import { PACKAGE_MODULE_ORDER } from "../../config/pricing.config.ts";

/** What the admin edits for ONE plan. A price that does not belong to the plan is null (monthly has no license price; one_time has no subscription price). */
export type EditablePackage = {
  licenseEgp: number | null;
  hostingMonthlyEgp: number | null;
  subscriptionMonthlyEgp: number | null;
  maxMembers: number | null;
  maxWarehouses: number | null;
  modules: PackageModuleKey[];
};
export type PricingOverrides = { packages: Record<string, {
  pricing: { licenseEgp?: number; hostingMonthlyEgp?: number; subscriptionMonthlyEgp?: number };
  modules: PackageModuleKey[];
  limits: { maxMembers: number | null; maxWarehouses: number | null };
}> };

export function toEditable(p: PackageConfig): EditablePackage {
  return {
    licenseEgp: p.key === "one_time" ? p.pricing.licenseEgp : null,
    hostingMonthlyEgp: p.key === "one_time" ? p.pricing.hostingMonthlyEgp : null,
    subscriptionMonthlyEgp: p.key === "monthly" ? p.pricing.subscriptionMonthlyEgp : null,
    maxMembers: p.limits.maxMembers, maxWarehouses: p.limits.maxWarehouses, modules: [...p.modules],
  };
}

/** Arabic validation messages for what an admin typed (empty = fine). */
export function validateEditable(key: string, name: string, e: EditablePackage): string[] {
  const errs: string[] = [];
  // `allowZero`: the monthly hosting & maintenance may be 0 (= free: the customer pays the license only, nothing afterwards)
  const price = (label: string, v: number | null, allowZero = false) => {
    if (v === null || !Number.isFinite(v) || v < 0 || (v === 0 && !allowZero)) errs.push(allowZero ? `${name}: ${label} يجب أن يكون صفرًا (مجانًا) أو أكبر من صفر.` : `${name}: ${label} يجب أن يكون أكبر من صفر.`);
    else if (Math.abs(v * 100 - Math.round(v * 100)) > 1e-6) errs.push(`${name}: ${label} لا يقبل أكثر من خانتين عشريتين.`);
    else if (v > 10_000_000) errs.push(`${name}: ${label} كبير جدًا.`);
  };
  if (key === "one_time") {
    price("سعر الرخصة الدائمة", e.licenseEgp);
    price("الاستضافة والصيانة الشهرية", e.hostingMonthlyEgp, true);
  } else if (key === "monthly") {
    price("الاشتراك الشهري", e.subscriptionMonthlyEgp);
  } else {
    errs.push(`${name}: باقة غير معروفة.`);
  }
  for (const [label, v] of [["حد أعضاء الفريق", e.maxMembers], ["حد المخازن", e.maxWarehouses]] as const) {
    if (v !== null && (!Number.isInteger(v) || v < 1 || v > 100000)) errs.push(`${name}: ${label} يجب أن يكون رقمًا صحيحًا ≥ 1 أو «بلا حد».`);
  }
  if (!Array.isArray(e.modules) || e.modules.some((m) => !(PACKAGE_MODULE_ORDER as string[]).includes(m)) || new Set(e.modules).size !== e.modules.length) errs.push(`${name}: قائمة الوحدات غير صالحة.`);
  return errs;
}

export function overridesFromEditable(all: Record<string, EditablePackage>): PricingOverrides {
  const out: PricingOverrides = { packages: {} };
  for (const [key, e] of Object.entries(all)) {
    if (!isPlanKey(key)) continue;
    out.packages[key] = {
      pricing: key === "one_time"
        ? { licenseEgp: e.licenseEgp ?? undefined, hostingMonthlyEgp: e.hostingMonthlyEgp ?? undefined }
        : { subscriptionMonthlyEgp: e.subscriptionMonthlyEgp ?? undefined },
      modules: PACKAGE_MODULE_ORDER.filter((m) => e.modules.includes(m)),
      limits: { maxMembers: e.maxMembers, maxWarehouses: e.maxWarehouses },
    };
  }
  return out;
}

/** Defaults + a stored override. Never throws; an unusable override yields the defaults. */
export function resolvePricingConfig(
  raw: unknown,
  base: PricingConfig = PRICING_CONFIG as PricingConfig,
): { config: PricingConfig; custom: boolean } {
  const pk = (raw as { packages?: Record<string, unknown> } | null)?.packages;
  if (!pk || typeof pk !== "object") return { config: base, custom: false };
  try {
    const packages = base.packages.map((p): PackageConfig => {
      const o = pk[p.key] as Partial<PricingOverrides["packages"][string]> | undefined;
      if (!o || typeof o !== "object") return p;
      const num = (v: unknown, d: number) => (typeof v === "number" ? v : d);
      const lim = (v: unknown, d: number | null) => (v === null ? null : typeof v === "number" ? v : d);
      const shared = {
        modules: Array.isArray(o.modules) ? (o.modules.filter((m): m is PackageModuleKey => (PACKAGE_MODULE_ORDER as string[]).includes(m as string))) : p.modules,
        limits: { maxMembers: lim(o.limits?.maxMembers, p.limits.maxMembers), maxWarehouses: lim(o.limits?.maxWarehouses, p.limits.maxWarehouses) },
      };
      if (p.key === "one_time") {
        return { ...p, ...shared, pricing: { licenseEgp: num(o.pricing?.licenseEgp, p.pricing.licenseEgp), hostingMonthlyEgp: num(o.pricing?.hostingMonthlyEgp, p.pricing.hostingMonthlyEgp) } };
      }
      return { ...p, ...shared, pricing: { subscriptionMonthlyEgp: num(o.pricing?.subscriptionMonthlyEgp, p.pricing.subscriptionMonthlyEgp) } };
    });
    const merged: PricingConfig = { ...base, packages };
    if (validatePricingConfig(merged).length > 0) return { config: base, custom: false };
    return { config: merged, custom: JSON.stringify(merged.packages) !== JSON.stringify(base.packages) };
  } catch {
    return { config: base, custom: false };
  }
}

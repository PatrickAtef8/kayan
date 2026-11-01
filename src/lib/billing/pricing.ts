// Pure pricing logic (no I/O, no server-only imports) so it can be unit-tested and used by both the server (which
// decides what is charged) and the screens (which show it). The server NEVER trusts an amount from the browser: it
// calls buildQuote() itself from the package key + payment option the browser asked for.
import {
  PRICING_CONFIG,
  MODULE_FEATURES,
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

export function isPaymentOption(v: unknown): v is PaymentOption {
  return v === "one_time" || v === "monthly";
}

export function entitlementsOf(pkg: PackageConfig): Entitlements {
  return { modules: [...pkg.modules], max_members: pkg.limits.maxMembers, max_warehouses: pkg.limits.maxWarehouses };
}

/** Throws on an unknown package / option: callers turn it into a plain "invalid request". */
export function buildQuote(
  input: { packageKey: string; option: string; purpose: Purpose },
  config: PricingConfig = PRICING_CONFIG as PricingConfig,
): Quote {
  const pkg = getPackage(input.packageKey, config);
  if (!pkg) throw new Error("unknown package");
  if (!isPaymentOption(input.option)) throw new Error("unknown payment option");
  const option = input.option;
  const auto = !!config.terms.automaticRenewal;
  const lines: QuoteLine[] = [];
  let recurring: Quote["recurring"] = null;
  let grantsMonths = 0;

  if (option === "one_time") {
    const { licenseEgp, hostingMonthlyEgp } = pkg.pricing.oneTime;
    const hosting = toPiasters(hostingMonthlyEgp);
    const withHosting = input.purpose === "renewal" || config.terms.includeFirstHostingWithLicense;
    if (input.purpose === "initial") lines.push({ id: "license", label: `رخصة ${pkg.name} الدائمة`, amount: toPiasters(licenseEgp) });
    if (withHosting) {
      lines.push({ id: "hosting", label: "استضافة وصيانة — شهر", amount: hosting });
      grantsMonths = 1;
    }
    recurring = { amount: hosting, periodMonths: 1, autoCharged: auto, label: "استضافة وصيانة" };
  } else {
    const price = toPiasters(pkg.pricing.monthly.subscriptionMonthlyEgp);
    lines.push({ id: "subscription", label: `اشتراك ${pkg.name} — شهر`, amount: price });
    grantsMonths = 1;
    recurring = { amount: price, periodMonths: 1, autoCharged: auto, label: "اشتراك شهري" };
  }

  return {
    packageKey: pkg.key,
    packageName: pkg.name,
    option,
    purpose: input.purpose,
    currency: config.currency,
    lines,
    dueToday: lines.reduce((s, l) => s + l.amount, 0),
    recurring,
    grantsMonths,
    entitlements: entitlementsOf(pkg),
  };
}

/** Everything wrong with a pricing config, as readable sentences (empty = fine). Run by the unit tests and at checkout. */
export function validatePricingConfig(config: PricingConfig = PRICING_CONFIG as PricingConfig): string[] {
  const errors: string[] = [];
  const seen = new Set<string>();
  const decimals = (n: number) => Math.abs(n * 100 - Math.round(n * 100)) < 1e-6;
  if (config.currency !== "EGP") errors.push("currency must be EGP");
  if (config.packages.length === 0) errors.push("at least one package is required");
  for (const p of config.packages) {
    if (!PACKAGE_KEY_PATTERN.test(p.key)) errors.push(`package key "${p.key}" is not allowed`);
    if (seen.has(p.key)) errors.push(`package key "${p.key}" is duplicated`);
    seen.add(p.key);
    if (!p.name.trim()) errors.push(`${p.key}: name is empty`);
    for (const m of p.modules) if (!(m in MODULE_FEATURES)) errors.push(`${p.key}: unknown module "${m}"`);
    if (new Set(p.modules).size !== p.modules.length) errors.push(`${p.key}: a module is listed twice`);
    for (const [k, v] of [["maxMembers", p.limits.maxMembers], ["maxWarehouses", p.limits.maxWarehouses]] as const) {
      if (v !== null && (!Number.isInteger(v) || v < 1)) errors.push(`${p.key}: ${k} must be a whole number ≥ 1 or null`);
    }
    for (const [k, v] of [
      ["oneTime.licenseEgp", p.pricing.oneTime.licenseEgp],
      ["oneTime.hostingMonthlyEgp", p.pricing.oneTime.hostingMonthlyEgp],
      ["monthly.subscriptionMonthlyEgp", p.pricing.monthly.subscriptionMonthlyEgp],
    ] as const) {
      if (!Number.isFinite(v) || v <= 0) errors.push(`${p.key}: ${k} must be greater than zero`);
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
      return `لديك وحدات مفعّلة غير مشمولة في هذه الباقة: ${names}. عطّلها من الإعدادات أو اختر باقة أعلى.`;
    }
    if (v.kind === "members") return `عدد أعضاء الفريق النشطين (${v.current}) أكبر من الحد الذي تتيحه الباقة (${v.max}).`;
    return `عدد المخازن النشطة (${v.current}) أكبر من الحد الذي تتيحه الباقة (${v.max}).`;
  });
}

// ---------------------------------------------------------------------------------------------------------------------
// Admin-managed overrides (migration 0061). The values in src/config/pricing.config.ts are the SHIPPED configuration and
// the fallback for everything: with no override stored, Kayan behaves exactly as before. An override replaces only the
// three editable parts of a package — prices, modules, limits — never names, taglines or payment terms. A stored override
// that is malformed or would produce an invalid config is ignored as a whole (the defaults win) rather than breaking pricing.
// ---------------------------------------------------------------------------------------------------------------------
import { PACKAGE_MODULE_ORDER } from "../../config/pricing.config.ts";

export type EditablePackage = {
  licenseEgp: number;
  hostingMonthlyEgp: number;
  subscriptionMonthlyEgp: number;
  maxMembers: number | null;
  maxWarehouses: number | null;
  modules: PackageModuleKey[];
};
export type PricingOverrides = { packages: Record<string, {
  pricing: { oneTime: { licenseEgp: number; hostingMonthlyEgp: number }; monthly: { subscriptionMonthlyEgp: number } };
  modules: PackageModuleKey[];
  limits: { maxMembers: number | null; maxWarehouses: number | null };
}> };

export function toEditable(p: PackageConfig): EditablePackage {
  return {
    licenseEgp: p.pricing.oneTime.licenseEgp, hostingMonthlyEgp: p.pricing.oneTime.hostingMonthlyEgp,
    subscriptionMonthlyEgp: p.pricing.monthly.subscriptionMonthlyEgp,
    maxMembers: p.limits.maxMembers, maxWarehouses: p.limits.maxWarehouses, modules: [...p.modules],
  };
}

/** Arabic validation messages for what an admin typed (empty = fine). */
export function validateEditable(key: string, name: string, e: EditablePackage): string[] {
  const errs: string[] = [];
  const price = (label: string, v: number) => {
    if (!Number.isFinite(v) || v <= 0) errs.push(`${name}: ${label} يجب أن يكون أكبر من صفر.`);
    else if (Math.abs(v * 100 - Math.round(v * 100)) > 1e-6) errs.push(`${name}: ${label} لا يقبل أكثر من خانتين عشريتين.`);
    else if (v > 10_000_000) errs.push(`${name}: ${label} كبير جدًا.`);
  };
  price("سعر الرخصة الدائمة", e.licenseEgp);
  price("الاستضافة والصيانة الشهرية", e.hostingMonthlyEgp);
  price("الاشتراك الشهري", e.subscriptionMonthlyEgp);
  for (const [label, v] of [["حد أعضاء الفريق", e.maxMembers], ["حد المخازن", e.maxWarehouses]] as const) {
    if (v !== null && (!Number.isInteger(v) || v < 1 || v > 100000)) errs.push(`${name}: ${label} يجب أن يكون رقمًا صحيحًا ≥ 1 أو «بلا حد».`);
  }
  if (!Array.isArray(e.modules) || e.modules.some((m) => !(PACKAGE_MODULE_ORDER as string[]).includes(m)) || new Set(e.modules).size !== e.modules.length) errs.push(`${name}: قائمة الوحدات غير صالحة.`);
  void key;
  return errs;
}

export function overridesFromEditable(all: Record<string, EditablePackage>): PricingOverrides {
  const out: PricingOverrides = { packages: {} };
  for (const [key, e] of Object.entries(all)) {
    out.packages[key] = {
      pricing: { oneTime: { licenseEgp: e.licenseEgp, hostingMonthlyEgp: e.hostingMonthlyEgp }, monthly: { subscriptionMonthlyEgp: e.subscriptionMonthlyEgp } },
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
    const packages = base.packages.map((p) => {
      const o = pk[p.key] as Partial<PricingOverrides["packages"][string]> | undefined;
      if (!o || typeof o !== "object") return p;
      const num = (v: unknown, d: number) => (typeof v === "number" ? v : d);
      const lim = (v: unknown, d: number | null) => (v === null ? null : typeof v === "number" ? v : d);
      return {
        ...p,
        modules: Array.isArray(o.modules) ? (o.modules.filter((m): m is PackageModuleKey => (PACKAGE_MODULE_ORDER as string[]).includes(m as string))) : p.modules,
        limits: { maxMembers: lim(o.limits?.maxMembers, p.limits.maxMembers), maxWarehouses: lim(o.limits?.maxWarehouses, p.limits.maxWarehouses) },
        pricing: {
          oneTime: { licenseEgp: num(o.pricing?.oneTime?.licenseEgp, p.pricing.oneTime.licenseEgp), hostingMonthlyEgp: num(o.pricing?.oneTime?.hostingMonthlyEgp, p.pricing.oneTime.hostingMonthlyEgp) },
          monthly: { subscriptionMonthlyEgp: num(o.pricing?.monthly?.subscriptionMonthlyEgp, p.pricing.monthly.subscriptionMonthlyEgp) },
        },
      } satisfies PackageConfig;
    });
    const merged: PricingConfig = { ...base, packages };
    if (validatePricingConfig(merged).length > 0) return { config: base, custom: false };
    return { config: merged, custom: JSON.stringify(merged.packages) !== JSON.stringify(base.packages) };
  } catch {
    return { config: base, custom: false };
  }
}

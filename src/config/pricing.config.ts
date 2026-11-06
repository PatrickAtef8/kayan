// ---------------------------------------------------------------------------------------------------------------------
// Kayan pricing — the ONE place that decides what each plan contains, what it costs and how it is paid for.
// There are exactly TWO plans, and a plan IS a way of paying:
//      • "monthly"   — one all-inclusive price every month (access + hosting + basic maintenance);
//      • "one_time"  — a perpetual license paid once, plus hosting & maintenance paid separately every month.
// There are no tiers (no basic / professional / complete). Each plan has its own prices, limits and modules, and the Super Admin edits
// all of them under /admin/packages. Change the SHIPPED defaults here; the public /pricing page, the checkout in /dashboard/billing,
// the amounts sent to XPay and the limits written into a license all read from this file (with the admin's edits laid over it).
//
// !! THE NUMBERS BELOW ARE PLACEHOLDERS !!
//    Nobody has told the code what Kayan actually charges. They exist so the screens and the payment flow can be built
//    and tested end to end. In production, checkout stays CLOSED until BILLING_PRICES_CONFIRMED=true is set (see
//    docs/BILLING.md) — set it only after you have replaced these with your real prices.
//
// WHAT A PLAN IS MADE OF (and why it contains nothing else)
//    A plan is exactly the things Kayan can really enforce today:
//      • `modules`  — which optional modules the organization may switch on. Enforced by a database trigger
//                      (organization_modules), not only hidden in the menu.
//      • `limits`   — how many active team members and active warehouses. Enforced by database triggers.
//    Everything else a customer gets (products, warehouses, reports, Excel/PDF export, attachments, search, the audit log,
//    the three roles) is the same in both plans and is listed once under INCLUDED_IN_EVERY_PACKAGE.
//    The "Offers" module is intentionally absent: it is a placeholder page with no function yet.
//
// MONEY
//    Prices here are whole Egyptian pounds (EGP). They are converted to piasters (integers) in one place:
//    src/lib/billing/pricing.ts. Never put a number with more than two decimals here.
// ---------------------------------------------------------------------------------------------------------------------
import type { ModuleKey } from "../lib/modules.ts";

/** The two plans. A plan key is also its payment option: "monthly" is paid monthly, "one_time" is a perpetual license. */
export type PackageKey = "monthly" | "one_time";
export type PaymentOption = PackageKey;
export const PLAN_KEYS: readonly PackageKey[] = ["one_time", "monthly"];

/** Modules a plan can switch on. The three core modules (products, warehouses, reports) are in every plan. */
export type PackageModuleKey = Exclude<ModuleKey, "products" | "warehouses" | "reports" | "offers">;

type PlanBase = {
  name: string;
  tagline: string;
  modules: PackageModuleKey[];
  /** null = unlimited */
  limits: { maxMembers: number | null; maxWarehouses: number | null };
};
/** One monthly price that includes access, hosting and basic maintenance. */
export type MonthlyPlan = PlanBase & { key: "monthly"; pricing: { subscriptionMonthlyEgp: number } };
/** A perpetual license paid once + hosting & maintenance charged separately each month. */
export type OneTimePlan = PlanBase & { key: "one_time"; pricing: { licenseEgp: number; hostingMonthlyEgp: number } };
export type PackageConfig = MonthlyPlan | OneTimePlan;

const ALL_MODULES: PackageModuleKey[] = ["customers", "suppliers", "sales", "purchases", "inventory", "expenses", "treasury", "representatives", "partners"];

export const PRICING_CONFIG = {
  currency: "EGP" as const,

  // Order = order on the page: the perpetual license first, the monthly subscription second.
  packages: [
    {
      key: "one_time",
      name: "الرخصة الدائمة",
      tagline: "ادفع الرخصة مرة واحدة لتملك النظام، والاستضافة والصيانة تُدفعان شهريًا بشكل منفصل.",
      modules: [...ALL_MODULES],
      limits: { maxMembers: null, maxWarehouses: null },
      pricing: { licenseEgp: 24000, hostingMonthlyEgp: 750 },
    },
    {
      key: "monthly",
      name: "الاشتراك الشهري",
      tagline: "سعر شهري واحد يشمل الدخول للنظام والاستضافة والصيانة الأساسية.",
      modules: [...ALL_MODULES],
      limits: { maxMembers: null, maxWarehouses: null },
      pricing: { subscriptionMonthlyEgp: 1150 },
    },
  ] satisfies PackageConfig[],

  terms: {
    /**
     * Option A, first payment. true  → the license AND the first month of hosting & maintenance are charged together
     *                                   (the system is hosted for you from day one).
     *                       false → only the license is charged today; hosting is paid from the Billing page afterwards.
     */
    includeFirstHostingWithLicense: true,

    // The grace period is NOT configured here any more: the Super Admin sets it (on/off + hours, default 24) under /admin/packages,
    // and the database applies it with its own clock (see docs/BILLING.md, "Grace period").

    /**
     * XPay's Checkout API does not support subscription (recurring) billing yet — its own documentation lists
     * `mode: "subscription"` as "not yet supported on the checkout API". So nothing in Kayan charges a card
     * automatically: every month is a separate, customer-approved XPay payment from the Billing page.
     * Flip this to true ONLY after XPay ships recurring billing AND the integration has been extended to use it.
     * The interface reads it so that it never promises an automatic charge that does not exist.
     */
    automaticRenewal: false,
  },

  // The wording of what the money buys. These are commercial promises: review them before launch.
  /**
   * Optional support link shown on the checkout and failure pages (a "mailto:..." or a page). The Terms, Privacy and Refund pages are
   * managed by the Super Admin under /admin/legal, and the contact number under the same page.
   */
  legal: {
    supportUrl: "/contact" as string | null,
  },

  copy: {
    licenseNotes: [
      "رخصة دائمة لاستخدام كيان بالباقة المختارة — لا تنتهي بانتهاء الاستضافة.",
      "الاستضافة والصيانة تُدفعان بشكل منفصل شهريًا، ولا تُحصَّلان من بطاقتك تلقائيًا.",
    ],
    hostingIncludes: ["استضافة نسختك من كيان وإتاحة الدخول إليها", "تشغيل النظام والمحافظة على بقائه متاحًا"],
    maintenanceIncludes: ["إصلاح الأخطاء البرمجية في النظام", "تحديثات الأمان الضرورية"],
    maintenanceExcludes: ["تطوير ميزات أو تقارير مخصصة", "ترحيل بيانات من نظام آخر", "تدريب الفريق"],
  },
};

/** What both plans give, whatever their price. Each line below exists in the product today. */
export const INCLUDED_IN_EVERY_PACKAGE: string[] = [
  "الأصناف والمخازن الأساسية",
  "تقارير الأرباح والخسائر والديون والمركز المالي",
  "تصدير التقارير والفواتير بصيغة Excel وPDF",
  "ثلاثة أدوار بصلاحيات محددة: المالك والمندوب وأمين المخزن",
  "حدود خصم لكل دور وسجل عمليات كامل",
  "بحث شامل وإشعارات داخل النظام",
];

/** What each optional module means for the customer — the rows of the comparison table. */
export const MODULE_FEATURES: Record<PackageModuleKey, { label: string; detail: string }> = {
  customers: { label: "العملاء", detail: "حسابات العملاء وأرصدة الافتتاح وكشوف الحساب والتحصيل" },
  suppliers: { label: "الموردون", detail: "حسابات الموردين وكشف حساب لكل مورد" },
  sales: { label: "المبيعات", detail: "فواتير البيع والمرتجعات، خصومات بالنسبة وشرائح خصم وبونص يدوي" },
  purchases: { label: "المشتريات", detail: "فواتير الشراء والمرتجعات بمتوسط تكلفة مرجّح" },
  inventory: { label: "المخزون", detail: "رصيد لكل مخزن، تحويلات، جرد وتسوية، ودفعات بتواريخ صلاحية" },
  expenses: { label: "المصروفات", detail: "تسجيل المصروفات مع المرفقات" },
  treasury: { label: "الخزنة", detail: "حركة التحصيل والدفع والرصيد الفعلي" },
  representatives: { label: "المناديب والعمولات", detail: "أهداف شهرية وحد أدنى للعمولة وتحصيل من العملاء المسندين لكل مندوب" },
  partners: { label: "الشركاء", detail: "حسابات الشركاء وسحوباتهم بمعزل عن الأرباح" },
};

export const PACKAGE_MODULE_ORDER: PackageModuleKey[] = [
  "customers", "suppliers", "sales", "purchases", "inventory", "expenses", "treasury", "representatives", "partners",
];

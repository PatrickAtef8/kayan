// ---------------------------------------------------------------------------------------------------------------------
// Kayan pricing — the ONE place that decides what each package contains, what it costs and how it is paid for.
// Change a price, a limit, a module or a sentence of the terms here; the public /pricing page, the checkout in
// /dashboard/billing, the amounts sent to XPay and the limits written into a license all read from this file.
//
// !! THE NUMBERS BELOW ARE PLACEHOLDERS !!
//    Nobody has told the code what Kayan actually charges. They exist so the screens and the payment flow can be built
//    and tested end to end. In production, checkout stays CLOSED until BILLING_PRICES_CONFIRMED=true is set (see
//    docs/BILLING.md) — set it only after you have replaced these with your real prices.
//
// WHAT A PACKAGE IS MADE OF (and why it contains nothing else)
//    A package is exactly the things Kayan can really enforce today:
//      • `modules`  — which optional modules the organization may switch on. Enforced by a database trigger
//                      (organization_modules), not only hidden in the menu.
//      • `limits`   — how many active team members and active warehouses. Enforced by database triggers.
//    Everything else a customer gets (products, warehouses, reports, Excel/PDF export, attachments, search, the audit log,
//    the three roles) is the same in every package and is listed once under INCLUDED_IN_EVERY_PACKAGE.
//    The "Offers" module is intentionally absent: it is a placeholder page with no function yet.
//
// MONEY
//    Prices here are whole Egyptian pounds (EGP). They are converted to piasters (integers) in one place:
//    src/lib/billing/pricing.ts. Never put a number with more than two decimals here.
// ---------------------------------------------------------------------------------------------------------------------
import type { ModuleKey } from "../lib/modules.ts";

export type PackageKey = "basic" | "professional" | "complete";
export type PaymentOption = "one_time" | "monthly";

/** Modules a package can switch on. The three core modules (products, warehouses, reports) are in every package. */
export type PackageModuleKey = Exclude<ModuleKey, "products" | "warehouses" | "reports" | "offers">;

export type PackageConfig = {
  key: PackageKey;
  name: string;
  tagline: string;
  /** shown as the recommended card */
  highlighted?: boolean;
  badge?: string;
  modules: PackageModuleKey[];
  /** null = unlimited */
  limits: { maxMembers: number | null; maxWarehouses: number | null };
  pricing: {
    /** Option A: a perpetual license paid once + hosting & maintenance charged separately each month */
    oneTime: { licenseEgp: number; hostingMonthlyEgp: number };
    /** Option B: one monthly price that includes access, hosting and basic maintenance */
    monthly: { subscriptionMonthlyEgp: number };
  };
};

export const PRICING_CONFIG = {
  currency: "EGP" as const,

  packages: [
    {
      key: "basic",
      name: "الأساسية",
      tagline: "للأنشطة التي تبدأ: مبيعات ومشتريات ومخزون وخزنة في نظام واحد.",
      modules: ["customers", "suppliers", "sales", "purchases", "inventory", "expenses", "treasury"],
      limits: { maxMembers: 3, maxWarehouses: 2 },
      pricing: {
        oneTime: { licenseEgp: 12000, hostingMonthlyEgp: 450 },
        monthly: { subscriptionMonthlyEgp: 650 },
      },
    },
    {
      key: "professional",
      name: "الاحترافية",
      tagline: "لفريق مبيعات متنامٍ: تضيف المناديب والعمولات وفريقًا ومخازن أكثر.",
      highlighted: true,
      badge: "الأكثر اختيارًا",
      modules: ["customers", "suppliers", "sales", "purchases", "inventory", "expenses", "treasury", "representatives"],
      limits: { maxMembers: 10, maxWarehouses: 5 },
      pricing: {
        oneTime: { licenseEgp: 24000, hostingMonthlyEgp: 750 },
        monthly: { subscriptionMonthlyEgp: 1150 },
      },
    },
    {
      key: "complete",
      name: "الكاملة",
      tagline: "كل وحدات كيان بلا حدود للفريق أو المخازن، شاملةً الشركاء وسحوباتهم.",
      modules: ["customers", "suppliers", "sales", "purchases", "inventory", "expenses", "treasury", "representatives", "partners"],
      limits: { maxMembers: null, maxWarehouses: null },
      pricing: {
        oneTime: { licenseEgp: 42000, hostingMonthlyEgp: 1150 },
        monthly: { subscriptionMonthlyEgp: 1850 },
      },
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

/** What every package gives, whatever its price. Each line below exists in the product today. */
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

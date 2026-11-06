import { PRICING_CONFIG } from "@/config/pricing.config";

export const fmtDate = (iso: string | null | undefined) => (iso ? new Intl.DateTimeFormat("ar-EG", { dateStyle: "medium" }).format(new Date(iso)) : "—");
export const PKG_NAME: Record<string, string> = Object.fromEntries(PRICING_CONFIG.packages.map((p) => [p.key, p.name]));
export const OPTION_NAME: Record<string, string> = { one_time: "رخصة دائمة", monthly: "اشتراك شهري" };
export const ROLE_NAME: Record<string, string> = { owner: "مالك", sales: "مندوب", warehouse: "أمين مخزن" };

export type LicenseLike = { package_key: string | null; payment_option?: string | null; complimentary?: boolean | null; access_paid_through?: string | null };

/** One short line + a colour for "what does this company have and is it paid up?" (`accessState` is the DATABASE's judgement). */
export function paymentStatus(
  l: LicenseLike & { access_state?: string | null },
  lastOrderStatus?: string | null,
  opts: { ownerless?: boolean } = {},
): { text: string; tone: "ok" | "warn" | "bad" | "none" } {
  if (!l.package_key) {
    if (l.access_state === "trial") return { text: "تجربة مجانية", tone: "ok" };
    if (l.access_state === "trial_expired") return { text: "انتهت التجربة — مغلق", tone: "bad" };
    if (opts.ownerless) return { text: "بلا مالك", tone: "none" };
    // a company that has not paid cannot open its dashboard (the payment gate)
    return lastOrderStatus === "pending" ? { text: "دفع قيد الإتمام", tone: "warn" } : { text: "بانتظار الدفع", tone: "warn" };
  }
  if (l.complimentary) return { text: "مجاني", tone: "ok" };
  switch (l.access_state) {
    case "active": return { text: "مدفوع وساري", tone: "ok" };
    case "grace": return { text: "فترة سماح", tone: "warn" };
    case "expired": return { text: "منتهي — مغلق", tone: "bad" };
    case "license_only": return { text: "رخصة بلا استضافة", tone: "warn" };
    default: return { text: "مدفوع", tone: "ok" };
  }
}

/** The back-office activity log, in words. */
export const ADMIN_ACTION_LABEL: Record<string, string> = {
  "user.deactivate": "تعطيل مستخدم",
  "user.reactivate": "إعادة تفعيل مستخدم",
  "user.delete": "حذف مستخدم",
  "license.grant_complimentary": "منح وصول مجاني لشركة",
  "license.revoke_complimentary": "إلغاء وصول مجاني لشركة",
  "billing.grace_settings": "تعديل فترة السماح",
  "billing.trial_settings": "تعديل إعدادات التجربة المجانية",
  "trial.extend": "تمديد تجربة مجانية لشركة",
  "legal.document": "تعديل نص قانوني (إصدار جديد)",
  "legal.settings": "تعديل بيانات التواصل القانونية",
  "pricing.save": "حفظ إعدادات الباقات",
  "pricing.restore": "استعادة نسخة من إعدادات الباقات",
  "pricing.reset": "استعادة الإعدادات الأصلية للباقات",
};
export const TONE = { ok: "bg-sageSoft text-sage", warn: "bg-amber-50 text-amber-800", bad: "bg-rose/10 text-rose", none: "bg-charcoal/5 text-charcoal/50" } as const;

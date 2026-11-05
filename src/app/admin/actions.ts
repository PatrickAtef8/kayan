"use server";

import { COMPLIMENTARY_ENTITLEMENTS } from "@/lib/billing/complimentary";
import { revalidatePath } from "next/cache";
import { namesMatch } from "@/lib/admin/confirm-name";
import { removeCompanyFiles } from "@/lib/admin/storage-cleanup";
import { requireSuperAdminAction } from "@/lib/admin/auth.server";
import { PRICING_CONFIG, PACKAGE_MODULE_ORDER } from "@/config/pricing.config";
import {
  entitlementsOf, overridesFromEditable, resolvePricingConfig, validateEditable, validatePricingConfig, toEditable,
  type EditablePackage, type PricingConfig,
} from "@/lib/billing/pricing";

// Every action starts with requireSuperAdminAction(): a signed-in, verified Super Admin or nothing. The service-role client
// is only ever handed to such a caller. Nothing the browser sends is trusted beyond "which record" and "which values".
export type AdminResult = { error: string | null; message?: string };
const base = PRICING_CONFIG as PricingConfig;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const FOREVER = "876000h"; // ~100 years: Supabase's way to deactivate a login without deleting anything

// ------------------------------------------------------------------------------------------------ users
export async function setUserActive(userId: string, active: boolean): Promise<AdminResult> {
  const ctx = await requireSuperAdminAction();
  if (!ctx.ok) return { error: ctx.error };
  if (typeof userId !== "string" || !UUID.test(userId)) return { error: "طلب غير صالح." };
  if (userId === ctx.userId) return { error: "لا يمكنك تعطيل حسابك الخاص." };
  const { data: target, error: getErr } = await ctx.admin.auth.admin.getUserById(userId);
  if (getErr || !target?.user) return { error: "المستخدم غير موجود." };
  const { error } = await ctx.admin.auth.admin.updateUserById(userId, { ban_duration: active ? "none" : FOREVER });
  if (error) { console.error("admin: could not change user status", error.message); return { error: "تعذّر تنفيذ العملية. حاول مرة أخرى." }; }
  await ctx.admin.rpc("admin_audit", { p_admin: ctx.userId, p_action: active ? "user.reactivate" : "user.deactivate", p_type: "user", p_id: userId, p_details: { email: target.user.email ?? null } });
  revalidatePath("/admin/users");
  return { error: null, message: active ? "أُعيد تفعيل المستخدم." : "عُطّل المستخدم ولن يتمكن من تسجيل الدخول." };
}

export async function deleteUser(userId: string): Promise<AdminResult> {
  const ctx = await requireSuperAdminAction();
  if (!ctx.ok) return { error: ctx.error };
  if (typeof userId !== "string" || !UUID.test(userId)) return { error: "طلب غير صالح." };
  if (userId === ctx.userId) return { error: "لا يمكنك حذف حسابك الخاص (كي لا تفقد الدخول إلى الإدارة)." };
  const { data: target } = await ctx.admin.auth.admin.getUserById(userId);
  if (!target?.user) return { error: "المستخدم غير موجود." };
  // The administrator may delete ANY account, including ones that belong to companies (migration 0067): the person's memberships are
  // removed and they are cleared from every "created by" column; the company's records stay, attributed to nobody.
  const { error: dErr } = await ctx.admin.rpc("admin_delete_user", { p_admin: ctx.userId, p_user: userId });
  if (dErr) { console.error("admin: could not detach the user", dErr.message); return { error: "تعذّر حذف المستخدم. تأكّد من تطبيق ترحيل قاعدة البيانات 0067." }; }
  const { error } = await ctx.admin.auth.admin.deleteUser(userId);
  if (error) {
    console.error("admin: delete user refused", error.message);
    return { error: "أُزيل المستخدم من الشركات لكن تعذّر حذف حسابه. عطّل حسابه أو أعد المحاولة." };
  }
  await ctx.admin.rpc("admin_audit", { p_admin: ctx.userId, p_action: "user.delete", p_type: "user", p_id: userId, p_details: { email: target.user.email ?? null } });
  revalidatePath("/admin/users"); revalidatePath("/admin/companies"); revalidatePath("/admin");
  return { error: null, message: "حُذف المستخدم نهائيًا." };
}

export async function deleteCompany(orgId: string, typedName: string): Promise<AdminResult> {
  const ctx = await requireSuperAdminAction();
  if (!ctx.ok) return { error: ctx.error };
  if (typeof orgId !== "string" || !UUID.test(orgId)) return { error: "طلب غير صالح." };

  // The name is read from the database, never from the browser: the typed text must equal what is stored.
  const { data: org } = await ctx.admin.from("organizations").select("name").eq("id", orgId).maybeSingle();
  if (!org) return { error: "الشركة غير موجودة." };
  if (!namesMatch(typedName, (org as { name: string }).name)) return { error: "الاسم المكتوب لا يطابق اسم الشركة تمامًا. لم يُحذف شيء." };

  // 1. the database (one transaction; archives the audit log and payment records first — migration 0072)
  const { data, error } = await ctx.admin.rpc("admin_delete_company", { p_admin: ctx.userId, p_org: orgId });
  if (error) { console.error("admin: could not delete the company", error.message); return { error: "تعذّر حذف الشركة، ولم يُحذف شيء. تأكّد من تطبيق ترحيل قاعدة البيانات 0072." }; }
  if (data === "not_found") return { error: "الشركة غير موجودة." };

  // 2. the files — only AFTER the database step succeeded, so a failure above never costs anyone their attachments
  let files = "";
  try {
    const { data: arch } = await ctx.admin.from("company_deletion_archive").select("id, attachment_paths").eq("source_org_id", orgId).order("deleted_at", { ascending: false }).limit(1).maybeSingle();
    const known = Array.isArray((arch as { attachment_paths?: unknown } | null)?.attachment_paths) ? ((arch as { attachment_paths: unknown[] }).attachment_paths.filter((p) => typeof p === "string") as string[]) : [];
    const report = await removeCompanyFiles(ctx.admin.storage.from("attachments"), orgId, known);
    await ctx.admin.rpc("admin_audit", { p_admin: ctx.userId, p_action: "company.delete.files", p_type: "organization", p_id: orgId, p_details: { found: report.found, removed: report.removed, failed: report.failed } });
    if (report.failed > 0) files = ` تعذّر حذف ${report.failed} ملفًا من التخزين — ابحث عن المجلد ${orgId} في Storage واحذفه يدويًا.`;
  } catch (e) {
    console.error("admin: company deleted but file cleanup failed", e instanceof Error ? e.message : "unknown");
    files = ` حُذفت الشركة لكن تعذّر تنظيف ملفاتها من Storage — احذف المجلد ${orgId} من bucket «attachments» يدويًا.`;
  }
  revalidatePath("/admin/companies"); revalidatePath("/admin/users"); revalidatePath("/admin");
  return { error: null, message: `حُذفت الشركة وكل بياناتها. نُسخ سجل المراجعة وسجل المدفوعات إلى الأرشيف قبل الحذف.${files}` };
}

// ------------------------------------------------------------------------------------------------ free licenses
export async function grantComplimentary(orgId: string): Promise<AdminResult> {
  const ctx = await requireSuperAdminAction();
  if (!ctx.ok) return { error: ctx.error };
  if (typeof orgId !== "string" || !UUID.test(orgId)) return { error: "طلب غير صالح." };
  // free access = every module, no limits (whatever the paid packages currently say)
  const entitlements = COMPLIMENTARY_ENTITLEMENTS;
  const { data, error } = await ctx.admin.rpc("admin_grant_complimentary_license", { p_admin: ctx.userId, p_org: orgId, p_package: "complete", p_entitlements: entitlements });
  if (error) return { error: "تعذّر تنفيذ العملية." };
  revalidatePath(`/admin/companies/${orgId}`); revalidatePath("/admin/companies");
  if (data === "has_paid_license") return { error: "هذه الشركة تملك باقة مدفوعة ولن نستبدلها بباقة مجانية." };
  if (data === "not_found") return { error: "الشركة غير موجودة." };
  return { error: null, message: "فُعّل الوصول المجاني الكامل لهذه الشركة." };
}

export async function revokeComplimentary(orgId: string): Promise<AdminResult> {
  const ctx = await requireSuperAdminAction();
  if (!ctx.ok) return { error: ctx.error };
  if (typeof orgId !== "string" || !UUID.test(orgId)) return { error: "طلب غير صالح." };
  const { data, error } = await ctx.admin.rpc("admin_revoke_complimentary_license", { p_admin: ctx.userId, p_org: orgId });
  if (error) return { error: "تعذّر تنفيذ العملية." };
  revalidatePath(`/admin/companies/${orgId}`); revalidatePath("/admin/companies");
  return data === true ? { error: null, message: "أُلغي الوصول المجاني. عادت الشركة إلى وضع «بلا باقة» كما كانت." } : { error: "لا يوجد وصول مجاني لإلغائه." };
}

// ------------------------------------------------------------------------------------------------ packages
export type EditablePackageInput = EditablePackage;

async function persist(ctx: Extract<Awaited<ReturnType<typeof requireSuperAdminAction>>, { ok: true }>, all: Record<string, EditablePackage>, applyExisting: boolean, action: "save" | "restore", note: string | null): Promise<AdminResult> {
  const overrides = overridesFromEditable(all);
  const resolved = resolvePricingConfig(overrides);
  if (validatePricingConfig(resolved.config).length > 0) return { error: "القيم المدخلة غير صالحة." };
  const entitlements = Object.fromEntries(resolved.config.packages.map((p) => [p.key, entitlementsOf(p)]));
  const { data, error } = await ctx.admin.rpc("admin_save_pricing_config", {
    p_admin: ctx.userId, p_config: overrides, p_entitlements: entitlements, p_apply_existing: applyExisting, p_action: action, p_note: note,
  });
  if (error) { console.error("admin: could not save pricing", error.message); return { error: "تعذّر حفظ الإعدادات. حاول مرة أخرى." }; }
  revalidatePath("/pricing"); revalidatePath("/dashboard/billing"); revalidatePath("/admin/packages");
  const n = (data as { applied_to_existing?: number } | null)?.applied_to_existing ?? 0;
  return { error: null, message: applyExisting ? `حُفظت الإعدادات وطُبّقت على ${n} شركة قائمة.` : "حُفظت الإعدادات. تسري فورًا على صفحة الأسعار والدفع والشراء الجديد." };
}

export async function savePricing(input: { packages: Record<string, EditablePackage>; applyExisting: boolean; note?: string }): Promise<AdminResult> {
  const ctx = await requireSuperAdminAction();
  if (!ctx.ok) return { error: ctx.error };
  const all: Record<string, EditablePackage> = {};
  const errors: string[] = [];
  for (const p of base.packages) {
    const e = input?.packages?.[p.key];
    if (!e) return { error: "طلب غير صالح." };
    const clean: EditablePackage = {
      licenseEgp: Number(e.licenseEgp), hostingMonthlyEgp: Number(e.hostingMonthlyEgp), subscriptionMonthlyEgp: Number(e.subscriptionMonthlyEgp),
      maxMembers: e.maxMembers === null ? null : Number(e.maxMembers), maxWarehouses: e.maxWarehouses === null ? null : Number(e.maxWarehouses),
      modules: Array.isArray(e.modules) ? e.modules : [],
    };
    errors.push(...validateEditable(p.key, p.name, clean));
    all[p.key] = clean;
  }
  if (errors.length) return { error: errors.join(" ") };
  return persist(ctx, all, !!input.applyExisting, "save", typeof input.note === "string" ? input.note.slice(0, 300) : null);
}

export async function resetPricing(): Promise<AdminResult> {
  const ctx = await requireSuperAdminAction();
  if (!ctx.ok) return { error: ctx.error };
  const { error } = await ctx.admin.rpc("admin_reset_pricing_config", { p_admin: ctx.userId, p_note: "restored the shipped configuration" });
  if (error) return { error: "تعذّر استعادة الإعدادات الأصلية." };
  revalidatePath("/pricing"); revalidatePath("/dashboard/billing"); revalidatePath("/admin/packages");
  return { error: null, message: "أُعيدت الإعدادات الأصلية (القيم المكتوبة في النظام) بالكامل." };
}

export async function restorePricingVersion(historyId: number): Promise<AdminResult> {
  const ctx = await requireSuperAdminAction();
  if (!ctx.ok) return { error: ctx.error };
  if (!Number.isInteger(historyId)) return { error: "طلب غير صالح." };
  const { data } = await ctx.admin.from("platform_pricing_history").select("config").eq("id", historyId).maybeSingle();
  if (!data?.config) return { error: "هذه النسخة غير موجودة." };
  const resolved = resolvePricingConfig(data.config);
  const all = Object.fromEntries(resolved.config.packages.map((p) => [p.key, toEditable(p)]));
  return persist(ctx, all, false, "restore", `restored version #${historyId}`);
}

// ------------------------------------------------------------------------------------------------ grace period
/** Global grace period: on/off + hours (0 = lock the moment a subscription ends). Applied by the DATABASE, with its own clock. */
export async function saveGraceSettings(input: { enabled: boolean; hours: number }): Promise<AdminResult> {
  const ctx = await requireSuperAdminAction();
  if (!ctx.ok) return { error: ctx.error };
  const hours = Number(input?.hours);
  if (typeof input?.enabled !== "boolean" || !Number.isInteger(hours) || hours < 0 || hours > 720) return { error: "أدخل عدد ساعات صحيحًا بين 0 و720 (30 يومًا)." };
  const { error } = await ctx.admin.rpc("admin_save_billing_settings", { p_admin: ctx.userId, p_enabled: input.enabled, p_hours: hours });
  if (error) { console.error("admin: could not save grace settings", error.message); return { error: "تعذّر حفظ الإعدادات. تأكّد من تطبيق ترحيل قاعدة البيانات 0063." }; }
  revalidatePath("/admin/packages"); revalidatePath("/dashboard", "layout");
  return { error: null, message: input.enabled && hours > 0 ? `حُفظت فترة السماح: ${hours} ساعة بعد انتهاء الاشتراك.` : "حُفظ الإعداد: يُغلق الوصول لحظة انتهاء الاشتراك." };
}

// ------------------------------------------------------------------------------------------------ legal pages
/** Saves the Arabic + English text of one legal document as a NEW immutable version (the previous versions stay, so what a customer
 *  accepted can always be reproduced). Nothing changed → no new version. */
export async function saveLegalDocument(input: { key: string; titleAr: string; bodyAr: string; titleEn: string; bodyEn: string; note?: string }): Promise<AdminResult> {
  const ctx = await requireSuperAdminAction();
  if (!ctx.ok) return { error: ctx.error };
  if (!["terms", "privacy", "refund"].includes(String(input?.key))) return { error: "مستند غير معروف." };
  const s = (v: unknown) => (typeof v === "string" ? v : "");
  if (![input.titleAr, input.bodyAr, input.titleEn, input.bodyEn].every((v) => s(v).trim())) return { error: "العنوان والنص مطلوبان بالعربية والإنجليزية." };
  if (s(input.bodyAr).length > 200000 || s(input.bodyEn).length > 200000) return { error: "النص أطول من الحد المسموح." };
  const { data, error } = await ctx.admin.rpc("admin_save_legal_document", {
    p_admin: ctx.userId, p_key: input.key, p_title_ar: input.titleAr, p_body_ar: input.bodyAr, p_title_en: input.titleEn, p_body_en: input.bodyEn, p_note: s(input.note).slice(0, 300),
  });
  if (error) { console.error("admin: could not save a legal document", error.message); return { error: "تعذّر الحفظ. تأكّد من تطبيق ترحيلات قاعدة البيانات 0064 و0065." }; }
  revalidatePath("/admin/legal"); for (const p of ["/terms", "/privacy", "/refund-policy", "/checkout"]) revalidatePath(p);
  const r = data as { version: number; unchanged: boolean };
  return { error: null, message: r.unchanged ? "لا تغيير في النص، فلم يُنشأ إصدار جديد." : `حُفظ كإصدار جديد رقم ${r.version}. سيُطلب من العملاء الموافقة عليه عند الدفع القادم.` };
}

export async function saveLegalSettings(input: {
  companyNameAr: string; companyNameEn: string; phone: string; email: string; addressAr: string; addressEn: string;
  commercialRegister: string; taxRegistration: string; lawyerReviewed: boolean;
}): Promise<AdminResult> {
  const ctx = await requireSuperAdminAction();
  if (!ctx.ok) return { error: ctx.error };
  const s = (v: unknown) => (typeof v === "string" ? v.trim() : "");
  if (!s(input?.companyNameAr) || !s(input?.companyNameEn)) return { error: "اسم الجهة مطلوب بالعربية والإنجليزية." };
  if (!/^[0-9+()\-\s]{0,30}$/.test(s(input.phone))) return { error: "رقم الهاتف غير صالح (أرقام و + و - وأقواس ومسافات فقط)." };
  if (s(input.email) && !/^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(s(input.email))) return { error: "البريد الإلكتروني غير صالح." };
  const { error } = await ctx.admin.rpc("admin_save_legal_settings", {
    p_admin: ctx.userId, p_name_ar: s(input.companyNameAr), p_name_en: s(input.companyNameEn), p_phone: s(input.phone), p_email: s(input.email),
    p_address_ar: s(input.addressAr), p_address_en: s(input.addressEn), p_register: s(input.commercialRegister), p_tax: s(input.taxRegistration), p_lawyer_reviewed: input.lawyerReviewed === true,
  });
  if (error) { console.error("admin: could not save the legal settings", error.message); return { error: "تعذّر الحفظ. تأكّد من تطبيق ترحيلات قاعدة البيانات 0064 و0065." }; }
  revalidatePath("/admin/legal"); revalidatePath("/", "layout");
  return { error: null, message: "حُفظت بيانات التواصل والإعدادات." };
}

import "server-only";
import { cache } from "react";
import { createClient } from "@/lib/supabase/server";
import { LEGAL_DEFAULTS, LEGAL_KEYS, type LegalKey } from "@/config/legal.defaults";
import type { LegalVars } from "./render";
import type { LegalVersions } from "./acceptance";

export type LegalDoc = { key: LegalKey; version: number; titleAr: string; bodyAr: string; titleEn: string; bodyEn: string; createdAt: string | null; note: string | null; shipped: boolean };
export type LegalSettings = {
  companyNameAr: string; companyNameEn: string; phone: string; email: string; addressAr: string; addressEn: string;
  commercialRegister: string; taxRegistration: string; lawyerReviewed: boolean;
};

const DEFAULT_SETTINGS: LegalSettings = { companyNameAr: "كيان", companyNameEn: "Kayan", phone: "", email: "", addressAr: "", addressEn: "", commercialRegister: "", taxRegistration: "", lawyerReviewed: false };

/** Placeholder values for one language. */
export function varsFor(s: LegalSettings, lang: "ar" | "en"): LegalVars {
  return { company_name: lang === "ar" ? s.companyNameAr : s.companyNameEn, phone: s.phone, email: s.email, address: lang === "ar" ? s.addressAr : s.addressEn, commercial_register: s.commercialRegister, tax_registration: s.taxRegistration };
}

/** Public: the current version of every document and the contact settings. Falls back to the shipped text (version 0) when the
 *  tables are not there yet, so the pages work even before the migrations are applied — but nothing can be ACCEPTED at version 0. */
export const loadLegal = cache(async (): Promise<{ docs: Record<LegalKey, LegalDoc>; settings: LegalSettings }> => {
  const docs = Object.fromEntries(LEGAL_KEYS.map((k) => [k, { key: k, version: 0, ...LEGAL_DEFAULTS[k], createdAt: null, note: null, shipped: true }])) as Record<LegalKey, LegalDoc>;
  let settings = DEFAULT_SETTINGS;
  try {
    const supabase = await createClient();
    const [d, s] = await Promise.all([
      supabase.from("legal_documents").select("doc_key, version, title_ar, body_ar, title_en, body_en, created_at, change_note").order("version", { ascending: false }),
      supabase.from("platform_legal_settings").select("*").eq("id", 1).maybeSingle(),
    ]);
    const seen = new Set<string>();
    for (const r of d.data ?? []) {
      if (seen.has(r.doc_key) || !LEGAL_KEYS.includes(r.doc_key)) continue;
      seen.add(r.doc_key);
      docs[r.doc_key as LegalKey] = { key: r.doc_key, version: r.version, titleAr: r.title_ar, bodyAr: r.body_ar, titleEn: r.title_en, bodyEn: r.body_en, createdAt: r.created_at, note: r.change_note, shipped: false };
    }
    if (s.data) settings = { companyNameAr: s.data.company_name_ar, companyNameEn: s.data.company_name_en, phone: s.data.contact_phone, email: s.data.contact_email, addressAr: s.data.address_ar, addressEn: s.data.address_en, commercialRegister: s.data.commercial_register, taxRegistration: s.data.tax_registration, lawyerReviewed: s.data.lawyer_reviewed };
  } catch (e) { console.error("legal: could not read the legal tables (is migration 0064/0065 applied?)", e instanceof Error ? e.message : e); }
  return { docs, settings };
});

/** The versions that can be ACCEPTED right now (database only; null when any document is missing). */
export async function loadAcceptableVersions(): Promise<LegalVersions | null> {
  try {
    const supabase = await createClient();
    const { data, error } = await supabase.rpc("legal_current_versions");
    if (error || !data) return null;
    const v = data as Partial<LegalVersions>;
    return Number.isInteger(v.terms) && Number.isInteger(v.privacy) && Number.isInteger(v.refund) ? (v as LegalVersions) : null;
  } catch { return null; }
}

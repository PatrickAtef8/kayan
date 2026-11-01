import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { Navbar } from "@/components/marketing/navbar";
import { MarketingFooter } from "@/components/marketing/footer";
import { LegalArticle } from "./legal-article";
import { loadLegal, varsFor } from "@/lib/legal/legal.server";
import { renderLegal } from "@/lib/legal/render";
import { LEGAL_KEYS, LEGAL_PATH, type LegalKey } from "@/config/legal.defaults";

const NAV: Record<LegalKey, { ar: string; en: string }> = {
  terms: { ar: "الشروط والأحكام", en: "Terms" },
  privacy: { ar: "سياسة الخصوصية", en: "Privacy" },
  refund: { ar: "الإلغاء والاسترداد", en: "Refunds" },
};
const dateOf = (iso: string | null, lang: "ar" | "en") => (iso ? new Intl.DateTimeFormat(lang === "ar" ? "ar-EG" : "en-GB", { dateStyle: "long" }).format(new Date(iso)) : "—");

export const pickLang = (v: string | undefined): "ar" | "en" => (v === "en" ? "en" : "ar");

/** One public legal page, Arabic (default, RTL) or English (?lang=en, LTR). */
export async function LegalPage({ docKey, lang }: { docKey: LegalKey; lang: "ar" | "en" }) {
  const supabase = await createClient();
  const [{ data: { user } }, { docs, settings }] = await Promise.all([supabase.auth.getUser(), loadLegal()]);
  const doc = docs[docKey];
  const en = lang === "en";
  const blocks = renderLegal(en ? doc.bodyEn : doc.bodyAr, varsFor(settings, lang));
  const path = LEGAL_PATH[docKey];
  return (
    <div className="min-h-screen bg-ivory text-charcoal" dir="rtl">
      <Navbar signedIn={!!user} />
      <main className="px-5 pb-24 pt-32 sm:px-6 sm:pt-40">
        <div className="mx-auto max-w-3xl">
          <nav aria-label="legal" className="mb-8 flex flex-wrap items-center justify-between gap-3 text-sm">
            <ul className="flex flex-wrap gap-2">
              {LEGAL_KEYS.map((k) => <li key={k}><Link href={en ? `${LEGAL_PATH[k]}?lang=en` : LEGAL_PATH[k]} aria-current={k === docKey ? "page" : undefined} className={`rounded-xl px-3.5 py-2 ${k === docKey ? "bg-sageSoft font-medium text-sage" : "text-charcoal/55 hover:bg-white hover:text-charcoal"}`}>{en ? NAV[k].en : NAV[k].ar}</Link></li>)}
            </ul>
            <Link href={en ? path : `${path}?lang=en`} hrefLang={en ? "ar" : "en"} className="rounded-xl border border-borderSoft bg-white px-3.5 py-2 text-charcoal/70 hover:border-sage">{en ? "العربية" : "English"}</Link>
          </nav>

          <article dir={en ? "ltr" : "rtl"} lang={lang} className="rounded-2xl border border-borderSoft bg-white p-6 sm:p-10">
            <header className="mb-8 border-b border-borderSoft pb-6">
              <h1 className="text-3xl font-semibold tracking-tight text-charcoal sm:text-4xl">{en ? doc.titleEn : doc.titleAr}</h1>
              <p className="mt-3 text-xs text-charcoal/45">
                {doc.version > 0 ? (en ? `Version ${doc.version}` : `الإصدار ${doc.version}`) : (en ? "Draft" : "مسودة")} · {en ? "Last updated" : "آخر تحديث"}: {dateOf(doc.createdAt, lang)}
              </p>
              {!settings.lawyerReviewed && <p role="note" className="mt-4 bg-amber-50 px-3 py-2 text-xs leading-6 text-amber-900">{en ? "This text is a draft pending legal review and may change." : "هذا النص مسودة قيد المراجعة القانونية وقد يتغير."}</p>}
              {en && <p className="mt-3 text-xs text-charcoal/45">The Arabic version prevails if the two differ.</p>}
            </header>
            <LegalArticle blocks={blocks} />
          </article>
        </div>
      </main>
      <MarketingFooter signedIn={!!user} />
    </div>
  );
}

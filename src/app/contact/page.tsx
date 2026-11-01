import type { Metadata } from "next";
import Link from "next/link";
import { Mail, MapPin, Phone } from "lucide-react";
import { createClient } from "@/lib/supabase/server";
import { Navbar } from "@/components/marketing/navbar";
import { MarketingFooter } from "@/components/marketing/footer";
import { loadLegal } from "@/lib/legal/legal.server";
import { pickLang } from "@/components/legal/legal-page";

export const metadata: Metadata = { title: "اتصل بنا — كيان" };

export default async function ContactPage({ searchParams }: { searchParams: Promise<{ lang?: string }> }) {
  const lang = pickLang((await searchParams).lang);
  const en = lang === "en";
  const supabase = await createClient();
  const [{ data: { user } }, { settings: s }] = await Promise.all([supabase.auth.getUser(), loadLegal()]);
  const rows = [
    { icon: Phone, label: en ? "Phone" : "الهاتف", value: s.phone, href: s.phone ? `tel:${s.phone.replace(/[^0-9+]/g, "")}` : null, ltr: true },
    { icon: Mail, label: en ? "Email" : "البريد الإلكتروني", value: s.email, href: s.email ? `mailto:${s.email}` : null, ltr: true },
    { icon: MapPin, label: en ? "Address" : "العنوان", value: en ? s.addressEn : s.addressAr, href: null, ltr: false },
  ].filter((r) => r.value);
  return (
    <div className="min-h-screen bg-ivory text-charcoal" dir="rtl">
      <Navbar signedIn={!!user} />
      <main className="px-5 pb-24 pt-32 sm:px-6 sm:pt-40">
        <div className="mx-auto max-w-xl">
          <div className="mb-6 text-end text-sm"><Link href={en ? "/contact" : "/contact?lang=en"} className="rounded-xl border border-borderSoft bg-white px-3.5 py-2 text-charcoal/70 hover:border-sage">{en ? "العربية" : "English"}</Link></div>
          <section dir={en ? "ltr" : "rtl"} lang={lang} className="rounded-2xl border border-borderSoft bg-white p-6 sm:p-10">
            <h1 className="text-3xl font-semibold tracking-tight">{en ? "Contact us" : "اتصل بنا"}</h1>
            <p className="mt-2 text-sm text-charcoal/55">{en ? s.companyNameEn : s.companyNameAr}</p>
            {rows.length === 0 ? <p className="mt-6 text-sm text-charcoal/55">{en ? "Contact details will be added soon." : "ستُضاف بيانات التواصل قريبًا."}</p> : (
              <ul className="mt-6 space-y-4">
                {rows.map((r) => (
                  <li key={r.label} className="flex items-start gap-3 text-sm">
                    <span className="mt-0.5 flex h-9 w-9 shrink-0 items-center justify-center rounded-full bg-sageSoft text-sage"><r.icon size={17} /></span>
                    <span><span className="block text-xs text-charcoal/45">{r.label}</span>{r.href ? <a href={r.href} dir={r.ltr ? "ltr" : undefined} className="font-medium text-charcoal underline-offset-4 hover:underline">{r.value}</a> : <span dir={r.ltr ? "ltr" : undefined} className="font-medium text-charcoal">{r.value}</span>}</span>
                  </li>
                ))}
              </ul>
            )}
          </section>
        </div>
      </main>
      <MarketingFooter signedIn={!!user} />
    </div>
  );
}

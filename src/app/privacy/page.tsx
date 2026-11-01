import type { Metadata } from "next";
import { LegalPage, pickLang } from "@/components/legal/legal-page";
import { loadLegal } from "@/lib/legal/legal.server";

export async function generateMetadata({ searchParams }: { searchParams: Promise<{ lang?: string }> }): Promise<Metadata> {
  const lang = pickLang((await searchParams).lang);
  const { docs } = await loadLegal();
  return { title: `${lang === "en" ? docs.privacy.titleEn : docs.privacy.titleAr} — Kayan` };
}

export default async function Page({ searchParams }: { searchParams: Promise<{ lang?: string }> }) {
  return <LegalPage docKey="privacy" lang={pickLang((await searchParams).lang)} />;
}

import Link from "next/link";
import { loadLegal } from "@/lib/legal/legal.server";

export async function MarketingFooter({ signedIn = false }: { signedIn?: boolean }) {
  const { settings } = await loadLegal();
  return (
    <footer className="border-t border-borderSoft px-6 py-8">
      <div className="mx-auto flex max-w-6xl flex-col items-center justify-between gap-4 text-xs text-charcoal/40 sm:flex-row">
        <div className="flex items-center gap-3">
          <div className="flex h-7 w-7 items-center justify-center bg-charcoal text-xs font-medium text-ivory">ك</div>
          <span>كيان — لإدارة أعمالك</span>
        </div>
        <nav className="flex flex-wrap items-center justify-center gap-x-5 gap-y-2">
          <Link href="/#features" className="transition-colors hover:text-charcoal">المميزات</Link>
          <Link href="/#roles" className="transition-colors hover:text-charcoal">الأدوار</Link>
          <Link href="/#how" className="transition-colors hover:text-charcoal">كيف يعمل</Link>
          <Link href="/pricing" className="transition-colors hover:text-charcoal">الأسعار</Link>
          {signedIn ? (
            <Link href="/dashboard" className="transition-colors hover:text-charcoal">لوحة التحكم</Link>
          ) : (
            <Link href="/login" className="transition-colors hover:text-charcoal">تسجيل الدخول</Link>
          )}
        </nav>
      </div>
      <div className="mx-auto mt-5 flex max-w-6xl flex-col items-center justify-between gap-3 border-t border-borderSoft/70 pt-5 text-xs text-charcoal/40 sm:flex-row">
        <nav aria-label="legal" className="flex flex-wrap items-center justify-center gap-x-5 gap-y-2">
          <Link href="/terms" className="transition-colors hover:text-charcoal">الشروط والأحكام</Link>
          <Link href="/privacy" className="transition-colors hover:text-charcoal">سياسة الخصوصية</Link>
          <Link href="/refund-policy" className="transition-colors hover:text-charcoal">الإلغاء والاسترداد</Link>
          <Link href="/contact" className="transition-colors hover:text-charcoal">اتصل بنا</Link>
          <Link href="/terms?lang=en" hrefLang="en" className="transition-colors hover:text-charcoal">English</Link>
        </nav>
        <p className="flex flex-wrap items-center justify-center gap-x-4 gap-y-1">
          {settings.phone && <a href={`tel:${settings.phone.replace(/[^0-9+]/g, "")}`} dir="ltr" className="transition-colors hover:text-charcoal">{settings.phone}</a>}
          <span>© {new Date().getFullYear()} {settings.companyNameAr}</span>
        </p>
      </div>
    </footer>
  );
}

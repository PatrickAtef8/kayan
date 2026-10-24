import Link from "next/link";

export function MarketingFooter({ signedIn = false }: { signedIn?: boolean }) {
  return (
    <footer className="border-t border-borderSoft px-6 py-8">
      <div className="mx-auto flex max-w-6xl flex-col items-center justify-between gap-4 text-xs text-charcoal/40 sm:flex-row">
        <div className="flex items-center gap-3">
          <div className="flex h-7 w-7 items-center justify-center bg-charcoal text-xs font-medium text-ivory">ك</div>
          <span>كيان — لإدارة أعمالك</span>
        </div>
        <nav className="flex flex-wrap items-center justify-center gap-5">
          <a href="#features" className="transition-colors hover:text-charcoal">المميزات</a>
          <a href="#roles" className="transition-colors hover:text-charcoal">الأدوار</a>
          <a href="#how" className="transition-colors hover:text-charcoal">كيف يعمل</a>
          {signedIn ? (
            <Link href="/dashboard" className="transition-colors hover:text-charcoal">لوحة التحكم</Link>
          ) : (
            <Link href="/login" className="transition-colors hover:text-charcoal">تسجيل الدخول</Link>
          )}
          <span>© {new Date().getFullYear()} كيان</span>
        </nav>
      </div>
    </footer>
  );
}

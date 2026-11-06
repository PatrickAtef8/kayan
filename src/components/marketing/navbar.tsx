"use client";

import { useEffect, useState } from "react";
import Link from "next/link";

export function Navbar({ signedIn = false, trialDays = null }: { signedIn?: boolean; trialDays?: number | null }) {
  const [scrolled, setScrolled] = useState(false);

  useEffect(() => {
    const onScroll = () => setScrolled(window.scrollY > 24);
    window.addEventListener("scroll", onScroll);
    return () => window.removeEventListener("scroll", onScroll);
  }, []);

  return (
    <header className={`fixed inset-x-0 top-0 z-50 px-4 pt-4 transition-all duration-300 sm:px-6 sm:pt-6 ${scrolled ? "pt-3" : ""}`}>
      <div className={`mx-auto flex h-14 max-w-6xl items-center justify-between border px-4 transition-all duration-300 sm:px-5 ${scrolled ? "border-borderSoft bg-ivory/90 shadow-[0_10px_30px_rgba(28,28,26,0.06)] backdrop-blur-md" : "border-charcoal/10 bg-ivory/75 backdrop-blur-sm"}`}>
        <Link href="/" className="flex items-center gap-3" aria-label="كيان — الصفحة الرئيسية">
          <span className="flex h-8 w-8 items-center justify-center bg-charcoal text-sm font-medium text-ivory">ك</span>
          <span className="font-medium tracking-tight text-charcoal">كيان</span>
        </Link>
        <nav className="hidden items-center gap-8 text-xs text-charcoal/55 md:flex">
          <Link href="/#features" className="transition-colors hover:text-charcoal">المميزات</Link>
          <Link href="/#roles" className="transition-colors hover:text-charcoal">الأدوار</Link>
          <Link href="/#how" className="transition-colors hover:text-charcoal">كيف يعمل</Link>
          <Link href="/pricing" className="transition-colors hover:text-charcoal">الأسعار</Link>
        </nav>
        <div className="flex items-center gap-4">
          {signedIn ? (
            <Link href="/dashboard" className="bg-charcoal px-4 py-2.5 text-xs font-medium text-ivory transition-colors hover:bg-sage">لوحة التحكم</Link>
          ) : (
            <>
              <Link href="/login" className="hidden text-xs text-charcoal/60 transition-colors hover:text-charcoal sm:block">تسجيل الدخول</Link>
              {trialDays ? <Link href="/signup?trial=1" className="bg-sage px-4 py-2.5 text-xs font-medium text-ivory transition-colors hover:bg-charcoal">ابدأ مجانًا</Link>
                : <Link href="/signup" className="bg-charcoal px-4 py-2.5 text-xs font-medium text-ivory transition-colors hover:bg-sage">ابدأ الآن</Link>}
            </>
          )}
        </div>
      </div>
    </header>
  );
}

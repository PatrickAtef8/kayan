import Link from "next/link";
import { ArrowRight, BarChart3, ShieldCheck, Wallet } from "lucide-react";

// Same palette as before (charcoal / ivory / sage); the panel now has depth (soft glow + dot grid),
// rounded feature cards, a visible brand on mobile, and the form sits on a raised card.
export function AuthShell({ children }: { children: React.ReactNode }) {
  return (
    <div className="min-h-screen bg-ivory text-charcoal lg:grid lg:grid-cols-[0.9fr_1.1fr]" dir="rtl">
      <aside className="relative hidden overflow-hidden bg-charcoal p-10 text-ivory lg:sticky lg:top-0 lg:flex lg:h-screen lg:flex-col lg:justify-between">
        <div aria-hidden className="pointer-events-none absolute inset-0 opacity-[0.35]" style={{ backgroundImage: "radial-gradient(rgba(247,246,242,0.16) 1px, transparent 1px)", backgroundSize: "22px 22px", maskImage: "radial-gradient(ellipse at 70% 30%, black 10%, transparent 70%)", WebkitMaskImage: "radial-gradient(ellipse at 70% 30%, black 10%, transparent 70%)" }} />
        <div aria-hidden className="pointer-events-none absolute -left-32 top-10 h-96 w-96 rounded-full bg-brassLight/30 blur-3xl" />
        <div aria-hidden className="pointer-events-none absolute -bottom-24 right-0 h-80 w-80 rounded-full bg-sage/40 blur-3xl" />

        <Link href="/" className="relative z-10 flex items-center gap-3 transition-opacity hover:opacity-80" aria-label="كيان — العودة إلى الصفحة الرئيسية">
          <Logo />
          <span className="text-lg font-semibold tracking-tight">كيان</span>
        </Link>

        <div className="relative z-10 max-w-md animate-auth-rise">
          <p className="mb-5 inline-flex items-center gap-2 rounded-full border border-white/10 bg-white/[0.04] px-3 py-1 text-xs text-ivory/70">
            <span className="h-1.5 w-1.5 rounded-full bg-[#8FB19C]" /> طريقة أهدأ لإدارة الأعمال
          </p>
          <h2 className="text-[2.6rem] font-semibold leading-[1.15] tracking-tight">
            إدارة أعمالك،<br /><span className="bg-gradient-to-l from-[#8FB19C] to-[#C9DACF] bg-clip-text text-transparent">بصوت واحد.</span>
          </h2>
          <p className="mt-6 max-w-sm text-sm leading-8 text-ivory/60">المبيعات والمشتريات والمخزون والخزنة، بلغة عربية كاملة، مصممة لطريقة عمل الشركات المصرية الصغيرة والمتوسطة.</p>
        </div>

        <div className="relative z-10 grid gap-3">
          <Feature icon={BarChart3} title="كل نشاطك في شاشة واحدة" text="مبيعات ومشتريات ومخزون بنظرة سريعة" />
          <Feature icon={Wallet} title="أرقام دقيقة لحظة بلحظة" text="أرباحك وخزنتك ومديونياتك محسوبة تلقائيًا" />
          <Feature icon={ShieldCheck} title="بيانات معزولة وآمنة" text="كل شركة في مساحة خاصة لا يراها غيرها" />
        </div>
      </aside>

      <main className="relative flex min-h-screen flex-col items-center justify-center px-4 py-10 sm:px-10">
        <div aria-hidden className="pointer-events-none absolute inset-x-0 top-0 h-64 bg-gradient-to-b from-sageSoft/60 to-transparent lg:hidden" />
        <Link href="/" className="absolute right-5 top-5 z-10 inline-flex items-center gap-1.5 rounded-lg px-2.5 py-1.5 text-xs text-charcoal/50 transition-colors hover:bg-white/70 hover:text-charcoal sm:right-8 sm:top-7">
          <ArrowRight size={14} />
          العودة إلى الصفحة الرئيسية
        </Link>
        <Link href="/" className="relative mb-7 flex items-center gap-3 lg:hidden" aria-label="كيان — العودة إلى الصفحة الرئيسية">
          <Logo dark />
          <span className="text-lg font-semibold tracking-tight">كيان</span>
        </Link>
        <div className="relative w-full max-w-[26rem] animate-auth-rise rounded-3xl border border-borderSoft bg-white/80 p-7 shadow-[0_24px_60px_-28px_rgba(28,28,26,0.28)] backdrop-blur sm:p-9">
          {children}
        </div>
        <p className="relative mt-6 text-xs text-charcoal/35">© كيان — جميع الحقوق محفوظة</p>
      </main>
    </div>
  );
}

function Logo({ dark = false }: { dark?: boolean }) {
  return (
    <div className={dark ? "flex h-10 w-10 items-center justify-center rounded-xl bg-charcoal text-lg font-semibold text-ivory shadow-sm" : "flex h-10 w-10 items-center justify-center rounded-xl bg-ivory text-lg font-semibold text-charcoal shadow-sm"}>ك</div>
  );
}

function Feature({ icon: Icon, title, text }: { icon: typeof BarChart3; title: string; text: string }) {
  return (
    <div className="flex items-center gap-4 rounded-2xl border border-white/10 bg-white/[0.04] p-4 backdrop-blur-sm transition-colors hover:bg-white/[0.07]">
      <div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-xl bg-white/10 text-[#C9DACF]"><Icon size={19} strokeWidth={1.7} /></div>
      <div>
        <p className="text-sm font-medium text-ivory/90">{title}</p>
        <p className="mt-0.5 text-xs text-ivory/50">{text}</p>
      </div>
    </div>
  );
}

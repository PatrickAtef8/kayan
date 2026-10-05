import { LayoutGrid, ShieldCheck, TrendingUp } from "lucide-react";

export function AuthShell({ children }: { children: React.ReactNode }) {
  return (
    <div className="min-h-screen bg-ivory text-charcoal lg:grid lg:grid-cols-[0.9fr_1.1fr]" dir="rtl">
      <div className="relative hidden min-h-screen overflow-hidden bg-charcoal p-10 text-ivory lg:flex lg:flex-col lg:justify-between">
        <div className="pointer-events-none absolute -left-24 top-24 h-72 w-72 rounded-full border border-sage/30" />
        <div className="pointer-events-none absolute bottom-20 right-12 h-2 w-2 rounded-full bg-sage" />
        <div className="relative z-10 flex items-center justify-between text-[0.625rem] tracking-[0.18em] text-ivory/40" dir="ltr"><span>كيان / الدخول</span><span>01 — 03</span></div>
        <div className="relative z-10 max-w-md">
          <div className="mb-9 flex h-11 w-11 items-center justify-center bg-ivory text-lg font-medium text-charcoal">ك</div>
          <p className="mb-5 text-xs tracking-[0.18em] text-sage" dir="ltr">طريقة أهدأ لإدارة الأعمال</p>
          <h2 className="text-5xl font-medium leading-[1.05] tracking-[-0.05em]">إدارة أعمالك،<br /><span className="text-sage">بصوت واحد.</span></h2>
          <p className="mt-7 max-w-sm text-sm leading-8 text-ivory/55">المبيعات والمشتريات والمخزون والخزنة، بلغة عربية كاملة، مصممة لطريقة عمل الشركات المصرية الصغيرة والمتوسطة.</p>
        </div>
        <div className="relative z-10 space-y-3">
          <Feature icon={LayoutGrid} index="٠١" text="كل نشاطك التجاري في شاشة واحدة" />
          <Feature icon={TrendingUp} index="٠٢" text="أرقام دقيقة عن أرباحك وخزنتك لحظة بلحظة" />
          <Feature icon={ShieldCheck} index="٠٣" text="بيانات شركتك معزولة وآمنة تمامًا" />
        </div>
      </div>
      <div className="flex min-h-screen items-center justify-center border-r border-borderSoft p-6 sm:p-10">
        <div className="w-full max-w-md">
          <div className="mb-10 flex items-center justify-between text-[0.625rem] tracking-[0.18em] text-charcoal/35" dir="ltr"><span>كيان / ٢٠٢٤</span><span>دخول آمن</span></div>
          {children}
        </div>
      </div>
    </div>
  );
}

function Feature({ icon: Icon, index, text }: { icon: typeof LayoutGrid; index: string; text: string }) {
  return <div className="flex items-center gap-4 border-t border-white/10 pt-3"><span className="text-[0.625rem] tracking-[0.16em] text-sage" dir="ltr">{index}</span><div className="flex h-8 w-8 items-center justify-center border border-white/15"><Icon size={19} strokeWidth={1.7} /></div><p className="text-sm text-ivory/65">{text}</p></div>;
}

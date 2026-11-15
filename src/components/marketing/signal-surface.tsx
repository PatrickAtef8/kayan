"use client";

import { useState } from "react";
import { m, AnimatePresence } from "framer-motion";
import { ArrowUpLeft, Boxes, ChartNoAxesCombined, UserCheck, WalletCards } from "lucide-react";

const SIGNALS = [
  { id: "sales", label: "المبيعات", title: "كم ربحت فعلًا؟", value: "١٤٬٩٥٠ ج.م", detail: "صافي الربح بعد المصروفات والعمولات، عن أي شهر أو سنة تختارها", icon: ChartNoAxesCombined, bars: [38, 52, 48, 62, 76, 70, 92] },
  { id: "stock", label: "المخزون", title: "ما الذي يحتاج انتباهك؟", value: "١٢", detail: "منتجًا وصل إلى حد إعادة الطلب، مع تنبيه بالأصناف القريبة من انتهاء الصلاحية", icon: Boxes, bars: [78, 64, 48, 36, 42, 29, 24] },
  { id: "cash", label: "الخزنة", title: "أين رصيدك الآن؟", value: "٨٢٬٤٠٠ ج.م", detail: "كل تحصيل ومصروف ودفعة لمورد مسجّلة ومعروف مصدرها", icon: WalletCards, bars: [46, 58, 54, 74, 60, 82, 78] },
  { id: "reps", label: "المناديب", title: "من يقترب من هدفه؟", value: "٩٢٪", detail: "من هدف الشهر، وتُحسب العمولة تلقائيًا بمجرد بلوغ الحد الأدنى", icon: UserCheck, bars: [30, 44, 52, 58, 71, 80, 92] },
];

export function SignalSurface() {
  const [active, setActive] = useState(0);
  const signal = SIGNALS[active];
  const Icon = signal.icon;

  return (
    <section className="overflow-hidden bg-paper px-6 py-24 text-charcoal sm:py-32">
      <div className="mx-auto grid max-w-6xl gap-14 lg:grid-cols-[0.7fr_1.3fr] lg:items-center">
        <div>
          <p className="mb-5 text-xs tracking-[0.18em] text-sage">٠٢ / نظرة سريعة</p>
          <h2 className="max-w-md text-4xl font-medium leading-[1.08] tracking-[-0.04em] sm:text-5xl">أهم أرقامك أمامك.</h2>
          <p className="mt-6 max-w-sm text-sm leading-7 text-charcoal/50">من الصفحة الرئيسية ترى أهم أرقامك، وتصل الإشعارات إلى كل شخص بما يخصه: نقص في المخزون، أو تحصيل جديد، أو أمر صرف ينتظر التأكيد.</p>
          <div className="mt-9 space-y-2">
            {SIGNALS.map((item, index) => {
              const ItemIcon = item.icon;
              return (
                <button key={item.id} onClick={() => setActive(index)} className={`flex w-full items-center justify-between border px-4 py-3 text-right transition-colors ${active === index ? "border-sage bg-sage text-ivory" : "border-borderSoft text-charcoal/50 hover:border-sage hover:text-charcoal"}`}>
                  <span className="flex items-center gap-3 text-sm"><ItemIcon size={20} strokeWidth={1.7} />{item.label}</span>
                  <span className="text-[0.625rem] tracking-[0.16em]">{["٠١", "٠٢", "٠٣", "٠٤"][index]}</span>
                </button>
              );
            })}
          </div>
        </div>

        <div className="relative min-h-[538px] border border-borderSoft p-3 pb-12 sm:p-5 sm:pb-12">
          <div className="flex items-center justify-between border-b border-borderSoft pb-4 text-[0.625rem] tracking-[0.16em] text-charcoal/45"><span>كيان / نظرة سريعة</span><span>مثال توضيحي</span></div>
          <AnimatePresence mode="wait">
            <m.div key={signal.id} initial={{ opacity: 0, y: 18 }} animate={{ opacity: 1, y: 0 }} exit={{ opacity: 0, y: -18 }} transition={{ duration: 0.35 }} className="pt-9" dir="rtl">
              <div className="flex items-start justify-between gap-5"><div><p className="text-sm text-charcoal/45">{signal.label}</p><h3 className="mt-3 text-3xl font-medium tracking-tight sm:text-4xl">{signal.title}</h3></div><div className="flex h-11 w-11 items-center justify-center border border-sage text-sage"><Icon size={25} strokeWidth={1.5} /></div></div>
              <div className="mt-14 flex items-end gap-2 border-b border-borderSoft pb-4" aria-label={signal.title}>
                {signal.bars.map((bar, index) => <m.span key={index} initial={{ height: 0 }} animate={{ height: `${bar * 1.9}px` }} transition={{ delay: index * 0.06, duration: 0.55, ease: [0.22, 1, 0.36, 1] }} className={`w-full ${index === signal.bars.length - 1 ? "bg-sage" : "bg-sageSoft"}`} />)}
              </div>
              <div className="mt-5 flex items-end justify-between gap-6"><div><p className="text-4xl font-medium tracking-[-0.05em] text-sage sm:text-5xl">{signal.value}</p><p className="mt-2 text-sm text-charcoal/45">{signal.detail}</p></div><ArrowUpLeft size={25} className="text-charcoal/45" /></div>
            </m.div>
          </AnimatePresence>
          <div className="absolute bottom-5 left-5 text-[0.625rem] text-charcoal/40">أرقام للتوضيح فقط</div>
        </div>
      </div>
    </section>
  );
}

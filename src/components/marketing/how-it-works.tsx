"use client";

import { m } from "framer-motion";
import { Building2, LayoutGrid, UsersRound, Rocket, ArrowDownLeft } from "lucide-react";

const STEPS = [
  { index: "٠١", icon: Building2, title: "أنشئ شركتك", description: "اسم الشركة ونوع نشاطها — أقل من دقيقة." },
  { index: "٠٢", icon: LayoutGrid, title: "فعّل وحداتك", description: "اختر ما تحتاجه الآن من المبيعات والمخزون والخزنة وغيرها، وعدّله لاحقًا من الإعدادات." },
  { index: "٠٣", icon: UsersRound, title: "أضف فريقك", description: "ادعُ المناديب وأمناء المخازن، وكل واحد يدخل بصلاحياته فقط." },
  { index: "٠٤", icon: Rocket, title: "ابدأ وراقب", description: "سجّل أول فاتورة، وشاهد الأرباح والخزنة تتحدّث من الرئيسية." },
];

export function HowItWorks() {
  return (
    <section id="how" className="border-t border-borderSoft px-6 py-28 sm:py-36">
      <div className="mx-auto max-w-6xl">
        <m.div initial={{ opacity: 0, y: 12 }} whileInView={{ opacity: 1, y: 0 }} viewport={{ once: true }} className="mb-16 flex items-end justify-between gap-6">
          <h2 className="max-w-xl text-4xl font-medium leading-tight tracking-[-0.04em] text-charcoal sm:text-5xl">من الفكرة إلى أول فاتورة.</h2>
          <p className="hidden text-xs tracking-[0.16em] text-charcoal/40 sm:block" dir="ltr">٠٥ / كيف يعمل</p>
        </m.div>
        <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
          {STEPS.map((step, i) => {
            const Icon = step.icon;
            return (
              <m.div key={step.title} initial={{ opacity: 0, y: 18 }} whileInView={{ opacity: 1, y: 0 }} viewport={{ once: true }} transition={{ delay: i * 0.12, duration: 0.6 }} className="group relative min-h-[325px] border border-borderSoft bg-white/35 p-6 transition-colors hover:border-sage">
                <div className="flex items-start justify-between"><span className="text-xs tracking-[0.16em] text-sage" dir="ltr">{step.index}</span><Icon size={28} strokeWidth={1.5} className="text-charcoal/45" /></div>
                <div className="absolute bottom-6 right-6 left-6"><h3 className="text-xl font-medium text-charcoal">{step.title}</h3><p className="mt-2 max-w-[288px] text-sm leading-7 text-charcoal/50">{step.description}</p><ArrowDownLeft size={21} className="mt-7 text-sage transition-transform duration-300 group-hover:-translate-x-1 group-hover:translate-y-1" /></div>
              </m.div>
            );
          })}
        </div>
      </div>
    </section>
  );
}

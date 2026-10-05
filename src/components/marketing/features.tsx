"use client";

import { m } from "framer-motion";
import { ShoppingCart, Boxes, Wallet, BarChart3, UserCheck, ArrowUpLeft } from "lucide-react";

const FEATURES = [
  { eyebrow: "المبيعات", title: "من البيع إلى الربح، بلا خطوة ضائعة", description: "كل عملية بيع تحدّث مخزونك وخزنتك وأرباحك في نفس اللحظة.", icon: ShoppingCart, size: "md:col-span-7" },
  { eyebrow: "المخزون", title: "اعرف اللي عندك فعلًا", description: "كمية دقيقة لكل منتج، لحظة بلحظة.", icon: Boxes, size: "md:col-span-5" },
  { eyebrow: "الخزنة", title: "رصيدك الحقيقي", description: "كل قرش داخل وخارج مسجل ومربوط بمصدره.", icon: Wallet, size: "md:col-span-4" },
  { eyebrow: "المندوبين", title: "أداء كل مندوب أمامك", description: "مبيعات وعمولات وتحصيل، لكل مندوب على حدة.", icon: UserCheck, size: "md:col-span-4" },
  { eyebrow: "التقارير", title: "أرقام تفهمها من أول نظرة", description: "أرباح، مصروفات، وموقفك المالي — بدون تعقيد محاسبي.", icon: BarChart3, size: "md:col-span-4" },
];

export function Features() {
  return (
    <section id="features" className="px-6 py-28 sm:py-36">
      <div className="mx-auto max-w-6xl">
        <m.div initial={{ opacity: 0, y: 14 }} whileInView={{ opacity: 1, y: 0 }} viewport={{ once: true }} className="mb-14 flex flex-col justify-between gap-5 md:flex-row md:items-end">
          <div>
            <p className="mb-4 text-xs font-medium tracking-[0.16em] text-sage">٠٢ / ما الذي يتضمنه كيان</p>
            <h2 className="max-w-2xl text-4xl font-medium leading-tight tracking-[-0.04em] text-charcoal sm:text-5xl">نظام واحد بدل ست شاشات متفرقة.</h2>
          </div>
          <p className="max-w-xs text-sm leading-7 text-charcoal/50 md:text-left">الأدوات التي تحتاجها شركتك، مرتبة حول طريقة عملك — لا حول تعقيد البرنامج.</p>
        </m.div>
        <div className="grid grid-cols-1 gap-3 md:grid-cols-12">
          {FEATURES.map((feature, index) => {
            const Icon = feature.icon;
            return (
              <m.article
                key={feature.title}
                initial={{ opacity: 0, y: 18 }}
                whileInView={{ opacity: 1, y: 0 }}
                viewport={{ once: true, margin: "-60px" }}
                transition={{ delay: index * 0.07, duration: 0.6 }}
                className={`${feature.size} group relative min-h-[275px] overflow-hidden border border-borderSoft bg-white/50 p-6 text-charcoal transition-colors duration-300 hover:border-sage`}
              >
                <div className="flex items-start justify-between">
                  <span className="text-xs text-charcoal/45">{feature.eyebrow}</span>
                  <div className="flex h-9 w-9 items-center justify-center border border-borderSoft"><Icon size={21} strokeWidth={1.7} /></div>
                </div>
                <div className="absolute bottom-6 right-6 left-6 flex items-end justify-between gap-5">
                  <div>
                    <h3 className="max-w-md text-xl font-medium leading-snug">{feature.title}</h3>
                    <p className="mt-2 max-w-sm text-sm leading-6 text-charcoal/50">{feature.description}</p>
                  </div>
                  <ArrowUpLeft size={23} className="mb-1 shrink-0 opacity-0 transition-all duration-300 group-hover:-translate-y-1 group-hover:opacity-100" />
                </div>
              </m.article>
            );
          })}
        </div>
      </div>
    </section>
  );
}

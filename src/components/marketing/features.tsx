"use client";

import { m } from "framer-motion";
import { ShoppingCart, Boxes, Wallet, BarChart3, UserCheck, Truck, Zap, ArrowUpLeft } from "lucide-react";

const FEATURES = [
  { eyebrow: "المبيعات", title: "من الفاتورة إلى الربح، بلا خطوة ضائعة", description: "خصومات بالنسبة المئوية وشرائح خصم وبونص يدوي، ومرتجعات بنفس السعر الفعلي. كل فاتورة تحدّث المخزون والخزنة والربح معًا.", icon: ShoppingCart, size: "md:col-span-7" },
  { eyebrow: "المخزون", title: "اعرف اللي عندك فعلًا", description: "رصيد لكل مخزن، تحويل بينها، جرد وتسوية، ودفعات بتواريخ صلاحية — والكمية المباعة تُحجز قبل صرفها.", icon: Boxes, size: "md:col-span-5" },
  { eyebrow: "المشتريات والموردين", title: "من المورد إلى الرف", description: "فواتير مشتريات بمتوسط تكلفة مرجّح، ومرتجعات، وكشف حساب لكل مورد.", icon: Truck, size: "md:col-span-4" },
  { eyebrow: "الخزنة والمصروفات", title: "رصيدك الحقيقي", description: "حركة لكل تحصيل ودفعة ومصروف، مع مرفقات، وسحوبات الشركاء بمعزل عن الأرباح.", icon: Wallet, size: "md:col-span-4" },
  { eyebrow: "المندوبين", title: "أداء كل مندوب أمامك", description: "أهداف شهرية وحد أدنى للعمولة، وتحصيل من عملائه المسندين إليه فقط.", icon: UserCheck, size: "md:col-span-4" },
  { eyebrow: "التقارير", title: "أرقام تفهمها من أول نظرة", description: "أرباح وخسائر، ديون العملاء والموردين، المركز المالي، رواتب المناديب والمرتجعات — لأي شهر أو سنة تختارها.", icon: BarChart3, size: "md:col-span-7" },
  { eyebrow: "ابدأ بسرعة", title: "استورد، وابحث في ثانية", description: "استورد منتجاتك وعملاءك وموردينك من ملف CSV، وابحث في كل شيء من مكان واحد.", icon: Zap, size: "md:col-span-5" },
];

export function Features() {
  return (
    <section id="features" className="px-6 py-28 sm:py-36">
      <div className="mx-auto max-w-6xl">
        <m.div initial={{ opacity: 0, y: 14 }} whileInView={{ opacity: 1, y: 0 }} viewport={{ once: true }} className="mb-14 flex flex-col justify-between gap-5 md:flex-row md:items-end">
          <div>
            <p className="mb-4 text-xs font-medium tracking-[0.16em] text-sage">٠٣ / ما الذي يتضمنه كيان</p>
            <h2 className="max-w-2xl text-4xl font-medium leading-tight tracking-[-0.04em] text-charcoal sm:text-5xl">نظام واحد بدل أوراق وجداول متفرقة.</h2>
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

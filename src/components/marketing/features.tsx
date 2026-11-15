"use client";

import { m } from "framer-motion";
import { ShoppingCart, Boxes, Wallet, BarChart3, UserCheck, Truck, Zap, ArrowUpLeft } from "lucide-react";

const FEATURES = [
  { eyebrow: "المبيعات", title: "من الفاتورة إلى الربح، دون خطوة ناقصة", description: "خصومات بالنسبة المئوية وشرائح للخصم، وبونص تدخله بنفسك، ومرتجعات بنفس السعر الذي بيعت به. وتنعكس كل فاتورة على المخزون والخزنة والأرباح.", icon: ShoppingCart, size: "md:col-span-7" },
  { eyebrow: "المخزون", title: "اعرف ما عندك فعلًا", description: "رصيد لكل مخزن، وتحويل بين المخازن، وجرد وتسوية، ودفعات بتواريخ صلاحية. والكمية المباعة تُحجز من لحظة الفاتورة قبل صرفها.", icon: Boxes, size: "md:col-span-5" },
  { eyebrow: "المشتريات والموردين", title: "من المورد إلى الرف", description: "فواتير الشراء بمتوسط التكلفة المرجّح، والمرتجعات، وكشف حساب لكل مورد.", icon: Truck, size: "md:col-span-4" },
  { eyebrow: "الخزنة والمصروفات", title: "رصيد خزنتك الحقيقي", description: "كل تحصيل ودفعة ومصروف يُسجَّل كحركة، مع المرفقات، وسحوبات الشركاء منفصلة عن الأرباح.", icon: Wallet, size: "md:col-span-4" },
  { eyebrow: "المناديب", title: "أداء كل مندوب أمامك", description: "لكل مندوب هدف شهري وحد أدنى للعمولة، ويحصّل من عملائه هو فقط.", icon: UserCheck, size: "md:col-span-4" },
  { eyebrow: "التقارير", title: "أرقام تفهمها من أول نظرة", description: "الأرباح والخسائر، وديون العملاء والموردين، والمركز المالي، ورواتب المناديب، والمرتجعات، عن أي شهر أو سنة تختارها.", icon: BarChart3, size: "md:col-span-7" },
  { eyebrow: "البحث والتصدير", title: "ابحث وصدّر بضغطة واحدة", description: "ابحث في كل شيء من مكان واحد، وصدّر أي تقرير بصيغة Excel أو PDF جاهز للمشاركة.", icon: Zap, size: "md:col-span-5" },
];

export function Features() {
  return (
    <section id="features" className="px-6 py-28 sm:py-36">
      <div className="mx-auto max-w-6xl">
        <m.div initial={{ opacity: 0, y: 14 }} whileInView={{ opacity: 1, y: 0 }} viewport={{ once: true }} className="mb-14 flex flex-col justify-between gap-5 md:flex-row md:items-end">
          <div>
            <p className="mb-4 text-xs font-medium tracking-[0.16em] text-sage">٠٣ / ماذا يقدّم كيان</p>
            <h2 className="max-w-2xl text-4xl font-medium leading-tight tracking-[-0.04em] text-charcoal sm:text-5xl">نظام واحد بدل الدفاتر وملفات Excel المتفرقة.</h2>
          </div>
          <p className="max-w-xs text-sm leading-7 text-charcoal/50 md:text-left">كل ما تحتاجه شركتك، مرتّب على طريقة شغلك أنت، لا على طريقة البرامج المعقدة.</p>
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

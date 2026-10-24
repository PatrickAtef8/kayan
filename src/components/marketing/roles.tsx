"use client";

import { m } from "framer-motion";
import { ShieldCheck, UserCheck, Warehouse, ArrowLeft } from "lucide-react";

const ROLES = [
  {
    eyebrow: "المالك",
    title: "يرى كل شيء",
    icon: ShieldCheck,
    points: ["كل التقارير والأرباح والخزنة", "ينشئ العملاء ويعيّنهم للمناديب", "يدير الفريق والوحدات والخصومات", "سجل تدقيق لكل عملية"],
  },
  {
    eyebrow: "المندوب",
    title: "عملاؤه فقط",
    icon: UserCheck,
    points: ["عملاؤه وفواتيره ومرتجعاته", "يسجّل التحصيل من عملائه", "يتابع هدفه وعمولته", "يبلّغ عن نقص المخزون"],
  },
  {
    eyebrow: "أمين المخزن",
    title: "الكميات لا الأسعار",
    icon: Warehouse,
    points: ["يؤكد الصرف والاستلام، كليًا أو جزئيًا", "بلا أسعار ولا أرباح ولا بيانات عملاء", "مهامه تصله كإشعارات خاصة بدوره", "يدير المخازن والمنتجات"],
  },
];

const FLOW = [
  { index: "٠١", title: "فاتورة بيع", note: "تُسجَّل وتُحجز كميتها" },
  { index: "٠٢", title: "تأكيد الصرف", note: "أمين المخزن بالكمية الفعلية" },
  { index: "٠٣", title: "تحصيل", note: "من عملاء المندوب فقط" },
  { index: "٠٤", title: "الخزنة والربح", note: "يتحدّثان من مصدرهما" },
];

export function Roles() {
  return (
    <section id="roles" className="border-t border-borderSoft bg-white/45 px-6 py-28 sm:py-36">
      <div className="mx-auto max-w-6xl">
        <m.div initial={{ opacity: 0, y: 14 }} whileInView={{ opacity: 1, y: 0 }} viewport={{ once: true }} className="mb-14 flex flex-col justify-between gap-5 md:flex-row md:items-end">
          <div>
            <p className="mb-4 text-xs font-medium tracking-[0.16em] text-sage">٠٤ / الأدوار والصلاحيات</p>
            <h2 className="max-w-2xl text-4xl font-medium leading-tight tracking-[-0.04em] text-charcoal sm:text-5xl">كل شخص يرى ما يخصه فقط.</h2>
          </div>
          <p className="max-w-xs text-sm leading-7 text-charcoal/50 md:text-left">ثلاثة أدوار واضحة، والفصل بينها مطبّق داخل قاعدة البيانات نفسها لا في الواجهة فقط.</p>
        </m.div>

        <div className="grid gap-3 md:grid-cols-3">
          {ROLES.map((role, index) => {
            const Icon = role.icon;
            return (
              <m.article
                key={role.eyebrow}
                initial={{ opacity: 0, y: 18 }}
                whileInView={{ opacity: 1, y: 0 }}
                viewport={{ once: true, margin: "-60px" }}
                transition={{ delay: index * 0.09, duration: 0.6 }}
                className="group relative border border-borderSoft bg-ivory p-6 text-charcoal transition-colors duration-300 hover:border-sage"
              >
                <div className="flex items-start justify-between">
                  <span className="text-xs text-charcoal/45">{role.eyebrow}</span>
                  <div className="flex h-9 w-9 items-center justify-center border border-borderSoft"><Icon size={21} strokeWidth={1.7} /></div>
                </div>
                <h3 className="mt-14 text-xl font-medium leading-snug">{role.title}</h3>
                <ul className="mt-5 space-y-2.5 text-sm leading-6 text-charcoal/55">
                  {role.points.map((point) => (
                    <li key={point} className="flex items-start gap-2.5"><span className="mt-2.5 h-px w-4 shrink-0 bg-sage" />{point}</li>
                  ))}
                </ul>
              </m.article>
            );
          })}
        </div>

        {/* the stock cycle the roles share */}
        <m.div initial={{ opacity: 0, y: 14 }} whileInView={{ opacity: 1, y: 0 }} viewport={{ once: true }} className="mt-10">
          <p className="mb-4 text-xs tracking-[0.16em] text-charcoal/40">دورة العمل بين الأدوار</p>
          <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
            {FLOW.map((step, i) => (
              <m.div key={step.title} initial={{ opacity: 0, y: 12 }} whileInView={{ opacity: 1, y: 0 }} viewport={{ once: true }} transition={{ delay: i * 0.08, duration: 0.5 }} className="flex items-center justify-between gap-4 border border-borderSoft bg-ivory px-5 py-4">
                <div>
                  <p className="text-sm font-medium text-charcoal"><span className="ml-2 text-xs text-sage" dir="ltr">{step.index}</span>{step.title}</p>
                  <p className="mt-1.5 text-xs text-charcoal/45">{step.note}</p>
                </div>
                {i < FLOW.length - 1 && <ArrowLeft size={18} className="hidden shrink-0 text-sage lg:block" />}
              </m.div>
            ))}
          </div>
        </m.div>
      </div>
    </section>
  );
}

"use client";

import { useRef } from "react";
import { m, useMotionValue, useScroll, useSpring, useTransform } from "framer-motion";
import { ArrowLeft, MoveUpLeft, Sparkles } from "lucide-react";
import { PrimaryButton, SecondaryLink } from "./effects/buttons";

const headline = ["كل عملية", "تترك أثرًا."];

const container = { hidden: {}, show: { transition: { staggerChildren: 0.12 } } };
const word = {
  hidden: { opacity: 0, y: 28 },
  show: { opacity: 1, y: 0, transition: { duration: 0.8, ease: [0.22, 1, 0.36, 1] as const } },
};

export function Hero({ signedIn = false, trialDays = null }: { signedIn?: boolean; trialDays?: number | null }) {
  const ref = useRef<HTMLDivElement>(null);
  const pointerX = useSpring(useMotionValue(0), { stiffness: 90, damping: 20 });
  const pointerY = useSpring(useMotionValue(0), { stiffness: 90, damping: 20 });
  const { scrollYProgress } = useScroll({ target: ref, offset: ["start start", "end start"] });
  const y = useTransform(scrollYProgress, [0, 1], [0, 90]);
  const rotate = useTransform(scrollYProgress, [0, 1], [0, -4]);
  const opacity = useTransform(scrollYProgress, [0, 0.75], [1, 0.15]);

  return (
    <section
      ref={ref}
      onPointerMove={(event) => {
        const bounds = event.currentTarget.getBoundingClientRect();
        pointerX.set((event.clientX - bounds.left - bounds.width / 2) / 18);
        pointerY.set((event.clientY - bounds.top - bounds.height / 2) / 24);
      }}
      onPointerLeave={() => { pointerX.set(0); pointerY.set(0); }}
      className="relative overflow-hidden px-6 pb-20 pt-32 sm:pt-40 lg:pb-28"
    >
      <div className="pointer-events-none absolute right-[-8rem] top-28 h-64 w-64 rounded-full border border-sage/20 sm:right-[-5rem] sm:h-96 sm:w-96" />
      <div className="pointer-events-none absolute left-[9%] top-44 h-3 w-3 rounded-full bg-sage" />
      <div className="mx-auto grid max-w-6xl items-end gap-12 lg:grid-cols-[1.05fr_0.95fr] lg:gap-16">
        <div className="relative z-10 text-right">
          <m.div
            initial={{ opacity: 0, x: 16 }}
            animate={{ opacity: 1, x: 0 }}
            transition={{ duration: 0.7 }}
            className="mb-7 flex items-center justify-end gap-3 text-xs font-medium tracking-[0.18em] text-charcoal/45"
          >
            <span>إدارة أبسط. قرار أسرع.</span>
            <span className="h-px w-10 bg-sage" />
            <span className="text-sage">٠١ / ٠٦</span>
          </m.div>

          <m.h1
            variants={container}
            initial="hidden"
            animate="show"
            className="max-w-3xl text-[3.6rem] font-medium leading-[1.02] tracking-[-0.055em] text-charcoal sm:text-7xl lg:text-[6.4rem]"
          >
            {headline.map((w, i) => (
              <m.span key={w} variants={word} className="block">
                {i === 1 ? <><span className="text-sage">{w.slice(0, -1)}</span>{w.slice(-1)}</> : w}
              </m.span>
            ))}
          </m.h1>

          <m.p
            initial={{ opacity: 0, y: 16 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ delay: 0.65, duration: 0.7 }}
            className="mt-8 max-w-md text-base leading-8 text-charcoal/58 sm:text-lg"
          >
            كيان يجمع مبيعاتك ومشترياتك ومخزونك وخزنتك ومندوبيك في نظام واحد، ويربط كل رقم بمصدره، لتعرف ماذا يحدث في شركتك قبل أن تسأل.
          </m.p>

          <m.div
            initial={{ opacity: 0, y: 14 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ delay: 0.78, duration: 0.7 }}
            className="mt-9 flex flex-wrap items-center justify-end gap-3"
          >
            <PrimaryButton href={signedIn ? "/dashboard" : trialDays ? "/signup?trial=1" : "/signup"} className="rounded-[4px] px-6 py-3.5">
              {signedIn ? "افتح لوحة التحكم" : trialDays ? "ابدأ مجانًا" : "ابدأ الآن"}
              <ArrowLeft size={19} strokeWidth={2} />
            </PrimaryButton>
            {!signedIn && trialDays ? <p className="w-full text-xs text-charcoal/45">تجربة مجانية {trialDays === 1 ? "ليوم واحد" : `لمدة ${trialDays} يومًا`} · بدون بطاقة ائتمان</p> : null}
            <SecondaryLink href="#how" className="rounded-[4px] border border-borderSoft px-5 py-3.5 hover:border-charcoal">
              شاهد كيف يعمل
              <MoveUpLeft size={19} strokeWidth={1.8} />
            </SecondaryLink>
          </m.div>
        </div>

        <m.div style={{ y, rotate, opacity, x: pointerX }} className="relative mx-auto w-full max-w-[650px] lg:mb-[-2.5rem]">
          <m.div style={{ x: useTransform(pointerX, (value) => value * -1.8), y: useTransform(pointerY, (value) => value * -1.8) }} className="pointer-events-none absolute -right-12 -top-12 h-40 w-40 rounded-full border border-sage/30" />
          <div className="absolute -left-3 top-14 z-20 hidden -rotate-6 rounded-[4px] bg-sage px-4 py-3 text-xs font-medium text-ivory shadow-[10px_10px_0_rgba(52,78,65,0.12)] sm:block">
            كل رقم في مكانه
          </div>
          <div className="relative overflow-hidden border border-borderSoft bg-white p-2 shadow-[18px_22px_0_rgba(52,78,65,0.14)]">
            <div className="flex items-center justify-between border-b border-borderSoft px-4 py-3 text-[0.625rem] tracking-[0.16em] text-charcoal/45">
              <span dir="ltr">كيان / نظرة عامة</span>
              <span className="flex items-center gap-2"><span className="h-1.5 w-1.5 rounded-full bg-sage" /> مثال توضيحي</span>
            </div>
            <div className="grid min-h-[463px] gap-4 p-4 sm:grid-cols-[0.85fr_1.15fr] sm:p-5" dir="rtl">
              <div className="flex flex-col justify-between border border-borderSoft p-4">
                <div>
                  <p className="text-xs text-charcoal/45">صافي الربح هذا الشهر</p>
                  <p className="mt-3 text-4xl font-medium tracking-tight text-charcoal" dir="ltr">14,950 <span className="text-base text-charcoal/50">ج.م</span></p>
                </div>
                <div className="flex items-end gap-1.5 pt-12" aria-label="رسم بياني لصافي الربح">
                  {[24, 38, 30, 56, 45, 72, 88].map((height, i) => (
                    <m.span
                      key={height + i}
                      initial={{ height: 0 }}
                      whileInView={{ height: `${height}%` }}
                      viewport={{ once: true }}
                      transition={{ delay: 0.35 + i * 0.06, duration: 0.6, ease: "easeOut" }}
                      className={`w-full ${i === 6 ? "bg-sage" : "bg-sageSoft"}`}
                    />
                  ))}
                </div>
              </div>
              <div className="flex flex-col gap-3">
                <div className="flex items-center justify-between border-b border-borderSoft pb-3">
                  <span className="text-xs text-charcoal/45">آخر الحركات</span>
                  <Sparkles size={19} className="text-sage" />
                </div>
                {[
                  ["فاتورة بيع S-001042", "+ 2,400 ج.م"],
                  ["فاتورة شراء P-000318", "− 8,100 ج.م"],
                  ["تحصيل من عميل", "+ 1,850 ج.م"],
                  ["مصروف — إيجار", "− 620 ج.م"],
                ].map(([label, amount], i) => (
                  <m.div
                    key={label}
                    initial={{ opacity: 0, x: 12 }}
                    whileInView={{ opacity: 1, x: 0 }}
                    viewport={{ once: true }}
                    transition={{ delay: 0.22 + i * 0.1, duration: 0.45 }}
                    className="flex items-center justify-between gap-3 border-b border-borderSoft py-2 text-xs"
                  >
                    <span className="text-charcoal/70">{label}</span>
                    <span className={amount.startsWith("+") ? "text-sage" : "text-charcoal/45"} dir="ltr">{amount}</span>
                  </m.div>
                ))}
              </div>
            </div>
            <div className="flex items-center justify-between border-t border-borderSoft px-4 py-3 text-[0.625rem] text-charcoal/35">
              <span>أرقام توضيحية لشكل الرئيسية</span>
              <span dir="ltr">١٢ وحدة تشغيلية</span>
            </div>
          </div>
          <div className="mt-5 flex items-center justify-between text-xs text-charcoal/40">
            <span>مساحة واحدة لكل قرار مهم.</span>
            <span dir="ltr">مرّر للاستكشاف ↓</span>
          </div>
        </m.div>
      </div>
    </section>
  );
}

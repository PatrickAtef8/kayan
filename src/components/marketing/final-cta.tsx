"use client";

import { m } from "framer-motion";
import { ArrowLeft } from "lucide-react";
import { PrimaryButton } from "./effects/buttons";

export function FinalCta({ signedIn = false }: { signedIn?: boolean }) {
  return (
    <section className="px-6 pb-28 pt-10 sm:pb-36">
      <m.div initial={{ opacity: 0, y: 16 }} whileInView={{ opacity: 1, y: 0 }} viewport={{ once: true }} transition={{ duration: 0.7 }} className="relative mx-auto max-w-6xl overflow-hidden bg-sage px-7 py-14 text-ivory sm:px-14 sm:py-20">
        <div className="pointer-events-none absolute -left-16 -top-20 h-64 w-64 rounded-full border border-ivory/20" />
        <div className="relative z-10 max-w-2xl">
          <p className="mb-5 text-xs tracking-[0.16em] text-ivory/60" dir="ltr">٠٦ / خطوتك التالية</p>
          <h2 className="text-4xl font-medium leading-tight tracking-[-0.04em] sm:text-6xl">جاهز تدير شركتك بشكل مختلف؟</h2>
          <p className="mt-5 text-sm text-ivory/65">بدون بطاقة ائتمان، وبدون التزام. ابدأ من الرقم الذي يهمك اليوم.</p>
          <div className="mt-9"><PrimaryButton href={signedIn ? "/dashboard" : "/signup"} className="rounded-[4px] bg-ivory text-charcoal hover:bg-charcoal hover:text-ivory">{signedIn ? "ارجع إلى لوحة التحكم" : "ابدأ الآن"} <ArrowLeft size={19} strokeWidth={2} /></PrimaryButton></div>
        </div>
        <div className="absolute bottom-7 left-8 hidden text-[0.625rem] tracking-[0.16em] text-ivory/45 sm:block" dir="ltr">كيان / بساطة مدروسة</div>
      </m.div>
    </section>
  );
}

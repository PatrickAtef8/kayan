"use client";

import { m } from "framer-motion";
import { NumberTicker } from "./effects/number-ticker";

const STATS = [
  { value: 11, suffix: "", label: "وحدة إدارية متكاملة", index: "٠١" },
  { value: 100, suffix: "%", label: "واجهة عربية بالكامل", index: "٠٢" },
  { value: 0, suffix: "", label: "أوراق أو ملفات متفرقة", index: "٠٣" },
];

export function Stats() {
  return (
    <section className="border-y border-borderSoft bg-white/45 px-6 py-7">
      <div className="mx-auto grid max-w-6xl divide-y divide-borderSoft md:grid-cols-3 md:divide-x md:divide-y-0 md:divide-x-reverse">
        {STATS.map((s, i) => (
          <m.div
            key={s.label}
            initial={{ opacity: 0, y: 14 }}
            whileInView={{ opacity: 1, y: 0 }}
            viewport={{ once: true }}
            transition={{ delay: i * 0.1, duration: 0.6 }}
            className="flex items-center justify-between gap-6 px-4 py-5 first:pt-0 last:pb-0 md:px-8 md:py-2 md:first:pt-2 md:last:pb-2"
          >
            <span className="text-[0.625rem] tracking-[0.18em] text-charcoal/35" dir="ltr">{s.index}</span>
            <div className="text-right">
              <p className="text-3xl font-medium tracking-tight text-charcoal"><NumberTicker value={s.value} suffix={s.suffix} /></p>
              <p className="mt-1 text-xs text-charcoal/45">{s.label}</p>
            </div>
          </m.div>
        ))}
      </div>
    </section>
  );
}

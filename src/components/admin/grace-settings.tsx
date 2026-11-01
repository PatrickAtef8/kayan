"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import clsx from "clsx";
import { Check, TriangleAlert } from "lucide-react";
import { Card } from "@/components/ui/card";
import { Spinner } from "@/components/ui/spinner";
import { saveGraceSettings } from "@/app/admin/actions";

// The platform-wide grace period. It is applied by the database against its own clock, to every company, from the actual
// subscription end time: during it the company works normally and sees a warning with the time left; after it, access is closed
// until a renewal payment is VERIFIED. 0 hours (or switched off) = closed the moment the subscription ends.
export function GraceSettings({ initial }: { initial: { enabled: boolean; hours: number } }) {
  const router = useRouter();
  const [enabled, setEnabled] = useState(initial.enabled);
  const [hours, setHours] = useState(String(initial.hours));
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [pending, start] = useTransition();
  const n = Number(hours);
  const valid = hours.trim() !== "" && Number.isInteger(n) && n >= 0 && n <= 720;
  const dirty = enabled !== initial.enabled || (valid && n !== initial.hours);
  const effective = enabled && valid && n > 0;

  function save() {
    setMsg(null);
    start(async () => {
      try {
        const r = await saveGraceSettings({ enabled, hours: n });
        if (r.error) setMsg({ ok: false, text: r.error }); else { setMsg({ ok: true, text: r.message ?? "حُفظت." }); router.refresh(); }
      } catch { setMsg({ ok: false, text: "تعذّر الاتصال بالخادم." }); }
    });
  }

  return (
    <Card className="mb-6 p-5">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h2 className="text-base font-semibold text-charcoal">فترة السماح بعد انتهاء الاشتراك</h2>
          <p className="mt-1 max-w-2xl text-xs leading-5 text-charcoal/50">تُحسب من وقت انتهاء الاشتراك الفعلي بتوقيت الخادم. خلالها يعمل العميل بشكل طبيعي مع تنبيه دائم بالوقت المتبقي وزر تجديد؛ وبعدها يُغلق الوصول حتى يتأكد دفع التجديد. الدفع المعلّق أو الفاشل أو الملغي لا يعيد الوصول.</p>
        </div>
        <label className="flex cursor-pointer items-center gap-2 text-sm"><input type="checkbox" checked={enabled} onChange={(e) => setEnabled(e.target.checked)} className="h-4 w-4 accent-[#344E41]" />تفعيل فترة السماح</label>
      </div>
      <div className="mt-4 flex flex-wrap items-end gap-4">
        <label className="block">
          <span className="block text-xs font-medium text-charcoal/70">المدة بالساعات</span>
          <input inputMode="numeric" disabled={!enabled} value={hours} onChange={(e) => setHours(e.target.value)} aria-invalid={!valid}
            className={clsx("num mt-1 w-32 rounded-xl border bg-white px-3 py-2 text-sm outline-none focus:ring-2 disabled:opacity-50", valid ? "border-borderSoft focus:border-sage focus:ring-sage/20" : "border-rose focus:ring-rose/20")} />
        </label>
        <button type="button" onClick={save} disabled={pending || !dirty || !valid} className="inline-flex items-center gap-2 rounded-xl bg-charcoal px-5 py-2.5 text-sm font-medium text-ivory hover:bg-sage disabled:cursor-not-allowed disabled:opacity-50">{pending ? <><Spinner />جارٍ الحفظ…</> : "حفظ"}</button>
        <p className="pb-2 text-xs text-charcoal/50">{effective ? `سماح ${n} ساعة (0 = إغلاق فوري، الحد الأقصى 720).` : "لا سماح: يُغلق الوصول لحظة انتهاء الاشتراك."}</p>
      </div>
      {!valid && <p className="mt-2 text-xs text-rose">أدخل عددًا صحيحًا بين 0 و720.</p>}
      {msg && <p role="alert" className={clsx("mt-3 flex items-start gap-2 text-sm", msg.ok ? "text-sage" : "text-rose")}>{msg.ok ? <Check size={16} className="mt-0.5 shrink-0" /> : <TriangleAlert size={16} className="mt-0.5 shrink-0" />}{msg.text}</p>}
    </Card>
  );
}

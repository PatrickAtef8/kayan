"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import clsx from "clsx";
import { Check, TriangleAlert } from "lucide-react";
import { Card } from "@/components/ui/card";
import { Spinner } from "@/components/ui/spinner";
import { saveTrialSettings } from "@/app/admin/actions";
import { TRIAL_MAX_DAYS, TRIAL_MIN_DAYS } from "@/lib/billing/trial";

// The free trial: switch it on/off (it controls the «ابدأ مجانًا» buttons) and set how many days it lasts (N). The length is copied
// into a company's own record the moment its trial starts, so changing N only affects trials that start afterwards.
export function TrialSettings({ initial }: { initial: { enabled: boolean; days: number } }) {
  const router = useRouter();
  const [enabled, setEnabled] = useState(initial.enabled);
  const [days, setDays] = useState(String(initial.days));
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [pending, start] = useTransition();
  const n = Number(days);
  const valid = days.trim() !== "" && Number.isInteger(n) && n >= TRIAL_MIN_DAYS && n <= TRIAL_MAX_DAYS;
  const dirty = enabled !== initial.enabled || (valid && n !== initial.days);

  function save() {
    setMsg(null);
    start(async () => {
      try {
        const r = await saveTrialSettings({ enabled, days: n });
        if (r.error) setMsg({ ok: false, text: r.error }); else { setMsg({ ok: true, text: r.message ?? "حُفظت." }); router.refresh(); }
      } catch { setMsg({ ok: false, text: "تعذّر الاتصال بالخادم." }); }
    });
  }

  return (
    <Card className="mb-6 p-5">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h2 className="text-base font-semibold text-charcoal">التجربة المجانية</h2>
          <p className="mt-1 max-w-2xl text-xs leading-5 text-charcoal/50">يضغط الزائر «ابدأ مجانًا» ويُنشئ حسابه ويستخدم لوحة التحكم بكل وحداتها طوال المدة. عند انتهائها يُغلق الدخول إلى لوحة التحكم وتظهر رسالة تطلب الاشتراك، وتبقى بياناته محفوظة وتعود فور الاشتراك. لكل حساب تجربة واحدة. تسري المدة الجديدة على التجارب التي تبدأ بعد الحفظ فقط، ويمكنك تمديد تجربة شركة بعينها من صفحتها.</p>
        </div>
        <label className="flex cursor-pointer items-center gap-2 text-sm"><input type="checkbox" checked={enabled} onChange={(e) => setEnabled(e.target.checked)} className="h-4 w-4 accent-[#344E41]" />تفعيل التجربة المجانية</label>
      </div>
      <div className="mt-4 flex flex-wrap items-end gap-4">
        <label className="block">
          <span className="block text-xs font-medium text-charcoal/70">المدة بالأيام (N)</span>
          <input inputMode="numeric" disabled={!enabled} value={days} onChange={(e) => setDays(e.target.value)} aria-invalid={!valid}
            className={clsx("num mt-1 w-32 rounded-xl border bg-white px-3 py-2 text-sm outline-none focus:ring-2 disabled:opacity-50", valid ? "border-borderSoft focus:border-sage focus:ring-sage/20" : "border-rose focus:ring-rose/20")} />
        </label>
        <button type="button" onClick={save} disabled={pending || !dirty || !valid} className="inline-flex items-center gap-2 rounded-xl bg-charcoal px-5 py-2.5 text-sm font-medium text-ivory hover:bg-sage disabled:cursor-not-allowed disabled:opacity-50">{pending ? <><Spinner />جارٍ الحفظ…</> : "حفظ"}</button>
        <p className="pb-2 text-xs text-charcoal/50">{enabled && valid ? `تجربة ${n} يومًا لكل شركة جديدة.` : "التجربة متوقفة: لا يظهر زر «ابدأ مجانًا»."}</p>
      </div>
      {!valid && <p className="mt-2 text-xs text-rose">أدخل عددًا صحيحًا من {TRIAL_MIN_DAYS} إلى {TRIAL_MAX_DAYS}.</p>}
      {msg && <p role="alert" className={clsx("mt-3 flex items-start gap-2 text-sm", msg.ok ? "text-sage" : "text-rose")}>{msg.ok ? <Check size={16} className="mt-0.5 shrink-0" /> : <TriangleAlert size={16} className="mt-0.5 shrink-0" />}{msg.text}</p>}
    </Card>
  );
}

import { Card } from "@/components/ui/card";
import { eventLabel, eventStatus, pulseHealth, relativeAr, summarize, type Health, type Tone, type WebhookRow } from "@/lib/billing/webhook-activity";

// «نبض المدفوعات»: is XPay actually talking to Kayan? One look tells the Super Admin (a) the webhook is alive, (b) what happened in the
// last seven days, (c) whether anything needs a human (a mismatching amount, a refund made at XPay, an event that never finished).
// Server component: no JavaScript is shipped for it (the setup helper is a plain <details>).

const REQUIRED = [
  ["checkout.session.completed", "اكتمل الدفع (بطاقة أو دفع فوري)"],
  ["checkout.session.async_payment_succeeded", "العميل سدّد لاحقًا، مثل فوري"],
  ["checkout.session.async_payment_failed", "لم يسدّد العميل في المهلة"],
  ["checkout.session.expired", "انتهت جلسة الدفع بلا سداد"],
] as const;

const CHIP: Record<Tone, string> = {
  ok: "bg-sageSoft text-sage",
  wait: "bg-amber-50 text-amber-700",
  bad: "bg-rose/10 text-rose",
  attention: "bg-amber-100 text-amber-800",
  neutral: "bg-ivory text-charcoal/60",
};

const DOT: Record<Health, string> = { ok: "bg-sage", attention: "bg-amber-500", idle: "bg-charcoal/25" };

function PulseDot({ health }: { health: Health }) {
  return (
    <span className="relative flex h-3 w-3 shrink-0" aria-hidden>
      {health !== "idle" && <span className={`absolute inline-flex h-full w-full animate-ping rounded-full opacity-50 ${DOT[health]}`} />}
      <span className={`relative inline-flex h-3 w-3 rounded-full ${DOT[health]}`} />
    </span>
  );
}

export function PaymentsPulse({ activity, mode, endpoint }: {
  activity: { recent: WebhookRow[]; week: WebhookRow[]; nowMs: number } | null;
  mode: "test" | "live" | "unset";
  endpoint: string;
}) {
  const nowMs = activity?.nowMs ?? 0;
  const summary = activity ? summarize(activity.week, nowMs) : null;
  const last = activity?.recent[0] ?? null;
  const health: Health = activity && summary ? pulseHealth(activity.recent.length > 0, summary) : "idle";
  const subtitle = !activity ? "تعذّرت قراءة سجل الأحداث الآن"
    : !last ? "لم تصل أي إشارة من XPay بعد"
    : health === "attention" ? "هناك ما يحتاج مراجعتك"
    : `آخر إشارة من XPay ${relativeAr(last.received_at, nowMs)}`;
  const maxBar = Math.max(1, ...(summary?.days.map((d) => d.paid) ?? [1]));

  return (
    <Card className="mt-4 overflow-hidden p-0 sm:p-0">
      <div className="flex flex-wrap items-center justify-between gap-3 border-b border-borderSoft px-5 py-4">
        <div className="flex items-center gap-3">
          <PulseDot health={health} />
          <div>
            <h2 className="text-base font-semibold">نبض المدفوعات</h2>
            <p className="mt-0.5 text-xs text-charcoal/50">{subtitle}</p>
          </div>
        </div>
        <span className={`px-2.5 py-1 text-xs font-medium ${mode === "live" ? "bg-sageSoft text-sage" : mode === "test" ? "bg-amber-100 text-amber-800" : "bg-ivory text-charcoal/55"}`}>
          {mode === "live" ? "وضع حقيقي (live)" : mode === "test" ? "وضع تجريبي (test)" : "غير مضبوط"}
        </span>
      </div>

      {summary && activity && activity.recent.length > 0 && (
        <>
          <div className="grid grid-cols-2 gap-px bg-borderSoft sm:grid-cols-4">
            {([
              ["مدفوعات مؤكدة", summary.paid, "text-sage"],
              ["بانتظار سداد العميل", summary.awaiting, "text-amber-700"],
              ["فاشلة أو منتهية", summary.failed, "text-charcoal"],
              ["تحتاج انتباهك", summary.attention, summary.attention > 0 ? "text-rose" : "text-charcoal"],
            ] as const).map(([label, value, color]) => (
              <div key={label} className="bg-white px-5 py-4">
                <p className="text-xs text-charcoal/45">{label}</p>
                <p className={`num mt-1.5 text-2xl font-semibold tracking-tight ${color}`}>{value}</p>
              </div>
            ))}
          </div>
          <p className="px-5 pt-3 text-[0.6875rem] text-charcoal/40">أحداث آخر ٧ أيام</p>

          <div className="border-b border-borderSoft px-5 pb-4 pt-3">
            <p className="text-xs text-charcoal/50">المدفوعات المؤكدة يوميًا</p>
            <div className="mt-3 flex h-20 items-end gap-2" role="img" aria-label="المدفوعات المؤكدة في آخر سبعة أيام">
              {summary.days.map((d) => (
                <div key={d.key} className="flex h-full min-w-0 flex-1 flex-col items-center justify-end gap-1.5" title={`${d.key}: ${d.paid}`}>
                  <span className="num text-[0.625rem] text-charcoal/45">{d.paid > 0 ? d.paid : ""}</span>
                  <div className={`w-full ${d.paid > 0 ? "bg-sage" : "bg-sageSoft"}`} style={{ height: `${d.paid > 0 ? Math.max(12, (d.paid / maxBar) * 100) : 6}%` }} />
                  <span className="text-[0.625rem] text-charcoal/45">{d.label}</span>
                </div>
              ))}
            </div>
          </div>

          <ul className="divide-y divide-borderSoft text-sm">
            {activity.recent.map((r, i) => {
              const st = eventStatus(r, nowMs);
              return (
                <li key={i} className="flex flex-wrap items-center justify-between gap-x-3 gap-y-1.5 px-5 py-3">
                  <div className="flex min-w-0 items-center gap-2.5">
                    <span className={`shrink-0 px-2 py-0.5 text-xs font-medium ${CHIP[st.tone]}`}>{st.label}</span>
                    <span className="truncate text-charcoal/75">{eventLabel(r.event_type)}</span>
                  </div>
                  <span className="text-xs text-charcoal/45">{relativeAr(r.received_at, nowMs)}</span>
                </li>
              );
            })}
          </ul>
        </>
      )}

      <details className="group border-t border-borderSoft" open={!last}>
        <summary className="flex cursor-pointer list-none items-center justify-between px-5 py-3.5 text-sm font-medium text-sage hover:bg-ivory/60 [&::-webkit-details-marker]:hidden">
          <span>{last ? "إعداد الـ webhook في XPay" : "ابدأ من هنا: اربط XPay بكيان"}</span>
          <span className="text-xs text-charcoal/40 transition-transform group-open:rotate-180">⌄</span>
        </summary>
        <div className="space-y-4 px-5 pb-5 text-sm text-charcoal/70">
          <div>
            <p className="text-xs text-charcoal/45">عنوان الـ endpoint</p>
            <p className="mt-1.5 select-all break-all border border-borderSoft bg-ivory px-3 py-2 text-xs text-charcoal" dir="ltr">{endpoint}</p>
          </div>
          <div>
            <p className="text-xs text-charcoal/45">الأحداث المطلوبة (4 فقط)</p>
            <ul className="mt-1.5 space-y-1.5">
              {REQUIRED.map(([type, what]) => (
                <li key={type} className="flex flex-wrap items-baseline gap-x-2 gap-y-0.5">
                  <code className="select-all bg-ivory px-1.5 py-0.5 text-[0.6875rem] text-charcoal" dir="ltr">{type}</code>
                  <span className="text-xs text-charcoal/55">{what}</span>
                </li>
              ))}
            </ul>
          </div>
          <p className="text-xs leading-6 text-charcoal/50">اختياري: أضف أحداث الاسترداد (refund) وحجز المخاطر، فتظهر هنا للمراجعة. لا تمنح ولا تسحب أي اشتراك تلقائيًا. بعد الحفظ انسخ مفتاح التوقيع <code className="bg-ivory px-1" dir="ltr">whsec_xxx</code> إلى <code className="bg-ivory px-1" dir="ltr">XPAY_WEBHOOK_SECRET</code> في Vercel.</p>
        </div>
      </details>
    </Card>
  );
}

// Pure helpers for the Super Admin «نبض المدفوعات» panel: they turn rows of billing_webhook_events into Arabic labels, counters and a
// 7-day series. No Next.js / Supabase import, so plain Node tests them (see webhook-activity.test.ts).

export type WebhookRow = { event_type: string; outcome: string | null; received_at: string; processed_at: string | null; attempts?: number | null };
export type Tone = "ok" | "wait" | "bad" | "attention" | "neutral";
export type Status = { label: string; tone: Tone };

/** An event that was received but not finished after this long is stuck (XPay will retry, but a human should know). */
export const STUCK_AFTER_MS = 10 * 60 * 1000;

const EVENT_LABEL: Record<string, string> = {
  "checkout.session.completed": "اكتمل الدفع",
  "checkout.session.async_payment_succeeded": "نجح دفع مؤجّل (فوري)",
  "checkout.session.async_payment_failed": "فشل دفع مؤجّل (فوري)",
  "checkout.session.expired": "انتهت جلسة الدفع",
};

export function eventLabel(type: string): string {
  if (EVENT_LABEL[type]) return EVENT_LABEL[type];
  if (/^refund\./.test(type) || type === "charge.refunded") return "استرداد";
  if (/^charge\.dispute/.test(type)) return "نزاع على دفعة";
  if (/^payment\.(held|hold)/.test(type)) return "حجز مخاطر على دفعة";
  return type;
}

const OUTCOME: Record<string, Status> = {
  applied: { label: "تم تسجيل الدفع", tone: "ok" },
  already_applied: { label: "سبق تسجيله", tone: "neutral" },
  awaiting_payment: { label: "بانتظار سداد العميل", tone: "wait" },
  session_open: { label: "الجلسة ما زالت مفتوحة", tone: "neutral" },
  expired: { label: "أُغلق الطلب: انتهت المهلة", tone: "neutral" },
  already_closed: { label: "الطلب مغلق مسبقًا", tone: "neutral" },
  not_paid: { label: "بدون دفع", tone: "neutral" },
  failed_marked: { label: "فشل الدفع", tone: "bad" },
  unknown_order: { label: "لا يوجد طلب مطابق", tone: "attention" },
  session_mismatch: { label: "الجلسة لا تطابق الطلب", tone: "attention" },
  amount_mismatch: { label: "المبلغ لا يطابق: للمراجعة", tone: "attention" },
  needs_attention: { label: "راجعه في لوحة XPay", tone: "attention" },
  duplicate: { label: "تسليم مكرر", tone: "neutral" },
};

/** What to show next to one event: its outcome, or «processing» / «stuck» while it has no outcome yet. */
export function eventStatus(row: Pick<WebhookRow, "outcome" | "processed_at" | "received_at">, nowMs: number): Status {
  if (!row.processed_at) {
    const age = nowMs - Date.parse(row.received_at);
    return age > STUCK_AFTER_MS ? { label: "لم يكتمل: XPay سيعيد المحاولة", tone: "attention" } : { label: "قيد المعالجة", tone: "wait" };
  }
  return (row.outcome && OUTCOME[row.outcome]) || { label: row.outcome ?? "تمت المعالجة", tone: "neutral" };
}

export type DayBucket = { key: string; label: string; paid: number; other: number };
export type Summary = { total: number; paid: number; awaiting: number; failed: number; attention: number; days: DayBucket[]; lastReceivedAt: string | null };

const cairoDay = new Intl.DateTimeFormat("en-CA", { timeZone: "Africa/Cairo", year: "numeric", month: "2-digit", day: "2-digit" });
const cairoWeekday = new Intl.DateTimeFormat("ar-EG", { timeZone: "Africa/Cairo", weekday: "short" });

/** Counters and a 7-day series (Cairo days, oldest first) for the rows received in the last seven days. */
export function summarize(rows: WebhookRow[], nowMs: number): Summary {
  const days: DayBucket[] = [];
  for (let i = 6; i >= 0; i--) {
    const ms = nowMs - i * 86_400_000;
    const key = cairoDay.format(new Date(ms));
    if (!days.some((d) => d.key === key)) days.push({ key, label: cairoWeekday.format(new Date(ms)), paid: 0, other: 0 });
  }
  const s: Summary = { total: 0, paid: 0, awaiting: 0, failed: 0, attention: 0, days, lastReceivedAt: null };
  for (const r of rows) {
    const t = Date.parse(r.received_at);
    if (Number.isNaN(t) || t > nowMs + 60_000 || nowMs - t > 7 * 86_400_000) continue;
    s.total++;
    if (!s.lastReceivedAt || t > Date.parse(s.lastReceivedAt)) s.lastReceivedAt = r.received_at;
    const status = eventStatus(r, nowMs);
    if (r.outcome === "applied") s.paid++;
    else if (r.outcome === "awaiting_payment") s.awaiting++;
    else if (r.outcome === "failed_marked" || r.outcome === "expired") s.failed++;
    if (status.tone === "attention") s.attention++;
    const day = days.find((d) => d.key === cairoDay.format(new Date(t)));
    if (day) { if (r.outcome === "applied") day.paid++; else day.other++; }
  }
  return s;
}

export type Health = "idle" | "ok" | "attention";
export function pulseHealth(hasAnyEvent: boolean, s: Summary): Health {
  if (!hasAnyEvent) return "idle";
  return s.attention > 0 ? "attention" : "ok";
}

function plural(n: number, one: string, two: string, few: string, many: string): string {
  if (n === 1) return `منذ ${one}`;
  if (n === 2) return `منذ ${two}`;
  return n >= 3 && n <= 10 ? `منذ ${n} ${few}` : `منذ ${n} ${many}`;
}

/** «منذ ٣ دقائق» — in Arabic number agreement (digits stay Western, like the rest of the admin area). */
export function relativeAr(iso: string, nowMs: number): string {
  const sec = Math.floor((nowMs - Date.parse(iso)) / 1000);
  if (!Number.isFinite(sec) || sec < 45) return "الآن";
  const min = Math.round(sec / 60);
  if (min < 60) return plural(min, "دقيقة", "دقيقتين", "دقائق", "دقيقة");
  const hours = Math.round(min / 60);
  if (hours < 24) return plural(hours, "ساعة", "ساعتين", "ساعات", "ساعة");
  const days = Math.round(hours / 24);
  if (days < 30) return plural(days, "يوم", "يومين", "أيام", "يومًا");
  return new Intl.DateTimeFormat("ar-EG", { dateStyle: "medium", timeZone: "Africa/Cairo" }).format(new Date(iso));
}

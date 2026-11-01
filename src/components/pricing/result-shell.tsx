import Link from "next/link";
import { Card } from "@/components/ui/card";

export function ResultShell({ icon, tone, title, children }: { icon: React.ReactNode; tone: "ok" | "wait" | "bad"; title: string; children: React.ReactNode }) {
  const c = tone === "ok" ? "bg-sageSoft text-sage" : tone === "wait" ? "bg-amber-50 text-amber-800" : "bg-rose/10 text-rose";
  return (
    <div className="mx-auto max-w-xl pt-4 sm:pt-10">
      <Card className="p-6 text-center sm:p-10 sm:text-right" aria-live="polite">
        <span className={`mx-auto mb-5 flex h-12 w-12 items-center justify-center rounded-full sm:mx-0 ${c}`}>{icon}</span>
        <h1 className="mb-3 text-2xl font-semibold tracking-tight text-charcoal">{title}</h1>
        <div className="text-start">{children}</div>
      </Card>
    </div>
  );
}

export const linkPrimary = "rounded-xl bg-charcoal px-5 py-2.5 text-sm font-medium text-ivory hover:bg-sage";
export const linkSecondary = "rounded-xl border border-borderSoft bg-white px-5 py-2.5 text-sm font-medium text-charcoal hover:border-sage";

export function OrderNotFound() {
  return (
    <ResultShell icon={<span className="text-xl">!</span>} tone="bad" title="لم نجد هذا الطلب">
      <p className="text-sm leading-7 text-charcoal/60">الرابط غير صحيح أو أنه يخص حسابًا آخر.</p>
      <div className="mt-6"><Link href="/dashboard/billing" className={linkPrimary}>الباقة والمدفوعات</Link></div>
    </ResultShell>
  );
}

/** "KY-3F9A1C2B": a short, stable reference the customer can quote to support (the end of the order id). */
export const orderRef = (id: string) => `KY-${id.replace(/-/g, "").slice(-8).toUpperCase()}`;

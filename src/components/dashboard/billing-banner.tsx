import Link from "next/link";
import { CalendarClock } from "lucide-react";
import { daysUntil, type DbAccess } from "@/lib/billing/license-status";

// Owner-only reminder that the paid period is about to end (the grace-period warning is GraceBanner, shown to every member).
export function BillingBanner({ access }: { access: DbAccess }) {
  if (access.state !== "active" || !access.paidThrough) return null;
  const left = daysUntil(access.paidThrough);
  if (left === null || left > 5) return null;
  return (
    <div role="status" className="mb-5 flex flex-col gap-2 rounded-2xl border border-amber-200 bg-amber-50 px-4 py-3 text-sm text-amber-900 sm:flex-row sm:items-center sm:justify-between">
      <span className="flex items-center gap-2"><CalendarClock size={16} className="shrink-0" />{left <= 1 ? "تنتهي الفترة المدفوعة خلال أقل من يوم." : `يتبقى ${left} أيام على انتهاء الفترة المدفوعة.`}</span>
      <Link href="/checkout?renew=1" className="font-medium underline underline-offset-4">جدّد الآن</Link>
    </div>
  );
}

"use client";

import { useEffect, useState } from "react";
import Link from "next/link";
import { TriangleAlert } from "lucide-react";
import { remainingText } from "@/lib/billing/license-status";

// Persistent warning shown above every page while the subscription is past its end but still inside the grace period. The remaining
// time is the DATABASE's figure (seconds_left, from its own clock) at the moment the page was rendered, counted down locally so it
// stays correct without asking again; when it reaches zero the next request is locked by the server, whatever this banner says.
export function GraceBanner({ secondsLeft, isOwner, monthly }: { secondsLeft: number; isOwner: boolean; monthly: boolean }) {
  const [left, setLeft] = useState(secondsLeft);
  useEffect(() => {
    const end = Date.now() + secondsLeft * 1000;
    const tick = () => setLeft(Math.max(0, Math.round((end - Date.now()) / 1000)));
    tick();
    const id = setInterval(tick, 15000);
    return () => clearInterval(id);
  }, [secondsLeft]);
  return (
    <div role="alert" className="mb-5 flex flex-col gap-3 rounded-2xl border border-rose/30 bg-rose/5 px-4 py-3 text-sm text-rose sm:flex-row sm:items-center sm:justify-between">
      <span className="flex items-start gap-2 leading-6">
        <TriangleAlert size={17} className="mt-1 shrink-0" />
        <span>
          {monthly ? "انتهى اشتراكك" : "انتهت فترة الاستضافة والصيانة المدفوعة"} وأنت الآن في فترة السماح. يتبقى <strong className="num">{remainingText(left)}</strong> قبل إيقاف الوصول إلى النظام حتى تجديد الاشتراك.
        </span>
      </span>
      {isOwner
        ? <Link href="/checkout?renew=1" className="shrink-0 rounded-xl bg-rose px-4 py-2 text-center font-medium text-white hover:opacity-90">جدّد الآن</Link>
        : <span className="shrink-0 text-xs">يرجى التواصل مع مالك الحساب للتجديد.</span>}
    </div>
  );
}

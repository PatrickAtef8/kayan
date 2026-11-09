"use client";

import { useEffect, useState } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { Gift } from "lucide-react";
import { trialCountdownText, trialIsUrgent } from "@/lib/billing/trial";

// Shown above every dashboard page, to every member, for as long as the free trial runs. `secondsLeft` is the DATABASE's figure (its own
// clock) at the moment the page was rendered; it is counted down here every few seconds so it stays correct while people work, and re-read from the server every 3 minutes so a trial extended by the Super Admin shows up without a reload.
// When it reaches zero the layout is re-evaluated on the server (router.refresh): the database has already closed the company, so the
// user lands on «انتهت فترتك التجريبية — اشترك الآن» instead of meeting errors. The server and the database decide, never this banner.
export function TrialBanner({ secondsLeft, isOwner }: { secondsLeft: number; isOwner: boolean }) {
  const router = useRouter();
  const [left, setLeft] = useState(secondsLeft);
  useEffect(() => {
    const end = Date.now() + secondsLeft * 1000;
    let id: ReturnType<typeof setTimeout>;
    const tick = () => {
      const l = Math.max(0, Math.ceil((end - Date.now()) / 1000));
      setLeft(l);
      if (l === 0) { router.refresh(); id = setTimeout(tick, 5000); return; }   // keep asking until the server says it is closed
      id = setTimeout(tick, l <= 120 ? 1000 : 15000);
    };
    tick();
    return () => clearTimeout(id);
  }, [secondsLeft, router]);

  // Re-sync with the server every 3 minutes (and when the tab comes back to the front): if the Super Admin extended this company's trial,
  // the new end date arrives here as a fresh `secondsLeft` and the countdown restarts from it. Skipped while the tab is hidden.
  useEffect(() => {
    let last = Date.now();
    const sync = () => { last = Date.now(); router.refresh(); };
    const id = setInterval(() => { if (document.visibilityState === "visible") sync(); }, 180_000);
    const onVisible = () => { if (document.visibilityState === "visible" && Date.now() - last > 60_000) sync(); };
    document.addEventListener("visibilitychange", onVisible);
    return () => { clearInterval(id); document.removeEventListener("visibilitychange", onVisible); };
  }, [router]);

  const urgent = trialIsUrgent(left);
  return (
    <div role="status" className={`mb-5 flex flex-col gap-2 rounded-2xl border px-4 py-3 text-sm sm:flex-row sm:items-center sm:justify-between ${urgent ? "border-amber-200 bg-amber-50 text-amber-900" : "border-sage/30 bg-sageSoft/50 text-charcoal/80"}`}>
      <span className="flex items-start gap-2 leading-6">
        <Gift size={16} className="mt-1 shrink-0" />
        <span>تجربة مجانية — يتبقى <strong className="num">{trialCountdownText(left)}</strong> على انتهائها. بياناتك تبقى كما هي عند الاشتراك.</span>
      </span>
      {isOwner
        ? <Link href="/dashboard/billing" className="shrink-0 font-medium underline underline-offset-4">اشترك الآن</Link>
        : <span className="shrink-0 text-xs">للاستمرار بعد انتهائها يلزم أن يشترك مالك الحساب.</span>}
    </div>
  );
}

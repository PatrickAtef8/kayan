import Link from "next/link";
import { Gift } from "lucide-react";
import { trialIsUrgent, trialLeftText } from "@/lib/billing/trial";

// Shown above every dashboard page, to every member, for as long as the free trial runs. The time left is the DATABASE's figure
// (seconds_left, its own clock) at the moment the page was rendered; when the trial ends the next request is closed by the server
// and by the database, whatever this banner says. Only the owner can subscribe, so everyone else is told to ask the owner.
export function TrialBanner({ secondsLeft, isOwner }: { secondsLeft: number; isOwner: boolean }) {
  const urgent = trialIsUrgent(secondsLeft);
  return (
    <div role="status" className={`mb-5 flex flex-col gap-2 rounded-2xl border px-4 py-3 text-sm sm:flex-row sm:items-center sm:justify-between ${urgent ? "border-amber-200 bg-amber-50 text-amber-900" : "border-sage/30 bg-sageSoft/50 text-charcoal/80"}`}>
      <span className="flex items-center gap-2 leading-6"><Gift size={16} className="shrink-0" />تجربة مجانية — {trialLeftText(secondsLeft)}. بياناتك تبقى كما هي عند الاشتراك.</span>
      {isOwner
        ? <Link href="/dashboard/billing" className="shrink-0 font-medium underline underline-offset-4">اشترك الآن</Link>
        : <span className="shrink-0 text-xs">للاستمرار بعد انتهائها يلزم أن يشترك مالك الحساب.</span>}
    </div>
  );
}

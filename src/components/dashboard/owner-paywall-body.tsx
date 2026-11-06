"use client";

import { usePathname } from "next/navigation";
import { isBillingPath } from "@/lib/billing/access-gate";
import { OwnerPayPrompt, type PromptReason, type PromptTrial } from "@/components/dashboard/paywall";

// The dashboard LAYOUT is not rendered again when the owner moves between pages (Next.js keeps layouts mounted and only swaps the
// page), so a decision made there from the URL goes stale: the "activate your account" card stayed on screen after clicking its
// button, because the layout still believed the owner was on /dashboard. The decision therefore lives here, in the browser, where
// the current path is always known:
//   • on a billing page  → show the page (choose a package, pay, come back from XPay);
//   • anywhere else      → show the "activate your account" card, whose button opens the billing page.
// Nothing here navigates by itself: the owner reads the card and presses the button. (An automatic redirect used to fire right after
// the card rendered, so it flashed by and the billing page appeared on its own.)
// This is only the friendly front door. The payment gate itself (layout on every render + the database on every table and RPC)
// is unchanged, so skipping this component would open nothing.
export function OwnerPaywallBody({ children, reason, trial }: { children: React.ReactNode; reason?: PromptReason; trial?: PromptTrial }) {
  const pathname = usePathname();
  return isBillingPath(pathname) ? <>{children}</> : <OwnerPayPrompt reason={reason} trial={trial} />;
}

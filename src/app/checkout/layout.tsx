import type { Metadata } from "next";
import { PaywallShell } from "@/components/dashboard/paywall";
import { getCheckoutContext } from "@/lib/billing/checkout-context.server";

export const metadata: Metadata = { title: "إتمام الطلب — كيان", robots: { index: false, follow: false } };

// Every /checkout page is for a signed-in customer (the proxy sends visitors to /login; this re-checks on the server).
// It sits OUTSIDE /dashboard on purpose: an unpaid company is locked out of the dashboard but must reach these pages.
export default async function CheckoutLayout({ children }: { children: React.ReactNode }) {
  const ctx = await getCheckoutContext();
  return <PaywallShell orgName={ctx.access?.orgName ?? undefined} userEmail={ctx.user.email}>{children}</PaywallShell>;
}

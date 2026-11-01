import { redirect } from "next/navigation";

// The old return URL (orders whose XPay page was opened before the /checkout pages existed). It only forwards; the checkout
// pages do the verification.
export default async function LegacyBillingReturn({ searchParams }: { searchParams: Promise<{ order?: string; status?: string }> }) {
  const sp = await searchParams;
  const q = sp.order && /^[0-9a-f-]{36}$/i.test(sp.order) ? `?order=${encodeURIComponent(sp.order)}` : "";
  redirect(sp.status === "failed" ? `/checkout/fail${q}` : `/checkout/success${q}`);
}

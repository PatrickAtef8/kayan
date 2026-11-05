import { NextResponse, type NextRequest } from "next/server";
import { verifyWebhookSignature } from "@/lib/billing/webhook-signature";
import { handleXpayEvent, isHandledEventType, type XpayEvent } from "@/lib/billing/reconcile";
import { createSupabaseBillingStore } from "@/lib/billing/store.server";
import { getXpay, xpayWebhookSecret } from "@/lib/billing/xpay.server";
import { notifyPaymentRecorded } from "@/lib/billing/notify.server";

// XPay → Kayan. https://docs.xpay.app/en/integrate/integration-patterns/hosted-checkout#confirm-with-a-webhook
//
//   1. read the RAW body (the signature covers the exact bytes XPay sent — never re-serialise parsed JSON)
//   2. verify `XPay-Signature` (HMAC-SHA256, 5-minute replay window, constant-time compare) → otherwise 400
//   3. skip an event id we already processed (XPay retries and replays deliveries)
//   4. ask XPay for the session itself and act on THAT answer, never on the body of the webhook
//   5. 200 when done / duplicate / irrelevant; 500 only for transient failures, so XPay retries
//
// No cookie, no user session: this route is authenticated by the signature alone. It is excluded from nothing —
// proxy.ts only redirects /dashboard routes, so XPay can reach it.
export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function POST(request: NextRequest) {
  let secret: string;
  try {
    secret = xpayWebhookSecret();
  } catch (e) {
    console.error("billing webhook: not configured —", e instanceof Error ? e.message : e);
    return NextResponse.json({ error: "webhook not configured" }, { status: 500 });
  }

  // refuse an oversized delivery before buffering it (the check after reading stays for chunked bodies without a length)
  if (Number(request.headers.get("content-length") ?? 0) > 1_000_000) return NextResponse.json({ error: "payload too large" }, { status: 413 });
  const raw = await request.text();
  if (raw.length > 1_000_000) return NextResponse.json({ error: "payload too large" }, { status: 413 });

  const verdict = verifyWebhookSignature(raw, request.headers.get("xpay-signature"), secret);
  if (!verdict.ok) {
    console.warn("billing webhook: rejected —", verdict.reason);
    return NextResponse.json({ error: "invalid signature" }, { status: 400 });
  }

  let event: XpayEvent;
  try {
    event = JSON.parse(raw) as XpayEvent;
  } catch {
    return NextResponse.json({ error: "invalid payload" }, { status: 400 });
  }

  // events we do not act on are acknowledged without touching the database or XPay (no pointless retries)
  if (!isHandledEventType(event?.type)) return NextResponse.json({ received: true, outcome: "ignored_type" }, { status: 200 });

  let result;
  try {
    result = await handleXpayEvent(event, {
      store: createSupabaseBillingStore(),
      xpay: getXpay(),
      log: (msg, meta) => console.error(msg, meta ?? {}),
      onPaymentRecorded: notifyPaymentRecorded,
    });
  } catch (e) {
    // the store or the XPay client could not even be created (missing service-role key / secret key): retry later
    console.error("billing webhook: could not start —", e instanceof Error ? e.message : e);
    return NextResponse.json({ error: "temporarily unavailable" }, { status: 500 });
  }
  return NextResponse.json({ received: true, outcome: result.outcome }, { status: result.status });
}

// Anything else on this URL is a mistake, not an attack surface: say so.
export function GET() {
  return NextResponse.json({ error: "method not allowed" }, { status: 405, headers: { Allow: "POST" } });
}

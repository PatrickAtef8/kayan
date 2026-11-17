# الدفع داخل الموقع — In-page payment on Kayan's own page (XPay drop-in, inline)

Off by default. Set `XPAY_PUBLISHABLE_KEY` (pk_live_… with sk_live_…, pk_test_… with sk_test_…) and redeploy; remove it to go back to XPay's own page.

The flow: `/checkout` (review + accept the terms) → **`/checkout/pay`** (Kayan's page, XPay's form embedded in it) → `/checkout/success` (verified result).

* `src/app/checkout/pay/page.tsx` + `pay-view.tsx` — the new step-2 page: a 3-step indicator, the amount first (also on phones), XPay's form in a card, an order
  summary with the lines (shown only when they add up to the order total), the company, the order reference and a «تعديل الطلب» link. The page reads the order
  (own company only), sends paid / expired / hosted sessions where they belong, reads the session back from XPay for its clientSecret (never stored).
* `src/components/pricing/inline-payment.tsx` — mounts the form; skeleton while loading; a calm «تعذّر تحميل نموذج الدفع» with retry and a way back (ad blocker /
  offline / 25 s with no form); a «تم استلام الدفع… جارٍ تأكيد اشتراكك» overlay while the browser goes to the result page; Kayan's colours inside XPay's form.
* `src/lib/billing/xpay-sdk.ts` — client-safe loader for `https://checkout.xpay.app/v1/sdk.js` (once per page, failures can be retried) and `mountInlineCheckout`. No dependency added.
* `src/lib/billing/checkout.server.ts` — when the key is set the session is created `embedded` (no cancelUrl, no stored page address) and the customer is sent to `/checkout/pay`;
  otherwise exactly as before. `actions.ts` and `checkout-button.tsx` are unchanged from before the in-page work.
* `src/lib/billing/xpay-client.ts` — `ui: "embedded"` body + `clientSecret` parsing; `xpay-guard.ts` — `embeddedCheckout(env)`: on only for a well-formed pk_ key of the same mode as the secret key.
* `src/app/checkout/page.tsx` — the line under the button says the payment is completed inside Kayan when the feature is on. `src/app/admin/page.tsx` — the readiness card shows whether it is on.
* `src/lib/security/csp.ts`, `next.config.mjs` — XPay's hosts in the CSP; `Permissions-Policy payment` allowed for XPay (Apple Pay).
* Tests: billing (embedded body / clientSecret / createCheckoutSession), guard (key rules), `xpay-sdk.test.ts` (loader, failure, inline mount options), csp.
* No database migration. The webhook is unchanged and remains the only thing that marks an order paid.

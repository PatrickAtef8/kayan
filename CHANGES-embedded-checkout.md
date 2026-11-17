# الدفع داخل الموقع — In-page payment window (XPay drop-in)

Off by default. Set `XPAY_PUBLISHABLE_KEY` (pk_live_… with sk_live_…, pk_test_… with sk_test_…) and redeploy; remove it to go back to XPay's own page.

* `lib/billing/xpay-client.ts` — `ui: "embedded"` builds the session with `uiMode: "embedded"` and NO `cancelUrl` (XPay rejects it); `clientSecret` is parsed; an
  embedded session is valid with a clientSecret (a hosted one still needs its url).
* `lib/billing/xpay-guard.ts` — `embeddedCheckout(env)`: on only for a well-formed pk_ key of the same mode as the secret key; a wrong key is a warning, never a blocker.
* `lib/billing/checkout.server.ts` + `app/dashboard/billing/actions.ts` — `StartResult` is `redirect | embedded`; an embedded session stores no page address and is
  resumed by reading it back from XPay (its clientSecret); a session that is already paid goes to the result page; an expired one asks the customer to start again.
* `lib/billing/xpay-sdk.ts` — client-safe loader for `https://checkout.xpay.app/v1/sdk.js` (once per page, failures can be retried) and `openEmbeddedCheckout`
  (Arabic, Kayan's green). No dependency added.
* `components/pricing/checkout-button.tsx` — opens the window; on completion goes to `/checkout/success?order=…`; closing re-enables the button; a blocked script gives a clear message.
* `lib/security/csp.ts`, `next.config.mjs` — XPay's hosts in the CSP; `Permissions-Policy payment` allowed for XPay (Apple Pay).
* `app/admin/page.tsx` — the readiness card shows whether the window is on.
* Tests: billing (embedded body / clientSecret / createCheckoutSession), guard (key rules), `xpay-sdk.test.ts` (loader, failure, window options), csp.
* No database migration. The webhook is unchanged and remains the only thing that marks an order paid.

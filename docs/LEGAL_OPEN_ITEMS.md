# Legal — open items (inventory, not legal advice)

I reviewed the legal texts (`src/config/legal.defaults.ts`, seeded by migration 0065) and `docs/LEGAL_REVIEW.md`. **I changed no legal wording** and invented no legal fact. Everything below needs *you* or an Egyptian lawyer.

## 1. `[[REVIEW: …]]` markers
There are **22 per language, 44 in total** (Terms, Privacy, Refund & Cancellation; Arabic and English copies), in `legal.defaults.ts` (45 matches = 44 + one comment line) and mirrored in migration 0065. They are never shown publicly; `/admin/legal` lists them. `docs/LEGAL_REVIEW.md` already tabulates all of them (19 numbered topics). Until you tick "reviewed by an Egyptian lawyer" in /admin/legal the public pages show a "draft pending legal review" notice — **do not tick it until a lawyer has actually reviewed them.**

## 2. Missing facts only you can supply (enter in /admin/legal → new version)
* Operator's full legal name, commercial register number, tax registration number, registered address; company vs sole trader (marker #1).
* Contact number and contact email (empty values print "—"; the footer shows the number only when set).
* **VAT:** whether you are VAT-registered, the rate on electronic services, and whether displayed prices include it. The product shows **no VAT line**; the checkout and receipts do not itemise VAT (marker #4).
* **E-invoicing** with the Egyptian Tax Authority: whether you must issue e-invoices/e-receipts for subscription payments and how. Not implemented (marker #4).
* **Supabase region / server location** — not recorded anywhere in the project; the Privacy text needs it, and the Personal Data Protection Law rules on transfers outside Egypt depend on it (marker #15). Decide the region (`docs/PERFORMANCE.md`), then state it.
* Data retention after a subscription ends, deletion date, export commitment/time (markers #5, #11). **No automatic deletion exists.**
* Refund windows and the 5-business-day reply time are *drafts* you must be able to honour (markers #18, #19). Refunds are manual in the XPay dashboard.

## 3. Added by this hardening — the privacy text does not mention them yet
The Privacy sub-processor list (marker #14) names Supabase, the host (Vercel) and XPay. This release adds:
* **Resend** — receives recipients' email addresses and the message content of every transactional email (invitations, resets, receipts, reminders).
* **Sentry** — only if you set `SENTRY_DSN`; receives scrubbed error reports (no cookies/bodies/emails, but IP addresses are processed by Sentry as a service).
* The **email log** stores a hash and a masked form of recipient addresses, never the address.
* The **company-deletion archive** keeps a deleted company's audit log and payment records indefinitely (until you define retention).
Add these to the Privacy text via /admin/legal (a new version) after your lawyer's input.

## 4. Questions for the lawyer raised by new features
* Is keeping a deleted company's audit/payment archive lawful, and for how long? (Tax records are typically kept for years; personal data may need erasure.)
* Does emailing invited people on a company owner's behalf need wording in the Terms (the owner is the one who adds them)?

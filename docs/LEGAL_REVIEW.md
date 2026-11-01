# Legal pages — what they rest on and what an Egyptian lawyer must review

The Terms, Privacy Policy and Refund & Cancellation Policy (Arabic + English) are **original drafts, not legal advice**. They are shipped
as version 1 (migration `0065`, generated from `src/config/legal.defaults.ts`) and edited by the Super Admin in **/admin/legal**; every
save is a new immutable version. Each `[[REVIEW: …]]` marker inside the texts is a clause for the lawyer; the markers are never shown on
the public pages, they are listed under each document in /admin/legal. The public pages carry a "draft pending legal review" notice
until you tick **"reviewed by an Egyptian lawyer"** in the same screen.

## Facts about Kayan the texts rely on (verified in this codebase)
- SaaS, hosted by Kayan; multi-tenant; roles owner / sales rep / storekeeper; Arabic UI, Egyptian pounds.
- Packages with module and limit entitlements; two payment options: **perpetual license** (+ monthly hosting & maintenance) and
  **monthly subscription**. Prices come from the server configuration, are copied into each order, and a later change does not alter a paid order.
- Payments only through **XPay's hosted page**; no card data touches Kayan; **no recurring / automatic charging** (each month is a separate owner-initiated payment);
  activation only after server-side verification of XPay's payment (webhook or server-to-server check) with a matching amount.
- Access after the paid period: grace period (set by the Super Admin, default 24 h, 0 = immediate) then **access blocked** until a verified renewal.
  Data is **not** deleted automatically.
- Data held: account (Supabase Auth: email, hashed password, metadata), company/business data entered by customers, orders/payments (references, status, amount),
  the acceptance record (versions, time, IP, user agent), technical logs. Cookies: only the authentication session. No analytics / ad trackers in the code.
- Processors visible in the stack: Supabase (database + auth + auth emails), the application host (Vercel, per the project's environment notes), XPay.

## Research basis (public sources, paraphrased — verify before relying)
- **Personal Data Protection Law No. 151 of 2020** and its **Executive Regulations (Ministerial Decision No. 816 of 2025)**: explicit consent, data-subject rights, controller/processor duties,
  breach notification, restrictions on transfers outside Egypt, licences/permits from the Personal Data Protection Centre, DPO / local representative, a transitional compliance period.
- **Consumer Protection Law No. 181 of 2018** and its Executive Regulation (PM Decree 822 of 2019): Arabic-language information duties, return/exchange and distance-selling rules (the 14-day right applies to goods; whether and how it reaches business customers / SaaS is the open question).
- **Civil Code (Law 131 of 1948)**: good-faith performance (Art. 148), adhesion contracts and the court's power over abusive terms (Art. 149), liability for fraud / gross negligence cannot be excluded (Art. 217).
- **Anti-Cyber and Information Technology Crimes Law No. 175 of 2018**: service providers' duty to retain user-traffic data (180 days).
- **E-Signature Law No. 15 of 2004**: electronic evidence / acceptance.
- **VAT Law No. 67 of 2016** (14% on electronic services) and the Egyptian Tax Authority's e-invoicing mandate.

## Clauses and assumptions to confirm (each also marked in the texts)
| # | Where | Question |
|---|---|---|
| 1 | Terms (parties) | Operator's legal name, commercial register, tax card, address; company vs sole trader. |
| 2 | Terms §5 | Package change / upgrade / proration — not implemented in the system. |
| 3 | Terms §6 | "Perpetual license" wording together with access stopping when hosting lapses. |
| 4 | Terms §8 | VAT registration and rate, e-invoicing, are displayed prices tax-inclusive? (The system shows no VAT line.) |
| 5 | Terms §10 / Privacy §6 | Data retention after expiry, deletion date, export commitment and time. No automatic deletion exists today. |
| 6 | Terms §14 | 12-month liability cap; fraud / gross negligence carve-out; abusive-term risk (Art. 149). |
| 7 | Terms §17 | Is publication on the page enough for changes, or must customers be notified / given a right to terminate? |
| 8 | Terms §18 | Sufficiency of the electronic acceptance record; lawfulness of recording IP + user agent as evidence. |
| 9 | Terms §19 | Court (Cairo?) or arbitration; applicability of Consumer Protection Law to business customers. |
| 10 | Terms §20 | Force majeure, non-waiver, Arabic precedence. |
| 11 | Privacy (intro) | PDPL compliance steps: Centre licences/permits, DPO, local representative, deadlines. |
| 12 | Privacy §1 | Controller / processor characterisation; data-processing agreement with customers. |
| 13 | Privacy §3 | Legal basis per purpose; consent rules. |
| 14 | Privacy §4 | Complete sub-processor list, their locations, processing agreements. |
| 15 | Privacy §5 | **Server regions are not specified in this project**; cross-border transfer rules and approvals. |
| 16 | Privacy §8, §11 | Data-subject request handling and times; breach-notification procedure and deadlines. |
| 17 | Refund §1 | Does the Consumer Protection Law (14-day return / distance selling) apply? Sets the legal minimum. |
| 18 | Refund §4 | **14-day first-purchase window** and the hosting deduction are *our assumption*, not a legal requirement. |
| 19 | Refund §9 | **"5 business days"** reply time is a commitment you must be able to meet. Refunds are manual (XPay dashboard). |

## Operational reminders
- Fill the company identity, **contact number** and email in /admin/legal before launch (empty values render as "—"; the footer shows the number only when set).
- Every payment start records, against the order, the three accepted versions + time (database clock) + IP + user agent
  (`billing_order_acceptances`, append-only). To audit an order:
  `select * from billing_order_acceptances where order_id = '<order id>' order by accepted_at;`
  Orders created before this feature have no row.
- Editing a text creates a new version; customers accept the new version at their next payment. Past acceptances still point at the exact text they saw (`legal_documents` rows are immutable).

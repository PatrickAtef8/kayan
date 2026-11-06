# Free trial + free hosting & maintenance

## 1. Free trial («ابدأ مجانًا»)
* Home page (navbar, hero, final banner) and /pricing show **ابدأ مجانًا** → `/signup?trial=1`. The button exists only while the trial is switched on.
* The visitor creates an account normally; the trial starts right away (or at the first login after confirming the email) and the dashboard works with **all modules**, with a persistent banner showing the days left.
* When the N days end, the dashboard is closed **by the database** (every table and RPC, same as an unpaid company) and the owner sees «انتهت فترتك التجريبية — اشترك الآن»; team members see a notice. **Nothing is deleted**: after a verified payment the company opens again with all its data.
* **Admin → الباقات والأسعار → التجربة المجانية**: on/off and the number of days N (1–365, default 15). A new N applies to trials that start afterwards (a running trial keeps its own length). **Admin → company page** : «تمديد التجربة» adds days to one company (from today if it already ended).
* One trial per account and per company (unique index). A license always wins: a lapsed paying company is never re-opened by a trial. An existing company that never paid is offered the trial from its «activate your account» screen.
* Admin home shows «في تجربة مجانية»; «بانتظار الدفع» no longer counts running trials.
* Not preventable by any design: someone using a different email for each trial. Email confirmation (Supabase) is the usual mitigation.

## 2. Hosting & maintenance = 0
* The perpetual-license plan's «الاستضافة والصيانة شهريًا» now accepts **0** (an empty field is rejected, not treated as 0). License and monthly prices must still be > 0.
* With 0: checkout charges the license only, no hosting line, no paid month, no end date, no renewal button, no reminder emails, pricing cards say «الاستضافة والصيانة مجانية».
* Existing perpetual-license companies are not closed for a missing hosting payment while the price is 0 (the database reads the saved price live). Setting a price above 0 again restores the old rule for companies that still carry an end date; companies that bought while it was 0 keep no end date. The monthly plan is unaffected.

## Migration `0074_free_trial_and_free_hosting.sql` — run BEFORE deploying the code
Adds `organization_trials`, trial settings columns, `billing_start_trial`, `admin_save_trial_settings`, `admin_extend_trial`, `admin_trial_stats`, `billing_hosting_free`, and replaces `billing_access_state`, `my_org_access`, `admin_companies_overview`, `admin_unpaid_company_count`. Idempotent. Trial is **on, 15 days** after migration; switch it off in the admin page if you do not want it yet.

## New / changed files
New: migration 0074, `supabase/tests/125_free_trial_test.sql`, `src/lib/billing/trial.ts`, `trial.server.ts`, `trial.test.ts`, `components/dashboard/{trial-banner,start-trial-button}.tsx`, `components/admin/{trial-settings,extend-trial}.tsx`.
Changed: `license-status.ts`, `access-gate.ts`, `pricing.ts`, dashboard layout/paywall/owner-paywall-body, billing page + actions, pricing-experience, signup page/form, landing page/navbar/hero/final-cta, /pricing, admin actions/packages/home/company page/package-editor/format, reminders cron, `package.json` (test script).

## Verified
`tsc`, `eslint`, unit tests (billing 104), full database suite incl. new test 125 (84 checks) and the schema walk, migration run twice. `next build` could not run here (the sandbox has no access to Google Fonts); please run it once on your side.
## Not verified against live services
Real sign-up with email confirmation, Server Actions through a real session, XPay with a license-only order.

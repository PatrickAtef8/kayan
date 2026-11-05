# Kayan — after extracting: setup + private GitHub repo (SSH)

## A. Run locally
```bash
unzip kayan_latest_updated_v4.zip && cd kayan   # needs Node >= 20.9
cp .env.example .env.local          # then fill in the 4 values (never commit this file)
npm ci
npm run dev                         # http://localhost:3000
```

## B. Apply the database changes (IMPORTANT — do this before deploying)
Six new migrations, in this order (all safe to re-run):
1. `0030_security_hardening.sql` — fixes C1/H1/H2/H3/H4 in docs/SECURITY_AUDIT_V2.md
2. `0031_role_limits_and_balance_access.sql` — configurable per-role discount/bonus limits + balance permissions
3. `0032_opening_balance_protection.sql` — moves customer/supplier opening balances into protected tables and **DROPS the old columns** (data is copied first). **Take a database backup before running this one.**
4. `0033_below_cost_and_rep_assignment.sql` — owner-only below-cost selling + rep-assignment guard (new permission `sales.assign_any_rep`)
5. `0034_cost_protection.sql` — moves ALL cost data into protected tables and **DROPS `product_prices.cost` and `inventory_stock.avg_cost`** (values copied first). **Back up the database first.** New permission `products.view_cost`.
6. `0035_restricted_rep_explicit_error.sql` — a restricted rep naming another rep now gets a clear error instead of being silently re-assigned

Run them once against your Supabase project:
- Dashboard → SQL Editor → paste the file → Run, **or**
- `supabase link --project-ref <ref> && supabase db push`

Verify (both should return zero rows):
```sql
select relname from pg_class c join pg_namespace n on n.oid=c.relnamespace
where n.nspname='public' and relkind='r' and not relrowsecurity;
select p.proname from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and has_function_privilege('anon',p.oid,'execute')
  and not exists (select 1 from pg_depend d where d.objid=p.oid and d.deptype='e');
```

## C. Supabase dashboard settings (cannot be set from code)
Authentication → turn ON "Confirm email"; set minimum password length to **8** (this is what the app itself enforces — `MIN_PASSWORD_LENGTH`
in `src/lib/password-strength.ts`; Supabase's setting must not be *lower*, and a higher value would reject passwords the app's form accepts) and
enable leaked-password protection if your plan has it; restrict Site URL / Redirect URLs to your real domains; review rate limits.
**Keep CAPTCHA OFF** — the sign-up / sign-in / reset forms do not send a `captchaToken`, so enabling Supabase CAPTCHA today would make every
sign-up and login fail. Abuse protection that IS in place: per-address / per-company rate limits in the app, Supabase's own Auth rate limits.
Full list of dashboard settings: `docs/SUPABASE_AUTH_SETTINGS.md`.

## D. Private GitHub repo over SSH
```bash
# one-time SSH key (skip if you already have one added to GitHub)
ssh-keygen -t ed25519 -C "your-email@example.com"
eval "$(ssh-agent -s)" && ssh-add ~/.ssh/id_ed25519
cat ~/.ssh/id_ed25519.pub            # GitHub → Settings → SSH and GPG keys → New SSH key
ssh -T git@github.com                # expect: "Hi PatrickAtef8! You've successfully authenticated"

# create + push (GitHub CLI route)
gh auth login                        # choose SSH when asked
gh config set git_protocol ssh
git init -b main
git add . && git status              # confirm NO .env / .env.local is listed
git commit -m "Kayan: security-hardened baseline (0030 + app patches)"
gh repo create PatrickAtef8/kayan --private --source=. --remote=origin --push

# OR without gh: create an EMPTY private repo named "kayan" on github.com, then:
git remote add origin git@github.com:PatrickAtef8/kayan.git
git push -u origin main
```

## E. What changed in v2 (read this before testing the app)
**Next.js 14 -> 16.3.8, React 18 -> 19** (npm audit: 0 critical; remaining findings are dev-tooling only).
- `middleware.ts` is now `proxy.ts` (Next 16 rename). Same logic.
- `createClient()` from `@/lib/supabase/server` is now **async** — always `await createClient()`.
- `params` / `searchParams` are Promises (already converted).
- `next lint` no longer exists: use `npm run lint` (ESLint 9, `eslint.config.mjs`).
- `next/font/google` downloads the font at build time, so the first `npm run build` needs internet.

**New: Settings -> حدود الخصم** (Owner/Admin). Per role: max discount % or "no limit", and whether manual bonus is allowed.
- Counted: line %, invoice %, cash-payment %, and selling below the product's lowest list price.
- Not counted: automatic volume tiers (Settings -> خصومات الشرائح) — company policy.
- Unconfigured roles: Owner/Admin unlimited; every other role 0% and no manual bonus. **Configure your sales roles before testing.**

**New permissions** `customers.view_balance` / `suppliers.view_balance` (default: owner, admin, accountant; view_financial implies both).
Without them: balances show blank, opening-balance fields are hidden and ignored on edit/import, and roles with no purchasing/finance permission (e.g. warehouse) cannot read suppliers at all.

**Invites**: existing users are now invited, not force-added. They accept at `/invites` (the dashboard sends them there automatically).

## F. Security test suite (run it after every migration change)
```bash
cd supabase/tests/security
PGUSER=postgres ./run.sh      # needs a PostgreSQL superuser; builds a scratch DB "kayan_security_test"
```
It recreates Supabase's default privileges, applies every migration, seeds two tenants and 9 personas, and runs
198 allowed/blocked checks. It exits non-zero on any failed check **or any test-script error** (so a skipped check can never look like a pass).
`KAYAN_SABOTAGE=file.sql ./run.sh` deliberately breaks a protection to prove the tests can fail.

## G. v3 behaviour changes
- **Opening balances** now live in `customer_opening_balances` / `supplier_opening_balances`. Read: view_financial or customers/suppliers.view_balance. Write: view_financial, treasury.manage or manage_settings. Audited.
- **Below cost**: only the system **Owner** role may sell a line below its cost. Admin is NOT exempt. Manual-bonus lines are governed by the bonus setting instead.
- **Reps**: a user linked to a rep record can only invoice / assign customers to themselves; an unlinked user can only keep the customer's own rep. Override = permission `sales.assign_any_rep` (default: owner, admin). Rep pickers are hidden without it.

## H. v4 behaviour changes
- **Cost is invisible to Sales/Warehouse.** Five places leaked it, not two: `product_prices.cost`, `inventory_stock.avg_cost`, `inventory_movements.unit_cost`, `stock_transfer_items.unit_cost/line_total` and `stock_transfers.total_value`. All now live in RLS-protected tables readable only with `view_financial` or `products.view_cost` (default owner, admin, accountant). Warehouse still sees stock **quantities**.
- **Cost editing**: product cost can be edited only by `view_financial`, `purchases.approve` or `manage_settings`; stock/movement/transfer costs are maintained only by the stock functions. Manual cost edits are audited.
- **UI**: the product cost field, the inventory cost/value columns and the dashboard valuation appear only for roles that may read cost; the purchases form starts at 0 for roles that may not.
- **Rep error**: a restricted rep who names another rep now sees "يمكنك تسجيل الفواتير باسمك فقط — لا يمكنك تعيين مندوب آخر لهذه الفاتورة"; nothing is created.

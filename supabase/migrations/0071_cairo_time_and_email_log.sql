-- 0071 — Cairo business dates + the transactional-email log.
--
-- Additive and idempotent: nothing is dropped, no data is rewritten, no earlier migration is touched.
--
-- 1. cairo_today(): "today" on the Cairo business calendar. Supabase sessions run in UTC, so `current_date` is the UTC date and is wrong for
--    the first two (summer: three) hours after Cairo midnight. The app now always sends an explicit Cairo date (cairoDate() in
--    src/lib/report-period.ts); these changes fix the places where the database picks the date itself:
--      * the two alert functions that compare against "today"  (report_overdue_collections, report_large_expenses), and
--      * the column DEFAULTs of the ten business-date columns (used only when a row is inserted without a date).
--    NOT changed on purpose: the `coalesce(p_date, current_date)` fallbacks inside the posting RPCs. The application never reaches them (it always
--    passes a date) and redefining ~25 financial functions for an unreachable branch would put the financial calculations at risk for no gain.
--    If you ever call those RPCs directly without a date, pass cairo_today() yourself.
-- 2. email_log: one row per transactional email attempt (template, hashed + masked recipient, outcome). It never stores the address, the link,
--    the subject or the body. Its partial unique index is what makes "send this once" (reminders, receipts, invitations) race-safe.

create or replace function cairo_today() returns date
language sql stable set search_path = pg_catalog as $$ select (now() at time zone 'Africa/Cairo')::date $$;
revoke all on function cairo_today() from public, anon;
grant execute on function cairo_today() to authenticated;
do $$ begin if exists (select 1 from pg_roles where rolname = 'service_role') then grant execute on function cairo_today() to service_role; end if; end $$;

-- ---- alerts: same bodies as 0019, current_date -> cairo_today() ----
create or replace function report_overdue_collections(org_id uuid, p_days int default 30)
returns table (customer_count bigint, total_balance numeric)
language plpgsql stable set search_path = public as $$
declare
  v_days int := least(greatest(coalesce(p_days, 30), 1), 365);
begin
  perform assert_report_access(org_id, true);

  return query
  select count(*), coalesce(sum(b.balance), 0)::numeric
  from customer_balances b
  where b.organization_id = org_id
    and b.balance > 0
    and exists (
      select 1 from sales_invoices i
      where i.customer_id = b.customer_id and i.invoice_date < cairo_today() - v_days
    )
    and not exists (
      select 1 from customer_collections c
      where c.customer_id = b.customer_id and c.collection_date >= cairo_today() - v_days
    );
end;
$$;

create or replace function report_large_expenses(org_id uuid, p_days int default 7)
returns table (expense_count bigint, largest_amount numeric, average_amount numeric)
language plpgsql stable set search_path = public as $$
declare
  v_days int := least(greatest(coalesce(p_days, 7), 1), 90);
  v_total bigint;
  v_avg numeric;
begin
  perform assert_report_access(org_id, true);

  select count(*), coalesce(avg(amount), 0) into v_total, v_avg
  from expenses where organization_id = org_id;

  if v_total < 5 then
    return query select 0::bigint, 0::numeric, v_avg::numeric;
    return;
  end if;

  return query
  select count(*), coalesce(max(e.amount), 0)::numeric, v_avg::numeric
  from expenses e
  where e.organization_id = org_id
    and e.expense_date >= cairo_today() - v_days
    and e.amount >= v_avg * 3;
end;
$$;

-- ---- column defaults (metadata-only change; existing rows are untouched) ----
alter table purchase_invoices   alter column invoice_date    set default cairo_today();
alter table supplier_payments   alter column payment_date    set default cairo_today();
alter table sales_invoices      alter column invoice_date    set default cairo_today();
alter table customer_collections alter column collection_date set default cairo_today();
alter table treasury_movements  alter column movement_date   set default cairo_today();
alter table expenses            alter column expense_date    set default cairo_today();
alter table partner_withdrawals alter column withdrawal_date set default cairo_today();
alter table sales_returns       alter column return_date     set default cairo_today();
alter table purchase_returns    alter column return_date     set default cairo_today();
alter table stock_transfers     alter column transfer_date   set default cairo_today();

-- ---- transactional email log ----
create table if not exists email_log (
  id               uuid primary key default gen_random_uuid(),
  created_at       timestamptz not null default now(),
  template         text not null check (char_length(template) between 1 and 60),
  recipient_hash   text not null check (char_length(recipient_hash) = 64),      -- sha-256 of the lower-cased address
  recipient_masked text not null check (char_length(recipient_masked) <= 80),   -- j***@d***.com — enough to recognise, not to use
  organization_id  uuid references organizations(id) on delete set null,
  dedupe_key       text check (dedupe_key is null or char_length(dedupe_key) <= 200),
  status           text not null check (status in ('pending', 'sent', 'failed')),
  provider_id      text check (provider_id is null or char_length(provider_id) <= 100),
  error_code       text check (error_code is null or char_length(error_code) <= 60),
  updated_at       timestamptz not null default now()
);
-- At most one live ('pending' or 'sent') row per template + key + recipient: the database, not application code, makes "once" race-safe.
create unique index if not exists email_log_once_idx on email_log (template, dedupe_key, recipient_hash) where dedupe_key is not null and status in ('pending', 'sent');
create index if not exists email_log_created_idx on email_log (created_at desc);
create index if not exists email_log_org_idx on email_log (organization_id, created_at desc) where organization_id is not null;

alter table email_log enable row level security;   -- no policy on purpose: only the service role (which bypasses RLS) reads or writes it
revoke all on email_log from public, anon, authenticated;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    grant select, insert, update, delete on email_log to service_role;
  end if;
end $$;

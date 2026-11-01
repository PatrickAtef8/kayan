-- Kayan — 0060: pricing packages, licenses and XPay payments
--
-- WHAT THIS ADDS
--   * organization_licenses  — what an organization has bought (package, payment option, entitlements, paid-through date).
--   * billing_orders         — one row per checkout attempt, with the XPay session it belongs to and its outcome.
--   * billing_webhook_events — one row per XPay webhook event id, so a re-delivered event is processed once.
--   * billing_* functions    — the ONLY way these tables are written. They are SECURITY DEFINER and executable by the
--                              service role alone: the Next.js server (which has verified the caller is the owner, and has
--                              verified the payment with XPay) is the only thing that can create an order or activate a
--                              license. A signed-in browser session can read its own organization's billing rows (owner only)
--                              and nothing else.
--   * entitlement triggers   — once an organization has a license, enabling a module outside its package, activating a
--                              member past the package's seat limit, or activating a warehouse past its limit is refused
--                              by the database itself (not just hidden in the UI).
--
-- SAFETY FOR EXISTING DATA
--   * Purely additive: no existing table, column, policy or function is changed.
--   * An organization WITHOUT a license row is completely unaffected (grandfathered). The triggers return immediately
--     for it, so every existing flow and test behaves exactly as before.
--   * Limits are applied on the way IN only (enabling / activating). Nothing is ever disabled, hidden or deleted because
--     of a package; an organization that already exceeds a package's limits is told so BEFORE it pays
--     (billing_fit_report) and is never silently cut down afterwards.
--
-- MONEY
--   Amounts are integers in minor units (piasters): 149900 = 1,499.00 EGP — the same unit XPay uses.

-- ============================================================
-- 1. Tables
-- ============================================================
create table organization_licenses (
  organization_id     uuid primary key references organizations(id) on delete cascade,
  package_key         text not null check (package_key ~ '^[a-z][a-z0-9_]{1,31}$'),
  payment_option      text not null check (payment_option in ('one_time', 'monthly')),
  -- snapshot of what the package allowed WHEN IT WAS BOUGHT: {"modules": [...], "max_members": n|null, "max_warehouses": n|null}
  -- (null = unlimited). A later price/feature change in the app config never silently changes an existing license.
  entitlements        jsonb not null,
  licensed_at         timestamptz not null default now(),
  -- one_time: the perpetual license never expires; this is how far HOSTING & MAINTENANCE is paid.
  -- monthly : this is how far the SUBSCRIPTION (access + hosting + basic maintenance) is paid.
  access_paid_through timestamptz,
  last_order_id       uuid,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

create table billing_orders (
  id                     uuid primary key default gen_random_uuid(),
  organization_id        uuid not null references organizations(id) on delete cascade,
  created_by             uuid references auth.users(id) on delete set null,
  package_key            text not null check (package_key ~ '^[a-z][a-z0-9_]{1,31}$'),
  payment_option         text not null check (payment_option in ('one_time', 'monthly')),
  purpose                text not null check (purpose in ('initial', 'renewal')),
  status                 text not null default 'pending' check (status in ('pending', 'paid', 'failed', 'expired', 'canceled')),
  currency               text not null default 'EGP',
  amount_total           bigint not null check (amount_total > 0),
  recurring_amount       bigint check (recurring_amount is null or recurring_amount > 0),
  lines                  jsonb not null check (jsonb_typeof(lines) = 'array'),
  entitlements           jsonb not null,
  -- months of hosting / subscription access this payment buys (0 = a license-only payment)
  grants_months          integer not null default 0 check (grants_months between 0 and 24),
  xpay_session_id        text unique,
  xpay_payment_intent_id text,
  checkout_url           text,
  failure_reason         text,
  -- money arrived but something does not add up (amount mismatch, a second payment for an existing license…):
  -- a human has to look; nothing is granted twice and nothing is lost silently
  needs_review           boolean not null default false,
  review_note            text,
  period_start           timestamptz,
  period_end             timestamptz,
  paid_at                timestamptz,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now()
);
create index billing_orders_org_idx on billing_orders (organization_id, created_at desc);
-- at most ONE open checkout per organization: a double click / second tab can never open two payment sessions
create unique index billing_orders_one_pending on billing_orders (organization_id) where status = 'pending';

create table billing_webhook_events (
  event_id     text primary key,
  event_type   text not null,
  session_id   text,
  outcome      text,
  attempts     integer not null default 1,
  received_at  timestamptz not null default now(),
  processed_at timestamptz
);

-- ============================================================
-- 2. Row Level Security: the owner can READ; nobody can write from a browser session
-- ============================================================
alter table organization_licenses  enable row level security;
alter table billing_orders         enable row level security;
alter table billing_webhook_events enable row level security;

create policy licenses_owner_read on organization_licenses
  for select to authenticated using (my_role_key(organization_id) = 'owner');
create policy billing_orders_owner_read on billing_orders
  for select to authenticated using (my_role_key(organization_id) = 'owner');
-- billing_webhook_events: RLS on, no policy, no grant → invisible to every API role

revoke all on organization_licenses, billing_orders, billing_webhook_events from public, anon, authenticated;
grant select on organization_licenses, billing_orders to authenticated;

do $$ begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    grant select, insert, update, delete on organization_licenses, billing_orders, billing_webhook_events to service_role;
  end if;
end $$;

create trigger audit_organization_licenses after insert or update on organization_licenses for each row execute function audit_row_change('license', '');
create trigger audit_billing_orders        after insert or update on billing_orders        for each row execute function audit_row_change('billing_order', '');

-- ============================================================
-- 3. Helpers
-- ============================================================
-- Modules that are never gated by a package: the three core ones, plus 'offers' (a placeholder page with no function yet).
create or replace function billing_ungated_modules() returns text[]
language sql immutable as $$ select array['products', 'warehouses', 'reports', 'offers']::text[] $$;

-- Does this organization already exceed what a package allows? Used BEFORE a payment is started, so a customer is never
-- charged for a package it cannot actually fit into. Returns {"ok": bool, "violations": [{kind, ...}]}.
create or replace function billing_fit_report(p_org uuid, p_entitlements jsonb) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_allowed  text[] := coalesce(array(select jsonb_array_elements_text(p_entitlements -> 'modules')), '{}');
  v_extra    text[];
  v_max_m    int := nullif(p_entitlements ->> 'max_members', '')::int;
  v_max_w    int := nullif(p_entitlements ->> 'max_warehouses', '')::int;
  v_members  int;
  v_wh       int;
  v_out      jsonb := '[]'::jsonb;
begin
  select coalesce(array_agg(m.module_key order by m.module_key), '{}') into v_extra
  from organization_modules m
  where m.organization_id = p_org and m.enabled
    and not (m.module_key = any (billing_ungated_modules()))
    and not (m.module_key = any (v_allowed));
  if cardinality(v_extra) > 0 then
    v_out := v_out || jsonb_build_array(jsonb_build_object('kind', 'modules', 'keys', to_jsonb(v_extra)));
  end if;

  select count(*) into v_members from organization_users where organization_id = p_org and status = 'active';
  if v_max_m is not null and v_members > v_max_m then
    v_out := v_out || jsonb_build_array(jsonb_build_object('kind', 'members', 'current', v_members, 'max', v_max_m));
  end if;

  select count(*) into v_wh from warehouses where organization_id = p_org and is_active;
  if v_max_w is not null and v_wh > v_max_w then
    v_out := v_out || jsonb_build_array(jsonb_build_object('kind', 'warehouses', 'current', v_wh, 'max', v_max_w));
  end if;

  return jsonb_build_object('ok', jsonb_array_length(v_out) = 0, 'violations', v_out);
end $$;

-- ============================================================
-- 4. Start an order (service role only; the server has already checked who the caller is)
-- ============================================================
-- Result codes (the app translates them): created | reused | not_owner | license_exists | no_license | mismatch | fit_failed
create or replace function billing_begin_order(
  p_org uuid, p_user uuid, p_package text, p_option text, p_purpose text,
  p_currency text, p_amount bigint, p_recurring bigint, p_lines jsonb, p_entitlements jsonb, p_grants_months int
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_lic     organization_licenses;
  v_pending billing_orders;
  v_new     billing_orders;
  v_fit     jsonb;
  v_super   text;
begin
  if p_option not in ('one_time', 'monthly') or p_purpose not in ('initial', 'renewal')
     or coalesce(p_amount, 0) <= 0 or p_lines is null or jsonb_typeof(p_lines) <> 'array' or p_entitlements is null then
    raise exception 'billing: invalid order';
  end if;

  if not exists (
    select 1 from organization_users ou join roles r on r.id = ou.role_id
    where ou.organization_id = p_org and ou.user_id = p_user and ou.status = 'active' and r.key = 'owner'
  ) then
    return jsonb_build_object('result', 'not_owner');
  end if;

  -- one billing operation per organization at a time
  perform pg_advisory_xact_lock(hashtextextended('billing:' || p_org::text, 0));

  select * into v_lic from organization_licenses where organization_id = p_org;

  if p_purpose = 'initial' then
    if found then return jsonb_build_object('result', 'license_exists'); end if;
    v_fit := billing_fit_report(p_org, p_entitlements);
    if not (v_fit ->> 'ok')::boolean then
      return jsonb_build_object('result', 'fit_failed', 'report', v_fit);
    end if;
  else
    if not found then return jsonb_build_object('result', 'no_license'); end if;
    if v_lic.package_key <> p_package or v_lic.payment_option <> p_option then
      return jsonb_build_object('result', 'mismatch');
    end if;
  end if;

  select * into v_pending from billing_orders where organization_id = p_org and status = 'pending' for update;
  if found then
    if v_pending.package_key = p_package and v_pending.payment_option = p_option and v_pending.purpose = p_purpose
       and v_pending.amount_total = p_amount and v_pending.created_at > now() - interval '50 minutes' then
      return jsonb_build_object('result', 'reused', 'order', to_jsonb(v_pending));
    end if;
    -- a different (or stale) open checkout is replaced; the caller expires its XPay session
    update billing_orders set status = 'canceled', failure_reason = 'superseded', updated_at = now() where id = v_pending.id;
    v_super := v_pending.xpay_session_id;
  end if;

  insert into billing_orders (organization_id, created_by, package_key, payment_option, purpose, currency,
                              amount_total, recurring_amount, lines, entitlements, grants_months)
  values (p_org, p_user, p_package, p_option, p_purpose, p_currency,
          p_amount, p_recurring, p_lines, p_entitlements, coalesce(p_grants_months, 0))
  returning * into v_new;

  return jsonb_build_object('result', 'created', 'order', to_jsonb(v_new), 'superseded_session_id', v_super);
end $$;

-- ============================================================
-- 5. Remember the XPay session of an order
-- ============================================================
create or replace function billing_attach_session(p_order uuid, p_session text, p_url text) returns boolean
language plpgsql security definer set search_path = public as $$
declare v_n int;
begin
  update billing_orders
     set xpay_session_id = p_session, checkout_url = p_url, updated_at = now()
   where id = p_order and status = 'pending' and (xpay_session_id is null or xpay_session_id = p_session);
  get diagnostics v_n = row_count;
  return v_n = 1;
end $$;

-- ============================================================
-- 6. Activate — idempotent, amount-checked, one transaction
-- ============================================================
-- Call ONLY with values read back from XPay by the server. Result: applied | already_applied | not_found |
-- session_mismatch | amount_mismatch
create or replace function billing_apply_payment(p_order uuid, p_session text, p_payment_intent text, p_amount bigint, p_currency text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_o     billing_orders;
  v_lic   organization_licenses;
  v_have  boolean;
  v_now   timestamptz := now();
  v_start timestamptz;
  v_end   timestamptz;
  v_note  text;
begin
  select * into v_o from billing_orders where id = p_order for update;
  if not found then return jsonb_build_object('result', 'not_found'); end if;

  -- a webhook re-delivery, a return-page check racing the webhook, a double click: all land here and change nothing
  if v_o.status = 'paid' then
    return jsonb_build_object('result', 'already_applied', 'order_id', v_o.id);
  end if;

  if v_o.xpay_session_id is not null and v_o.xpay_session_id <> p_session then
    return jsonb_build_object('result', 'session_mismatch');
  end if;

  if p_amount is distinct from v_o.amount_total or upper(coalesce(p_currency, '')) <> upper(v_o.currency) then
    update billing_orders
       set status = 'failed', needs_review = true, failure_reason = 'amount_mismatch',
           review_note = format('XPay reported %s %s for session %s; the order expects %s %s', p_amount, p_currency, p_session, v_o.amount_total, v_o.currency),
           xpay_session_id = coalesce(xpay_session_id, p_session), xpay_payment_intent_id = p_payment_intent, updated_at = v_now
     where id = v_o.id;
    return jsonb_build_object('result', 'amount_mismatch');
  end if;

  select * into v_lic from organization_licenses where organization_id = v_o.organization_id for update;
  v_have := found;

  -- access is extended from whichever is later: today, or the date it is already paid through (early renewals lose nothing)
  v_start := greatest(coalesce(v_lic.access_paid_through, v_now), v_now);
  if v_o.grants_months > 0 then
    v_end := v_start + make_interval(months => v_o.grants_months);
  else
    v_end := v_lic.access_paid_through;
  end if;

  if v_o.purpose = 'initial' then
    if not v_have then
      insert into organization_licenses (organization_id, package_key, payment_option, entitlements, licensed_at, access_paid_through, last_order_id)
      values (v_o.organization_id, v_o.package_key, v_o.payment_option, v_o.entitlements, v_now, v_end, v_o.id);
    else
      -- a second "initial" payment for an organization that already holds a license (two tabs, an old session paid late):
      -- the license is NOT granted twice and is never overwritten; the paid time is kept and a human is asked to look
      v_note := 'duplicate_initial_payment: the organization already had a license; only the paid access time was added';
      update organization_licenses set access_paid_through = v_end, last_order_id = v_o.id, updated_at = v_now
       where organization_id = v_o.organization_id;
    end if;
  else
    if v_have then
      update organization_licenses set access_paid_through = v_end, last_order_id = v_o.id, updated_at = v_now
       where organization_id = v_o.organization_id;
    else
      v_note := 'renewal_without_license: a renewal was paid but the organization has no license';
    end if;
  end if;

  update billing_orders
     set status = 'paid', paid_at = v_now, updated_at = v_now,
         xpay_session_id = coalesce(xpay_session_id, p_session), xpay_payment_intent_id = p_payment_intent,
         period_start = case when v_o.grants_months > 0 then v_start end,
         period_end   = case when v_o.grants_months > 0 then v_end end,
         failure_reason = null,
         needs_review = (v_note is not null), review_note = v_note
   where id = v_o.id;

  return jsonb_build_object('result', 'applied', 'order_id', v_o.id, 'needs_review', v_note is not null);
end $$;

-- ============================================================
-- 7. Close an order that did not end in a payment (never touches a paid one)
-- ============================================================
create or replace function billing_mark_order(p_order uuid, p_status text, p_reason text) returns boolean
language plpgsql security definer set search_path = public as $$
declare v_n int;
begin
  if p_status not in ('failed', 'expired', 'canceled') then raise exception 'billing: invalid status'; end if;
  update billing_orders set status = p_status, failure_reason = p_reason, updated_at = now()
   where id = p_order and status = 'pending';
  get diagnostics v_n = row_count;
  return v_n = 1;
end $$;

-- ============================================================
-- 8. Webhook de-duplication (XPay re-delivers: retries on timeouts, manual replays)
-- ============================================================
-- true = process this delivery. false = this event id was already processed completely.
-- A delivery that arrived but never finished (the handler crashed / returned 5xx) is processed again.
create or replace function billing_begin_webhook_event(p_event_id text, p_type text, p_session text) returns boolean
language plpgsql security definer set search_path = public as $$
declare v_done timestamptz; v_n int;
begin
  insert into billing_webhook_events (event_id, event_type, session_id) values (p_event_id, p_type, p_session)
  on conflict (event_id) do nothing;
  get diagnostics v_n = row_count;
  if v_n = 1 then return true; end if;
  select processed_at into v_done from billing_webhook_events where event_id = p_event_id for update;
  if v_done is not null then return false; end if;
  update billing_webhook_events set attempts = attempts + 1 where event_id = p_event_id;
  return true;
end $$;

create or replace function billing_finish_webhook_event(p_event_id text, p_outcome text) returns void
language sql security definer set search_path = public as $$
  update billing_webhook_events set processed_at = now(), outcome = left(p_outcome, 200) where event_id = p_event_id
$$;

-- ============================================================
-- 9. Who may call what
-- ============================================================
revoke all on function
  billing_ungated_modules(), billing_fit_report(uuid, jsonb),
  billing_begin_order(uuid, uuid, text, text, text, text, bigint, bigint, jsonb, jsonb, int),
  billing_attach_session(uuid, text, text), billing_apply_payment(uuid, text, text, bigint, text),
  billing_mark_order(uuid, text, text), billing_begin_webhook_event(text, text, text), billing_finish_webhook_event(text, text)
from public, anon, authenticated;

do $$ begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    grant execute on function
      billing_fit_report(uuid, jsonb),
      billing_begin_order(uuid, uuid, text, text, text, text, bigint, bigint, jsonb, jsonb, int),
      billing_attach_session(uuid, text, text), billing_apply_payment(uuid, text, text, bigint, text),
      billing_mark_order(uuid, text, text), billing_begin_webhook_event(text, text, text), billing_finish_webhook_event(text, text)
    to service_role;
  end if;
end $$;

-- ============================================================
-- 10. Package limits enforced by the database
-- ============================================================
-- All three triggers return at once for an organization without a license (grandfathered / not yet purchased).

create or replace function enforce_module_entitlement() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_ent jsonb;
begin
  if not NEW.enabled then return NEW; end if;
  if TG_OP = 'UPDATE' and OLD.enabled then return NEW; end if;   -- already on: not an "enabling"
  if NEW.module_key = any (billing_ungated_modules()) then return NEW; end if;
  select entitlements into v_ent from organization_licenses where organization_id = NEW.organization_id;
  if not found then return NEW; end if;
  if not (v_ent -> 'modules') ? NEW.module_key then
    raise exception 'هذه الوحدة غير مشمولة في باقتك الحالية — رقِّ الباقة لتفعيلها';
  end if;
  return NEW;
end $$;

create or replace function enforce_member_limit() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_ent jsonb; v_max int; v_n int;
begin
  if NEW.status <> 'active' then return NEW; end if;
  if TG_OP = 'UPDATE' and OLD.status = 'active' and OLD.organization_id = NEW.organization_id then return NEW; end if;
  -- the license row lock serialises concurrent activations of members of the same organization
  select entitlements into v_ent from organization_licenses where organization_id = NEW.organization_id for update;
  if not found then return NEW; end if;
  v_max := nullif(v_ent ->> 'max_members', '')::int;
  if v_max is null then return NEW; end if;
  select count(*) into v_n from organization_users where organization_id = NEW.organization_id and status = 'active' and id <> NEW.id;
  if v_n + 1 > v_max then
    raise exception 'وصلت إلى الحد الأقصى لعدد أعضاء الفريق في باقتك (%) — رقِّ الباقة لإضافة المزيد', v_max;
  end if;
  return NEW;
end $$;

create or replace function enforce_warehouse_limit() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_ent jsonb; v_max int; v_n int;
begin
  if not NEW.is_active then return NEW; end if;
  if TG_OP = 'UPDATE' and OLD.is_active and OLD.organization_id = NEW.organization_id then return NEW; end if;
  select entitlements into v_ent from organization_licenses where organization_id = NEW.organization_id for update;
  if not found then return NEW; end if;
  v_max := nullif(v_ent ->> 'max_warehouses', '')::int;
  if v_max is null then return NEW; end if;
  select count(*) into v_n from warehouses where organization_id = NEW.organization_id and is_active and id <> NEW.id;
  if v_n + 1 > v_max then
    raise exception 'وصلت إلى الحد الأقصى لعدد المخازن في باقتك (%) — رقِّ الباقة لإضافة المزيد', v_max;
  end if;
  return NEW;
end $$;

create trigger billing_module_entitlement before insert or update on organization_modules for each row execute function enforce_module_entitlement();
create trigger billing_member_limit       before insert or update on organization_users   for each row execute function enforce_member_limit();
create trigger billing_warehouse_limit    before insert or update on warehouses           for each row execute function enforce_warehouse_limit();

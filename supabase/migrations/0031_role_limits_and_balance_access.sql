-- Kayan — Phase 31: configurable per-role sales limits + balance visibility
-- Depends on 0030. Safe to re-run.

-- ============================================================
-- 1. Balance visibility: two new permissions.
--    customers.view_balance  – see customer balances / debts
--    suppliers.view_balance  – see supplier balances / payables
--    (view_financial still implies both.)  Granted by default to owner, admin, accountant.
-- ============================================================
insert into permissions (key, description, category)
select v.key, v.description, (select category from permissions where key = 'view_financial')
from (values
  ('customers.view_balance', 'View customer balances and debts'),
  ('suppliers.view_balance', 'View supplier balances and payables')
) as v(key, description)
on conflict (key) do nothing;

insert into role_permissions (role_id, permission_key)
select r.id, p.key
from roles r
cross join (values ('customers.view_balance'), ('suppliers.view_balance')) as p(key)
where r.organization_id is null and r.key in ('owner', 'admin', 'accountant')
on conflict do nothing;

create or replace function balance_org_ids(p_kind text) returns setof uuid
language sql security definer stable set search_path = public as $$
  select distinct ou.organization_id
  from organization_users ou
  join role_permissions rp on rp.role_id = ou.role_id
  where ou.user_id = auth.uid() and ou.status = 'active'
    and (rp.permission_key = 'view_financial'
         or (p_kind = 'customer' and rp.permission_key = 'customers.view_balance')
         or (p_kind = 'supplier' and rp.permission_key = 'suppliers.view_balance'))
$$;
revoke all on function balance_org_ids(text) from public, anon;
grant execute on function balance_org_ids(text) to authenticated;

-- Balances come back NULL (not 0) for users without the permission, so a UI can tell
-- "not allowed" apart from "zero". Report RPCs already require view_financial.
create or replace view customer_balances
with (security_invoker = true) as
select
  c.id as customer_id,
  c.organization_id,
  case when c.organization_id in (select balance_org_ids('customer')) then coalesce(s.total_sales, 0) end as total_sales,
  case when c.organization_id in (select balance_org_ids('customer')) then coalesce(col.total_collected, 0) end as total_collected,
  case when c.organization_id in (select balance_org_ids('customer')) then
    c.opening_balance + coalesce(s.total_sales, 0) - coalesce(col.total_collected, 0)
    - coalesce(r.total_returned, 0) + coalesce(r.total_refunded, 0) end as balance,
  case when c.organization_id in (select balance_org_ids('customer')) then coalesce(r.total_returned, 0) end as total_returned,
  case when c.organization_id in (select balance_org_ids('customer')) then coalesce(r.total_refunded, 0) end as total_refunded
from customers c
left join (select customer_id, sum(total) as total_sales from sales_invoices group by customer_id) s on s.customer_id = c.id
left join (select customer_id, sum(amount) as total_collected from customer_collections group by customer_id) col on col.customer_id = c.id
left join (select customer_id, sum(total) as total_returned, sum(cash_refunded) as total_refunded from sales_returns group by customer_id) r on r.customer_id = c.id;

create or replace view supplier_balances
with (security_invoker = true) as
select
  s.id as supplier_id,
  s.organization_id,
  case when s.organization_id in (select balance_org_ids('supplier')) then coalesce(p.total_purchases, 0) end as total_purchases,
  case when s.organization_id in (select balance_org_ids('supplier')) then coalesce(pay.total_paid, 0) end as total_paid,
  case when s.organization_id in (select balance_org_ids('supplier')) then
    s.opening_balance + coalesce(p.total_purchases, 0) - coalesce(pay.total_paid, 0)
    - coalesce(r.total_returned, 0) + coalesce(r.total_refunded, 0) end as balance,
  case when s.organization_id in (select balance_org_ids('supplier')) then coalesce(r.total_returned, 0) end as total_returned,
  case when s.organization_id in (select balance_org_ids('supplier')) then coalesce(r.total_refunded, 0) end as total_refunded
from suppliers s
left join (select supplier_id, sum(total) as total_purchases from purchase_invoices group by supplier_id) p on p.supplier_id = s.id
left join (select supplier_id, sum(amount) as total_paid from supplier_payments group by supplier_id) pay on pay.supplier_id = s.id
left join (select supplier_id, sum(total) as total_returned, sum(cash_refunded) as total_refunded from purchase_returns group by supplier_id) r on r.supplier_id = s.id;

-- Warehouse (and any role with no purchasing / finance permission) cannot read the suppliers
-- table at all: its opening_balance column is a supplier balance.
drop policy if exists purch_gate on suppliers;
create policy purch_gate on suppliers as restrictive for select
  using (organization_id in (select purchasing_org_ids()));

-- ============================================================
-- 2. Configurable per-role sales limits (set by Owner/Admin in Settings).
--    One row per (organization, role).
--      max_discount_pct IS NULL  => UNLIMITED
--      max_discount_pct = N      => at most N% off the reference (lowest list) price
--    No row => defaults: owner & admin unlimited; every other role 0% and no manual bonus.
-- ============================================================
create table if not exists role_sales_limits (
  id                     uuid primary key default gen_random_uuid(),
  organization_id        uuid not null references organizations(id) on delete cascade,
  role_id                uuid not null references roles(id) on delete cascade,
  max_discount_pct       numeric(5,2) check (max_discount_pct is null or (max_discount_pct >= 0 and max_discount_pct <= 100)),
  can_give_manual_bonus  boolean not null default false,
  updated_by             uuid,
  updated_at             timestamptz not null default now(),
  unique (organization_id, role_id)
);

alter table role_sales_limits enable row level security;
alter table role_sales_limits force row level security;
revoke all on role_sales_limits from public, anon;
grant select, insert, update, delete on role_sales_limits to authenticated;

drop policy if exists rsl_select on role_sales_limits;
drop policy if exists rsl_insert on role_sales_limits;
drop policy if exists rsl_update on role_sales_limits;
drop policy if exists rsl_delete on role_sales_limits;
create policy rsl_select on role_sales_limits for select using (has_permission(organization_id, 'manage_settings'));
create policy rsl_insert on role_sales_limits for insert with check (
  has_permission(organization_id, 'manage_settings')
  and exists (select 1 from roles r where r.id = role_id and (r.organization_id is null or r.organization_id = role_sales_limits.organization_id)));
create policy rsl_update on role_sales_limits for update
  using (has_permission(organization_id, 'manage_settings'))
  with check (has_permission(organization_id, 'manage_settings')
  and exists (select 1 from roles r where r.id = role_id and (r.organization_id is null or r.organization_id = role_sales_limits.organization_id)));
create policy rsl_delete on role_sales_limits for delete using (has_permission(organization_id, 'manage_settings'));

create or replace function rsl_stamp() returns trigger language plpgsql as $$
begin NEW.updated_by := auth.uid(); NEW.updated_at := now(); return NEW; end $$;
drop trigger if exists rsl_stamp on role_sales_limits;
create trigger rsl_stamp before insert or update on role_sales_limits for each row execute function rsl_stamp();

drop trigger if exists audit_rsl on role_sales_limits;
create trigger audit_rsl after insert or update or delete on role_sales_limits
  for each row execute function audit_row_change('role_sales_limit', '');

-- The effective limits of the CALLING user inside an organization.
create or replace function _sales_limits(p_org uuid)
returns table (unlimited boolean, max_pct numeric, can_bonus boolean)
language plpgsql security definer stable set search_path = public as $$
declare v_role uuid; v_key text; v_row role_sales_limits%rowtype;
begin
  select ou.role_id, r.key into v_role, v_key
  from organization_users ou join roles r on r.id = ou.role_id
  where ou.organization_id = p_org and ou.user_id = auth.uid() and ou.status = 'active'
  limit 1;
  if v_role is null then return query select false, 0::numeric, false; return; end if;

  select * into v_row from role_sales_limits where organization_id = p_org and role_id = v_role;
  if found then
    return query select (v_row.max_discount_pct is null), coalesce(v_row.max_discount_pct, 100), v_row.can_give_manual_bonus;
  elsif v_key in ('owner', 'admin') then
    return query select true, 100::numeric, true;
  else
    return query select false, 0::numeric, false;
  end if;
end $$;
revoke all on function _sales_limits(uuid) from public, anon;

-- For the UI: what may I do?
create or replace function my_sales_limits(org_id uuid) returns jsonb
language plpgsql security definer stable set search_path = public as $$
declare l record;
begin
  if not is_org_member(org_id) then raise exception 'غير مصرح'; end if;
  select * into l from _sales_limits(org_id);
  return jsonb_build_object('unlimited', l.unlimited,
                            'max_discount_pct', case when l.unlimited then null else l.max_pct end,
                            'can_give_manual_bonus', l.can_bonus);
end $$;
revoke all on function my_sales_limits(uuid) from public, anon;
grant execute on function my_sales_limits(uuid) to authenticated;

-- ============================================================
-- 3. Enforcement: wrap the shared pricing engine (used by create_sales_invoice AND the live preview).
--    Counted against the role's limit: the line %, the invoice %, and the cash-payment % the user
--    entered, PLUS any price set below the lowest list price. Automatic volume tiers
--    (discount_tiers) are company policy and are NOT counted.
-- ============================================================
do $$ begin
  if not exists (select 1 from pg_proc where proname = '_pricing_core' and pronamespace = 'public'::regnamespace) then
    alter function _pricing(uuid, text, jsonb, numeric, numeric, numeric, numeric, jsonb) rename to _pricing_core;
  end if;
end $$;

create or replace function _pricing(
  org_id uuid, p_applies text, items jsonb,
  p_invoice_discount_pct numeric, p_cash_discount_pct numeric,
  p_amount_paid numeric, p_tax numeric,
  p_bonus_items jsonb default '[]'::jsonb
) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  l record; e jsonb;
  v_ref numeric; v_price numeric; v_line numeric; v_inv numeric; v_cash numeric;
  v_net numeric; v_floor numeric;
begin
  if p_applies = 'sales' and auth.uid() is not null then
    select * into l from _sales_limits(org_id);
    if not l.unlimited then
      if p_bonus_items is not null and jsonb_typeof(p_bonus_items) = 'array' and jsonb_array_length(p_bonus_items) > 0
         and not l.can_bonus then
        raise exception 'ليس لديك صلاحية إضافة بونص يدوي';
      end if;

      if items is not null and jsonb_typeof(items) = 'array' then
        v_inv  := coalesce(p_invoice_discount_pct, 0);
        v_cash := case when coalesce(p_amount_paid, 0) > 0 then coalesce(p_cash_discount_pct, 0) else 0 end;
        for e in select * from jsonb_array_elements(items) loop
          v_price := (e->>'unit_price')::numeric;
          v_line  := coalesce((e->>'discount_pct')::numeric, 0);
          -- reference = the lowest configured list price (retail / wholesale / distributor) > 0
          select min(x) into v_ref
          from product_prices pp, lateral (values (pp.selling_price), (pp.wholesale_price), (pp.distributor_price)) as t(x)
          where pp.organization_id = org_id and pp.product_id = (e->>'product_id')::uuid and x is not null and x > 0;
          if v_ref is null or v_price is null then continue; end if;   -- no list price to compare with
          v_net   := v_price * (1 - v_line / 100) * (1 - v_inv / 100) * (1 - v_cash / 100);
          v_floor := v_ref * (1 - l.max_pct / 100);
          if v_net < v_floor - 0.005 then
            raise exception '%', 'الخصم أو السعر يتجاوز الحد المسموح لدورك (الحد الأقصى للخصم: ' || rtrim(to_char(l.max_pct, 'FM990.99'), '.') || '%)';
          end if;
        end loop;
      end if;
    end if;
  end if;

  return _pricing_core(org_id, p_applies, items, p_invoice_discount_pct, p_cash_discount_pct, p_amount_paid, p_tax, p_bonus_items);
end $$;
revoke all on function _pricing(uuid, text, jsonb, numeric, numeric, numeric, numeric, jsonb) from public, anon, authenticated;

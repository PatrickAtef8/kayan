-- Kayan — Phase 43: exactly THREE roles (Owner / Sales Rep / Storekeeper) with data-level isolation
-- Depends on 0042. Re-runnable.  TAKE A DATABASE BACKUP FIRST: old roles are deleted and members re-assigned.
--
--   مالك         owner      everything; assigns customers to reps (customers.sales_rep_id) at any time.
--   مندوب        sales      ONLY the customers assigned to his rep record and everything that hangs off them
--                           (invoices, items, returns, collections/payments, balances, notes, reports, dashboard).
--   أمين مخزن    warehouse  operational data only: quantities, never prices, totals, debts, payments or reports.
--                           Works the sales dispatch + purchase receiving queue through the warehouse_* RPCs.
--
-- Everything below is enforced INSIDE the database (RLS + definer RPCs). The UI only hides what the
-- database already refuses, so opening a page directly or calling /rest/v1 or /rpc yourself gets nothing.
--
-- MEMBER MAPPING (nobody loses access to the company, nobody silently gains MORE than they had):
--   admin, accountant  -> owner      (the only role that sees financial figures now)
--   custom roles       -> owner if they held a financial/settings permission,
--                         else sales if they held a sales permission, else warehouse.

-- ============================================================
-- 1. Consolidate roles
-- ============================================================
do $$
declare v_owner uuid; v_sales uuid; v_wh uuid;
begin
  select id into v_owner from roles where organization_id is null and key = 'owner';
  select id into v_sales from roles where organization_id is null and key = 'sales';
  select id into v_wh    from roles where organization_id is null and key = 'warehouse';
  if v_owner is null or v_sales is null or v_wh is null then
    raise exception 'system roles owner/sales/warehouse are missing';
  end if;

  -- (a) retire the extra system roles
  update organization_users set role_id = v_owner
  where role_id in (select id from roles where organization_id is null and key in ('admin', 'accountant'));

  -- (b) retire custom roles, by what they could actually do
  update organization_users ou set role_id = case
      when exists (select 1 from role_permissions rp where rp.role_id = ou.role_id
                   and rp.permission_key in ('view_financial', 'manage_settings', 'treasury.manage', 'purchases.approve', 'purchases.create')) then v_owner
      when exists (select 1 from role_permissions rp where rp.role_id = ou.role_id
                   and rp.permission_key in ('sales.create', 'sales.edit', 'sales.approve')) then v_sales
      else v_wh end
  where ou.role_id in (select id from roles where organization_id is not null);
end $$;

-- the custom-role audit triggers would log every deletion below
drop trigger if exists audit_custom_roles_ins on roles;
drop trigger if exists audit_custom_roles_upd on roles;
drop trigger if exists audit_custom_roles_del on roles;

delete from roles where organization_id is not null or key in ('admin', 'accountant');

-- (c) nobody can create another role again (the builder RPCs and the RLS write policy are gone)
drop function if exists create_custom_role(uuid, text, text[]);
drop function if exists update_custom_role(uuid, uuid, text, text[]);
drop function if exists delete_custom_role(uuid, uuid);
drop policy if exists roles_manage on roles;
revoke insert, update, delete on roles from authenticated, anon;

alter table roles drop constraint if exists roles_only_three;
alter table roles add constraint roles_only_three check (organization_id is null and key in ('owner', 'sales', 'warehouse'));
create unique index if not exists roles_system_key_uniq on roles (key) where organization_id is null;

update roles set name = 'مالك'       where organization_id is null and key = 'owner';
update roles set name = 'مندوب'      where organization_id is null and key = 'sales';
update roles set name = 'أمين مخزن'  where organization_id is null and key = 'warehouse';

-- ============================================================
-- 2. Permissions of the three roles
-- ============================================================
insert into permissions (key, description, category) values
  ('warehouse.fulfill', 'View sales/purchase orders (items & quantities only) and confirm dispatch / receiving', 'inventory')
on conflict (key) do nothing;

delete from role_permissions
where role_id in (select id from roles where organization_id is null and key in ('owner', 'sales', 'warehouse'));

-- owner: the whole catalogue
insert into role_permissions (role_id, permission_key)
select r.id, p.key from roles r cross join permissions p
where r.organization_id is null and r.key = 'owner';

-- sales rep: create invoices for his own customers, see their balances; no money-moving rights
insert into role_permissions (role_id, permission_key)
select r.id, k from roles r cross join (values ('sales.create'), ('view_dashboard'), ('customers.view_balance')) v(k)
where r.organization_id is null and r.key = 'sales';

-- storekeeper: stock work + the dispatch/receiving queue; nothing financial
insert into role_permissions (role_id, permission_key)
select r.id, k from roles r cross join (values ('view_dashboard'), ('inventory.adjust'), ('warehouse.fulfill')) v(k)
where r.organization_id is null and r.key = 'warehouse';

-- ============================================================
-- 3. Role helpers (set-based, same pattern as 0020 so RLS stays fast)
-- ============================================================
create or replace function my_role_key(target_org uuid) returns text
language sql security definer stable set search_path = public as $$
  select r.key from organization_users ou join roles r on r.id = ou.role_id
  where ou.organization_id = target_org and ou.user_id = auth.uid() and ou.status = 'active'
  limit 1
$$;

-- A sales-role member is ALWAYS restricted — also when no representative record is linked to the
-- account yet. (Before this, an unlinked sales user silently saw the whole company.)
create or replace function restricted_rep_org_ids() returns setof uuid
language sql security definer stable set search_path = public as $$
  select ou.organization_id
  from organization_users ou join roles r on r.id = ou.role_id
  where ou.user_id = auth.uid() and ou.status = 'active' and r.key = 'sales'
$$;

create or replace function storekeeper_org_ids() returns setof uuid
language sql security definer stable set search_path = public as $$
  select ou.organization_id
  from organization_users ou join roles r on r.id = ou.role_id
  where ou.user_id = auth.uid() and ou.status = 'active' and r.key = 'warehouse'
$$;

create or replace function is_restricted_rep(target_org uuid) returns boolean
language sql security definer stable set search_path = public as $$
  select coalesce(my_role_key(target_org) = 'sales', false)
$$;

create or replace function is_storekeeper(target_org uuid) returns boolean
language sql security definer stable set search_path = public as $$
  select coalesce(my_role_key(target_org) = 'warehouse', false)
$$;

revoke all on function my_role_key(uuid), storekeeper_org_ids(), is_storekeeper(uuid) from public, anon;
grant execute on function my_role_key(uuid), storekeeper_org_ids(), is_storekeeper(uuid) to authenticated;
revoke all on function restricted_rep_org_ids(), is_restricted_rep(uuid) from public, anon;
grant execute on function restricted_rep_org_ids(), is_restricted_rep(uuid) to authenticated;

-- ============================================================
-- 4. A rep may only ever act for HIS OWN rep record
--    (guards run for every write path, not just the RPCs)
-- ============================================================
create or replace function guard_rep_assignment() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_own uuid; v_default uuid;
begin
  if auth.uid() is null then return NEW; end if;
  if TG_OP = 'UPDATE' and NEW.sales_rep_id is not distinct from OLD.sales_rep_id then return NEW; end if;
  if has_permission(NEW.organization_id, 'sales.assign_any_rep') then return NEW; end if;

  v_own := own_rep_id(NEW.organization_id);
  if is_restricted_rep(NEW.organization_id) and v_own is null then
    raise exception 'حسابك غير مربوط بسجل مندوب — اطلب من المالك ربطه أولاً';
  end if;

  if TG_TABLE_NAME = 'sales_invoices' then
    if v_own is not null then
      if NEW.sales_rep_id is distinct from v_own then
        raise exception 'يمكنك تسجيل الفواتير باسمك فقط — تعيين مندوب آخر يحتاج صلاحية خاصة';
      end if;
    else
      select sales_rep_id into v_default from customers where id = NEW.customer_id;
      if NEW.sales_rep_id is not null and NEW.sales_rep_id is distinct from v_default then
        raise exception 'تعيين مندوب مختلف عن مندوب العميل يحتاج صلاحية خاصة';
      end if;
    end if;
  else  -- customers
    if TG_OP = 'INSERT' and NEW.sales_rep_id is null then return NEW; end if;
    if v_own is null or NEW.sales_rep_id is distinct from v_own then
      raise exception 'تعيين مندوب للعميل يحتاج صلاحية خاصة (المالك فقط)';
    end if;
  end if;
  return NEW;
end $$;

create or replace function customers_rep_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if is_restricted_rep(NEW.organization_id) then
    if TG_OP = 'INSERT' then
      raise exception 'إنشاء العملاء وتعيينهم للمناديب من صلاحيات المالك فقط';
    else
      NEW.sales_rep_id := OLD.sales_rep_id;   -- only the owner moves a customer between reps
    end if;
  end if;
  if NEW.sales_rep_id is not null and not exists (select 1 from sales_representatives where id = NEW.sales_rep_id and organization_id = NEW.organization_id) then
    raise exception 'هذا المندوب لا ينتمي إلى هذه المؤسسة';
  end if;
  return NEW;
end $$;

-- ============================================================
-- 5. Rep isolation: close the tables 0024 missed + explicit write scoping
--    (RESTRICTIVE policies are AND-ed with whatever already exists)
-- ============================================================
-- 5a. data that hangs off an invoice / a customer
drop policy if exists rep_scope on sales_batch_allocations;
create policy rep_scope on sales_batch_allocations as restrictive for select
  using (organization_id not in (select restricted_rep_org_ids())
         or sales_invoice_id in (select id from sales_invoices where sales_rep_id in (select my_rep_ids())));

drop policy if exists rep_scope on sales_invoice_channel_snapshot;
create policy rep_scope on sales_invoice_channel_snapshot as restrictive for select
  using (organization_id not in (select restricted_rep_org_ids())
         or sales_invoice_id in (select id from sales_invoices where sales_rep_id in (select my_rep_ids())));

drop policy if exists rep_scope on customer_opening_balances;
create policy rep_scope on customer_opening_balances as restrictive for select
  using (organization_id not in (select restricted_rep_org_ids())
         or customer_id in (select id from customers where sales_rep_id in (select my_rep_ids())));

-- 5b. warehouse/stock internals are not a rep's business (inventory_stock was already closed in 0024)
do $$
declare t text;
begin
  foreach t in array array['stock_batches', 'stocktakes', 'stocktake_lines', 'attachments']
  loop
    execute format('drop policy if exists rep_scope on %I', t);
    execute format('create policy rep_scope on %I as restrictive for select using (organization_id not in (select restricted_rep_org_ids()))', t);
  end loop;
end $$;

-- 5c. writes: a rep can only touch customers that are assigned to him (and can never create or reassign one)
drop policy if exists rep_scope_upd on customers;
create policy rep_scope_upd on customers as restrictive for update
  using (organization_id not in (select restricted_rep_org_ids()) or sales_rep_id in (select my_rep_ids()));
drop policy if exists rep_scope_del on customers;
create policy rep_scope_del on customers as restrictive for delete
  using (organization_id not in (select restricted_rep_org_ids()));

-- ============================================================
-- 6. Storekeeper isolation: no prices, totals, debts, payments, customers' money, rep pay, reports
--    The storekeeper still READS: products, warehouses, stock, batches, movements, transfers, stocktakes.
--    Orders reach him only through warehouse_sales_orders()/warehouse_purchase_orders() (0044),
--    which return product, unit and quantity — nothing else (0044).
--    (purchase_* / suppliers / supplier_payments / treasury / expenses / partners were already closed
--    to him by purch_gate and fin_gate in 0030 because he holds none of those permissions.)
-- ============================================================
do $$
declare t text;
begin
  foreach t in array array[
    'sales_invoices', 'sales_invoice_items', 'sales_returns', 'sales_return_items',
    'customer_collections', 'customers', 'customer_opening_balances',
    'sales_representatives', 'discount_tiers', 'bonus_rules', 'expense_categories', 'party_notes',
    'product_prices', 'sales_invoice_financials', 'sales_item_financials',
    'sales_return_financials', 'sales_return_item_financials',
    'sales_batch_allocations', 'sales_invoice_channel_snapshot', 'attachments'
  ]
  loop
    execute format('drop policy if exists storekeeper_scope on %I', t);
    execute format('create policy storekeeper_scope on %I as restrictive for select using (organization_id not in (select storekeeper_org_ids()))', t);
  end loop;
end $$;

-- the price list view bypasses RLS by design (reps read their selling prices through it) —
-- so it must refuse the storekeeper itself
create or replace view product_sale_prices as
  select product_id, organization_id, selling_price, wholesale_price, distributor_price
  from product_prices pp
  where organization_id in (select user_org_ids())
    and organization_id not in (select storekeeper_org_ids());

-- the live pricing engine would otherwise hand list prices to any member
create or replace function pricing_preview(
  org_id uuid, p_applies text, items jsonb,
  p_invoice_discount_pct numeric default 0, p_cash_discount_pct numeric default 0,
  p_amount_paid numeric default 0, p_tax numeric default 0, p_bonus_items jsonb default '[]'::jsonb
) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'يجب تسجيل الدخول أولاً'; end if;
  if not is_org_member(org_id) then raise exception 'أنت لست عضوًا في هذه المؤسسة'; end if;
  if not (has_permission(org_id, 'sales.create') or has_permission(org_id, 'purchases.create') or has_permission(org_id, 'manage_settings')) then
    raise exception 'ليس لديك صلاحية عرض الأسعار';
  end if;
  return _pricing(org_id, p_applies, items, p_invoice_discount_pct, p_cash_discount_pct, p_amount_paid, p_tax, p_bonus_items);
end $$;
revoke all on function pricing_preview(uuid, text, jsonb, numeric, numeric, numeric, numeric, jsonb) from public, anon;
grant execute on function pricing_preview(uuid, text, jsonb, numeric, numeric, numeric, numeric, jsonb) to authenticated;

-- Attachments hold receipts/invoices (money): owner level only, in the table AND in the storage bucket.
drop policy if exists attachments_owner_only on attachments;
create policy attachments_owner_only on attachments as restrictive for all
  using (organization_id in (select finance_org_ids()))
  with check (organization_id in (select finance_org_ids()));

drop policy if exists attachments_storage_select on storage.objects;
drop policy if exists attachments_storage_insert on storage.objects;
drop policy if exists attachments_storage_delete on storage.objects;
create policy attachments_storage_select on storage.objects for select
  using (bucket_id = 'attachments' and (storage.foldername(name))[1]::uuid in (select finance_org_ids()));
create policy attachments_storage_insert on storage.objects for insert
  with check (bucket_id = 'attachments' and (storage.foldername(name))[1]::uuid in (select finance_org_ids()));
create policy attachments_storage_delete on storage.objects for delete
  using (bucket_id = 'attachments' and (storage.foldername(name))[1]::uuid in (select finance_org_ids()));

-- ============================================================
-- 7. Writes: master data was writable by ANY member (INSERT/UPDATE policies only checked membership).
--    Reps and storekeepers now cannot create or edit products, categories, prices, warehouses or suppliers;
--    customers are created and assigned to reps by the OWNER only (policy + trigger below).
-- ============================================================
do $$
declare t text;
begin
  foreach t in array array['products', 'product_categories', 'warehouses']
  loop
    execute format('drop policy if exists owner_write_ins on %I', t);
    execute format('drop policy if exists owner_write_upd on %I', t);
    execute format($p$create policy owner_write_ins on %I as restrictive for insert with check (has_permission(organization_id, 'manage_settings'))$p$, t);
    execute format($p$create policy owner_write_upd on %I as restrictive for update using (has_permission(organization_id, 'manage_settings'))$p$, t);
  end loop;
end $$;

drop policy if exists owner_write_ins on product_prices;
create policy owner_write_ins on product_prices as restrictive for insert
  with check (has_permission(organization_id, 'manage_settings') or has_permission(organization_id, 'purchases.approve'));

drop policy if exists owner_write_ins on suppliers;
create policy owner_write_ins on suppliers as restrictive for insert
  with check (has_permission(organization_id, 'manage_settings') or has_permission(organization_id, 'purchases.create'));

drop policy if exists owner_write_ins on customers;
create policy owner_write_ins on customers as restrictive for insert
  with check (has_permission(organization_id, 'manage_settings'));   -- customers are created (and assigned to a rep) by the owner only

-- ============================================================
-- 8. Reports & dashboard
--    8a. sales-side reports refuse the storekeeper outright (RLS already returns nothing; now they say no).
--    8b. the customer statement (كشف حساب) opens for a rep — on HIS customers only: the ledger reads
--        customers / invoices / collections / returns through RLS, so another rep's customer is "not found".
--    Bodies below are the live definitions from 0042 with ONLY the access line changed.
-- ============================================================
create or replace function assert_sales_report_access(org_id uuid) returns void
language plpgsql stable set search_path = public as $$
begin
  perform assert_report_access(org_id, false);
  if is_storekeeper(org_id) then
    raise exception 'ليس لديك صلاحية عرض بيانات المبيعات';
  end if;
end $$;
revoke all on function assert_sales_report_access(uuid) from public, anon;
grant execute on function assert_sales_report_access(uuid) to authenticated;

CREATE OR REPLACE FUNCTION public.dashboard_sales_rollups(org_id uuid, p_from date DEFAULT NULL::date)
 RETURNS TABLE(kind text, group_key text, group_label text, ref_date date, invoices bigint, net_sales numeric, gross_profit numeric)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
declare
  fin boolean;
begin
  perform assert_sales_report_access(org_id);
  fin := has_permission(org_id, 'view_financial');

  return query
  with f as materialized (
    select i.invoice_date, i.customer_id, i.sales_rep_id, i.subtotal, i.discount_total, i.profit_total,
           coalesce(rt.ret_total, 0) as ret_total,
           coalesce(rt.ret_profit, 0) as ret_profit
    from v_sales_invoices i
    left join (
      select r.sales_invoice_id, sum(r.subtotal_reversed) as ret_total, sum(r.profit_reversed) as ret_profit
      from v_sales_returns r
      where r.organization_id = org_id
      group by r.sales_invoice_id
    ) rt on rt.sales_invoice_id = i.id
    where i.organization_id = org_id
      and (p_from is null or i.invoice_date >= p_from)
  ),
  trend as (
    select 'trend'::text as k, x.invoice_date::text as gk, x.invoice_date::text as gl, x.invoice_date as rd,
           count(*)::bigint as n,
           coalesce(sum(x.subtotal - x.discount_total - x.ret_total), 0)::numeric as ns,
           case when fin then coalesce(sum(x.profit_total - x.ret_profit), 0)::numeric end as gp
    from f x
    group by x.invoice_date
    order by x.invoice_date desc
    limit 1000
  ),
  cust as (
    select 'customer'::text as k, x.customer_id::text as gk, coalesce(c.name, '—') as gl, null::date as rd,
           count(*)::bigint as n,
           coalesce(sum(x.subtotal - x.discount_total - x.ret_total), 0)::numeric as ns,
           case when fin then coalesce(sum(x.profit_total - x.ret_profit), 0)::numeric end as gp
    from f x
    left join customers c on c.id = x.customer_id
    group by x.customer_id, coalesce(c.name, '—')
    order by 6 desc nulls last, 3
    limit 5
  ),
  reps as (
    select 'representative'::text as k, coalesce(x.sales_rep_id::text, '') as gk, coalesce(r.name, 'بدون مندوب') as gl, null::date as rd,
           count(*)::bigint as n,
           coalesce(sum(x.subtotal - x.discount_total - x.ret_total), 0)::numeric as ns,
           case when fin then coalesce(sum(x.profit_total - x.ret_profit), 0)::numeric end as gp
    from f x
    left join sales_representatives r on r.id = x.sales_rep_id
    group by coalesce(x.sales_rep_id::text, ''), coalesce(r.name, 'بدون مندوب')
    order by 6 desc nulls last, 3
    limit 5
  )
  select * from trend
  union all select * from cust
  union all select * from reps;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.dashboard_sales_totals(org_id uuid, p_from date DEFAULT NULL::date)
 RETURNS TABLE(total_sales numeric, total_profit numeric)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
declare
  s jsonb;
begin
  perform assert_sales_report_access(org_id);
  s := report_summary(org_id, p_from, null);
  return query select
    coalesce((s->'sales'->>'net_sales')::numeric, 0),
    coalesce((s->'financial'->>'net_profit')::numeric, 0);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.report_recent_activity(org_id uuid, p_limit integer DEFAULT 8)
 RETURNS TABLE(occurred_at timestamp with time zone, kind text, label text, amount numeric)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
declare
  fin boolean;
  v_limit int := least(greatest(coalesce(p_limit, 8), 1), 50);
begin
  perform assert_sales_report_access(org_id);
  fin := has_permission(org_id, 'view_financial');

  return query
  select * from (
    (select i.created_at, 'sale'::text, coalesce(c.name, '—'), i.total::numeric
     from sales_invoices i left join customers c on c.id = i.customer_id
     where i.organization_id = org_id
     order by i.created_at desc limit v_limit)
    union all
    (select r.created_at, 'sales_return'::text, coalesce(c.name, '—'), r.total::numeric
     from sales_returns r left join customers c on c.id = r.customer_id
     where r.organization_id = org_id
     order by r.created_at desc limit v_limit)
    union all
    (select pi.created_at, 'purchase'::text, coalesce(s.name, '—'), pi.total::numeric
     from purchase_invoices pi left join suppliers s on s.id = pi.supplier_id
     where fin and pi.organization_id = org_id
     order by pi.created_at desc limit v_limit)
    union all
    (select pr.created_at, 'purchase_return'::text, coalesce(s.name, '—'), pr.total::numeric
     from purchase_returns pr left join suppliers s on s.id = pr.supplier_id
     where fin and pr.organization_id = org_id
     order by pr.created_at desc limit v_limit)
    union all
    (select cc.created_at, 'collection'::text, coalesce(c.name, '—'), cc.amount::numeric
     from customer_collections cc left join customers c on c.id = cc.customer_id
     where fin and cc.organization_id = org_id
     order by cc.created_at desc limit v_limit)
    union all
    (select sp.created_at, 'supplier_payment'::text, coalesce(s.name, '—'), sp.amount::numeric
     from supplier_payments sp left join suppliers s on s.id = sp.supplier_id
     where fin and sp.organization_id = org_id
     order by sp.created_at desc limit v_limit)
    union all
    (select e.created_at, 'expense'::text, coalesce(ec.name, 'بدون تصنيف'), e.amount::numeric
     from expenses e left join expense_categories ec on ec.id = e.category_id
     where fin and e.organization_id = org_id
     order by e.created_at desc limit v_limit)
  ) a
  order by 1 desc
  limit v_limit;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.report_returns_by_reason(org_id uuid, p_from date DEFAULT NULL::date, p_to date DEFAULT NULL::date, p_group text DEFAULT 'reason'::text, p_reason text DEFAULT NULL::text, p_warehouse uuid DEFAULT NULL::uuid, p_rep uuid DEFAULT NULL::uuid, p_limit integer DEFAULT 500, p_offset integer DEFAULT 0)
 RETURNS TABLE(group_id text, group_label text, returns bigint, lines bigint, customers bigint, units numeric, resalable_units numeric, damaged_units numeric, value numeric, share_pct numeric, total_count bigint)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
declare
  v_limit int := least(greatest(coalesce(p_limit, 500), 1), 1000);
  v_off   int := greatest(coalesce(p_offset, 0), 0);
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  perform assert_sales_report_access(org_id);
  if p_group is null or p_group not in ('reason', 'product', 'customer') then raise exception 'نوع التقرير غير صحيح'; end if;
  if v_reason is not null and v_reason not in ('damaged', 'expired', 'slow_moving', 'other', 'unclassified') then raise exception 'سبب المرتجع غير صحيح'; end if;

  return query
  with base as (
    select r.id as rid, r.customer_id as cid, ri.product_id as pid, ri.quantity::numeric as q, ri.condition as cond,
           ri.revenue_reversed::numeric as rev, coalesce(ri.return_reason, 'unclassified') as reason,
           p.name as pname, cu.name as cname
    from sales_return_items ri
    join sales_returns r on r.id = ri.sales_return_id
    join sales_invoices inv on inv.id = r.sales_invoice_id
    join products p on p.id = ri.product_id
    join customers cu on cu.id = r.customer_id
    where ri.organization_id = org_id and r.organization_id = org_id
      and (p_from is null or r.return_date >= p_from) and (p_to is null or r.return_date <= p_to)
      and (p_warehouse is null or r.warehouse_id = p_warehouse)
      and (p_rep is null or inv.sales_rep_id = p_rep)
  ),
  filtered as (select * from base where v_reason is null or base.reason = v_reason),
  agg as (
    select (case p_group when 'reason' then f.reason when 'product' then f.pid::text else f.cid::text end) as k,
           max(case p_group when 'reason' then (case f.reason when 'damaged' then 'تالف' when 'expired' then 'صلاحية منتهية'
                                                         when 'slow_moving' then 'عدم الدوران عند التاجر' when 'other' then 'أخرى' else 'غير مصنّف' end)
                            when 'product' then f.pname else f.cname end) as lbl,
           count(distinct f.rid) as rets, count(*) as ls, count(distinct f.cid) as custs,
           sum(f.q) as u, coalesce(sum(f.q) filter (where f.cond = 'resalable'), 0) as ru, coalesce(sum(f.q) filter (where f.cond = 'damaged'), 0) as du,
           sum(f.rev) as v
    from filtered f group by 1
  ),
  allrows as (
    select a.* from agg a
    union all   -- the reason report always lists every reason, even with no returns
    select x.k, x.l, 0::bigint, 0::bigint, 0::bigint, 0::numeric, 0::numeric, 0::numeric, 0::numeric
    from (values ('damaged', 'تالف'), ('expired', 'صلاحية منتهية'), ('slow_moving', 'عدم الدوران عند التاجر'), ('other', 'أخرى'), ('unclassified', 'غير مصنّف')) x(k, l)
    where p_group = 'reason' and (v_reason is null or v_reason = x.k) and not exists (select 1 from agg a where a.k = x.k)
  )
  select r.k, r.lbl, r.rets, r.ls, r.custs, r.u, r.ru, r.du, r.v,
         (case when sum(r.v) over () > 0 then round(r.v * 100 / sum(r.v) over (), 2) else 0 end)::numeric,
         count(*) over ()
  from allrows r
  order by (case when p_group = 'reason' then array_position(array['damaged', 'expired', 'slow_moving', 'other', 'unclassified'], r.k) end), r.v desc, r.lbl
  limit v_limit offset v_off;
end $function$
;

CREATE OR REPLACE FUNCTION public.report_sales_breakdown(org_id uuid, p_from date, p_to date, p_group text, p_limit integer DEFAULT 100, p_offset integer DEFAULT 0)
 RETURNS TABLE(group_key text, group_label text, ref_date date, party text, invoices bigint, quantity numeric, gross_sales numeric, discounts numeric, returns numeric, net_sales numeric, cogs numeric, gross_profit numeric, commission numeric, total_count bigint)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
declare
  fin boolean;
  v_limit int := least(greatest(coalesce(p_limit, 100), 1), 1000);
  v_offset int := greatest(coalesce(p_offset, 0), 0);
begin
  perform assert_sales_report_access(org_id);
  if p_group not in ('date', 'invoice', 'customer', 'product', 'representative') then
    raise exception 'نوع التجميع غير مدعوم';
  end if;
  fin := has_permission(org_id, 'view_financial');

  if p_group = 'product' then
    return query
    select
      x.product_id::text,
      coalesce(p.name, '—'),
      null::date,
      null::text,
      count(distinct x.sales_invoice_id),
      coalesce(sum(x.quantity), 0)::numeric - coalesce(sum(x.ret_qty), 0)::numeric,
      coalesce(sum(x.quantity * x.unit_price), 0)::numeric,
      coalesce(sum(x.discount + x.alloc), 0)::numeric,
      coalesce(sum(x.ret_revenue), 0)::numeric,
      coalesce(sum(x.line_total - x.alloc - x.ret_revenue), 0)::numeric,
      case when fin then coalesce(sum(x.cost_total - x.ret_cost), 0)::numeric end,
      case when fin then coalesce(sum(x.profit - x.ret_profit), 0)::numeric end,
      null::numeric,
      count(*) over ()
    from (
      select it.id, it.product_id, it.sales_invoice_id, it.quantity, it.unit_price, it.discount,
             it.line_total, it.cost_total, it.profit,
             it.allocated_discount as alloc,
             coalesce(ra.ret_qty, 0) as ret_qty,
             coalesce(ra.ret_revenue, 0) as ret_revenue,
             coalesce(ra.ret_cost, 0) as ret_cost,
             coalesce(ra.ret_profit, 0) as ret_profit
      from v_sales_invoice_items it
      join v_sales_invoices i on i.id = it.sales_invoice_id
      left join (
        select sri.sales_invoice_item_id, sum(sri.quantity) as ret_qty, sum(sri.revenue_reversed) as ret_revenue,
               sum(sri.cost_reversed) as ret_cost, sum(sri.profit_reversed) as ret_profit
        from v_sales_return_items sri
        where sri.organization_id = org_id
        group by sri.sales_invoice_item_id
      ) ra on ra.sales_invoice_item_id = it.id
      where it.organization_id = org_id
        and i.organization_id = org_id
        and (p_from is null or i.invoice_date >= p_from)
        and (p_to is null or i.invoice_date <= p_to)
    ) x
    left join products p on p.id = x.product_id
    group by x.product_id, p.name
    order by sum(x.line_total - x.alloc - x.ret_revenue) desc, p.name
    limit v_limit offset v_offset;
    return;
  end if;

  return query
  with inv as (
    select i.*, coalesce(ic.earned_commission, 0) as earned_commission,
           coalesce((select sum(it.quantity) from v_sales_invoice_items it where it.sales_invoice_id = i.id), 0) as qty,
           coalesce((select sum(sri.quantity) from v_sales_return_items sri join v_sales_returns r on r.id = sri.sales_return_id where r.sales_invoice_id = i.id), 0) as ret_qty,
           coalesce((select sum(r.subtotal_reversed) from v_sales_returns r where r.sales_invoice_id = i.id), 0) as ret_total,
           coalesce((select sum(r.cost_reversed) from v_sales_returns r where r.sales_invoice_id = i.id), 0) as ret_cost,
           coalesce((select sum(r.profit_reversed) from v_sales_returns r where r.sales_invoice_id = i.id), 0) as ret_profit
    from v_sales_invoices i
    left join invoice_commissions ic on ic.sales_invoice_id = i.id
    where i.organization_id = org_id
      and (p_from is null or i.invoice_date >= p_from)
      and (p_to is null or i.invoice_date <= p_to)
  )
  select * from (
    select
      case p_group
        when 'date' then i.invoice_date::text
        when 'invoice' then i.id::text
        when 'customer' then i.customer_id::text
        else coalesce(i.sales_rep_id::text, '')
      end as group_key,
      case p_group
        when 'date' then i.invoice_date::text
        when 'invoice' then coalesce(nullif(i.invoice_number, ''), '—')
        when 'customer' then coalesce(c.name, '—')
        else coalesce(r.name, 'بدون مندوب')
      end as group_label,
      case p_group
        when 'date' then i.invoice_date
        when 'invoice' then i.invoice_date
        else null::date
      end as ref_date,
      case p_group when 'invoice' then c.name else null::text end as party,
      count(*)::bigint as invoices,
      coalesce(sum(i.qty - i.ret_qty), 0)::numeric as quantity,
      coalesce(sum(i.subtotal), 0)::numeric as gross_sales,
      coalesce(sum(i.discount_total), 0)::numeric as discounts,
      coalesce(sum(i.ret_total), 0)::numeric as returns,
      coalesce(sum(i.subtotal - i.discount_total - i.ret_total), 0)::numeric as net_sales,
      case when fin then coalesce(sum(i.cogs_total - i.ret_cost), 0)::numeric end as cogs,
      case when fin then coalesce(sum(i.profit_total - i.ret_profit), 0)::numeric end as gross_profit,
      case when fin then coalesce(sum(i.earned_commission), 0)::numeric end as commission,
      count(*) over () as total_count
    from inv i
    left join customers c on c.id = i.customer_id
    left join sales_representatives r on r.id = i.sales_rep_id
    group by
      case p_group
        when 'date' then i.invoice_date::text
        when 'invoice' then i.id::text
        when 'customer' then i.customer_id::text
        else coalesce(i.sales_rep_id::text, '')
      end,
      case p_group
        when 'date' then i.invoice_date::text
        when 'invoice' then coalesce(nullif(i.invoice_number, ''), '—')
        when 'customer' then coalesce(c.name, '—')
        else coalesce(r.name, 'بدون مندوب')
      end,
      case p_group
        when 'date' then i.invoice_date
        when 'invoice' then i.invoice_date
        else null::date
      end,
      case p_group when 'invoice' then c.name else null::text end
  ) g
  order by
    case when p_group in ('date', 'invoice') then g.ref_date end desc nulls last,
    case when p_group in ('customer', 'representative') then g.net_sales end desc nulls last,
    g.group_label
  limit v_limit offset v_offset;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.report_sales_by(org_id uuid, p_group text, p_from date DEFAULT NULL::date, p_to date DEFAULT NULL::date, p_warehouse uuid DEFAULT NULL::uuid, p_rep uuid DEFAULT NULL::uuid, p_channel text DEFAULT NULL::text, p_limit integer DEFAULT 200, p_offset integer DEFAULT 0)
 RETURNS TABLE(group_id text, group_label text, invoices bigint, customers bigint, products bigint, billed_qty numeric, bonus_qty numeric, returned_qty numeric, net_qty numeric, units_per_carton numeric, whole_cartons numeric, remainder_units numeric, cartons numeric, loose_units numeric, gross_sales numeric, discounts numeric, returns_value numeric, net_revenue numeric, total_count bigint)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
declare
  v_limit int := least(greatest(coalesce(p_limit, 200), 1), 1000);
  v_off   int := greatest(coalesce(p_offset, 0), 0);
  v_chan  text := nullif(btrim(coalesce(p_channel, '')), '');
begin
  perform assert_sales_report_access(org_id);
  if p_group is null or p_group not in ('rep', 'channel', 'product', 'customer') then raise exception 'نوع التقرير غير صحيح'; end if;
  if v_chan is not null and v_chan not in ('wholesale', 'retail', 'social') then raise exception 'قناة البيع غير صحيحة'; end if;

  return query
  with ret as (   -- returns summed PER INVOICE ITEM, so they join 1:1 and can never multiply a line
    select r.sales_invoice_item_id as item_id, sum(r.quantity) as qty, sum(r.revenue_reversed) as rev
    from sales_return_items r
    where r.organization_id = org_id
    group by r.sales_invoice_item_id
  ),
  ln as (
    select inv.id as inv_id, inv.customer_id as cust_id, inv.sales_rep_id as rep_id, i.product_id as prod_id,
           coalesce(inv.sales_channel, snap.sales_channel, case c.price_tier when 'retail' then 'retail' else 'wholesale' end) as chan,
           sr.name as rep_name, c.name as cust_name, p.name as prod_name, p.units_per_carton as per,
           (case when i.is_bonus then 0 else i.quantity end)::numeric as billed,
           (i.bonus_quantity + case when i.is_bonus then i.quantity else 0 end)::numeric as bonus,
           coalesce(ret.qty, 0)::numeric as returned,
           (i.quantity * i.unit_price)::numeric as gross,
           (i.discount + i.allocated_discount)::numeric as disc,
           coalesce(ret.rev, 0)::numeric as ret_rev,
           (i.line_total - i.allocated_discount)::numeric as net_pre
    from sales_invoice_items i
    join sales_invoices inv on inv.id = i.sales_invoice_id
    join customers c on c.id = inv.customer_id
    join products p on p.id = i.product_id
    left join sales_representatives sr on sr.id = inv.sales_rep_id
    left join sales_invoice_channel_snapshot snap on snap.sales_invoice_id = inv.id
    left join ret on ret.item_id = i.id
    where i.organization_id = org_id and inv.organization_id = org_id
      and (p_from is null or inv.invoice_date >= p_from)
      and (p_to is null or inv.invoice_date <= p_to)
      and (p_warehouse is null or inv.warehouse_id = p_warehouse)
      and (p_rep is null or inv.sales_rep_id = p_rep)
  ),
  filtered as (select * from ln where v_chan is null or ln.chan = v_chan),
  agg as (
    select (case p_group when 'rep' then coalesce(f.rep_id::text, 'none') when 'channel' then f.chan
                         when 'product' then f.prod_id::text else f.cust_id::text end) as k,
           max(case p_group when 'rep' then coalesce(f.rep_name, 'بدون مندوب')
                            when 'channel' then (case f.chan when 'wholesale' then 'جملة' when 'retail' then 'تجزئة' else 'سوشيال ميديا' end)
                            when 'product' then f.prod_name else f.cust_name end) as lbl,
           count(distinct f.inv_id) as invs, count(distinct f.cust_id) as custs, count(distinct f.prod_id) as prods,
           sum(f.billed) as billed, sum(f.bonus) as bonus, sum(f.returned) as returned,
           sum(f.billed + f.bonus - f.returned) as net_units,
           (case when p_group = 'product' then max(f.per) end) as per_out,
           coalesce(sum((f.billed + f.bonus - f.returned) / f.per) filter (where f.per is not null), 0) as ctn,
           coalesce(sum(f.billed + f.bonus - f.returned) filter (where f.per is null), 0) as loose,
           sum(f.gross) as gross, sum(f.disc) as disc, sum(f.ret_rev) as retv, sum(f.net_pre - f.ret_rev) as net
    from filtered f
    group by 1
  ),
  allrows as (
    select a.* from agg a
    union all   -- the channel report always lists all three channels, even with no sales
    select v.k, v.l, 0, 0, 0, 0::numeric, 0::numeric, 0::numeric, 0::numeric, null::numeric, 0::numeric, 0::numeric, 0::numeric, 0::numeric, 0::numeric, 0::numeric
    from (values ('wholesale', 'جملة'), ('retail', 'تجزئة'), ('social', 'سوشيال ميديا')) v(k, l)
    where p_group = 'channel' and (v_chan is null or v_chan = v.k) and not exists (select 1 from agg a where a.k = v.k)
  )
  select r.k, r.lbl, r.invs, r.custs, r.prods, r.billed, r.bonus, r.returned, r.net_units,
         r.per_out,
         (case when r.per_out is not null then floor(r.net_units / r.per_out) end),
         (case when r.per_out is not null then r.net_units - floor(r.net_units / r.per_out) * r.per_out end),
         r.ctn, r.loose, r.gross, r.disc, r.retv, r.net, count(*) over ()
  from allrows r
  order by r.net desc, r.lbl
  limit v_limit offset v_off;
end $function$
;

CREATE OR REPLACE FUNCTION public.report_summary(org_id uuid, p_from date DEFAULT NULL::date, p_to date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
declare
  fin boolean;
  s record;
  v_expenses numeric(14,2);
  v_collections numeric(14,2);
  v_supplier_payments numeric(14,2);
  v_purchases numeric(14,2);
  v_purchase_returns numeric(14,2);
  v_by_category jsonb;
  v_receivable numeric;
  v_payable numeric;
  v_inventory numeric;
  v_treasury numeric;
  v_net_sales numeric;
  v_gross_profit numeric;
  v_returns numeric;
  v_returns_cost numeric;
  v_returns_profit numeric;
begin
  perform assert_sales_report_access(org_id);
  fin := has_permission(org_id, 'view_financial');

  select
    count(*) as invoices,
    coalesce(sum(subtotal), 0) as gross_sales,
    coalesce(sum(discount_total), 0) as discounts,
    coalesce(sum(tax_total), 0) as tax,
    coalesce(sum(total), 0) as billed,
    coalesce(sum(cogs_total), 0) as cogs,
    coalesce(sum(profit_total), 0) as gross_profit,
    (select coalesce(sum(ic.earned_commission), 0) from invoice_commissions ic
     where ic.organization_id = org_id
       and (p_from is null or ic.invoice_date >= p_from)
       and (p_to is null or ic.invoice_date <= p_to)) as commissions
  into s
  from v_sales_invoices
  where organization_id = org_id
    and (p_from is null or invoice_date >= p_from)
    and (p_to is null or invoice_date <= p_to);

  select coalesce(sum(subtotal_reversed), 0), coalesce(sum(cost_reversed), 0), coalesce(sum(profit_reversed), 0)
  into v_returns, v_returns_cost, v_returns_profit
  from v_sales_returns
  where organization_id = org_id
    and (p_from is null or return_date >= p_from)
    and (p_to is null or return_date <= p_to);

  v_net_sales := s.gross_sales - s.discounts - v_returns;

  if not fin then
    return jsonb_build_object(
      'period', jsonb_build_object('from', p_from, 'to', p_to),
      'sales', jsonb_build_object(
        'invoices', s.invoices,
        'gross_sales', s.gross_sales,
        'discounts', s.discounts,
        'returns', v_returns,
        'net_sales', v_net_sales,
        'tax', s.tax,
        'billed', s.billed
      ),
      'financial', null,
      'balances', null
    );
  end if;

  select coalesce(sum(amount), 0) into v_expenses
  from operating_expenses
  where organization_id = org_id
    and (p_from is null or expense_date >= p_from)
    and (p_to is null or expense_date <= p_to);

  select coalesce(jsonb_agg(jsonb_build_object('name', name, 'amount', amount) order by amount desc), '[]'::jsonb)
  into v_by_category
  from (
    select coalesce(c.name, 'بدون تصنيف') as name, sum(e.amount) as amount
    from operating_expenses e
    left join expense_categories c on c.id = e.category_id
    where e.organization_id = org_id
      and (p_from is null or e.expense_date >= p_from)
      and (p_to is null or e.expense_date <= p_to)
    group by 1
  ) t;

  select coalesce(sum(amount), 0) into v_collections
  from customer_collections
  where organization_id = org_id
    and (p_from is null or collection_date >= p_from)
    and (p_to is null or collection_date <= p_to);

  select coalesce(sum(amount), 0) into v_supplier_payments
  from supplier_payments
  where organization_id = org_id
    and (p_from is null or payment_date >= p_from)
    and (p_to is null or payment_date <= p_to);

  select coalesce(sum(total), 0) into v_purchases
  from purchase_invoices
  where organization_id = org_id
    and (p_from is null or invoice_date >= p_from)
    and (p_to is null or invoice_date <= p_to);

  select coalesce(sum(total), 0) into v_purchase_returns
  from purchase_returns
  where organization_id = org_id
    and (p_from is null or return_date >= p_from)
    and (p_to is null or return_date <= p_to);

  select coalesce(sum(balance), 0) into v_receivable from customer_balances where organization_id = org_id;
  select coalesce(sum(balance), 0) into v_payable from supplier_balances where organization_id = org_id;
  select coalesce(sum(st.quantity * coalesce(stc.avg_cost, 0)), 0) into v_inventory from inventory_stock st left join stock_costs stc on stc.stock_id = st.id where st.organization_id = org_id;
  select coalesce(sum(balance), 0) into v_treasury from treasury_balances where organization_id = org_id;

  v_gross_profit := v_net_sales - (s.cogs - v_returns_cost);

  return jsonb_build_object(
    'period', jsonb_build_object('from', p_from, 'to', p_to),
    'sales', jsonb_build_object(
      'invoices', s.invoices,
      'gross_sales', s.gross_sales,
      'discounts', s.discounts,
      'returns', v_returns,
      'net_sales', v_net_sales,
      'tax', s.tax,
      'billed', s.billed
    ),
    'financial', jsonb_build_object(
      'cogs', s.cogs - v_returns_cost,
      'gross_profit', v_gross_profit,
      'operating_expenses', v_expenses,
      'commissions', s.commissions,
      'commissions_paid', (select coalesce(sum(x.amount), 0) from expenses x
                           where x.organization_id = org_id and x.expense_type = 'commission_payout'
                             and (p_from is null or x.expense_date >= p_from) and (p_to is null or x.expense_date <= p_to)),
      'net_profit', v_gross_profit - v_expenses - s.commissions,
      'collections', v_collections,
      'supplier_payments', v_supplier_payments,
      'purchases', v_purchases,
      'purchase_returns', v_purchase_returns,
      'expenses_by_category', v_by_category
    ),
    'balances', jsonb_build_object(
      'receivable', v_receivable,
      'payable', v_payable,
      'inventory_value', v_inventory,
      'treasury', v_treasury
    )
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.report_timeseries(org_id uuid, p_from date DEFAULT NULL::date, p_to date DEFAULT NULL::date, p_bucket text DEFAULT 'day'::text)
 RETURNS TABLE(bucket date, net_sales numeric, gross_profit numeric, expenses numeric)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
declare
  fin boolean;
begin
  perform assert_sales_report_access(org_id);
  if p_bucket not in ('day', 'week', 'month') then
    raise exception 'تجميع غير مدعوم';
  end if;
  fin := has_permission(org_id, 'view_financial');

  return query
  with s as (
    select date_trunc(p_bucket, i.invoice_date::timestamp)::date as b,
           sum(i.subtotal - i.discount_total) as ns,
           sum(i.profit_total) as gp
    from v_sales_invoices i
    where i.organization_id = org_id
      and (p_from is null or i.invoice_date >= p_from)
      and (p_to is null or i.invoice_date <= p_to)
    group by 1
  ), rt as (
    select date_trunc(p_bucket, r.return_date::timestamp)::date as b,
           sum(r.subtotal_reversed) as rs,
           sum(r.profit_reversed) as rp
    from v_sales_returns r
    where r.organization_id = org_id
      and (p_from is null or r.return_date >= p_from)
      and (p_to is null or r.return_date <= p_to)
    group by 1
  ), e as (
    select date_trunc(p_bucket, x.expense_date::timestamp)::date as b,
           sum(x.amount) as ex
    from operating_expenses x
    where fin
      and x.organization_id = org_id
      and (p_from is null or x.expense_date >= p_from)
      and (p_to is null or x.expense_date <= p_to)
    group by 1
  )
  select coalesce(s.b, rt.b, e.b),
         (coalesce(s.ns, 0) - coalesce(rt.rs, 0))::numeric,
         case when fin then (coalesce(s.gp, 0) - coalesce(rt.rp, 0))::numeric end,
         case when fin then coalesce(e.ex, 0)::numeric end
  from s
  full join rt on rt.b = s.b
  full join e on e.b = coalesce(s.b, rt.b)
  order by 1;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.report_party_ledger(org_id uuid, p_type text, p_party uuid, p_from date DEFAULT NULL::date, p_to date DEFAULT NULL::date)
 RETURNS TABLE(entry_date date, entry_type text, reference text, description text, increase numeric, decrease numeric, balance numeric)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
declare
  v_opening_balance numeric(14,2) := 0;
begin
  if p_type = 'customer' then
    perform _assert_balance_access(org_id, 'customer');   -- owner, or a rep (his own customers only, by RLS)
  else
    perform assert_report_access(org_id, true);
  end if;
  if p_type not in ('customer', 'supplier') then
    raise exception 'نوع الطرف غير صحيح';
  end if;

  if p_type = 'customer' then
    select coalesce(ob.amount, 0) into v_opening_balance from customers c left join customer_opening_balances ob on ob.customer_id = c.id where c.id = p_party and c.organization_id = org_id;
    if not found then
      raise exception 'هذا العميل لا ينتمي إلى هذه المؤسسة';
    end if;
  else
    select coalesce(ob.amount, 0) into v_opening_balance from suppliers s left join supplier_opening_balances ob on ob.supplier_id = s.id where s.id = p_party and s.organization_id = org_id;
    if not found then
      raise exception 'هذا المورد لا ينتمي إلى هذه المؤسسة';
    end if;
  end if;

  return query
  with entries as (
    select i.invoice_date as d, i.created_at as ts, i.id as eid,
           'sale'::text as t, coalesce(i.invoice_number, '') as ref, i.notes as descr,
           i.total::numeric as inc, 0::numeric as dec
    from sales_invoices i
    where p_type = 'customer' and i.organization_id = org_id and i.customer_id = p_party
    union all
    select c.collection_date, c.created_at, c.id,
           'collection', coalesce(c.reference, ''), coalesce(c.payment_method, ''),
           0::numeric, c.amount::numeric
    from customer_collections c
    where p_type = 'customer' and c.organization_id = org_id and c.customer_id = p_party
    union all
    select r.return_date, r.created_at, r.id,
           'return', coalesce((select invoice_number from sales_invoices where id = r.sales_invoice_id), ''), r.notes,
           0::numeric, r.total::numeric
    from sales_returns r
    where p_type = 'customer' and r.organization_id = org_id and r.customer_id = p_party
    union all
    select r.return_date, r.created_at + interval '1 microsecond', r.id,
           'refund', coalesce((select invoice_number from sales_invoices where id = r.sales_invoice_id), ''), r.notes,
           r.cash_refunded::numeric, 0::numeric
    from sales_returns r
    where p_type = 'customer' and r.organization_id = org_id and r.customer_id = p_party and r.cash_refunded > 0
    union all
    select pi.invoice_date, pi.created_at, pi.id,
           'purchase', coalesce(pi.invoice_number, ''), pi.notes,
           pi.total::numeric, 0::numeric
    from purchase_invoices pi
    where p_type = 'supplier' and pi.organization_id = org_id and pi.supplier_id = p_party
    union all
    select sp.payment_date, sp.created_at, sp.id,
           'payment', coalesce(sp.reference, ''), coalesce(sp.payment_method, ''),
           0::numeric, sp.amount::numeric
    from supplier_payments sp
    where p_type = 'supplier' and sp.organization_id = org_id and sp.supplier_id = p_party
    union all
    select pr.return_date, pr.created_at, pr.id,
           'return', coalesce((select invoice_number from purchase_invoices where id = pr.purchase_invoice_id), ''), pr.notes,
           0::numeric, pr.total::numeric
    from purchase_returns pr
    where p_type = 'supplier' and pr.organization_id = org_id and pr.supplier_id = p_party
    union all
    select pr.return_date, pr.created_at + interval '1 microsecond', pr.id,
           'refund', coalesce((select invoice_number from purchase_invoices where id = pr.purchase_invoice_id), ''), pr.notes,
           pr.cash_refunded::numeric, 0::numeric
    from purchase_returns pr
    where p_type = 'supplier' and pr.organization_id = org_id and pr.supplier_id = p_party and pr.cash_refunded > 0
  ), running as (
    select e.*, v_opening_balance + sum(e.inc - e.dec) over (order by e.d, e.ts, (case when e.inc > 0 then 0 else 1 end), e.eid) as bal
    from entries e
  ), opening as (
    select p_from as d, 'opening'::text as t, ''::text as ref, ''::text as descr,
           0::numeric as inc, 0::numeric as dec,
           v_opening_balance + coalesce((select sum(e.inc - e.dec) from entries e where e.d < p_from), 0) as bal,
           0 as ord
    where p_from is not null
  )
  select x.d, x.t, x.ref, x.descr, x.inc, x.dec, x.bal
  from (
    select o.d, o.t, o.ref, o.descr, o.inc, o.dec, o.bal, o.ord, null::timestamptz as ts, 0 as tie, null::uuid as eid from opening o
    union all
    select r.d, r.t, r.ref, r.descr, r.inc, r.dec, r.bal, 1, r.ts, (case when r.inc > 0 then 0 else 1 end), r.eid
    from running r
    where (p_from is null or r.d >= p_from) and (p_to is null or r.d <= p_to)
  ) x
  order by x.d, x.ord, x.ts, x.tie, x.eid;
end;
$function$
;

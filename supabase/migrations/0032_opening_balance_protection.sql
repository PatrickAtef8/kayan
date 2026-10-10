-- Kayan — Phase 32: protect customers/suppliers opening balances (read AND write)
-- Depends on 0030, 0031. Re-runnable.
--
-- Why: row-level security cannot hide ONE column, so customers.opening_balance /
-- suppliers.opening_balance were readable (and writable by anyone who could update the row)
-- by every role that could see the party. The amount now lives in its own tables:
--   READ  : view_financial, or customers.view_balance / suppliers.view_balance
--   WRITE : view_financial, treasury.manage or manage_settings
-- and every change is audited. The old columns are dropped.

-- ---------------------------------------------------------------- helpers
create or replace function balance_edit_org_ids() returns setof uuid
language sql security definer stable set search_path = public as $$
  select distinct ou.organization_id
  from organization_users ou
  join role_permissions rp on rp.role_id = ou.role_id
  where ou.user_id = auth.uid() and ou.status = 'active'
    and rp.permission_key in ('view_financial', 'treasury.manage', 'manage_settings')
$$;
revoke all on function balance_edit_org_ids() from public, anon;
grant execute on function balance_edit_org_ids() to authenticated;

-- ---------------------------------------------------------------- tables
create table if not exists customer_opening_balances (
  customer_id     uuid primary key references customers(id) on delete cascade,
  organization_id uuid not null references organizations(id) on delete cascade,
  amount          numeric(14,2) not null default 0
                  check (amount <> 'NaN'::numeric and amount <> 'Infinity'::numeric and amount <> '-Infinity'::numeric),
  updated_by      uuid,
  updated_at      timestamptz not null default now()
);
create table if not exists supplier_opening_balances (
  supplier_id     uuid primary key references suppliers(id) on delete cascade,
  organization_id uuid not null references organizations(id) on delete cascade,
  amount          numeric(14,2) not null default 0
                  check (amount <> 'NaN'::numeric and amount <> 'Infinity'::numeric and amount <> '-Infinity'::numeric),
  updated_by      uuid,
  updated_at      timestamptz not null default now()
);
create index if not exists customer_opening_balances_org on customer_opening_balances (organization_id);
create index if not exists supplier_opening_balances_org on supplier_opening_balances (organization_id);

-- copy existing data (before the columns are dropped at the end)
do $$
begin
  if exists (select 1 from information_schema.columns where table_schema='public' and table_name='customers' and column_name='opening_balance') then
    insert into customer_opening_balances (customer_id, organization_id, amount)
    select id, organization_id, opening_balance from customers where opening_balance is not null and opening_balance <> 0
    on conflict (customer_id) do nothing;
  end if;
  if exists (select 1 from information_schema.columns where table_schema='public' and table_name='suppliers' and column_name='opening_balance') then
    insert into supplier_opening_balances (supplier_id, organization_id, amount)
    select id, organization_id, opening_balance from suppliers where opening_balance is not null and opening_balance <> 0
    on conflict (supplier_id) do nothing;
  end if;
end $$;

-- organization_id always comes from the party row (cannot be forged); stamp the editor
create or replace function opening_balance_stamp() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if TG_TABLE_NAME = 'customer_opening_balances' then
    select organization_id into NEW.organization_id from customers where id = NEW.customer_id;
  else
    select organization_id into NEW.organization_id from suppliers where id = NEW.supplier_id;
  end if;
  if NEW.organization_id is null then raise exception 'السجل غير موجود'; end if;
  NEW.updated_by := auth.uid();
  NEW.updated_at := now();
  return NEW;
end $$;
revoke all on function opening_balance_stamp() from public, anon;

drop trigger if exists opening_balance_stamp on customer_opening_balances;
drop trigger if exists opening_balance_stamp on supplier_opening_balances;
create trigger opening_balance_stamp before insert or update on customer_opening_balances for each row execute function opening_balance_stamp();
create trigger opening_balance_stamp before insert or update on supplier_opening_balances for each row execute function opening_balance_stamp();

-- audit every change (who / before / after)
drop trigger if exists audit_cob on customer_opening_balances;
drop trigger if exists audit_sob on supplier_opening_balances;
create trigger audit_cob after insert or update or delete on customer_opening_balances for each row execute function audit_row_change('customer_opening_balance', 'customer_id');
create trigger audit_sob after insert or update or delete on supplier_opening_balances for each row execute function audit_row_change('supplier_opening_balance', 'supplier_id');

-- ---------------------------------------------------------------- RLS
alter table customer_opening_balances enable row level security;
alter table customer_opening_balances force  row level security;
alter table supplier_opening_balances enable row level security;
alter table supplier_opening_balances force  row level security;
revoke all on customer_opening_balances, supplier_opening_balances from public, anon;
grant select, insert, update, delete on customer_opening_balances, supplier_opening_balances to authenticated;

do $$
declare t text; k text; col text; fn text;
begin
  for t, k, col, fn in values
    ('customer_opening_balances','customer','customer_id','customers'),
    ('supplier_opening_balances','supplier','supplier_id','suppliers')
  loop
    execute format('drop policy if exists ob_select on %I', t);
    execute format('drop policy if exists ob_insert on %I', t);
    execute format('drop policy if exists ob_update on %I', t);
    execute format('drop policy if exists ob_delete on %I', t);
    -- the EXISTS runs under the party table's own RLS, so a restricted rep only ever matches their own customers
    execute format($p$create policy ob_select on %1$I for select using (
        organization_id in (select balance_org_ids(%2$L)) and exists (select 1 from %3$I p where p.id = %1$I.%4$I))$p$, t, k, fn, col);
    execute format($p$create policy ob_insert on %1$I for insert with check (
        organization_id in (select balance_edit_org_ids()) and exists (select 1 from %3$I p where p.id = %1$I.%4$I))$p$, t, k, fn, col);
    execute format($p$create policy ob_update on %1$I for update
        using (organization_id in (select balance_edit_org_ids()) and exists (select 1 from %3$I p where p.id = %1$I.%4$I))
        with check (organization_id in (select balance_edit_org_ids()) and exists (select 1 from %3$I p where p.id = %1$I.%4$I))$p$, t, k, fn, col);
    execute format($p$create policy ob_delete on %1$I for delete using (
        organization_id in (select balance_edit_org_ids()) and exists (select 1 from %3$I p where p.id = %1$I.%4$I))$p$, t, k, fn, col);
  end loop;
end $$;

-- ---------------------------------------------------------------- views (same maths, new source)
create or replace view customer_balances
with (security_invoker = true) as
select
  c.id as customer_id,
  c.organization_id,
  case when c.organization_id in (select balance_org_ids('customer')) then coalesce(s.total_sales, 0) end as total_sales,
  case when c.organization_id in (select balance_org_ids('customer')) then coalesce(col.total_collected, 0) end as total_collected,
  case when c.organization_id in (select balance_org_ids('customer')) then
    coalesce(ob.amount, 0) + coalesce(s.total_sales, 0) - coalesce(col.total_collected, 0)
    - coalesce(r.total_returned, 0) + coalesce(r.total_refunded, 0) end as balance,
  case when c.organization_id in (select balance_org_ids('customer')) then coalesce(r.total_returned, 0) end as total_returned,
  case when c.organization_id in (select balance_org_ids('customer')) then coalesce(r.total_refunded, 0) end as total_refunded
from customers c
left join customer_opening_balances ob on ob.customer_id = c.id
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
    coalesce(ob.amount, 0) + coalesce(p.total_purchases, 0) - coalesce(pay.total_paid, 0)
    - coalesce(r.total_returned, 0) + coalesce(r.total_refunded, 0) end as balance,
  case when s.organization_id in (select balance_org_ids('supplier')) then coalesce(r.total_returned, 0) end as total_returned,
  case when s.organization_id in (select balance_org_ids('supplier')) then coalesce(r.total_refunded, 0) end as total_refunded
from suppliers s
left join supplier_opening_balances ob on ob.supplier_id = s.id
left join (select supplier_id, sum(total) as total_purchases from purchase_invoices group by supplier_id) p on p.supplier_id = s.id
left join (select supplier_id, sum(amount) as total_paid from supplier_payments group by supplier_id) pay on pay.supplier_id = s.id
left join (select supplier_id, sum(total) as total_returned, sum(cash_refunded) as total_refunded from purchase_returns group by supplier_id) r on r.supplier_id = s.id;

-- ---------------------------------------------------------------- report functions (only the opening-balance source changed)
CREATE OR REPLACE FUNCTION public.report_customer_analysis(org_id uuid, p_customer_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
declare
  c record; b record; v_rep_name text;
  v_totals jsonb; v_invoices jsonb; v_payments jsonb; v_returns jsonb; v_notes jsonb;
begin
  perform assert_party_report_access(org_id);
  select * into c from customers where id = p_customer_id and organization_id = org_id;
  if not found then raise exception 'العميل غير موجود'; end if;
  select * into b from customer_balances where customer_id = p_customer_id;
  select name into v_rep_name from sales_representatives where id = c.sales_rep_id;

  select jsonb_build_object(
    'invoices', count(*),
    'gross_sales', coalesce(sum(subtotal), 0),
    'line_discounts', coalesce(sum(line_discount_total), 0),
    'invoice_discounts', coalesce(sum(invoice_discount), 0),
    'cash_discounts', coalesce(sum(cash_discount), 0),
    'tier_discounts', coalesce(sum(tier_discount), 0),
    'discounts', coalesce(sum(discount_total), 0),
    'net_sales', coalesce(sum(subtotal - discount_total), 0),
    'tax', coalesce(sum(tax_total), 0),
    'billed', coalesce(sum(total), 0),
    'bonus_units', coalesce(sum(bonus_units), 0)
  ) into v_totals
  from sales_invoices where customer_id = p_customer_id and organization_id = org_id;

  select coalesce(jsonb_agg(jsonb_build_object(
      'id', i.id, 'invoice_number', i.invoice_number, 'invoice_date', i.invoice_date,
      'payment_method', i.payment_method, 'payment_status', i.payment_status,
      'subtotal', i.subtotal, 'line_discount', i.line_discount_total, 'invoice_discount', i.invoice_discount,
      'cash_discount', i.cash_discount, 'tier_discount', i.tier_discount, 'discount_total', i.discount_total,
      'tax', i.tax_total, 'total', i.total, 'amount_paid', i.amount_paid, 'bonus_units', i.bonus_units,
      'notes', i.notes,
      'items', (select coalesce(jsonb_agg(jsonb_build_object(
                  'product', p.name, 'quantity', it.quantity, 'bonus_quantity', it.bonus_quantity, 'is_bonus', it.is_bonus,
                  'unit_price', it.unit_price, 'discount', it.discount, 'allocated_discount', it.allocated_discount,
                  'net_total', it.net_total, 'effective_unit_price', it.effective_unit_price
                ) order by it.is_bonus, p.name), '[]'::jsonb)
                from sales_invoice_items it join products p on p.id = it.product_id where it.sales_invoice_id = i.id)
    ) order by i.invoice_date desc, i.created_at desc), '[]'::jsonb)
  into v_invoices
  from sales_invoices i where i.customer_id = p_customer_id and i.organization_id = org_id;

  select coalesce(jsonb_agg(jsonb_build_object(
      'id', cc.id, 'date', cc.collection_date, 'amount', cc.amount, 'payment_method', cc.payment_method,
      'reference', cc.reference, 'invoice_number', si.invoice_number, 'notes', cc.notes
    ) order by cc.collection_date desc, cc.created_at desc), '[]'::jsonb)
  into v_payments
  from customer_collections cc left join sales_invoices si on si.id = cc.sales_invoice_id
  where cc.customer_id = p_customer_id and cc.organization_id = org_id;

  select coalesce(jsonb_agg(jsonb_build_object(
      'id', r.id, 'date', r.return_date, 'total', r.total, 'cash_refunded', r.cash_refunded, 'invoice_number', si.invoice_number,
      'notes', r.notes,
      'items', (select coalesce(jsonb_agg(jsonb_build_object('product', p.name, 'quantity', ri.quantity, 'condition', ri.condition,
                  'unit_price', ri.unit_price, 'amount', ri.revenue_reversed) order by p.name), '[]'::jsonb)
                from sales_return_items ri join products p on p.id = ri.product_id where ri.sales_return_id = r.id)
    ) order by r.return_date desc, r.created_at desc), '[]'::jsonb)
  into v_returns
  from sales_returns r join sales_invoices si on si.id = r.sales_invoice_id
  where r.customer_id = p_customer_id and r.organization_id = org_id;

  select coalesce(jsonb_agg(jsonb_build_object('id', n.id, 'note', n.note, 'created_at', n.created_at, 'invoice_id', n.sales_invoice_id)
                            order by n.created_at desc), '[]'::jsonb)
  into v_notes from party_notes n where n.customer_id = p_customer_id and n.organization_id = org_id;

  return jsonb_build_object(
    'customer', jsonb_build_object('id', c.id, 'name', c.name, 'phone', c.phone, 'address', c.address,
                                   'rep_id', c.sales_rep_id, 'rep_name', v_rep_name, 'opening_balance', coalesce((select ob.amount from customer_opening_balances ob where ob.customer_id = c.id), 0),
                                   'credit_status', c.credit_status),
    'totals', v_totals || jsonb_build_object('payments', coalesce(b.total_collected, 0), 'returns', coalesce(b.total_returned, 0),
                                             'debt', coalesce(b.balance, 0)),
    'invoices', v_invoices, 'payments', v_payments, 'returns', v_returns, 'notes', v_notes
  );
end $function$;

CREATE OR REPLACE FUNCTION public.report_customer_debts(org_id uuid, p_search text DEFAULT NULL::text, p_rep_id uuid DEFAULT NULL::uuid, p_only_debt boolean DEFAULT true, p_limit integer DEFAULT 100, p_offset integer DEFAULT 0)
 RETURNS TABLE(customer_id uuid, customer_name text, phone text, rep_id uuid, rep_name text, opening_balance numeric, total_sales numeric, total_paid numeric, total_returned numeric, outstanding numeric, last_payment_date date, last_payment_amount numeric, grand_total numeric, total_count bigint)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
declare
  v_limit int := least(greatest(coalesce(p_limit, 100), 1), 1000);
  v_offset int := greatest(coalesce(p_offset, 0), 0);
  v_q text := nullif(btrim(coalesce(p_search, '')), '');
begin
  perform assert_party_report_access(org_id);
  return query
  select * from (
    select c.id as k_id, c.name as k_name, c.phone as k_phone, c.sales_rep_id as k_rep, r.name as k_rep_name,
           (coalesce((select ob.amount from customer_opening_balances ob where ob.customer_id = c.id), 0))::numeric as k_open, b.total_sales::numeric as k_sales, b.total_collected::numeric as k_paid,
           b.total_returned::numeric as k_ret, b.balance::numeric as k_bal,
           lp.collection_date as k_lp_date, lp.amount::numeric as k_lp_amt,
           (sum(b.balance) over ())::numeric as k_total,
           (count(*) over ())::bigint as k_count
    from customers c
    join customer_balances b on b.customer_id = c.id
    left join sales_representatives r on r.id = c.sales_rep_id
    left join lateral (
      select cc.collection_date, cc.amount from customer_collections cc
      where cc.customer_id = c.id order by cc.collection_date desc, cc.created_at desc limit 1
    ) lp on true
    where c.organization_id = org_id and b.organization_id = org_id
      and (v_q is null or c.name ilike '%' || v_q || '%' or c.phone ilike '%' || v_q || '%')
      and (p_rep_id is null or c.sales_rep_id = p_rep_id)
      and (not coalesce(p_only_debt, true) or b.balance > 0)
  ) x
  order by x.k_bal desc, x.k_name
  limit v_limit offset v_offset;
end $function$;

CREATE OR REPLACE FUNCTION public.report_party_ledger(org_id uuid, p_type text, p_party uuid, p_from date DEFAULT NULL::date, p_to date DEFAULT NULL::date)
 RETURNS TABLE(entry_date date, entry_type text, reference text, description text, increase numeric, decrease numeric, balance numeric)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
declare
  v_opening_balance numeric(14,2) := 0;
begin
  perform assert_report_access(org_id, true);
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
$function$;

CREATE OR REPLACE FUNCTION public.report_supplier_analysis(org_id uuid, p_supplier_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
declare
  s record; b record; v_totals jsonb; v_invoices jsonb; v_payments jsonb; v_returns jsonb; v_notes jsonb;
begin
  perform assert_party_report_access(org_id);
  select * into s from suppliers where id = p_supplier_id and organization_id = org_id;
  if not found then raise exception 'المورد غير موجود'; end if;
  select * into b from supplier_balances where supplier_id = p_supplier_id;

  select jsonb_build_object(
    'invoices', count(*),
    'gross_purchases', coalesce(sum(subtotal), 0),
    'line_discounts', coalesce(sum(line_discount_total), 0),
    'invoice_discounts', coalesce(sum(invoice_discount), 0),
    'cash_discounts', coalesce(sum(cash_discount), 0),
    'tier_discounts', coalesce(sum(tier_discount), 0),
    'discounts', coalesce(sum(discount_total), 0),
    'net_purchases', coalesce(sum(subtotal - discount_total), 0),
    'tax', coalesce(sum(tax_total), 0),
    'billed', coalesce(sum(total), 0),
    'bonus_units', coalesce(sum(bonus_units), 0)
  ) into v_totals
  from purchase_invoices where supplier_id = p_supplier_id and organization_id = org_id;

  select coalesce(jsonb_agg(jsonb_build_object(
      'id', i.id, 'invoice_number', i.invoice_number, 'invoice_date', i.invoice_date,
      'payment_method', i.payment_method, 'payment_status', i.payment_status,
      'subtotal', i.subtotal, 'line_discount', i.line_discount_total, 'invoice_discount', i.invoice_discount,
      'cash_discount', i.cash_discount, 'tier_discount', i.tier_discount, 'discount_total', i.discount_total,
      'tax', i.tax_total, 'total', i.total, 'amount_paid', i.amount_paid, 'bonus_units', i.bonus_units, 'notes', i.notes,
      'items', (select coalesce(jsonb_agg(jsonb_build_object(
                  'product', p.name, 'quantity', it.quantity, 'bonus_quantity', it.bonus_quantity, 'is_bonus', it.is_bonus,
                  'unit_cost', it.unit_cost, 'discount', it.discount, 'allocated_discount', it.allocated_discount,
                  'net_total', it.net_total, 'effective_unit_cost', it.effective_unit_cost
                ) order by it.is_bonus, p.name), '[]'::jsonb)
                from purchase_invoice_items it join products p on p.id = it.product_id where it.purchase_invoice_id = i.id)
    ) order by i.invoice_date desc, i.created_at desc), '[]'::jsonb)
  into v_invoices
  from purchase_invoices i where i.supplier_id = p_supplier_id and i.organization_id = org_id;

  select coalesce(jsonb_agg(jsonb_build_object(
      'id', sp.id, 'date', sp.payment_date, 'amount', sp.amount, 'payment_method', sp.payment_method,
      'reference', sp.reference, 'invoice_number', pi.invoice_number, 'notes', sp.notes
    ) order by sp.payment_date desc, sp.created_at desc), '[]'::jsonb)
  into v_payments
  from supplier_payments sp left join purchase_invoices pi on pi.id = sp.purchase_invoice_id
  where sp.supplier_id = p_supplier_id and sp.organization_id = org_id;

  select coalesce(jsonb_agg(jsonb_build_object(
      'id', r.id, 'date', r.return_date, 'total', r.total, 'cash_refunded', r.cash_refunded, 'invoice_number', pi.invoice_number,
      'notes', r.notes,
      'items', (select coalesce(jsonb_agg(jsonb_build_object('product', p.name, 'quantity', ri.quantity, 'unit_cost', ri.unit_cost, 'amount', ri.line_total) order by p.name), '[]'::jsonb)
                from purchase_return_items ri join products p on p.id = ri.product_id where ri.purchase_return_id = r.id)
    ) order by r.return_date desc, r.created_at desc), '[]'::jsonb)
  into v_returns
  from purchase_returns r join purchase_invoices pi on pi.id = r.purchase_invoice_id
  where r.supplier_id = p_supplier_id and r.organization_id = org_id;

  select coalesce(jsonb_agg(jsonb_build_object('id', n.id, 'note', n.note, 'created_at', n.created_at) order by n.created_at desc), '[]'::jsonb)
  into v_notes from party_notes n where n.supplier_id = p_supplier_id and n.organization_id = org_id;

  return jsonb_build_object(
    'supplier', jsonb_build_object('id', s.id, 'name', s.name, 'phone', s.phone, 'address', s.address, 'opening_balance', coalesce((select ob.amount from supplier_opening_balances ob where ob.supplier_id = s.id), 0)),
    'totals', v_totals || jsonb_build_object('payments', coalesce(b.total_paid, 0), 'returns', coalesce(b.total_returned, 0), 'debt', coalesce(b.balance, 0)),
    'invoices', v_invoices, 'payments', v_payments, 'returns', v_returns, 'notes', v_notes
  );
end $function$;

CREATE OR REPLACE FUNCTION public.report_supplier_debts(org_id uuid, p_search text DEFAULT NULL::text, p_only_debt boolean DEFAULT true, p_limit integer DEFAULT 100, p_offset integer DEFAULT 0)
 RETURNS TABLE(supplier_id uuid, supplier_name text, phone text, opening_balance numeric, total_purchases numeric, total_paid numeric, total_returned numeric, outstanding numeric, last_payment_date date, last_payment_amount numeric, grand_total numeric, total_count bigint)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
declare
  v_limit int := least(greatest(coalesce(p_limit, 100), 1), 1000);
  v_offset int := greatest(coalesce(p_offset, 0), 0);
  v_q text := nullif(btrim(coalesce(p_search, '')), '');
begin
  perform assert_party_report_access(org_id);
  return query
  select * from (
    select s.id as k_id, s.name as k_name, s.phone as k_phone,
           (coalesce((select ob.amount from supplier_opening_balances ob where ob.supplier_id = s.id), 0))::numeric as k_open, b.total_purchases::numeric as k_sales, b.total_paid::numeric as k_paid,
           b.total_returned::numeric as k_ret, b.balance::numeric as k_bal,
           lp.payment_date as k_lp_date, lp.amount::numeric as k_lp_amt,
           (sum(b.balance) over ())::numeric as k_total,
           (count(*) over ())::bigint as k_count
    from suppliers s
    join supplier_balances b on b.supplier_id = s.id
    left join lateral (
      select sp.payment_date, sp.amount from supplier_payments sp
      where sp.supplier_id = s.id order by sp.payment_date desc, sp.created_at desc limit 1
    ) lp on true
    where s.organization_id = org_id and b.organization_id = org_id
      and (v_q is null or s.name ilike '%' || v_q || '%' or s.phone ilike '%' || v_q || '%')
      and (not coalesce(p_only_debt, true) or b.balance > 0)
  ) x
  order by x.k_bal desc, x.k_name
  limit v_limit offset v_offset;
end $function$;

-- ---------------------------------------------------------------- drop the exposed columns
alter table customers drop column if exists opening_balance;
alter table suppliers drop column if exists opening_balance;

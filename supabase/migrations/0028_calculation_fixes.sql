-- ============================================================
-- 0028 — Calculation audit fixes, applied on top of 0022–0027
--
-- Your 0022–0027 (pricing engine, net-price returns, rep commission gate,
-- analysis reports, hidden cost/profit) already fix part of the audit:
--   * line discounts and the invoice-level discount reach subtotal / total /
--     profit, allocated to lines with the last line absorbing the rounding
--   * returns are valued at the net price and a full return reverses the
--     exact net amount
-- This migration fixes what is still open, on top of that design:
--   #2  returns also reverse the invoice TAX (sales and purchases)
--   #3  dashboard totals = the numbers of report_summary
--   #4  purchase returns take the returned units out of the weighted average
--   #5  stock cost keeps 6 decimals (money columns stay at 2)
--   #6  a tracked product cannot be sold below zero stock (bonus items too)
--   #7  server-side validation: no negative discount / tax, collections and
--       payments never above what is owed, tax only on a non-zero invoice
--   #8  commission recomputed after collections; never on tax, never grown
--       by overpayment (returns keep their commission: your 0024 policy)
--   #9  report_timeseries nets returns; every report subtracts net-of-tax
--       return value
--   +   a cash refund now moves the customer / supplier balance and appears
--       as its own ledger entry
--
-- Conventions added here:
--   item.tax_alloc               the line's share of the invoice tax
--   return.subtotal_reversed     net sales reversed (excludes tax)
--   return.tax_reversed          tax reversed
--   return.total                 subtotal_reversed + tax_reversed (the credit)
-- ============================================================

-- ---------- 0. Prerequisite check ----------
do $$
declare
  missing text[] := '{}';
begin
  if to_regclass('public.sales_returns') is null            then missing := array_append(missing, '0011_returns_and_team'::text); end if;
  if to_regclass('public.stock_transfer_items') is null     then missing := array_append(missing, '0015_warehouse_transfers'::text); end if;
  if not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'customers' and column_name = 'opening_balance')
                                                              then missing := array_append(missing, '0018_opening_balances'::text); end if;
  if not exists (select 1 from pg_proc where proname = 'dashboard_sales_totals')
                                                              then missing := array_append(missing, '0021_dashboard_totals'::text); end if;
  if to_regclass('public.discount_tiers') is null            then missing := array_append(missing, '0022_discounts_bonus_net_pricing'::text); end if;
  if not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'sales_invoice_items' and column_name = 'net_total')
                                                              then missing := array_append(missing, '0022_discounts_bonus_net_pricing'::text); end if;
  if not exists (select 1 from pg_proc where proname = 'get_returnable_items' and pronargs = 2 and pg_get_function_result(oid) like '%bonus_quantity%')
                                                              then missing := array_append(missing, '0023_net_price_returns'::text); end if;
  if to_regclass('public.party_notes') is null               then missing := array_append(missing, '0024_rep_targets_commission_rls'::text); end if;
  if not exists (select 1 from pg_proc where proname = 'report_customer_analysis')
                                                              then missing := array_append(missing, '0025_analysis_reports'::text); end if;
  if to_regclass('public.sales_invoice_financials') is null  then missing := array_append(missing, '0027_hide_cost_profit'::text); end if;

  if array_length(missing, 1) is not null then
    raise exception '0028 cannot run yet: these earlier migrations are not applied on this database: %. Apply them in order (oldest first), then run 0028 again. Nothing was changed.',
      array_to_string(array(select distinct x from unnest(missing) x order by x), ', ');
  end if;
end $$;

-- ---------- 0b. Leftover overloads ----------
-- If the first-round fix file (an older "0022_calculation_fixes") was ever applied on
-- this database, its function versions can sit next to the current ones with a
-- different argument list, which makes calls ambiguous. Remove those old signatures
-- (no-ops on a database that never had them).
drop function if exists create_sales_invoice(uuid, uuid, uuid, text, date, jsonb, numeric, numeric, numeric, text, text, uuid);
drop function if exists create_purchase_invoice(uuid, uuid, uuid, text, date, jsonb, numeric, numeric, numeric, text, text);
drop function if exists create_sales_return(uuid, uuid, date, jsonb, numeric, text);
drop function if exists create_purchase_return(uuid, uuid, date, jsonb, numeric, text);

-- ---------- 1. Precision: stock cost keeps 6 decimals ----------
-- (sales_item_financials / sales_return_item_financials.unit_cost stay 2 decimals:
--  they are display values, the ledger numbers are cost_total / cost_reversed.)
alter table inventory_stock       alter column avg_cost  type numeric(14,6);
alter table product_prices        alter column cost      type numeric(14,6);
alter table inventory_movements   alter column unit_cost type numeric(14,6);
alter table stock_transfer_items  alter column unit_cost type numeric(14,6);

-- ---------- 2. New columns ----------
alter table sales_invoices         add column if not exists commission_rate_snapshot numeric(5,2);
alter table sales_invoice_items    add column if not exists tax_alloc numeric(14,2) not null default 0;
alter table purchase_invoice_items add column if not exists tax_alloc numeric(14,2) not null default 0;
alter table sales_returns          add column if not exists tax_reversed numeric(14,2) not null default 0;
alter table purchase_returns       add column if not exists tax_reversed numeric(14,2) not null default 0;
alter table sales_return_items     add column if not exists tax_reversed numeric(14,2) not null default 0;
alter table purchase_return_items  add column if not exists tax_reversed numeric(14,2) not null default 0;

-- ---------- 3. Helpers ----------
create or replace function allocate_by_weight(p_amount numeric, p_weights numeric[])
returns numeric[]
language plpgsql
immutable
as $$
declare
  v_total numeric := 0;
  v_cum numeric := 0;
  v_prev numeric := 0;
  v_now numeric;
  v_out numeric[] := '{}';
  i int;
begin
  if p_weights is null or array_length(p_weights, 1) is null then
    return v_out;
  end if;
  for i in 1 .. array_length(p_weights, 1) loop
    v_total := v_total + coalesce(p_weights[i], 0);
  end loop;
  for i in 1 .. array_length(p_weights, 1) loop
    if v_total = 0 or coalesce(p_amount, 0) = 0 then
      v_out := v_out || 0::numeric;
    else
      v_cum := v_cum + coalesce(p_weights[i], 0);
      v_now := round(p_amount * v_cum / v_total, 2);
      v_out := v_out || (v_now - v_prev);
      v_prev := v_now;
    end if;
  end loop;
  return v_out;
end;
$$;

-- Splits the invoice tax over its paid lines by net value (cumulative
-- rounding, so the shares add up exactly to the tax).
create or replace function allocate_invoice_tax(p_kind text, p_invoice_id uuid, p_tax numeric)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ids uuid[];
  v_w numeric[];
  v_alloc numeric[];
  k int;
begin
  if coalesce(p_tax, 0) = 0 then
    return;
  end if;
  if p_kind = 'sales' then
    select array_agg(id order by id), array_agg(net_total order by id) into v_ids, v_w
    from sales_invoice_items where sales_invoice_id = p_invoice_id and net_total > 0;
  else
    select array_agg(id order by id), array_agg(net_total order by id) into v_ids, v_w
    from purchase_invoice_items where purchase_invoice_id = p_invoice_id and net_total > 0;
  end if;
  if v_ids is null then
    raise exception 'لا يمكن إضافة ضريبة على فاتورة قيمتها صفر';
  end if;
  v_alloc := allocate_by_weight(p_tax, v_w);
  for k in 1 .. array_length(v_ids, 1) loop
    if p_kind = 'sales' then
      update sales_invoice_items set tax_alloc = v_alloc[k] where id = v_ids[k];
    else
      update purchase_invoice_items set tax_alloc = v_alloc[k] where id = v_ids[k];
    end if;
  end loop;
end;
$$;
revoke all on function allocate_invoice_tax(text, uuid, numeric) from public, anon, authenticated;

-- What is still owed on one invoice (credit notes and cash refunds included).
create or replace function sales_invoice_remaining(p_invoice_id uuid)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select i.total - i.amount_paid
         - coalesce((select sum(r.total) from sales_returns r where r.sales_invoice_id = i.id), 0)
         + coalesce((select sum(r.cash_refunded) from sales_returns r where r.sales_invoice_id = i.id), 0)
  from sales_invoices i where i.id = p_invoice_id;
$$;
revoke all on function sales_invoice_remaining(uuid) from public, anon, authenticated;

create or replace function purchase_invoice_remaining(p_invoice_id uuid)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select i.total - i.amount_paid
         - coalesce((select sum(r.total) from purchase_returns r where r.purchase_invoice_id = i.id), 0)
         + coalesce((select sum(r.cash_refunded) from purchase_returns r where r.purchase_invoice_id = i.id), 0)
  from purchase_invoices i where i.id = p_invoice_id;
$$;
revoke all on function purchase_invoice_remaining(uuid) from public, anon, authenticated;

-- Commission is recomputed from the invoice's own figures (never on tax, never
-- grown by overpayment). Returns do NOT reduce it: your 0024 keeps a returned
-- invoice's commission ("history kept") and gates what is EARNED per month through
-- invoice_commissions / rep_monthly_performance, which net returns into the month.
create or replace function recompute_sales_commission(p_invoice_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  i record;
  v_profit numeric := 0;
  v_net numeric;
  v_base numeric := 0;
begin
  select * into i from sales_invoices where id = p_invoice_id;
  if not found or i.sales_rep_id is null or i.commission_basis_snapshot is null then
    return;
  end if;

  select coalesce(f.profit_total, 0) into v_profit from sales_invoice_financials f where f.sales_invoice_id = p_invoice_id;
  v_net := i.subtotal - i.discount_total;

  v_base := case i.commission_basis_snapshot
    when 'sales_value'      then i.subtotal
    when 'net_sales'        then v_net
    when 'gross_profit'     then v_profit
    -- cash collected, with the tax share taken out
    when 'collected_amount' then least(i.amount_paid, i.total) * case when i.total > 0 then v_net / i.total else 1 end
    else 0
  end;

  update sales_invoices
  set commission_amount = round(v_base * coalesce(i.commission_rate_snapshot, 0) / 100, 2)
  where id = p_invoice_id;
end;
$$;
revoke all on function recompute_sales_commission(uuid) from public, anon, authenticated;

-- ---------- 4. Back-fill existing rows ----------
update sales_invoices i
set commission_rate_snapshot = r.commission_rate
from sales_representatives r
where r.id = i.sales_rep_id and i.commission_rate_snapshot is null;

-- Allocate the tax of existing invoices to their lines so future returns can
-- reverse it. History is NOT rewritten: totals and balances stay as billed.
do $$
declare
  inv record;
  ids uuid[];
  w numeric[];
  alloc numeric[];
  k int;
begin
  for inv in select id, tax_total from sales_invoices where tax_total > 0 loop
    select array_agg(id order by id), array_agg(net_total order by id) into ids, w
    from sales_invoice_items where sales_invoice_id = inv.id and net_total > 0;
    continue when ids is null;
    alloc := allocate_by_weight(inv.tax_total, w);
    for k in 1 .. array_length(ids, 1) loop
      update sales_invoice_items set tax_alloc = alloc[k] where id = ids[k];
    end loop;
  end loop;
  for inv in select id, tax_total from purchase_invoices where tax_total > 0 loop
    select array_agg(id order by id), array_agg(net_total order by id) into ids, w
    from purchase_invoice_items where purchase_invoice_id = inv.id and net_total > 0;
    continue when ids is null;
    alloc := allocate_by_weight(inv.tax_total, w);
    for k in 1 .. array_length(ids, 1) loop
      update purchase_invoice_items set tax_alloc = alloc[k] where id = ids[k];
    end loop;
  end loop;
end $$;

-- ============================================================
-- 5. Pricing engine — reject negative discount/tax/payment, no tax on a zero invoice
-- ============================================================
CREATE OR REPLACE FUNCTION public._pricing(org_id uuid, p_applies text, items jsonb, p_invoice_discount numeric, p_cash_discount numeric, p_payment_method text, p_amount_paid numeric, p_tax numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  e jsonb;
  rule record;
  v_q numeric; v_p numeric; v_d numeric;
  v_gross numeric(14,2) := 0;
  v_line_disc numeric(14,2) := 0;
  v_base numeric(14,2);
  v_tier numeric(14,2) := 0;
  v_inv numeric(14,2) := greatest(coalesce(p_invoice_discount, 0), 0);
  v_cash numeric(14,2) := 0;
  v_times numeric;
  v_bonus jsonb := '[]'::jsonb;
  v_disc numeric(14,2);
  v_net numeric(14,2);
begin
  if p_applies not in ('sales', 'purchases') then raise exception 'نوع العملية غير مدعوم'; end if;
  if coalesce(p_invoice_discount, 0) < 0 then raise exception 'الخصم لا يمكن أن يكون سالبًا'; end if;
  if coalesce(p_cash_discount, 0) < 0 then raise exception 'الخصم النقدي لا يمكن أن يكون سالبًا'; end if;
  if coalesce(p_tax, 0) < 0 then raise exception 'الضريبة لا يمكن أن تكون سالبة'; end if;
  if coalesce(p_amount_paid, 0) < 0 then raise exception 'المبلغ لا يمكن أن يكون سالبًا'; end if;
  if items is null or jsonb_array_length(items) = 0 then
    raise exception 'يجب إضافة صنف واحد على الأقل للفاتورة';
  end if;

  for e in select * from jsonb_array_elements(items) loop
    v_q := (e->>'quantity')::numeric;
    v_p := case p_applies when 'sales' then (e->>'unit_price')::numeric else (e->>'unit_cost')::numeric end;
    v_d := coalesce((e->>'discount')::numeric, 0);
    if v_q is null or v_q <= 0 then raise exception 'يجب أن تكون الكمية أكبر من صفر'; end if;
    if v_p is null or v_p < 0 then raise exception 'السعر غير صحيح'; end if;
    if v_d < 0 or v_d > v_q * v_p then raise exception 'خصم الصنف غير صحيح'; end if;
    v_gross := v_gross + round(v_q * v_p, 2);
    v_line_disc := v_line_disc + v_d;
  end loop;
  v_base := v_gross - v_line_disc;

  select t.discount_amount into v_tier
  from discount_tiers t
  where t.organization_id = org_id and t.applies_to = p_applies and t.is_active and t.min_amount <= v_base
  order by t.min_amount desc limit 1;
  v_tier := coalesce(v_tier, 0);

  if is_cash_payment(p_payment_method) and coalesce(p_amount_paid, 0) > 0 then
    v_cash := greatest(coalesce(p_cash_discount, 0), 0);
  end if;

  if v_inv + v_cash + v_tier > v_base then
    raise exception 'إجمالي الخصومات أكبر من قيمة الفاتورة';
  end if;

  for rule in
    select r.*, agg.q
    from bonus_rules r
    join (
      select (x->>'product_id')::uuid as pid, sum((x->>'quantity')::numeric) as q
      from jsonb_array_elements(items) x group by 1
    ) agg on agg.pid = r.product_id
    where r.organization_id = org_id and r.applies_to = p_applies and r.is_active and agg.q >= r.min_quantity
    order by r.created_at, r.id
  loop
    v_times := case when rule.is_repeating then floor(rule.q / rule.min_quantity) else 1 end;
    v_bonus := v_bonus || jsonb_build_object('trigger', rule.product_id, 'product', rule.bonus_product_id, 'qty', v_times * rule.bonus_quantity);
  end loop;

  v_disc := v_line_disc + v_inv + v_cash + v_tier;
  v_net := v_gross - v_disc;
  if coalesce(p_tax, 0) > 0 and v_net <= 0 then raise exception 'لا يمكن إضافة ضريبة على فاتورة قيمتها صفر'; end if;
  return jsonb_build_object(
    'gross', v_gross, 'line_discount', v_line_disc, 'base', v_base,
    'tier_discount', v_tier, 'invoice_discount', v_inv, 'cash_discount', v_cash,
    'invoice_level_discount', v_inv + v_cash + v_tier,
    'discount_total', v_disc, 'net', v_net,
    'tax', coalesce(p_tax, 0), 'total', v_net + coalesce(p_tax, 0),
    'bonus', v_bonus
  );
end $function$;

-- ============================================================
-- 6. Stock helpers — 6-decimal cost, no selling below zero stock
-- ============================================================
CREATE OR REPLACE FUNCTION public._consume_stock(org_id uuid, p_product uuid, p_wh uuid, p_qty numeric, p_ref uuid)
 RETURNS numeric
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_track boolean; v_old_qty numeric(14,3); v_old_avg numeric(14,6); v_cost numeric(14,6);
begin
  select track_inventory into v_track from products where id = p_product and organization_id = org_id;
  if not found then raise exception 'أحد المنتجات المختارة لا ينتمي إلى هذه المؤسسة'; end if;
  if v_track then
    select quantity, avg_cost into v_old_qty, v_old_avg
    from inventory_stock where product_id = p_product and warehouse_id = p_wh for update;
    if not found then
      v_old_qty := 0; v_old_avg := 0;
      insert into inventory_stock (organization_id, product_id, warehouse_id, quantity, avg_cost) values (org_id, p_product, p_wh, 0, 0);
    end if;
    if v_old_qty < p_qty then
      raise exception 'الكمية المتاحة بالمخزون أقل من الكمية المطلوبة (المتاح: %)', greatest(v_old_qty, 0);
    end if;
    v_cost := v_old_avg;
    update inventory_stock set quantity = v_old_qty - p_qty, updated_at = now() where product_id = p_product and warehouse_id = p_wh;
    insert into inventory_movements (organization_id, product_id, warehouse_id, movement_type, quantity_delta, unit_cost, reference_type, reference_id, created_by)
    values (org_id, p_product, p_wh, 'sale', -p_qty, v_cost, 'sales_invoice', p_ref, auth.uid());
  else
    select coalesce(cost, 0) into v_cost from product_prices where product_id = p_product and organization_id = org_id limit 1;
    v_cost := coalesce(v_cost, 0);
  end if;
  return v_cost;
end $function$;

CREATE OR REPLACE FUNCTION public._receive_stock(org_id uuid, p_product uuid, p_wh uuid, p_qty numeric, p_unit_cost numeric, p_ref uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_old_qty numeric(14,3); v_old_avg numeric(14,6); v_new_qty numeric(14,3); v_new_avg numeric(14,6);
begin
  select quantity, avg_cost into v_old_qty, v_old_avg
  from inventory_stock where product_id = p_product and warehouse_id = p_wh for update;
  if not found then
    v_old_qty := 0; v_old_avg := 0;
    insert into inventory_stock (organization_id, product_id, warehouse_id, quantity, avg_cost) values (org_id, p_product, p_wh, 0, 0);
  end if;
  v_new_qty := v_old_qty + p_qty;
  v_new_avg := case when greatest(v_old_qty, 0) + p_qty = 0 then v_old_avg
                    else ((greatest(v_old_qty, 0) * v_old_avg) + (p_qty * p_unit_cost)) / (greatest(v_old_qty, 0) + p_qty) end;
  update inventory_stock set quantity = v_new_qty, avg_cost = v_new_avg, updated_at = now() where product_id = p_product and warehouse_id = p_wh;
  insert into inventory_movements (organization_id, product_id, warehouse_id, movement_type, quantity_delta, unit_cost, reference_type, reference_id, created_by)
  values (org_id, p_product, p_wh, 'purchase', p_qty, p_unit_cost, 'purchase_invoice', p_ref, auth.uid());
  update product_prices set cost = v_new_avg, updated_at = now() where product_id = p_product and organization_id = org_id;
end $function$;

-- ============================================================
-- 7. create_sales_invoice — tax shares, no overpay, exact cost, commission snapshot
-- ============================================================
CREATE OR REPLACE FUNCTION public.create_sales_invoice(org_id uuid, p_customer_id uuid, p_warehouse_id uuid, p_invoice_number text, p_invoice_date date, items jsonb, p_discount_total numeric, p_tax_total numeric, p_amount_collected numeric, p_payment_method text, p_notes text, p_sales_rep_id uuid DEFAULT NULL::uuid, p_cash_discount numeric DEFAULT 0)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  new_invoice_id uuid;
  account_id uuid;
  e jsonb; b record;
  v_pr jsonb; v_bonus jsonb;
  v_rep uuid; v_cust_rep uuid;
  v_product_id uuid; v_q numeric(14,3); v_price numeric(14,2); v_ldisc numeric(14,2);
  v_same numeric(14,3); v_done uuid[] := '{}';
  v_idx int := 0; v_n int; v_item_id uuid;
  v_base_line numeric(14,2); v_base_sum numeric(14,2); v_level numeric(14,2);
  v_alloc numeric(14,2); v_alloc_used numeric(14,2) := 0;
  v_units numeric(14,3); v_unit_cost numeric(14,6); v_cost_total numeric(14,2); v_net_line numeric(14,2);
  v_gross numeric(14,2); v_disc_total numeric(14,2); v_net numeric(14,2); v_total numeric(14,2);
  v_cogs numeric(14,2) := 0; v_bonus_units numeric(14,3) := 0; v_bonus_cost numeric(14,2) := 0;
  v_profit numeric(14,2); v_collected numeric(14,2); v_status text;
  v_commission_basis text; v_commission_rate numeric(5,2); v_commission numeric(14,2) := 0;
begin
  if auth.uid() is null then raise exception 'يجب تسجيل الدخول أولاً'; end if;
  if not is_org_member(org_id) then raise exception 'أنت لست عضوًا في هذه المؤسسة'; end if;
  if not has_permission(org_id, 'sales.create') then raise exception 'ليس لديك صلاحية إنشاء فواتير البيع'; end if;

  select sales_rep_id into v_cust_rep from customers where id = p_customer_id and organization_id = org_id;
  if not found then raise exception 'هذا العميل لا ينتمي إلى هذه المؤسسة'; end if;
  if not exists (select 1 from warehouses where id = p_warehouse_id and organization_id = org_id) then
    raise exception 'هذا المخزن لا ينتمي إلى هذه المؤسسة';
  end if;
  if items is null or jsonb_array_length(items) = 0 then
    raise exception 'يجب إضافة صنف واحد على الأقل لفاتورة البيع';
  end if;

  v_rep := p_sales_rep_id;
  if is_restricted_rep(org_id) then
    v_rep := current_rep_id(org_id);
    if v_cust_rep is distinct from v_rep then raise exception 'هذا العميل غير تابع لك'; end if;
  elsif v_rep is null then
    v_rep := v_cust_rep;
  end if;
  if v_rep is not null and not exists (select 1 from sales_representatives where id = v_rep and organization_id = org_id) then
    raise exception 'هذا المندوب لا ينتمي إلى هذه المؤسسة';
  end if;

  v_pr := _pricing(org_id, 'sales', items, p_discount_total, p_cash_discount, p_payment_method, p_amount_collected, p_tax_total);
  v_bonus := v_pr->'bonus';
  v_gross := (v_pr->>'gross')::numeric;
  v_base_sum := (v_pr->>'base')::numeric;
  v_level := (v_pr->>'invoice_level_discount')::numeric;
  v_disc_total := (v_pr->>'discount_total')::numeric;
  v_net := (v_pr->>'net')::numeric;
  v_total := (v_pr->>'total')::numeric;
  v_n := jsonb_array_length(items);

  insert into sales_invoices (organization_id, customer_id, warehouse_id, invoice_number, invoice_date, notes, created_by, sales_rep_id, payment_method)
  values (org_id, p_customer_id, p_warehouse_id, nullif(p_invoice_number, ''), coalesce(p_invoice_date, current_date), nullif(p_notes, ''), auth.uid(), v_rep, nullif(p_payment_method, ''))
  returning id into new_invoice_id;

  for e in select * from jsonb_array_elements(items) loop
    v_idx := v_idx + 1;
    v_product_id := (e->>'product_id')::uuid;
    v_q := (e->>'quantity')::numeric;
    v_price := (e->>'unit_price')::numeric;
    v_ldisc := coalesce((e->>'discount')::numeric, 0);

    v_same := 0;
    if not (v_product_id = any (v_done)) then
      select coalesce(sum((x->>'qty')::numeric), 0) into v_same
      from jsonb_array_elements(v_bonus) x
      where (x->>'trigger')::uuid = v_product_id and (x->>'product')::uuid = v_product_id;
      v_done := v_done || v_product_id;
    end if;

    v_base_line := round(v_q * v_price, 2) - v_ldisc;
    v_alloc := case
      when v_idx = v_n then v_level - v_alloc_used
      when v_base_sum > 0 then round(v_level * v_base_line / v_base_sum, 2)
      else 0 end;
    v_alloc_used := v_alloc_used + v_alloc;

    v_units := v_q + v_same;
    v_unit_cost := _consume_stock(org_id, v_product_id, p_warehouse_id, v_units, new_invoice_id);
    v_cost_total := round(v_units * v_unit_cost, 2);
    v_net_line := v_base_line - v_alloc;

    insert into sales_invoice_items (organization_id, sales_invoice_id, product_id, quantity, unit_price, discount, line_total,
                                     bonus_quantity, allocated_discount, net_total, effective_unit_price)
    values (org_id, new_invoice_id, v_product_id, v_q, v_price, v_ldisc, v_base_line,
            v_same, v_alloc, v_net_line, v_net_line / v_units)
    returning id into v_item_id;
    insert into sales_item_financials (sales_invoice_item_id, organization_id, unit_cost, cost_total, profit)
    values (v_item_id, org_id, v_unit_cost, v_cost_total, v_net_line - v_cost_total);

    v_cogs := v_cogs + v_cost_total;
    v_bonus_units := v_bonus_units + v_same;
    v_bonus_cost := v_bonus_cost + round(v_same * v_unit_cost, 2);
  end loop;

  for b in
    select (x->>'product')::uuid as pid, sum((x->>'qty')::numeric) as q
    from jsonb_array_elements(v_bonus) x
    where (x->>'trigger') <> (x->>'product') group by 1
  loop
    v_unit_cost := _consume_stock(org_id, b.pid, p_warehouse_id, b.q, new_invoice_id);
    v_cost_total := round(b.q * v_unit_cost, 2);
    insert into sales_invoice_items (organization_id, sales_invoice_id, product_id, quantity, unit_price, discount, line_total,
                                     is_bonus, net_total, effective_unit_price)
    values (org_id, new_invoice_id, b.pid, b.q, 0, 0, 0, true, 0, 0)
    returning id into v_item_id;
    insert into sales_item_financials (sales_invoice_item_id, organization_id, unit_cost, cost_total, profit)
    values (v_item_id, org_id, v_unit_cost, v_cost_total, -v_cost_total);
    v_cogs := v_cogs + v_cost_total;
    v_bonus_units := v_bonus_units + b.q;
    v_bonus_cost := v_bonus_cost + v_cost_total;
  end loop;

  v_profit := v_net - v_cogs;
  if coalesce(p_amount_collected, 0) > v_total then
    raise exception 'المبلغ المحصل أكبر من إجمالي الفاتورة';
  end if;
  v_collected := coalesce(p_amount_collected, 0);
  v_status := case when v_collected <= 0 then 'unpaid' when v_collected >= v_total then 'paid' else 'partial' end;

  if v_rep is not null then
    select commission_basis, commission_rate into v_commission_basis, v_commission_rate from sales_representatives where id = v_rep;
    v_commission := case v_commission_basis
      when 'sales_value' then v_gross * v_commission_rate / 100
      when 'net_sales' then v_net * v_commission_rate / 100
      when 'gross_profit' then v_profit * v_commission_rate / 100
      when 'collected_amount' then v_collected * v_commission_rate / 100
      else 0 end;
  end if;

  perform allocate_invoice_tax('sales', new_invoice_id, coalesce(p_tax_total, 0));

  update sales_invoices
  set subtotal = v_gross, discount_total = v_disc_total,
      line_discount_total = (v_pr->>'line_discount')::numeric,
      invoice_discount = (v_pr->>'invoice_discount')::numeric,
      cash_discount = (v_pr->>'cash_discount')::numeric,
      tier_discount = (v_pr->>'tier_discount')::numeric,
      bonus_units = v_bonus_units,
      tax_total = coalesce(p_tax_total, 0), total = v_total,
      amount_paid = v_collected, payment_status = v_status,
      commission_basis_snapshot = v_commission_basis, commission_rate_snapshot = v_commission_rate, commission_amount = v_commission,
      updated_at = now()
  where id = new_invoice_id;

  insert into sales_invoice_financials (sales_invoice_id, organization_id, cogs_total, profit_total, bonus_cost)
  values (new_invoice_id, org_id, v_cogs, v_profit, v_bonus_cost);

  if v_collected > 0 then
    account_id := ensure_default_treasury_account(org_id);
    insert into customer_collections (organization_id, customer_id, sales_invoice_id, amount, collection_date, payment_method, created_by)
    values (org_id, p_customer_id, new_invoice_id, v_collected, coalesce(p_invoice_date, current_date), nullif(p_payment_method, ''), auth.uid());
    insert into treasury_movements (organization_id, treasury_account_id, direction, amount, category, movement_date, source_type, source_id, description, created_by)
    values (org_id, account_id, 'in', v_collected, 'customer_collection', coalesce(p_invoice_date, current_date), 'sales_invoice', new_invoice_id, nullif(p_notes, ''), auth.uid());
  end if;

  perform recompute_sales_commission(new_invoice_id);

  return new_invoice_id;
end $function$;

-- ============================================================
-- 8. create_purchase_invoice — tax shares, no overpay
-- ============================================================
CREATE OR REPLACE FUNCTION public.create_purchase_invoice(org_id uuid, p_supplier_id uuid, p_warehouse_id uuid, p_invoice_number text, p_invoice_date date, items jsonb, p_discount_total numeric, p_tax_total numeric, p_amount_paid numeric, p_payment_method text, p_notes text, p_cash_discount numeric DEFAULT 0)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  new_invoice_id uuid; account_id uuid;
  e jsonb; b record; v_pr jsonb; v_bonus jsonb;
  v_product_id uuid; v_q numeric(14,3); v_cost numeric(14,2); v_ldisc numeric(14,2);
  v_same numeric(14,3); v_done uuid[] := '{}'; v_idx int := 0; v_n int;
  v_base_line numeric(14,2); v_base_sum numeric(14,2); v_level numeric(14,2);
  v_alloc numeric(14,2); v_alloc_used numeric(14,2) := 0; v_units numeric(14,3); v_net_line numeric(14,2);
  v_gross numeric(14,2); v_disc_total numeric(14,2); v_total numeric(14,2);
  v_bonus_units numeric(14,3) := 0; v_paid numeric(14,2); v_status text;
begin
  if auth.uid() is null then raise exception 'يجب تسجيل الدخول أولاً'; end if;
  if not is_org_member(org_id) then raise exception 'أنت لست عضوًا في هذه المؤسسة'; end if;
  if not has_permission(org_id, 'purchases.create') then raise exception 'ليس لديك صلاحية إنشاء فواتير الشراء'; end if;
  if not exists (select 1 from suppliers where id = p_supplier_id and organization_id = org_id) then
    raise exception 'هذا المورد لا ينتمي إلى هذه المؤسسة';
  end if;
  if not exists (select 1 from warehouses where id = p_warehouse_id and organization_id = org_id) then
    raise exception 'هذا المخزن لا ينتمي إلى هذه المؤسسة';
  end if;
  if items is null or jsonb_array_length(items) = 0 then
    raise exception 'يجب إضافة صنف واحد على الأقل لفاتورة الشراء';
  end if;

  v_pr := _pricing(org_id, 'purchases', items, p_discount_total, p_cash_discount, p_payment_method, p_amount_paid, p_tax_total);
  v_bonus := v_pr->'bonus';
  v_gross := (v_pr->>'gross')::numeric; v_base_sum := (v_pr->>'base')::numeric;
  v_level := (v_pr->>'invoice_level_discount')::numeric; v_disc_total := (v_pr->>'discount_total')::numeric;
  v_total := (v_pr->>'total')::numeric; v_n := jsonb_array_length(items);

  insert into purchase_invoices (organization_id, supplier_id, warehouse_id, invoice_number, invoice_date, notes, created_by, payment_method)
  values (org_id, p_supplier_id, p_warehouse_id, nullif(p_invoice_number, ''), coalesce(p_invoice_date, current_date), nullif(p_notes, ''), auth.uid(), nullif(p_payment_method, ''))
  returning id into new_invoice_id;

  for e in select * from jsonb_array_elements(items) loop
    v_idx := v_idx + 1;
    v_product_id := (e->>'product_id')::uuid;
    v_q := (e->>'quantity')::numeric;
    v_cost := (e->>'unit_cost')::numeric;
    v_ldisc := coalesce((e->>'discount')::numeric, 0);
    if not exists (select 1 from products where id = v_product_id and organization_id = org_id) then
      raise exception 'أحد المنتجات المختارة لا ينتمي إلى هذه المؤسسة';
    end if;

    v_same := 0;
    if not (v_product_id = any (v_done)) then
      select coalesce(sum((x->>'qty')::numeric), 0) into v_same
      from jsonb_array_elements(v_bonus) x
      where (x->>'trigger')::uuid = v_product_id and (x->>'product')::uuid = v_product_id;
      v_done := v_done || v_product_id;
    end if;

    v_base_line := round(v_q * v_cost, 2) - v_ldisc;
    v_alloc := case when v_idx = v_n then v_level - v_alloc_used
                    when v_base_sum > 0 then round(v_level * v_base_line / v_base_sum, 2) else 0 end;
    v_alloc_used := v_alloc_used + v_alloc;
    v_units := v_q + v_same;
    v_net_line := v_base_line - v_alloc;

    insert into purchase_invoice_items (organization_id, purchase_invoice_id, product_id, quantity, unit_cost, discount, line_total,
                                        bonus_quantity, allocated_discount, net_total, effective_unit_cost)
    values (org_id, new_invoice_id, v_product_id, v_q, v_cost, v_ldisc, v_base_line, v_same, v_alloc, v_net_line, v_net_line / v_units);

    perform _receive_stock(org_id, v_product_id, p_warehouse_id, v_units, v_net_line / v_units, new_invoice_id);
    v_bonus_units := v_bonus_units + v_same;
  end loop;

  for b in
    select (x->>'product')::uuid as pid, sum((x->>'qty')::numeric) as q
    from jsonb_array_elements(v_bonus) x where (x->>'trigger') <> (x->>'product') group by 1
  loop
    if not exists (select 1 from products where id = b.pid and organization_id = org_id) then
      raise exception 'أحد المنتجات المختارة لا ينتمي إلى هذه المؤسسة';
    end if;
    insert into purchase_invoice_items (organization_id, purchase_invoice_id, product_id, quantity, unit_cost, discount, line_total, is_bonus, net_total, effective_unit_cost)
    values (org_id, new_invoice_id, b.pid, b.q, 0, 0, 0, true, 0, 0);
    perform _receive_stock(org_id, b.pid, p_warehouse_id, b.q, 0, new_invoice_id);
    v_bonus_units := v_bonus_units + b.q;
  end loop;

  if coalesce(p_amount_paid, 0) > v_total then
    raise exception 'المبلغ المدفوع أكبر من إجمالي الفاتورة';
  end if;
  v_paid := coalesce(p_amount_paid, 0);
  v_status := case when v_paid <= 0 then 'unpaid' when v_paid >= v_total then 'paid' else 'partial' end;

  perform allocate_invoice_tax('purchases', new_invoice_id, coalesce(p_tax_total, 0));

  update purchase_invoices
  set subtotal = v_gross, discount_total = v_disc_total,
      line_discount_total = (v_pr->>'line_discount')::numeric, invoice_discount = (v_pr->>'invoice_discount')::numeric,
      cash_discount = (v_pr->>'cash_discount')::numeric, tier_discount = (v_pr->>'tier_discount')::numeric,
      bonus_units = v_bonus_units, tax_total = coalesce(p_tax_total, 0), total = v_total,
      amount_paid = v_paid, payment_status = v_status, updated_at = now()
  where id = new_invoice_id;

  if v_paid > 0 then
    account_id := ensure_default_treasury_account(org_id);
    insert into supplier_payments (organization_id, supplier_id, purchase_invoice_id, amount, payment_date, payment_method, created_by)
    values (org_id, p_supplier_id, new_invoice_id, v_paid, coalesce(p_invoice_date, current_date), nullif(p_payment_method, ''), auth.uid());
    insert into treasury_movements (organization_id, treasury_account_id, direction, amount, category, movement_date, source_type, source_id, description, created_by)
    values (org_id, account_id, 'out', v_paid, 'supplier_payment', coalesce(p_invoice_date, current_date), 'purchase_invoice', new_invoice_id, nullif(p_notes, ''), auth.uid());
  end if;

  return new_invoice_id;
end $function$;

-- ============================================================
-- 9. create_sales_return — tax reversed, exact cost, cash-refund limit
-- ============================================================
CREATE OR REPLACE FUNCTION public.create_sales_return(org_id uuid, p_sales_invoice_id uuid, p_return_date date, items jsonb, p_cash_refund numeric DEFAULT 0, p_notes text DEFAULT NULL::text, p_full_return boolean DEFAULT false, p_condition text DEFAULT 'resalable'::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  new_return_id uuid; v_customer_id uuid; v_warehouse_id uuid; v_inv_rep uuid; account_id uuid;
  item jsonb; v_items jsonb;
  v_item_id uuid; v_quantity numeric(14,3); v_condition text; v_orig record;
  v_already numeric(14,3); v_remaining numeric(14,3); v_units numeric(14,3); v_prior numeric(14,2);
  v_revenue numeric(14,2); v_cost numeric(14,2); v_profit numeric(14,2);
  v_track boolean; v_old_qty numeric(14,3); v_old_avg numeric(14,6); v_unit_cost numeric(14,2); v_ri_id uuid;
  v_tax numeric(14,2); v_tax_prior numeric(14,2); v_tax_total numeric(14,2) := 0;
  v_item_cost numeric(14,2); v_prev_cost numeric(14,2); v_prev_damaged numeric(14,3);
  v_subtotal numeric(14,2) := 0; v_cost_total numeric(14,2) := 0; v_profit_total numeric(14,2) := 0;
begin
  if auth.uid() is null then raise exception 'يجب تسجيل الدخول أولاً'; end if;
  if not is_org_member(org_id) then raise exception 'أنت لست عضوًا في هذه المؤسسة'; end if;
  if not has_permission(org_id, 'sales.approve') then raise exception 'ليس لديك صلاحية تسجيل مرتجعات المبيعات'; end if;

  select customer_id, warehouse_id, sales_rep_id into v_customer_id, v_warehouse_id, v_inv_rep
  from sales_invoices where id = p_sales_invoice_id and organization_id = org_id;
  if not found then raise exception 'هذه الفاتورة لا تنتمي إلى هذه المؤسسة'; end if;
  if is_restricted_rep(org_id) and v_inv_rep is distinct from current_rep_id(org_id) then
    raise exception 'هذه الفاتورة ليست من فواتيرك';
  end if;
  if p_cash_refund is null or p_cash_refund < 0 then raise exception 'قيمة الاسترجاع النقدي غير صحيحة'; end if;

  v_items := items;
  if p_full_return then
    if p_condition not in ('resalable', 'damaged') then raise exception 'حالة الصنف المرتجع غير صحيحة'; end if;
    select jsonb_agg(jsonb_build_object('sales_invoice_item_id', it.id,
             'quantity', it.quantity + it.bonus_quantity - coalesce(ret.qty, 0), 'condition', p_condition))
    into v_items
    from sales_invoice_items it
    left join (select sales_invoice_item_id, sum(quantity) qty from sales_return_items group by 1) ret on ret.sales_invoice_item_id = it.id
    where it.sales_invoice_id = p_sales_invoice_id and it.organization_id = org_id
      and it.quantity + it.bonus_quantity - coalesce(ret.qty, 0) > 0;
    if v_items is null then raise exception 'لا توجد كميات متبقية لإرجاعها في هذه الفاتورة'; end if;
  end if;
  if v_items is null or jsonb_array_length(v_items) = 0 then
    raise exception 'يجب اختيار صنف واحد على الأقل للمرتجع';
  end if;

  insert into sales_returns (organization_id, sales_invoice_id, customer_id, warehouse_id, return_date, notes, created_by)
  values (org_id, p_sales_invoice_id, v_customer_id, v_warehouse_id, coalesce(p_return_date, current_date), nullif(p_notes, ''), auth.uid())
  returning id into new_return_id;

  for item in select * from jsonb_array_elements(v_items) loop
    v_item_id := (item->>'sales_invoice_item_id')::uuid;
    v_quantity := (item->>'quantity')::numeric;
    v_condition := item->>'condition';
    if v_condition not in ('resalable', 'damaged') then raise exception 'حالة الصنف المرتجع غير صحيحة'; end if;
    if v_quantity is null or v_quantity <= 0 then raise exception 'يجب أن تكون كمية المرتجع أكبر من صفر'; end if;

    select * into v_orig from sales_invoice_items
    where id = v_item_id and sales_invoice_id = p_sales_invoice_id and organization_id = org_id for update;
    if not found then raise exception 'هذا الصنف لا ينتمي إلى هذه الفاتورة'; end if;

    select unit_cost, cost_total into v_unit_cost, v_item_cost from sales_item_financials where sales_invoice_item_id = v_item_id;
    v_unit_cost := coalesce(v_unit_cost, 0);
    v_item_cost := coalesce(v_item_cost, 0);

    select coalesce(sum(quantity), 0), coalesce(sum(revenue_reversed), 0) into v_already, v_prior
    from sales_return_items where sales_invoice_item_id = v_item_id;
    v_units := v_orig.quantity + v_orig.bonus_quantity;
    v_remaining := v_units - v_already;
    if v_quantity > v_remaining then
      raise exception 'الكمية المطلوب إرجاعها أكبر من المتاح لهذا الصنف (المتبقي: %)', v_remaining;
    end if;

    v_revenue := case when v_quantity = v_remaining then v_orig.net_total - v_prior
                      else round(v_orig.net_total * v_quantity / v_units, 2) end;
    select coalesce(sum(ri.tax_reversed), 0), coalesce(sum(f.cost_reversed), 0), coalesce(sum(ri.quantity) filter (where ri.condition = 'damaged'), 0)
    into v_tax_prior, v_prev_cost, v_prev_damaged
    from sales_return_items ri left join sales_return_item_financials f on f.sales_return_item_id = ri.id
    where ri.sales_invoice_item_id = v_item_id;
    v_tax := case when v_quantity = v_remaining then v_orig.tax_alloc - v_tax_prior
                  else round(v_orig.tax_alloc * v_quantity / v_units, 2) end;
    -- cost comes back from the line's recorded cost (exact; last piece takes the remainder)
    v_cost := case when v_condition <> 'resalable' then 0
                   when v_quantity = v_remaining and v_prev_damaged = 0 then v_item_cost - v_prev_cost
                   else round(v_item_cost * v_quantity / v_units, 2) end;
    v_profit := v_revenue - v_cost;

    if v_condition = 'resalable' then
      select track_inventory into v_track from products where id = v_orig.product_id and organization_id = org_id;
      if v_track then
        select quantity, avg_cost into v_old_qty, v_old_avg
        from inventory_stock where product_id = v_orig.product_id and warehouse_id = v_warehouse_id for update;
        if not found then
          v_old_qty := 0; v_old_avg := 0;
          insert into inventory_stock (organization_id, product_id, warehouse_id, quantity, avg_cost) values (org_id, v_orig.product_id, v_warehouse_id, 0, 0);
        end if;
        update inventory_stock
        set quantity = v_old_qty + v_quantity,
            avg_cost = case when (v_old_qty + v_quantity) > 0
                            then ((greatest(v_old_qty, 0) * v_old_avg) + v_cost) / (greatest(v_old_qty, 0) + v_quantity) else v_old_avg end,
            updated_at = now()
        where product_id = v_orig.product_id and warehouse_id = v_warehouse_id;
        insert into inventory_movements (organization_id, product_id, warehouse_id, movement_type, quantity_delta, unit_cost, reference_type, reference_id, created_by)
        values (org_id, v_orig.product_id, v_warehouse_id, 'sale_return', v_quantity, v_cost / v_quantity, 'sales_return', new_return_id, auth.uid());
      end if;
    end if;

    insert into sales_return_items (organization_id, sales_return_id, sales_invoice_item_id, product_id, quantity, condition, unit_price, revenue_reversed, tax_reversed)
    values (org_id, new_return_id, v_item_id, v_orig.product_id, v_quantity, v_condition, v_orig.effective_unit_price, v_revenue, v_tax)
    returning id into v_ri_id;
    insert into sales_return_item_financials (sales_return_item_id, organization_id, unit_cost, cost_reversed, profit_reversed)
    values (v_ri_id, org_id, v_unit_cost, v_cost, v_profit);

    v_tax_total := v_tax_total + v_tax; v_subtotal := v_subtotal + v_revenue; v_cost_total := v_cost_total + v_cost; v_profit_total := v_profit_total + v_profit;
  end loop;

  if p_cash_refund > v_subtotal + v_tax_total then raise exception 'قيمة الاسترجاع النقدي أكبر من قيمة المرتجع'; end if;

  update sales_returns
  set subtotal_reversed = v_subtotal, tax_reversed = v_tax_total, total = v_subtotal + v_tax_total, cash_refunded = p_cash_refund, updated_at = now()
  where id = new_return_id;
  insert into sales_return_financials (sales_return_id, organization_id, cost_reversed, profit_reversed)
  values (new_return_id, org_id, v_cost_total, v_profit_total);

  if p_cash_refund > 0 then
    account_id := ensure_default_treasury_account(org_id);
    insert into treasury_movements (organization_id, treasury_account_id, direction, amount, category, movement_date, source_type, source_id, description, created_by)
    values (org_id, account_id, 'out', p_cash_refund, 'sales_return', coalesce(p_return_date, current_date), 'sales_return', new_return_id, nullif(p_notes, ''), auth.uid());
  end if;
  return new_return_id;
end $function$;

-- ============================================================
-- 10. create_purchase_return — tax reversed, weighted average recomputed
-- ============================================================
CREATE OR REPLACE FUNCTION public.create_purchase_return(org_id uuid, p_purchase_invoice_id uuid, p_return_date date, items jsonb, p_cash_refund numeric DEFAULT 0, p_notes text DEFAULT NULL::text, p_full_return boolean DEFAULT false)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  new_return_id uuid; v_supplier_id uuid; v_warehouse_id uuid; account_id uuid;
  item jsonb; v_items jsonb; v_item_id uuid; v_quantity numeric(14,3); v_orig record;
  v_already numeric(14,3); v_remaining numeric(14,3); v_units numeric(14,3); v_prior numeric(14,2);
  v_line_total numeric(14,2); v_track boolean; v_current_qty numeric(14,3); v_subtotal numeric(14,2) := 0;
  v_current_avg numeric(14,6); v_tax numeric(14,2); v_tax_prior numeric(14,2); v_tax_total numeric(14,2) := 0;
begin
  if auth.uid() is null then raise exception 'يجب تسجيل الدخول أولاً'; end if;
  if not is_org_member(org_id) then raise exception 'أنت لست عضوًا في هذه المؤسسة'; end if;
  if not has_permission(org_id, 'purchases.approve') then raise exception 'ليس لديك صلاحية تسجيل مرتجعات المشتريات'; end if;

  select supplier_id, warehouse_id into v_supplier_id, v_warehouse_id
  from purchase_invoices where id = p_purchase_invoice_id and organization_id = org_id;
  if not found then raise exception 'هذه الفاتورة لا تنتمي إلى هذه المؤسسة'; end if;
  if p_cash_refund is null or p_cash_refund < 0 then raise exception 'قيمة الاسترجاع النقدي غير صحيحة'; end if;

  v_items := items;
  if p_full_return then
    select jsonb_agg(jsonb_build_object('purchase_invoice_item_id', it.id, 'quantity', it.quantity + it.bonus_quantity - coalesce(ret.qty, 0)))
    into v_items
    from purchase_invoice_items it
    left join (select purchase_invoice_item_id, sum(quantity) qty from purchase_return_items group by 1) ret on ret.purchase_invoice_item_id = it.id
    where it.purchase_invoice_id = p_purchase_invoice_id and it.organization_id = org_id
      and it.quantity + it.bonus_quantity - coalesce(ret.qty, 0) > 0;
    if v_items is null then raise exception 'لا توجد كميات متبقية لإرجاعها في هذه الفاتورة'; end if;
  end if;
  if v_items is null or jsonb_array_length(v_items) = 0 then raise exception 'يجب اختيار صنف واحد على الأقل للمرتجع'; end if;

  insert into purchase_returns (organization_id, purchase_invoice_id, supplier_id, warehouse_id, return_date, notes, created_by)
  values (org_id, p_purchase_invoice_id, v_supplier_id, v_warehouse_id, coalesce(p_return_date, current_date), nullif(p_notes, ''), auth.uid())
  returning id into new_return_id;

  for item in select * from jsonb_array_elements(v_items) loop
    v_item_id := (item->>'purchase_invoice_item_id')::uuid;
    v_quantity := (item->>'quantity')::numeric;
    if v_quantity is null or v_quantity <= 0 then raise exception 'يجب أن تكون كمية المرتجع أكبر من صفر'; end if;

    select * into v_orig from purchase_invoice_items
    where id = v_item_id and purchase_invoice_id = p_purchase_invoice_id and organization_id = org_id for update;
    if not found then raise exception 'هذا الصنف لا ينتمي إلى هذه الفاتورة'; end if;

    select coalesce(sum(quantity), 0), coalesce(sum(line_total), 0) into v_already, v_prior
    from purchase_return_items where purchase_invoice_item_id = v_item_id;
    v_units := v_orig.quantity + v_orig.bonus_quantity;
    v_remaining := v_units - v_already;
    if v_quantity > v_remaining then
      raise exception 'الكمية المطلوب إرجاعها أكبر من المتاح لهذا الصنف (المتبقي: %)', v_remaining;
    end if;

    v_line_total := case when v_quantity = v_remaining then v_orig.net_total - v_prior
                         else round(v_orig.net_total * v_quantity / v_units, 2) end;

    select coalesce(sum(tax_reversed), 0) into v_tax_prior from purchase_return_items where purchase_invoice_item_id = v_item_id;
    v_tax := case when v_quantity = v_remaining then v_orig.tax_alloc - v_tax_prior
                  else round(v_orig.tax_alloc * v_quantity / v_units, 2) end;

    select track_inventory into v_track from products where id = v_orig.product_id and organization_id = org_id;
    if v_track then
      select quantity, avg_cost into v_current_qty, v_current_avg from inventory_stock
      where product_id = v_orig.product_id and warehouse_id = v_warehouse_id for update;
      if not found or coalesce(v_current_qty, 0) < v_quantity then
        raise exception 'الكمية المتاحة بالمخزون أقل من كمية المرتجع لهذا الصنف';
      end if;
      -- the returned units leave the weighted-average pool at the value they entered with
      update inventory_stock set quantity = quantity - v_quantity,
        avg_cost = case when (v_current_qty - v_quantity) > 0
                        then greatest((v_current_qty * v_current_avg) - v_line_total, 0) / (v_current_qty - v_quantity)
                        else v_current_avg end,
        updated_at = now()
      where product_id = v_orig.product_id and warehouse_id = v_warehouse_id;
      insert into inventory_movements (organization_id, product_id, warehouse_id, movement_type, quantity_delta, unit_cost, reference_type, reference_id, created_by)
      values (org_id, v_orig.product_id, v_warehouse_id, 'purchase_return', -v_quantity, v_orig.effective_unit_cost, 'purchase_return', new_return_id, auth.uid());
    end if;

    insert into purchase_return_items (organization_id, purchase_return_id, purchase_invoice_item_id, product_id, quantity, unit_cost, line_total, tax_reversed)
    values (org_id, new_return_id, v_item_id, v_orig.product_id, v_quantity, v_orig.effective_unit_cost, v_line_total, v_tax);
    v_subtotal := v_subtotal + v_line_total;
    v_tax_total := v_tax_total + v_tax;
  end loop;

  if p_cash_refund > v_subtotal + v_tax_total then raise exception 'قيمة الاسترجاع النقدي أكبر من قيمة المرتجع'; end if;
  update purchase_returns set total = v_subtotal + v_tax_total, tax_reversed = v_tax_total, cash_refunded = p_cash_refund, updated_at = now() where id = new_return_id;

  if p_cash_refund > 0 then
    account_id := ensure_default_treasury_account(org_id);
    insert into treasury_movements (organization_id, treasury_account_id, direction, amount, category, movement_date, source_type, source_id, description, created_by)
    values (org_id, account_id, 'in', p_cash_refund, 'purchase_return', coalesce(p_return_date, current_date), 'purchase_return', new_return_id, nullif(p_notes, ''), auth.uid());
  end if;
  return new_return_id;
end $function$;

-- ============================================================
-- 11. get_returnable_items — also exposes the tax share (the return form previews it)
-- ============================================================
drop function if exists get_returnable_items(uuid, uuid);
CREATE OR REPLACE FUNCTION public.get_returnable_items(org_id uuid, p_sales_invoice_id uuid)
 RETURNS TABLE(sales_invoice_item_id uuid, product_id uuid, product_name text, quantity numeric, bonus_quantity numeric, is_bonus boolean, already_returned numeric, returnable numeric, unit_price numeric, line_total numeric, tax_alloc numeric, tax_returned numeric)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
begin
  if auth.uid() is null then raise exception 'يجب تسجيل الدخول أولاً'; end if;
  if not is_org_member(org_id) then raise exception 'أنت لست عضوًا في هذه المؤسسة'; end if;
  if not exists (select 1 from sales_invoices where id = p_sales_invoice_id and organization_id = org_id) then
    raise exception 'هذه الفاتورة لا تنتمي إلى هذه المؤسسة';
  end if;
  return query
  select it.id, it.product_id, p.name,
         it.quantity::numeric, it.bonus_quantity::numeric, it.is_bonus,
         coalesce(ret.qty, 0)::numeric,
         (it.quantity + it.bonus_quantity - coalesce(ret.qty, 0))::numeric,
         it.effective_unit_price::numeric,
         it.net_total::numeric,
         it.tax_alloc::numeric,
         coalesce(ret.tax, 0)::numeric
  from sales_invoice_items it
  join products p on p.id = it.product_id
  left join (
    select sri.sales_invoice_item_id, sum(sri.quantity) as qty, sum(sri.tax_reversed) as tax
    from sales_return_items sri group by sri.sales_invoice_item_id
  ) ret on ret.sales_invoice_item_id = it.id
  where it.sales_invoice_id = p_sales_invoice_id and it.organization_id = org_id
  order by it.is_bonus, p.name;
end $function$;
revoke all on function get_returnable_items(uuid, uuid) from public, anon;
grant execute on function get_returnable_items(uuid, uuid) to authenticated;

drop function if exists get_returnable_purchase_items(uuid, uuid);
CREATE OR REPLACE FUNCTION public.get_returnable_purchase_items(org_id uuid, p_purchase_invoice_id uuid)
 RETURNS TABLE(purchase_invoice_item_id uuid, product_id uuid, product_name text, quantity numeric, bonus_quantity numeric, is_bonus boolean, already_returned numeric, returnable numeric, on_hand numeric, unit_cost numeric, line_total numeric, tax_alloc numeric, tax_returned numeric)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
begin
  if auth.uid() is null then raise exception 'يجب تسجيل الدخول أولاً'; end if;
  if not is_org_member(org_id) then raise exception 'أنت لست عضوًا في هذه المؤسسة'; end if;
  if not exists (select 1 from purchase_invoices where id = p_purchase_invoice_id and organization_id = org_id) then
    raise exception 'هذه الفاتورة لا تنتمي إلى هذه المؤسسة';
  end if;
  return query
  select it.id, it.product_id, p.name,
         it.quantity::numeric, it.bonus_quantity::numeric, it.is_bonus,
         coalesce(ret.qty, 0)::numeric,
         (it.quantity + it.bonus_quantity - coalesce(ret.qty, 0))::numeric,
         coalesce(stk.quantity, 0)::numeric,
         it.effective_unit_cost::numeric,
         it.net_total::numeric,
         it.tax_alloc::numeric,
         coalesce(ret.tax, 0)::numeric
  from purchase_invoice_items it
  join products p on p.id = it.product_id
  join purchase_invoices pi on pi.id = it.purchase_invoice_id
  left join (select pri.purchase_invoice_item_id, sum(pri.quantity) as qty, sum(pri.tax_reversed) as tax from purchase_return_items pri group by 1) ret on ret.purchase_invoice_item_id = it.id
  left join inventory_stock stk on stk.product_id = it.product_id and stk.warehouse_id = pi.warehouse_id and stk.organization_id = org_id
  where it.purchase_invoice_id = p_purchase_invoice_id and it.organization_id = org_id
  order by it.is_bonus, p.name;
end $function$;
revoke all on function get_returnable_purchase_items(uuid, uuid) from public, anon;
grant execute on function get_returnable_purchase_items(uuid, uuid) to authenticated;

-- ============================================================
-- 12. Collections and supplier payments — never beyond what is owed; commission recomputed
-- ============================================================
CREATE OR REPLACE FUNCTION public.record_customer_collection(org_id uuid, p_customer_id uuid, p_sales_invoice_id uuid, p_amount numeric, p_collection_date date, p_payment_method text, p_reference text, p_notes text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  new_collection_id uuid;
  account_id uuid;
  v_total numeric(14,2);
  v_amount_paid numeric(14,2);
  v_sales_rep_id uuid;
  v_commission_basis text;
  v_commission_rate numeric(5,2);
begin
  if auth.uid() is null then
    raise exception 'يجب تسجيل الدخول أولاً';
  end if;
  if not is_org_member(org_id) then
    raise exception 'أنت لست عضوًا في هذه المؤسسة';
  end if;
  if not has_permission(org_id, 'treasury.manage') then
    raise exception 'ليس لديك صلاحية تسجيل التحصيلات';
  end if;
  if not exists (select 1 from customers where id = p_customer_id and organization_id = org_id) then
    raise exception 'هذا العميل لا ينتمي إلى هذه المؤسسة';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'يجب أن يكون المبلغ أكبر من صفر';
  end if;
  if p_amount > 999999999999 then
    raise exception 'المبلغ كبير جدًا';
  end if;
  if p_sales_invoice_id is not null
     and not exists (select 1 from sales_invoices where id = p_sales_invoice_id and organization_id = org_id and customer_id = p_customer_id) then
    raise exception 'هذه الفاتورة لا تخص هذا العميل';
  end if;

  if p_sales_invoice_id is not null and round(p_amount, 2) > sales_invoice_remaining(p_sales_invoice_id) then
    raise exception 'المبلغ أكبر من المتبقي على الفاتورة (المتبقي: %)', sales_invoice_remaining(p_sales_invoice_id);
  end if;

  account_id := ensure_default_treasury_account(org_id);

  insert into customer_collections (organization_id, customer_id, sales_invoice_id, amount, collection_date, payment_method, reference, notes, created_by)
  values (org_id, p_customer_id, p_sales_invoice_id, p_amount, coalesce(p_collection_date, current_date), nullif(p_payment_method, ''), nullif(p_reference, ''), nullif(p_notes, ''), auth.uid())
  returning id into new_collection_id;

  insert into treasury_movements (organization_id, treasury_account_id, direction, amount, category, movement_date, source_type, source_id, description, created_by)
  values (org_id, account_id, 'in', p_amount, 'customer_collection', coalesce(p_collection_date, current_date), 'customer_collection', new_collection_id, nullif(p_notes, ''), auth.uid());

  if p_sales_invoice_id is not null then
    select total, amount_paid, sales_rep_id, commission_basis_snapshot
    into v_total, v_amount_paid, v_sales_rep_id, v_commission_basis
    from sales_invoices
    where id = p_sales_invoice_id and organization_id = org_id
    for update;

    if found then
      v_amount_paid := v_amount_paid + p_amount;

      if v_sales_rep_id is not null and v_commission_basis = 'collected_amount' then
        select commission_rate into v_commission_rate from sales_representatives where id = v_sales_rep_id;
        update sales_invoices
        set amount_paid = v_amount_paid,
            payment_status = case when v_amount_paid >= v_total then 'paid' when v_amount_paid <= 0 then 'unpaid' else 'partial' end,
            updated_at = now()
        where id = p_sales_invoice_id;
      else
        update sales_invoices
        set amount_paid = v_amount_paid,
            payment_status = case when v_amount_paid >= v_total then 'paid' when v_amount_paid <= 0 then 'unpaid' else 'partial' end,
            updated_at = now()
        where id = p_sales_invoice_id;
      end if;
    end if;
  end if;

  if p_sales_invoice_id is not null then
    perform recompute_sales_commission(p_sales_invoice_id);
  end if;

  return new_collection_id;
end;
$function$;

CREATE OR REPLACE FUNCTION public.record_supplier_payment(org_id uuid, p_supplier_id uuid, p_purchase_invoice_id uuid, p_amount numeric, p_payment_date date, p_payment_method text, p_reference text, p_notes text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  new_payment_id uuid;
  account_id uuid;
  v_total numeric(14,2);
  v_amount_paid numeric(14,2);
begin
  if auth.uid() is null then
    raise exception 'يجب تسجيل الدخول أولاً';
  end if;
  if not is_org_member(org_id) then
    raise exception 'أنت لست عضوًا في هذه المؤسسة';
  end if;
  if not has_permission(org_id, 'treasury.manage') then
    raise exception 'ليس لديك صلاحية تسجيل المدفوعات';
  end if;
  if not exists (select 1 from suppliers where id = p_supplier_id and organization_id = org_id) then
    raise exception 'هذا المورد لا ينتمي إلى هذه المؤسسة';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'يجب أن يكون المبلغ أكبر من صفر';
  end if;
  if p_amount > 999999999999 then
    raise exception 'المبلغ كبير جدًا';
  end if;
  if p_purchase_invoice_id is not null
     and not exists (select 1 from purchase_invoices where id = p_purchase_invoice_id and organization_id = org_id and supplier_id = p_supplier_id) then
    raise exception 'هذه الفاتورة لا تخص هذا المورد';
  end if;

  if p_purchase_invoice_id is not null and round(p_amount, 2) > purchase_invoice_remaining(p_purchase_invoice_id) then
    raise exception 'المبلغ أكبر من المتبقي على الفاتورة (المتبقي: %)', purchase_invoice_remaining(p_purchase_invoice_id);
  end if;

  account_id := ensure_default_treasury_account(org_id);

  insert into supplier_payments (organization_id, supplier_id, purchase_invoice_id, amount, payment_date, payment_method, reference, notes, created_by)
  values (org_id, p_supplier_id, p_purchase_invoice_id, p_amount, coalesce(p_payment_date, current_date), nullif(p_payment_method, ''), nullif(p_reference, ''), nullif(p_notes, ''), auth.uid())
  returning id into new_payment_id;

  insert into treasury_movements (organization_id, treasury_account_id, direction, amount, category, movement_date, source_type, source_id, description, created_by)
  values (org_id, account_id, 'out', p_amount, 'supplier_payment', coalesce(p_payment_date, current_date), 'supplier_payment', new_payment_id, nullif(p_notes, ''), auth.uid());

  if p_purchase_invoice_id is not null then
    select total, amount_paid into v_total, v_amount_paid
    from purchase_invoices
    where id = p_purchase_invoice_id and organization_id = org_id
    for update;

    if found then
      v_amount_paid := v_amount_paid + p_amount;
      update purchase_invoices
      set amount_paid = v_amount_paid,
          payment_status = case when v_amount_paid >= v_total then 'paid' when v_amount_paid <= 0 then 'unpaid' else 'partial' end,
          updated_at = now()
      where id = p_purchase_invoice_id;
    end if;
  end if;

  return new_payment_id;
end;
$function$;

-- ============================================================
-- 13. Reports — returns are subtracted net of tax; timeseries nets returns; dashboard = report_summary
-- ============================================================
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
  perform assert_report_access(org_id, false);
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
  select coalesce(sum(quantity * avg_cost), 0) into v_inventory from inventory_stock where organization_id = org_id;
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
$function$;

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
  perform assert_report_access(org_id, false);
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
$function$;

CREATE OR REPLACE FUNCTION public.dashboard_sales_rollups(org_id uuid, p_from date DEFAULT NULL::date)
 RETURNS TABLE(kind text, group_key text, group_label text, ref_date date, invoices bigint, net_sales numeric, gross_profit numeric)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
declare
  fin boolean;
begin
  perform assert_report_access(org_id, false);
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
$function$;

CREATE OR REPLACE FUNCTION public.report_timeseries(org_id uuid, p_from date DEFAULT NULL::date, p_to date DEFAULT NULL::date, p_bucket text DEFAULT 'day'::text)
 RETURNS TABLE(bucket date, net_sales numeric, gross_profit numeric, expenses numeric)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
declare
  fin boolean;
begin
  perform assert_report_access(org_id, false);
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
$function$;

create or replace function dashboard_sales_totals(org_id uuid, p_from date default null)
returns table (total_sales numeric, total_profit numeric)
language plpgsql
stable
set search_path = public
as $$
declare
  s jsonb;
begin
  perform assert_report_access(org_id, false);
  s := report_summary(org_id, p_from, null);
  return query select
    coalesce((s->'sales'->>'net_sales')::numeric, 0),
    coalesce((s->'financial'->>'net_profit')::numeric, 0);
end;
$$;

-- ============================================================
-- 14. Balances — a cash refund moves the balance back
-- ============================================================
create or replace view customer_balances
with (security_invoker = true) as
select
  c.id as customer_id,
  c.organization_id,
  coalesce(s.total_sales, 0) as total_sales,
  coalesce(col.total_collected, 0) as total_collected,
  c.opening_balance
    + coalesce(s.total_sales, 0) - coalesce(col.total_collected, 0)
    - coalesce(r.total_returned, 0) + coalesce(r.total_refunded, 0) as balance,
  coalesce(r.total_returned, 0) as total_returned,
  coalesce(r.total_refunded, 0) as total_refunded
from customers c
left join (select customer_id, sum(total) as total_sales from sales_invoices group by customer_id) s on s.customer_id = c.id
left join (select customer_id, sum(amount) as total_collected from customer_collections group by customer_id) col on col.customer_id = c.id
left join (select customer_id, sum(total) as total_returned, sum(cash_refunded) as total_refunded from sales_returns group by customer_id) r on r.customer_id = c.id;

create or replace view supplier_balances
with (security_invoker = true) as
select
  s.id as supplier_id,
  s.organization_id,
  coalesce(p.total_purchases, 0) as total_purchases,
  coalesce(pay.total_paid, 0) as total_paid,
  s.opening_balance
    + coalesce(p.total_purchases, 0) - coalesce(pay.total_paid, 0)
    - coalesce(r.total_returned, 0) + coalesce(r.total_refunded, 0) as balance,
  coalesce(r.total_returned, 0) as total_returned,
  coalesce(r.total_refunded, 0) as total_refunded
from suppliers s
left join (select supplier_id, sum(total) as total_purchases from purchase_invoices group by supplier_id) p on p.supplier_id = s.id
left join (select supplier_id, sum(amount) as total_paid from supplier_payments group by supplier_id) pay on pay.supplier_id = s.id
left join (select supplier_id, sum(total) as total_returned, sum(cash_refunded) as total_refunded from purchase_returns group by supplier_id) r on r.supplier_id = s.id;

-- ============================================================
-- 15. Party ledger — a cash refund is its own entry
-- ============================================================
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
    select opening_balance into v_opening_balance from customers where id = p_party and organization_id = org_id;
    if not found then
      raise exception 'هذا العميل لا ينتمي إلى هذه المؤسسة';
    end if;
  else
    select opening_balance into v_opening_balance from suppliers where id = p_party and organization_id = org_id;
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

-- ============================================================
-- 16. Transfers and stock adjustments keep the 6-decimal cost
-- ============================================================
CREATE OR REPLACE FUNCTION public.create_stock_transfer(org_id uuid, p_from_warehouse_id uuid, p_to_warehouse_id uuid, p_transfer_date date, items jsonb, p_notes text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  new_transfer_id uuid;
  item jsonb;
  v_product_id uuid;
  v_quantity numeric(14,3);
  v_track_inventory boolean;
  v_source_qty numeric(14,3);
  v_source_avg numeric(14,6);
  v_dest_qty numeric(14,3);
  v_dest_avg numeric(14,6);
  v_new_dest_avg numeric(14,6);
  v_line_total numeric(14,2);
  v_total numeric(14,2) := 0;
begin
  if auth.uid() is null then
    raise exception 'يجب تسجيل الدخول أولاً';
  end if;
  if not is_org_member(org_id) then
    raise exception 'أنت لست عضوًا في هذه المؤسسة';
  end if;
  if not has_permission(org_id, 'inventory.adjust') then
    raise exception 'ليس لديك صلاحية نقل المخزون بين المخازن';
  end if;
  if p_from_warehouse_id = p_to_warehouse_id then
    raise exception 'لا يمكن النقل إلى نفس المخزن';
  end if;
  if not exists (select 1 from warehouses where id = p_from_warehouse_id and organization_id = org_id) then
    raise exception 'مخزن المصدر لا ينتمي إلى هذه المؤسسة';
  end if;
  if not exists (select 1 from warehouses where id = p_to_warehouse_id and organization_id = org_id) then
    raise exception 'مخزن الوجهة لا ينتمي إلى هذه المؤسسة';
  end if;
  if items is null or jsonb_array_length(items) = 0 then
    raise exception 'يجب اختيار صنف واحد على الأقل للنقل';
  end if;

  insert into stock_transfers (organization_id, from_warehouse_id, to_warehouse_id, transfer_date, notes, created_by)
  values (org_id, p_from_warehouse_id, p_to_warehouse_id, coalesce(p_transfer_date, current_date), nullif(p_notes, ''), auth.uid())
  returning id into new_transfer_id;

  for item in select * from jsonb_array_elements(items)
  loop
    v_product_id := (item->>'product_id')::uuid;
    v_quantity := (item->>'quantity')::numeric;

    if v_quantity is null or v_quantity <= 0 then
      raise exception 'يجب أن تكون كمية النقل أكبر من صفر';
    end if;
    if not exists (select 1 from products where id = v_product_id and organization_id = org_id) then
      raise exception 'هذا المنتج لا ينتمي إلى هذه المؤسسة';
    end if;

    select track_inventory into v_track_inventory from products where id = v_product_id;
    if not v_track_inventory then
      raise exception 'هذا المنتج لا يخضع لتتبع المخزون ولا يمكن نقله بين المخازن';
    end if;

    select quantity, avg_cost into v_source_qty, v_source_avg
    from inventory_stock
    where product_id = v_product_id and warehouse_id = p_from_warehouse_id and organization_id = org_id
    for update;

    if not found or coalesce(v_source_qty, 0) < v_quantity then
      raise exception 'الكمية المتاحة بمخزن المصدر أقل من كمية النقل لهذا الصنف';
    end if;

    update inventory_stock
    set quantity = quantity - v_quantity, updated_at = now()
    where product_id = v_product_id and warehouse_id = p_from_warehouse_id and organization_id = org_id;

    select quantity, avg_cost into v_dest_qty, v_dest_avg
    from inventory_stock
    where product_id = v_product_id and warehouse_id = p_to_warehouse_id and organization_id = org_id
    for update;

    if not found then
      v_dest_qty := 0;
      v_dest_avg := 0;
      insert into inventory_stock (organization_id, product_id, warehouse_id, quantity, avg_cost)
      values (org_id, v_product_id, p_to_warehouse_id, 0, 0);
    end if;

    -- Weighted-average blend at the destination (§21), same formula a
    -- purchase uses — the transferred stock brings its cost basis with it.
    if v_dest_qty + v_quantity > 0 then
      v_new_dest_avg := round(((v_dest_qty * v_dest_avg) + (v_quantity * v_source_avg)) / (v_dest_qty + v_quantity), 6);
    else
      v_new_dest_avg := v_source_avg;
    end if;

    update inventory_stock
    set quantity = v_dest_qty + v_quantity, avg_cost = v_new_dest_avg, updated_at = now()
    where product_id = v_product_id and warehouse_id = p_to_warehouse_id and organization_id = org_id;

    insert into inventory_movements (organization_id, product_id, warehouse_id, movement_type, quantity_delta, unit_cost, reference_type, reference_id, created_by)
    values (org_id, v_product_id, p_from_warehouse_id, 'transfer_out', -v_quantity, v_source_avg, 'stock_transfer', new_transfer_id, auth.uid());
    insert into inventory_movements (organization_id, product_id, warehouse_id, movement_type, quantity_delta, unit_cost, reference_type, reference_id, created_by)
    values (org_id, v_product_id, p_to_warehouse_id, 'transfer_in', v_quantity, v_source_avg, 'stock_transfer', new_transfer_id, auth.uid());

    v_line_total := v_quantity * v_source_avg;
    insert into stock_transfer_items (organization_id, stock_transfer_id, product_id, quantity, unit_cost, line_total)
    values (org_id, new_transfer_id, v_product_id, v_quantity, v_source_avg, v_line_total);

    v_total := v_total + v_line_total;
  end loop;

  update stock_transfers set total_value = v_total where id = new_transfer_id;

  return new_transfer_id;
end;
$function$;

CREATE OR REPLACE FUNCTION public.adjust_inventory_stock(org_id uuid, p_product_id uuid, p_warehouse_id uuid, p_quantity_delta numeric, p_reason text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_old_qty numeric(14,3);
  v_avg numeric(14,6);
  v_movement_id uuid;
begin
  if auth.uid() is null then
    raise exception 'يجب تسجيل الدخول أولاً';
  end if;
  if not is_org_member(org_id) then
    raise exception 'أنت لست عضوًا في هذه المؤسسة';
  end if;
  if not has_permission(org_id, 'inventory.adjust') then
    raise exception 'ليس لديك صلاحية تسوية المخزون';
  end if;
  if not exists (select 1 from products where id = p_product_id and organization_id = org_id) then
    raise exception 'هذا المنتج لا ينتمي إلى هذه المؤسسة';
  end if;
  if not exists (select 1 from warehouses where id = p_warehouse_id and organization_id = org_id) then
    raise exception 'هذا المخزن لا ينتمي إلى هذه المؤسسة';
  end if;
  if p_quantity_delta is null or p_quantity_delta = 0 then
    raise exception 'أدخل كمية التسوية';
  end if;
  if abs(p_quantity_delta) > 999999999 then
    raise exception 'الكمية كبيرة جدًا';
  end if;
  if coalesce(trim(p_reason), '') = '' then
    raise exception 'سبب التسوية مطلوب';
  end if;

  select quantity, avg_cost into v_old_qty, v_avg
  from inventory_stock
  where product_id = p_product_id and warehouse_id = p_warehouse_id and organization_id = org_id
  for update;

  if not found then
    v_old_qty := 0;
    v_avg := 0;
    insert into inventory_stock (organization_id, product_id, warehouse_id, quantity, avg_cost)
    values (org_id, p_product_id, p_warehouse_id, 0, 0);
  end if;

  if v_old_qty + p_quantity_delta < 0 then
    raise exception 'لا يمكن أن يصبح رصيد المخزون سالبًا بسبب التسوية';
  end if;

  update inventory_stock
  set quantity = v_old_qty + p_quantity_delta, updated_at = now()
  where product_id = p_product_id and warehouse_id = p_warehouse_id and organization_id = org_id;

  insert into inventory_movements (organization_id, product_id, warehouse_id, movement_type, quantity_delta, unit_cost, reference_type, note, created_by)
  values (org_id, p_product_id, p_warehouse_id, 'adjustment', p_quantity_delta, v_avg, 'manual_adjustment', trim(p_reason), auth.uid())
  returning id into v_movement_id;

  return v_movement_id;
end;
$function$;

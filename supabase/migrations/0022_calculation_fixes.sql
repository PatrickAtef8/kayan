-- ============================================================
-- 0022 — Calculation audit fixes
--
-- Fixes (numbers refer to KAYAN_CALCULATION_AUDIT.md):
--   #1  per-line discounts now flow into invoice subtotal/discount/total/profit
--   #2  returns reverse the invoice-level discount and tax proportionally
--   #3  dashboard totals = the same numbers as report_summary
--   #4  purchase returns remove their cost from the weighted average
--   #5  avg_cost / unit costs keep 6 decimals (money columns stay 2)
--   #6  a tracked product cannot be sold below zero stock
--   #7  server-side validation of discounts, tax, prices and payments
--   #8  commission is recomputed after collections and returns, never on tax
--   #9  report_timeseries nets returns; every report nets the same way
--   #10 returns allocate by cumulative rounding — a full return is exact
--   +   cash refunds now move the customer/supplier balance and the ledger
--
-- Conventions introduced here:
--   invoice.subtotal            = Σ qty × price  (gross, before any discount)
--   invoice.discount_total      = invoice-level discount + Σ line discounts
--   invoice.line_discount_total = Σ line discounts (so invoice-level = difference)
--   invoice.total               = subtotal − discount_total + tax
--   item.discount_alloc         = this line's share of the invoice-level discount
--   item.tax_alloc              = this line's share of the invoice tax
--   (shares are allocated by cumulative rounding, so they add up exactly)
--   return.subtotal_reversed    = net sales reversed (excludes tax)
--   return.tax_reversed         = tax reversed
--   return.total                = subtotal_reversed + tax_reversed (the credit)
--   purchases: stock cost of a line = line_total − discount_alloc (tax excluded)
-- ============================================================

-- ---------- 0. Prerequisite check ----------
-- This migration rewrites functions and tables created by 0011–0021. Running it
-- on a database that is missing any of them fails half-way (for example
-- 'relation "stock_transfer_items" does not exist' when 0015 was never applied).
-- Check first and say exactly what is missing, before anything is changed.
do $$
declare
  missing text[] := '{}';
begin
  if to_regclass('public.sales_returns') is null            then missing := array_append(missing, '0011_returns_and_team'::text); end if;
  if to_regclass('public.purchase_returns') is null         then missing := array_append(missing, '0012_purchase_returns'::text); end if;
  if not exists (select 1 from pg_proc where proname = 'create_custom_role')
                                                              then missing := array_append(missing, '0013_custom_roles'::text); end if;
  if not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'customers' and column_name = 'price_tier')
                                                              then missing := array_append(missing, '0014_price_tiers'::text); end if;
  if to_regclass('public.stock_transfer_items') is null     then missing := array_append(missing, '0015_warehouse_transfers'::text); end if;
  if to_regclass('public.attachments') is null              then missing := array_append(missing, '0016_attachments'::text); end if;
  if not exists (select 1 from pg_proc where proname = 'global_search')
                                                              then missing := array_append(missing, '0017_global_search'::text); end if;
  if not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'customers' and column_name = 'opening_balance')
                                                              then missing := array_append(missing, '0018_opening_balances'::text); end if;
  if not exists (select 1 from pg_proc where proname = 'report_overdue_collections')
                                                              then missing := array_append(missing, '0019_alert_queries'::text); end if;
  if not exists (select 1 from pg_proc where proname = 'dashboard_sales_totals')
                                                              then missing := array_append(missing, '0021_dashboard_totals'::text); end if;

  if array_length(missing, 1) is not null then
    raise exception '0022 cannot run yet: these earlier migrations are not applied on this database: %. Apply them in order (oldest first), then run 0022 again. Nothing was changed.',
      array_to_string(missing, ', ');
  end if;
end $$;

-- ---------- 1. Precision: costs keep 6 decimals ----------
alter table inventory_stock       alter column avg_cost  type numeric(14,6);
alter table product_prices        alter column cost      type numeric(14,6);
alter table inventory_movements   alter column unit_cost type numeric(14,6);
alter table sales_invoice_items   alter column unit_cost type numeric(14,6);
alter table sales_return_items    alter column unit_cost type numeric(14,6);
alter table stock_transfer_items  alter column unit_cost type numeric(14,6);
alter table purchase_return_items alter column unit_cost type numeric(14,6);

-- ---------- 2. New columns ----------
alter table sales_invoices    add column if not exists line_discount_total   numeric(14,2) not null default 0;
alter table sales_invoices    add column if not exists commission_rate_snapshot numeric(5,2);
alter table purchase_invoices add column if not exists line_discount_total   numeric(14,2) not null default 0;

alter table sales_invoice_items    add column if not exists discount_alloc numeric(14,2) not null default 0;
alter table sales_invoice_items    add column if not exists tax_alloc      numeric(14,2) not null default 0;
alter table purchase_invoice_items add column if not exists discount_alloc numeric(14,2) not null default 0;
alter table purchase_invoice_items add column if not exists tax_alloc      numeric(14,2) not null default 0;

alter table sales_returns    add column if not exists tax_reversed numeric(14,2) not null default 0;
alter table purchase_returns add column if not exists tax_reversed numeric(14,2) not null default 0;

-- ---------- 3. Helpers ----------

-- Splits p_amount across p_weights so the pieces add up to p_amount exactly
-- (cumulative rounding). Weights are consumed in array order.
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

-- The part of `p_amount` that belongs to returning `p_qty` units when
-- `p_already` of `p_total_qty` units were returned before. Cumulative
-- rounding: returning everything reverses exactly p_amount.
create or replace function cumulative_share(p_amount numeric, p_already numeric, p_qty numeric, p_total_qty numeric)
returns numeric
language sql
immutable
as $$
  select case when coalesce(p_total_qty, 0) = 0 then 0
         else round(p_amount * (p_already + p_qty) / p_total_qty, 2)
              - round(p_amount * p_already / p_total_qty, 2)
         end;
$$;

-- Commission is always a pure function of the invoice's current state.
create or replace function recompute_sales_commission(p_invoice_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  i record;
  v_ret_net numeric;
  v_ret_profit numeric;
  v_refunds numeric;
  v_net numeric;
  v_base numeric := 0;
  v_ratio numeric;
begin
  select * into i from sales_invoices where id = p_invoice_id;
  if not found or i.sales_rep_id is null or i.commission_basis_snapshot is null then
    return;
  end if;

  select coalesce(sum(subtotal_reversed), 0), coalesce(sum(profit_reversed), 0), coalesce(sum(cash_refunded), 0)
  into v_ret_net, v_ret_profit, v_refunds
  from sales_returns where sales_invoice_id = p_invoice_id;

  v_net := i.subtotal - i.discount_total;
  v_ratio := case when v_net > 0 then least(v_ret_net / v_net, 1) else 0 end;

  v_base := case i.commission_basis_snapshot
    when 'sales_value'      then i.subtotal * (1 - v_ratio)
    when 'net_sales'        then v_net - v_ret_net
    when 'gross_profit'     then greatest(i.profit_total - v_ret_profit, 0)
    -- cash actually kept, with the tax share removed
    when 'collected_amount' then greatest(least(i.amount_paid, i.total) - v_refunds, 0)
                                 * case when i.total > 0 then v_net / i.total else 1 end
    else 0
  end;

  update sales_invoices
  set commission_amount = round(v_base * coalesce(i.commission_rate_snapshot, 0) / 100, 2)
  where id = p_invoice_id;
end;
$$;
revoke all on function recompute_sales_commission(uuid) from public, anon, authenticated;

-- What is still owed on one invoice (credit notes and refunds included).
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

-- ---------- 4. Back-fill existing rows ----------
-- Snapshot the commission rate each existing invoice was earning.
update sales_invoices i
set commission_rate_snapshot = r.commission_rate
from sales_representatives r
where r.id = i.sales_rep_id and i.commission_rate_snapshot is null;

-- Allocate the existing invoice-level discount / tax to lines.
-- (Old invoices stay exactly as billed: their line_discount_total stays 0.)
do $$
declare
  inv record;
  ids uuid[];
  lts numeric[];
  nets numeric[];
  disc numeric[];
  taxa numeric[];
  base numeric;
  k int;
begin
  for inv in select id, discount_total, tax_total from sales_invoices loop
    select array_agg(id order by id), array_agg(line_total order by id) into ids, lts
    from sales_invoice_items where sales_invoice_id = inv.id;
    continue when ids is null;
    base := (select coalesce(sum(x), 0) from unnest(lts) x);
    disc := allocate_by_weight(least(inv.discount_total, base), lts);
    nets := '{}';
    for k in 1 .. array_length(ids, 1) loop
      nets := nets || (lts[k] - disc[k]);
    end loop;
    taxa := allocate_by_weight(inv.tax_total, nets);
    for k in 1 .. array_length(ids, 1) loop
      update sales_invoice_items set discount_alloc = disc[k], tax_alloc = taxa[k] where id = ids[k];
    end loop;
  end loop;

  for inv in select id, discount_total, tax_total from purchase_invoices loop
    select array_agg(id order by id), array_agg(line_total order by id) into ids, lts
    from purchase_invoice_items where purchase_invoice_id = inv.id;
    continue when ids is null;
    base := (select coalesce(sum(x), 0) from unnest(lts) x);
    disc := allocate_by_weight(least(inv.discount_total, base), lts);
    nets := '{}';
    for k in 1 .. array_length(ids, 1) loop
      nets := nets || (lts[k] - disc[k]);
    end loop;
    taxa := allocate_by_weight(inv.tax_total, nets);
    for k in 1 .. array_length(ids, 1) loop
      update purchase_invoice_items set discount_alloc = disc[k], tax_alloc = taxa[k] where id = ids[k];
    end loop;
  end loop;
end $$;

-- ============================================================
-- 5. create_purchase_invoice — line discounts, allocation, net stock cost
-- ============================================================
create or replace function create_purchase_invoice(
  org_id uuid,
  p_supplier_id uuid,
  p_warehouse_id uuid,
  p_invoice_number text,
  p_invoice_date date,
  items jsonb,
  p_discount_total numeric,
  p_tax_total numeric,
  p_amount_paid numeric,
  p_payment_method text,
  p_notes text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  new_invoice_id uuid;
  new_payment_id uuid;
  account_id uuid;
  item jsonb;
  v_product_id uuid;
  v_quantity numeric(14,3);
  v_unit_cost numeric(14,2);
  v_discount numeric(14,2);
  v_line_total numeric(14,2);
  v_item_id uuid;
  v_ids uuid[] := '{}';
  v_products uuid[] := '{}';
  v_qtys numeric[] := '{}';
  v_lts numeric[] := '{}';
  v_nets numeric[] := '{}';
  v_disc_alloc numeric[];
  v_tax_alloc numeric[];
  v_subtotal numeric(14,2) := 0;
  v_line_discounts numeric(14,2) := 0;
  v_invoice_discount numeric(14,2);
  v_tax numeric(14,2);
  v_total numeric(14,2);
  v_old_qty numeric(14,3);
  v_old_avg numeric(14,6);
  v_base_qty numeric;
  v_new_qty numeric(14,3);
  v_new_avg numeric(14,6);
  v_net_cost numeric;
  v_payment_status text;
  v_paid numeric(14,2);
  k int;
begin
  if auth.uid() is null then
    raise exception 'يجب تسجيل الدخول أولاً';
  end if;
  if not is_org_member(org_id) then
    raise exception 'أنت لست عضوًا في هذه المؤسسة';
  end if;
  if not has_permission(org_id, 'purchases.create') then
    raise exception 'ليس لديك صلاحية إنشاء فواتير الشراء';
  end if;
  if not exists (select 1 from suppliers where id = p_supplier_id and organization_id = org_id) then
    raise exception 'هذا المورد لا ينتمي إلى هذه المؤسسة';
  end if;
  if not exists (select 1 from warehouses where id = p_warehouse_id and organization_id = org_id) then
    raise exception 'هذا المخزن لا ينتمي إلى هذه المؤسسة';
  end if;
  if items is null or jsonb_typeof(items) <> 'array' or jsonb_array_length(items) = 0 then
    raise exception 'يجب إضافة صنف واحد على الأقل لفاتورة الشراء';
  end if;

  v_invoice_discount := coalesce(p_discount_total, 0);
  v_tax := coalesce(p_tax_total, 0);
  if v_invoice_discount < 0 then raise exception 'الخصم لا يمكن أن يكون سالبًا'; end if;
  if v_tax < 0 then raise exception 'الضريبة لا يمكن أن تكون سالبة'; end if;
  if coalesce(p_amount_paid, 0) < 0 then raise exception 'المبلغ المدفوع لا يمكن أن يكون سالبًا'; end if;

  insert into purchase_invoices (organization_id, supplier_id, warehouse_id, invoice_number, invoice_date, notes, created_by)
  values (org_id, p_supplier_id, p_warehouse_id, nullif(p_invoice_number, ''), coalesce(p_invoice_date, current_date), nullif(p_notes, ''), auth.uid())
  returning id into new_invoice_id;

  -- Pass 1: validate and store the lines.
  for item in select * from jsonb_array_elements(items)
  loop
    v_product_id := (item->>'product_id')::uuid;
    v_quantity := (item->>'quantity')::numeric;
    v_unit_cost := (item->>'unit_cost')::numeric;
    v_discount := coalesce((item->>'discount')::numeric, 0);

    if not exists (select 1 from products where id = v_product_id and organization_id = org_id) then
      raise exception 'أحد المنتجات المختارة لا ينتمي إلى هذه المؤسسة';
    end if;
    if v_quantity is null or v_quantity <= 0 then
      raise exception 'يجب أن تكون الكمية أكبر من صفر';
    end if;
    if v_unit_cost is null or v_unit_cost < 0 then
      raise exception 'سعر الشراء لا يمكن أن يكون سالبًا';
    end if;
    if v_discount < 0 then
      raise exception 'خصم الصنف لا يمكن أن يكون سالبًا';
    end if;
    if v_discount > round(v_quantity * v_unit_cost, 2) then
      raise exception 'خصم الصنف أكبر من قيمة الصنف';
    end if;

    v_line_total := round(v_quantity * v_unit_cost, 2) - v_discount;
    v_subtotal := v_subtotal + round(v_quantity * v_unit_cost, 2);
    v_line_discounts := v_line_discounts + v_discount;

    insert into purchase_invoice_items (organization_id, purchase_invoice_id, product_id, quantity, unit_cost, discount, line_total)
    values (org_id, new_invoice_id, v_product_id, v_quantity, v_unit_cost, v_discount, v_line_total)
    returning id into v_item_id;

    v_ids := v_ids || v_item_id;
    v_products := v_products || v_product_id;
    v_qtys := v_qtys || v_quantity;
    v_lts := v_lts || v_line_total;
  end loop;

  if v_invoice_discount > v_subtotal - v_line_discounts then
    raise exception 'الخصم أكبر من قيمة الفاتورة';
  end if;

  -- Allocate the invoice-level discount, then the tax, to the lines.
  v_disc_alloc := allocate_by_weight(v_invoice_discount, v_lts);
  for k in 1 .. array_length(v_ids, 1) loop
    v_nets := v_nets || (v_lts[k] - v_disc_alloc[k]);
  end loop;
  if v_tax > 0 and (v_subtotal - v_line_discounts - v_invoice_discount) <= 0 then
    raise exception 'لا يمكن إضافة ضريبة على فاتورة قيمتها صفر';
  end if;
  v_tax_alloc := allocate_by_weight(v_tax, v_nets);

  v_total := v_subtotal - (v_invoice_discount + v_line_discounts) + v_tax;
  v_paid := coalesce(p_amount_paid, 0);
  if v_paid > v_total then
    raise exception 'المبلغ المدفوع أكبر من إجمالي الفاتورة';
  end if;

  -- Pass 2: stock. A line enters stock at its NET cost (line discount and
  -- its share of the invoice discount removed, tax excluded).
  for k in 1 .. array_length(v_ids, 1) loop
    update purchase_invoice_items
    set discount_alloc = v_disc_alloc[k], tax_alloc = v_tax_alloc[k]
    where id = v_ids[k];

    v_net_cost := v_nets[k];

    select quantity, avg_cost into v_old_qty, v_old_avg
    from inventory_stock
    where product_id = v_products[k] and warehouse_id = p_warehouse_id
    for update;

    if not found then
      v_old_qty := 0;
      v_old_avg := 0;
      insert into inventory_stock (organization_id, product_id, warehouse_id, quantity, avg_cost)
      values (org_id, v_products[k], p_warehouse_id, 0, 0);
    end if;

    v_base_qty := greatest(v_old_qty, 0);
    v_new_qty := v_old_qty + v_qtys[k];
    v_new_avg := case when v_base_qty + v_qtys[k] = 0 then v_old_avg
                      else ((v_base_qty * v_old_avg) + v_net_cost) / (v_base_qty + v_qtys[k]) end;

    update inventory_stock
    set quantity = v_new_qty, avg_cost = v_new_avg, updated_at = now()
    where product_id = v_products[k] and warehouse_id = p_warehouse_id;

    insert into inventory_movements (organization_id, product_id, warehouse_id, movement_type, quantity_delta, unit_cost, reference_type, reference_id, created_by)
    values (org_id, v_products[k], p_warehouse_id, 'purchase', v_qtys[k], v_net_cost / v_qtys[k], 'purchase_invoice', new_invoice_id, auth.uid());

    update product_prices set cost = v_new_avg, updated_at = now()
    where product_id = v_products[k] and organization_id = org_id;
  end loop;

  v_payment_status := case
    when v_paid <= 0 then 'unpaid'
    when v_paid >= v_total then 'paid'
    else 'partial'
  end;

  update purchase_invoices
  set subtotal = v_subtotal,
      discount_total = v_invoice_discount + v_line_discounts,
      line_discount_total = v_line_discounts,
      tax_total = v_tax,
      total = v_total,
      amount_paid = v_paid,
      payment_status = v_payment_status,
      updated_at = now()
  where id = new_invoice_id;

  if v_paid > 0 then
    account_id := ensure_default_treasury_account(org_id);

    insert into supplier_payments (organization_id, supplier_id, purchase_invoice_id, amount, payment_date, payment_method, created_by)
    values (org_id, p_supplier_id, new_invoice_id, v_paid, coalesce(p_invoice_date, current_date), nullif(p_payment_method, ''), auth.uid())
    returning id into new_payment_id;

    insert into treasury_movements (organization_id, treasury_account_id, direction, amount, category, movement_date, source_type, source_id, description, created_by)
    values (org_id, account_id, 'out', v_paid, 'supplier_payment', coalesce(p_invoice_date, current_date), 'purchase_invoice', new_invoice_id, nullif(p_notes, ''), auth.uid());
  end if;

  return new_invoice_id;
end;
$$;

-- ============================================================
-- 6. create_sales_invoice — line discounts, allocation, stock guard
-- ============================================================
create or replace function create_sales_invoice(
  org_id uuid,
  p_customer_id uuid,
  p_warehouse_id uuid,
  p_invoice_number text,
  p_invoice_date date,
  items jsonb,
  p_discount_total numeric,
  p_tax_total numeric,
  p_amount_collected numeric,
  p_payment_method text,
  p_notes text,
  p_sales_rep_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  new_invoice_id uuid;
  new_collection_id uuid;
  account_id uuid;
  item jsonb;
  v_product_id uuid;
  v_quantity numeric(14,3);
  v_unit_price numeric(14,2);
  v_discount numeric(14,2);
  v_line_total numeric(14,2);
  v_unit_cost numeric(14,6);
  v_cost_total numeric(14,2);
  v_line_profit numeric(14,2);
  v_track_inventory boolean;
  v_old_qty numeric(14,3);
  v_old_avg numeric(14,6);
  v_item_id uuid;
  v_ids uuid[] := '{}';
  v_lts numeric[] := '{}';
  v_nets numeric[] := '{}';
  v_disc_alloc numeric[];
  v_tax_alloc numeric[];
  v_subtotal numeric(14,2) := 0;
  v_line_discounts numeric(14,2) := 0;
  v_invoice_discount numeric(14,2);
  v_tax numeric(14,2);
  v_cogs numeric(14,2) := 0;
  v_total numeric(14,2);
  v_net_sales numeric(14,2);
  v_profit numeric(14,2);
  v_payment_status text;
  v_collected numeric(14,2);
  v_commission_basis text;
  v_commission_rate numeric(5,2);
  k int;
begin
  if auth.uid() is null then
    raise exception 'يجب تسجيل الدخول أولاً';
  end if;
  if not is_org_member(org_id) then
    raise exception 'أنت لست عضوًا في هذه المؤسسة';
  end if;
  if not has_permission(org_id, 'sales.create') then
    raise exception 'ليس لديك صلاحية إنشاء فواتير البيع';
  end if;
  if not exists (select 1 from customers where id = p_customer_id and organization_id = org_id) then
    raise exception 'هذا العميل لا ينتمي إلى هذه المؤسسة';
  end if;
  if not exists (select 1 from warehouses where id = p_warehouse_id and organization_id = org_id) then
    raise exception 'هذا المخزن لا ينتمي إلى هذه المؤسسة';
  end if;
  if items is null or jsonb_typeof(items) <> 'array' or jsonb_array_length(items) = 0 then
    raise exception 'يجب إضافة صنف واحد على الأقل لفاتورة البيع';
  end if;
  if p_sales_rep_id is not null and not exists (select 1 from sales_representatives where id = p_sales_rep_id and organization_id = org_id) then
    raise exception 'هذا المندوب لا ينتمي إلى هذه المؤسسة';
  end if;

  v_invoice_discount := coalesce(p_discount_total, 0);
  v_tax := coalesce(p_tax_total, 0);
  if v_invoice_discount < 0 then raise exception 'الخصم لا يمكن أن يكون سالبًا'; end if;
  if v_tax < 0 then raise exception 'الضريبة لا يمكن أن تكون سالبة'; end if;
  if coalesce(p_amount_collected, 0) < 0 then raise exception 'المبلغ المحصل لا يمكن أن يكون سالبًا'; end if;

  insert into sales_invoices (organization_id, customer_id, warehouse_id, invoice_number, invoice_date, notes, created_by, sales_rep_id)
  values (org_id, p_customer_id, p_warehouse_id, nullif(p_invoice_number, ''), coalesce(p_invoice_date, current_date), nullif(p_notes, ''), auth.uid(), p_sales_rep_id)
  returning id into new_invoice_id;

  for item in select * from jsonb_array_elements(items)
  loop
    v_product_id := (item->>'product_id')::uuid;
    v_quantity := (item->>'quantity')::numeric;
    v_unit_price := (item->>'unit_price')::numeric;
    v_discount := coalesce((item->>'discount')::numeric, 0);

    select track_inventory into v_track_inventory from products where id = v_product_id and organization_id = org_id;
    if not found then
      raise exception 'أحد المنتجات المختارة لا ينتمي إلى هذه المؤسسة';
    end if;
    if v_quantity is null or v_quantity <= 0 then
      raise exception 'يجب أن تكون الكمية أكبر من صفر';
    end if;
    if v_unit_price is null or v_unit_price < 0 then
      raise exception 'سعر البيع لا يمكن أن يكون سالبًا';
    end if;
    if v_discount < 0 then
      raise exception 'خصم الصنف لا يمكن أن يكون سالبًا';
    end if;
    if v_discount > round(v_quantity * v_unit_price, 2) then
      raise exception 'خصم الصنف أكبر من قيمة الصنف';
    end if;

    if v_track_inventory then
      select quantity, avg_cost into v_old_qty, v_old_avg
      from inventory_stock
      where product_id = v_product_id and warehouse_id = p_warehouse_id
      for update;

      if not found then
        v_old_qty := 0;
        v_old_avg := 0;
      end if;

      if v_old_qty < v_quantity then
        raise exception 'الكمية المتاحة بالمخزون أقل من الكمية المطلوبة (المتاح: %)', greatest(v_old_qty, 0);
      end if;

      v_unit_cost := v_old_avg;

      update inventory_stock
      set quantity = v_old_qty - v_quantity, updated_at = now()
      where product_id = v_product_id and warehouse_id = p_warehouse_id;

      insert into inventory_movements (organization_id, product_id, warehouse_id, movement_type, quantity_delta, unit_cost, reference_type, reference_id, created_by)
      values (org_id, v_product_id, p_warehouse_id, 'sale', -v_quantity, v_unit_cost, 'sales_invoice', new_invoice_id, auth.uid());
    else
      select coalesce(cost, 0) into v_unit_cost from product_prices where product_id = v_product_id and organization_id = org_id;
      v_unit_cost := coalesce(v_unit_cost, 0);
    end if;

    v_line_total := round(v_quantity * v_unit_price, 2) - v_discount;
    v_cost_total := v_quantity * v_unit_cost;
    v_line_profit := v_line_total - v_cost_total;

    insert into sales_invoice_items (organization_id, sales_invoice_id, product_id, quantity, unit_price, discount, line_total, unit_cost, cost_total, profit)
    values (org_id, new_invoice_id, v_product_id, v_quantity, v_unit_price, v_discount, v_line_total, v_unit_cost, v_cost_total, v_line_profit)
    returning id into v_item_id;

    v_ids := v_ids || v_item_id;
    v_lts := v_lts || v_line_total;
    v_subtotal := v_subtotal + round(v_quantity * v_unit_price, 2);
    v_line_discounts := v_line_discounts + v_discount;
    v_cogs := v_cogs + v_cost_total;
  end loop;

  if v_invoice_discount > v_subtotal - v_line_discounts then
    raise exception 'الخصم أكبر من قيمة الفاتورة';
  end if;

  v_disc_alloc := allocate_by_weight(v_invoice_discount, v_lts);
  for k in 1 .. array_length(v_ids, 1) loop
    v_nets := v_nets || (v_lts[k] - v_disc_alloc[k]);
  end loop;
  if v_tax > 0 and (v_subtotal - v_line_discounts - v_invoice_discount) <= 0 then
    raise exception 'لا يمكن إضافة ضريبة على فاتورة قيمتها صفر';
  end if;
  v_tax_alloc := allocate_by_weight(v_tax, v_nets);
  for k in 1 .. array_length(v_ids, 1) loop
    update sales_invoice_items set discount_alloc = v_disc_alloc[k], tax_alloc = v_tax_alloc[k] where id = v_ids[k];
  end loop;

  v_net_sales := v_subtotal - v_line_discounts - v_invoice_discount;
  v_total := v_net_sales + v_tax;
  v_profit := v_net_sales - v_cogs;
  v_collected := coalesce(p_amount_collected, 0);
  if v_collected > v_total then
    raise exception 'المبلغ المحصل أكبر من إجمالي الفاتورة';
  end if;
  v_payment_status := case
    when v_collected <= 0 then 'unpaid'
    when v_collected >= v_total then 'paid'
    else 'partial'
  end;

  -- §33: commission basis/rate is captured on the invoice at creation time.
  if p_sales_rep_id is not null then
    select commission_basis, commission_rate into v_commission_basis, v_commission_rate
    from sales_representatives where id = p_sales_rep_id;
  end if;

  update sales_invoices
  set subtotal = v_subtotal,
      discount_total = v_invoice_discount + v_line_discounts,
      line_discount_total = v_line_discounts,
      tax_total = v_tax,
      total = v_total,
      cogs_total = v_cogs,
      profit_total = v_profit,
      amount_paid = v_collected,
      payment_status = v_payment_status,
      commission_basis_snapshot = v_commission_basis,
      commission_rate_snapshot = v_commission_rate,
      commission_amount = 0,
      updated_at = now()
  where id = new_invoice_id;

  if v_collected > 0 then
    account_id := ensure_default_treasury_account(org_id);

    insert into customer_collections (organization_id, customer_id, sales_invoice_id, amount, collection_date, payment_method, created_by)
    values (org_id, p_customer_id, new_invoice_id, v_collected, coalesce(p_invoice_date, current_date), nullif(p_payment_method, ''), auth.uid())
    returning id into new_collection_id;

    insert into treasury_movements (organization_id, treasury_account_id, direction, amount, category, movement_date, source_type, source_id, description, created_by)
    values (org_id, account_id, 'in', v_collected, 'customer_collection', coalesce(p_invoice_date, current_date), 'sales_invoice', new_invoice_id, nullif(p_notes, ''), auth.uid());
  end if;

  perform recompute_sales_commission(new_invoice_id);

  return new_invoice_id;
end;
$$;

-- ============================================================
-- 7. Collections and supplier payments — never beyond what is owed
--    on the invoice they are attached to
-- ============================================================
create or replace function record_customer_collection(
  org_id uuid,
  p_customer_id uuid,
  p_sales_invoice_id uuid,
  p_amount numeric,
  p_collection_date date,
  p_payment_method text,
  p_reference text,
  p_notes text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  new_collection_id uuid;
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

  if p_sales_invoice_id is not null then
    select total, amount_paid into v_total, v_amount_paid
    from sales_invoices
    where id = p_sales_invoice_id and organization_id = org_id and customer_id = p_customer_id
    for update;
    if not found then
      raise exception 'هذه الفاتورة لا تخص هذا العميل';
    end if;
    if round(p_amount, 2) > sales_invoice_remaining(p_sales_invoice_id) then
      raise exception 'المبلغ أكبر من المتبقي على الفاتورة (المتبقي: %)', sales_invoice_remaining(p_sales_invoice_id);
    end if;
  end if;

  account_id := ensure_default_treasury_account(org_id);

  insert into customer_collections (organization_id, customer_id, sales_invoice_id, amount, collection_date, payment_method, reference, notes, created_by)
  values (org_id, p_customer_id, p_sales_invoice_id, p_amount, coalesce(p_collection_date, current_date), nullif(p_payment_method, ''), nullif(p_reference, ''), nullif(p_notes, ''), auth.uid())
  returning id into new_collection_id;

  insert into treasury_movements (organization_id, treasury_account_id, direction, amount, category, movement_date, source_type, source_id, description, created_by)
  values (org_id, account_id, 'in', p_amount, 'customer_collection', coalesce(p_collection_date, current_date), 'customer_collection', new_collection_id, nullif(p_notes, ''), auth.uid());

  if p_sales_invoice_id is not null then
    v_amount_paid := v_amount_paid + p_amount;
    update sales_invoices
    set amount_paid = v_amount_paid,
        payment_status = case when v_amount_paid >= v_total then 'paid' when v_amount_paid <= 0 then 'unpaid' else 'partial' end,
        updated_at = now()
    where id = p_sales_invoice_id;
    perform recompute_sales_commission(p_sales_invoice_id);
  end if;

  return new_collection_id;
end;
$$;

create or replace function record_supplier_payment(
  org_id uuid,
  p_supplier_id uuid,
  p_purchase_invoice_id uuid,
  p_amount numeric,
  p_payment_date date,
  p_payment_method text,
  p_reference text,
  p_notes text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
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

  if p_purchase_invoice_id is not null then
    select total, amount_paid into v_total, v_amount_paid
    from purchase_invoices
    where id = p_purchase_invoice_id and organization_id = org_id and supplier_id = p_supplier_id
    for update;
    if not found then
      raise exception 'هذه الفاتورة لا تخص هذا المورد';
    end if;
    if round(p_amount, 2) > purchase_invoice_remaining(p_purchase_invoice_id) then
      raise exception 'المبلغ أكبر من المتبقي على الفاتورة (المتبقي: %)', purchase_invoice_remaining(p_purchase_invoice_id);
    end if;
  end if;

  account_id := ensure_default_treasury_account(org_id);

  insert into supplier_payments (organization_id, supplier_id, purchase_invoice_id, amount, payment_date, payment_method, reference, notes, created_by)
  values (org_id, p_supplier_id, p_purchase_invoice_id, p_amount, coalesce(p_payment_date, current_date), nullif(p_payment_method, ''), nullif(p_reference, ''), nullif(p_notes, ''), auth.uid())
  returning id into new_payment_id;

  insert into treasury_movements (organization_id, treasury_account_id, direction, amount, category, movement_date, source_type, source_id, description, created_by)
  values (org_id, account_id, 'out', p_amount, 'supplier_payment', coalesce(p_payment_date, current_date), 'supplier_payment', new_payment_id, nullif(p_notes, ''), auth.uid());

  if p_purchase_invoice_id is not null then
    v_amount_paid := v_amount_paid + p_amount;
    update purchase_invoices
    set amount_paid = v_amount_paid,
        payment_status = case when v_amount_paid >= v_total then 'paid' when v_amount_paid <= 0 then 'unpaid' else 'partial' end,
        updated_at = now()
    where id = p_purchase_invoice_id;
  end if;

  return new_payment_id;
end;
$$;

-- ============================================================
-- 8. Sales returns — proportional discount/tax reversal, exact rounding
-- ============================================================
create or replace function create_sales_return(
  org_id uuid,
  p_sales_invoice_id uuid,
  p_return_date date,
  items jsonb,          -- [{sales_invoice_item_id, quantity, condition}]
  p_cash_refund numeric default 0,
  p_notes text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  new_return_id uuid;
  v_customer_id uuid;
  v_warehouse_id uuid;
  account_id uuid;
  item jsonb;
  v_item_id uuid;
  v_quantity numeric(14,3);
  v_condition text;
  v_orig record;
  v_already_returned numeric(14,3);
  v_already_damaged numeric(14,3);
  v_prev_cost numeric(14,2);
  v_remaining numeric(14,3);
  v_unit_price numeric(14,2);
  v_revenue numeric(14,2);
  v_tax numeric(14,2);
  v_cost numeric(14,2);
  v_profit numeric(14,2);
  v_old_qty numeric(14,3);
  v_old_avg numeric(14,6);
  v_base_qty numeric;
  v_track_inventory boolean;
  v_subtotal numeric(14,2) := 0;
  v_tax_total numeric(14,2) := 0;
  v_cost_total numeric(14,2) := 0;
  v_profit_total numeric(14,2) := 0;
begin
  if auth.uid() is null then
    raise exception 'يجب تسجيل الدخول أولاً';
  end if;
  if not is_org_member(org_id) then
    raise exception 'أنت لست عضوًا في هذه المؤسسة';
  end if;
  if not has_permission(org_id, 'sales.approve') then
    raise exception 'ليس لديك صلاحية تسجيل مرتجعات المبيعات';
  end if;

  select customer_id, warehouse_id into v_customer_id, v_warehouse_id
  from sales_invoices
  where id = p_sales_invoice_id and organization_id = org_id
  for update;
  if not found then
    raise exception 'هذه الفاتورة لا تنتمي إلى هذه المؤسسة';
  end if;

  if items is null or jsonb_array_length(items) = 0 then
    raise exception 'يجب اختيار صنف واحد على الأقل للمرتجع';
  end if;
  if p_cash_refund is null or p_cash_refund < 0 then
    raise exception 'قيمة الاسترجاع النقدي غير صحيحة';
  end if;

  insert into sales_returns (organization_id, sales_invoice_id, customer_id, warehouse_id, return_date, notes, created_by)
  values (org_id, p_sales_invoice_id, v_customer_id, v_warehouse_id, coalesce(p_return_date, current_date), nullif(p_notes, ''), auth.uid())
  returning id into new_return_id;

  for item in select * from jsonb_array_elements(items)
  loop
    v_item_id := (item->>'sales_invoice_item_id')::uuid;
    v_quantity := (item->>'quantity')::numeric;
    v_condition := item->>'condition';

    if v_condition not in ('resalable', 'damaged') then
      raise exception 'حالة الصنف المرتجع غير صحيحة';
    end if;
    if v_quantity is null or v_quantity <= 0 then
      raise exception 'يجب أن تكون كمية المرتجع أكبر من صفر';
    end if;

    select * into v_orig
    from sales_invoice_items
    where id = v_item_id and sales_invoice_id = p_sales_invoice_id and organization_id = org_id;
    if not found then
      raise exception 'هذا الصنف لا ينتمي إلى هذه الفاتورة';
    end if;

    select coalesce(sum(quantity), 0),
           coalesce(sum(quantity) filter (where condition = 'damaged'), 0),
           coalesce(sum(cost_reversed), 0)
    into v_already_returned, v_already_damaged, v_prev_cost
    from sales_return_items
    where sales_invoice_item_id = v_item_id;

    v_remaining := v_orig.quantity - v_already_returned;
    if v_quantity > v_remaining then
      raise exception 'الكمية المطلوب إرجاعها أكبر من المتاح لهذا الصنف (المتبقي: %)', v_remaining;
    end if;

    -- Net revenue of the line (after its share of the invoice discount) and
    -- its share of the tax, reversed by cumulative rounding.
    v_revenue := cumulative_share(v_orig.line_total - v_orig.discount_alloc, v_already_returned, v_quantity, v_orig.quantity);
    v_tax := cumulative_share(v_orig.tax_alloc, v_already_returned, v_quantity, v_orig.quantity);
    v_unit_price := v_revenue / v_quantity;

    if v_condition = 'resalable' then
      if v_already_returned + v_quantity = v_orig.quantity and v_already_damaged = 0 then
        v_cost := v_orig.cost_total - v_prev_cost;   -- last piece: exact remainder
      else
        v_cost := round(v_orig.cost_total * v_quantity / v_orig.quantity, 2);
      end if;
    else
      v_cost := 0;
    end if;
    v_profit := v_revenue - v_cost;

    if v_condition = 'resalable' then
      select track_inventory into v_track_inventory from products where id = v_orig.product_id and organization_id = org_id;

      if v_track_inventory then
        select quantity, avg_cost into v_old_qty, v_old_avg
        from inventory_stock
        where product_id = v_orig.product_id and warehouse_id = v_warehouse_id
        for update;

        if not found then
          v_old_qty := 0;
          v_old_avg := 0;
          insert into inventory_stock (organization_id, product_id, warehouse_id, quantity, avg_cost)
          values (org_id, v_orig.product_id, v_warehouse_id, 0, 0);
        end if;

        -- Re-enters stock at exactly the cost it left with.
        v_base_qty := greatest(v_old_qty, 0);
        update inventory_stock
        set quantity = v_old_qty + v_quantity,
            avg_cost = case when v_base_qty + v_quantity > 0
                            then ((v_base_qty * v_old_avg) + v_cost) / (v_base_qty + v_quantity)
                            else v_old_avg end,
            updated_at = now()
        where product_id = v_orig.product_id and warehouse_id = v_warehouse_id;

        insert into inventory_movements (organization_id, product_id, warehouse_id, movement_type, quantity_delta, unit_cost, reference_type, reference_id, created_by)
        values (org_id, v_orig.product_id, v_warehouse_id, 'sale_return', v_quantity, v_cost / v_quantity, 'sales_return', new_return_id, auth.uid());
      end if;
    end if;

    insert into sales_return_items (organization_id, sales_return_id, sales_invoice_item_id, product_id, quantity, condition, unit_price, unit_cost, revenue_reversed, cost_reversed, profit_reversed)
    values (org_id, new_return_id, v_item_id, v_orig.product_id, v_quantity, v_condition, v_unit_price, v_orig.unit_cost, v_revenue, v_cost, v_profit);

    v_subtotal := v_subtotal + v_revenue;
    v_tax_total := v_tax_total + v_tax;
    v_cost_total := v_cost_total + v_cost;
    v_profit_total := v_profit_total + v_profit;
  end loop;

  if p_cash_refund > v_subtotal + v_tax_total then
    raise exception 'قيمة الاسترجاع النقدي أكبر من قيمة المرتجع';
  end if;

  update sales_returns
  set subtotal_reversed = v_subtotal,
      tax_reversed = v_tax_total,
      cost_reversed = v_cost_total,
      profit_reversed = v_profit_total,
      total = v_subtotal + v_tax_total,
      cash_refunded = p_cash_refund,
      updated_at = now()
  where id = new_return_id;

  if p_cash_refund > 0 then
    account_id := ensure_default_treasury_account(org_id);
    insert into treasury_movements (organization_id, treasury_account_id, direction, amount, category, movement_date, source_type, source_id, description, created_by)
    values (org_id, account_id, 'out', p_cash_refund, 'sales_return', coalesce(p_return_date, current_date), 'sales_return', new_return_id, nullif(p_notes, ''), auth.uid());
  end if;

  perform recompute_sales_commission(p_sales_invoice_id);

  return new_return_id;
end;
$$;

-- ============================================================
-- 9. Purchase returns — proportional discount/tax, WAC recomputed
-- ============================================================
create or replace function create_purchase_return(
  org_id uuid,
  p_purchase_invoice_id uuid,
  p_return_date date,
  items jsonb,          -- [{purchase_invoice_item_id, quantity}]
  p_cash_refund numeric default 0,
  p_notes text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  new_return_id uuid;
  v_supplier_id uuid;
  v_warehouse_id uuid;
  account_id uuid;
  item jsonb;
  v_item_id uuid;
  v_quantity numeric(14,3);
  v_orig record;
  v_already_returned numeric(14,3);
  v_remaining numeric(14,3);
  v_value numeric(14,2);
  v_tax numeric(14,2);
  v_track_inventory boolean;
  v_current_qty numeric(14,3);
  v_current_avg numeric(14,6);
  v_new_qty numeric(14,3);
  v_subtotal numeric(14,2) := 0;
  v_tax_total numeric(14,2) := 0;
begin
  if auth.uid() is null then
    raise exception 'يجب تسجيل الدخول أولاً';
  end if;
  if not is_org_member(org_id) then
    raise exception 'أنت لست عضوًا في هذه المؤسسة';
  end if;
  if not has_permission(org_id, 'purchases.approve') then
    raise exception 'ليس لديك صلاحية تسجيل مرتجعات المشتريات';
  end if;

  select supplier_id, warehouse_id into v_supplier_id, v_warehouse_id
  from purchase_invoices
  where id = p_purchase_invoice_id and organization_id = org_id
  for update;
  if not found then
    raise exception 'هذه الفاتورة لا تنتمي إلى هذه المؤسسة';
  end if;

  if items is null or jsonb_array_length(items) = 0 then
    raise exception 'يجب اختيار صنف واحد على الأقل للمرتجع';
  end if;
  if p_cash_refund is null or p_cash_refund < 0 then
    raise exception 'قيمة الاسترجاع النقدي غير صحيحة';
  end if;

  insert into purchase_returns (organization_id, purchase_invoice_id, supplier_id, warehouse_id, return_date, notes, created_by)
  values (org_id, p_purchase_invoice_id, v_supplier_id, v_warehouse_id, coalesce(p_return_date, current_date), nullif(p_notes, ''), auth.uid())
  returning id into new_return_id;

  for item in select * from jsonb_array_elements(items)
  loop
    v_item_id := (item->>'purchase_invoice_item_id')::uuid;
    v_quantity := (item->>'quantity')::numeric;

    if v_quantity is null or v_quantity <= 0 then
      raise exception 'يجب أن تكون كمية المرتجع أكبر من صفر';
    end if;

    select * into v_orig
    from purchase_invoice_items
    where id = v_item_id and purchase_invoice_id = p_purchase_invoice_id and organization_id = org_id;
    if not found then
      raise exception 'هذا الصنف لا ينتمي إلى هذه الفاتورة';
    end if;

    select coalesce(sum(quantity), 0) into v_already_returned
    from purchase_return_items
    where purchase_invoice_item_id = v_item_id;

    v_remaining := v_orig.quantity - v_already_returned;
    if v_quantity > v_remaining then
      raise exception 'الكمية المطلوب إرجاعها أكبر من المتاح لهذا الصنف (المتبقي: %)', v_remaining;
    end if;

    -- Net value of what goes back (line discount and its share of the
    -- invoice discount removed) and its share of the tax.
    v_value := cumulative_share(v_orig.line_total - v_orig.discount_alloc, v_already_returned, v_quantity, v_orig.quantity);
    v_tax := cumulative_share(v_orig.tax_alloc, v_already_returned, v_quantity, v_orig.quantity);

    select track_inventory into v_track_inventory from products where id = v_orig.product_id and organization_id = org_id;

    if v_track_inventory then
      select quantity, avg_cost into v_current_qty, v_current_avg
      from inventory_stock
      where product_id = v_orig.product_id and warehouse_id = v_warehouse_id
      for update;

      if not found or coalesce(v_current_qty, 0) < v_quantity then
        raise exception 'الكمية المتاحة بالمخزون أقل من كمية المرتجع لهذا الصنف';
      end if;

      -- The returned units leave the weighted-average pool at the cost they
      -- entered it with, so the pool value (and avg) stays truthful.
      v_new_qty := v_current_qty - v_quantity;
      update inventory_stock
      set quantity = v_new_qty,
          avg_cost = case when v_new_qty > 0
                          then greatest((v_current_qty * v_current_avg) - v_value, 0) / v_new_qty
                          else v_current_avg end,
          updated_at = now()
      where product_id = v_orig.product_id and warehouse_id = v_warehouse_id;

      insert into inventory_movements (organization_id, product_id, warehouse_id, movement_type, quantity_delta, unit_cost, reference_type, reference_id, created_by)
      values (org_id, v_orig.product_id, v_warehouse_id, 'purchase_return', -v_quantity, v_value / v_quantity, 'purchase_return', new_return_id, auth.uid());
    end if;

    insert into purchase_return_items (organization_id, purchase_return_id, purchase_invoice_item_id, product_id, quantity, unit_cost, line_total)
    values (org_id, new_return_id, v_item_id, v_orig.product_id, v_quantity, v_value / v_quantity, v_value);

    v_subtotal := v_subtotal + v_value;
    v_tax_total := v_tax_total + v_tax;
  end loop;

  if p_cash_refund > v_subtotal + v_tax_total then
    raise exception 'قيمة الاسترجاع النقدي أكبر من قيمة المرتجع';
  end if;

  update purchase_returns
  set total = v_subtotal + v_tax_total,
      tax_reversed = v_tax_total,
      cash_refunded = p_cash_refund,
      updated_at = now()
  where id = new_return_id;

  if p_cash_refund > 0 then
    account_id := ensure_default_treasury_account(org_id);
    insert into treasury_movements (organization_id, treasury_account_id, direction, amount, category, movement_date, source_type, source_id, description, created_by)
    values (org_id, account_id, 'in', p_cash_refund, 'purchase_return', coalesce(p_return_date, current_date), 'purchase_return', new_return_id, nullif(p_notes, ''), auth.uid());
  end if;

  return new_return_id;
end;
$$;
-- ============================================================
-- 10. Stock transfer — keep 6-decimal costs
-- ============================================================
create or replace function create_stock_transfer(
  org_id uuid,
  p_from_warehouse_id uuid,
  p_to_warehouse_id uuid,
  p_transfer_date date,
  items jsonb,  -- [{product_id, quantity}]
  p_notes text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
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
$$;

create or replace function adjust_inventory_stock(
  org_id uuid,
  p_product_id uuid,
  p_warehouse_id uuid,
  p_quantity_delta numeric,
  p_reason text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
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
$$;

-- ============================================================
-- 11. Reports — net sales never include returned tax
-- ============================================================
create or replace function report_summary(org_id uuid, p_from date default null, p_to date default null)
returns jsonb
language plpgsql
stable
set search_path = public
as $$
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
    coalesce(sum(commission_amount), 0) as commissions
  into s
  from sales_invoices
  where organization_id = org_id
    and (p_from is null or invoice_date >= p_from)
    and (p_to is null or invoice_date <= p_to);

  select coalesce(sum(subtotal_reversed), 0), coalesce(sum(cost_reversed), 0), coalesce(sum(profit_reversed), 0)
  into v_returns, v_returns_cost, v_returns_profit
  from sales_returns
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
  from expenses
  where organization_id = org_id
    and (p_from is null or expense_date >= p_from)
    and (p_to is null or expense_date <= p_to);

  select coalesce(jsonb_agg(jsonb_build_object('name', name, 'amount', amount) order by amount desc), '[]'::jsonb)
  into v_by_category
  from (
    select coalesce(c.name, 'بدون تصنيف') as name, sum(e.amount) as amount
    from expenses e
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
$$;

create or replace function report_sales_breakdown(
  org_id uuid,
  p_from date,
  p_to date,
  p_group text,
  p_limit int default 100,
  p_offset int default 0
)
returns table (
  group_key text,
  group_label text,
  ref_date date,
  party text,
  invoices bigint,
  quantity numeric,
  gross_sales numeric,
  discounts numeric,
  returns numeric,
  net_sales numeric,
  cogs numeric,
  gross_profit numeric,
  commission numeric,
  total_count bigint
)
language plpgsql
stable
set search_path = public
as $$
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
      case when fin then coalesce(sum(x.profit - x.alloc - x.ret_profit), 0)::numeric end,
      null::numeric,
      count(*) over ()
    from (
      select it.id, it.product_id, it.sales_invoice_id, it.quantity, it.unit_price, it.discount,
             it.line_total, it.cost_total, it.profit,
             it.discount_alloc as alloc,
             coalesce(ra.ret_qty, 0) as ret_qty,
             coalesce(ra.ret_revenue, 0) as ret_revenue,
             coalesce(ra.ret_cost, 0) as ret_cost,
             coalesce(ra.ret_profit, 0) as ret_profit
      from sales_invoice_items it
      join sales_invoices i on i.id = it.sales_invoice_id
      left join (
        select sri.sales_invoice_item_id, sum(sri.quantity) as ret_qty, sum(sri.revenue_reversed) as ret_revenue,
               sum(sri.cost_reversed) as ret_cost, sum(sri.profit_reversed) as ret_profit
        from sales_return_items sri
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
    select i.*,
           coalesce((select sum(it.quantity) from sales_invoice_items it where it.sales_invoice_id = i.id), 0) as qty,
           coalesce((select sum(sri.quantity) from sales_return_items sri join sales_returns r on r.id = sri.sales_return_id where r.sales_invoice_id = i.id), 0) as ret_qty,
           coalesce((select sum(r.subtotal_reversed) from sales_returns r where r.sales_invoice_id = i.id), 0) as ret_total,
           coalesce((select sum(r.cost_reversed) from sales_returns r where r.sales_invoice_id = i.id), 0) as ret_cost,
           coalesce((select sum(r.profit_reversed) from sales_returns r where r.sales_invoice_id = i.id), 0) as ret_profit
    from sales_invoices i
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
      case when fin then coalesce(sum(i.commission_amount), 0)::numeric end as commission,
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
$$;

create or replace function dashboard_sales_rollups(org_id uuid, p_from date default null)
returns table (
  kind text,
  group_key text,
  group_label text,
  ref_date date,
  invoices bigint,
  net_sales numeric,
  gross_profit numeric
)
language plpgsql
stable
set search_path = public
as $$
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
    from sales_invoices i
    left join (
      select r.sales_invoice_id, sum(r.subtotal_reversed) as ret_total, sum(r.profit_reversed) as ret_profit
      from sales_returns r
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
$$;

-- ============================================================
-- 12. Balances: a cash refund moves the balance back
--     (customer got cash back for a credited return → credit consumed)
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
left join (
  select customer_id, sum(total) as total_sales
  from sales_invoices
  group by customer_id
) s on s.customer_id = c.id
left join (
  select customer_id, sum(amount) as total_collected
  from customer_collections
  group by customer_id
) col on col.customer_id = c.id
left join (
  select customer_id, sum(total) as total_returned, sum(cash_refunded) as total_refunded
  from sales_returns
  group by customer_id
) r on r.customer_id = c.id;

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
left join (
  select supplier_id, sum(total) as total_purchases
  from purchase_invoices
  group by supplier_id
) p on p.supplier_id = s.id
left join (
  select supplier_id, sum(amount) as total_paid
  from supplier_payments
  group by supplier_id
) pay on pay.supplier_id = s.id
left join (
  select supplier_id, sum(total) as total_returned, sum(cash_refunded) as total_refunded
  from purchase_returns
  group by supplier_id
) r on r.supplier_id = s.id;

-- ============================================================
-- 13. Party ledger — refunds are their own entry
-- ============================================================
create or replace function report_party_ledger(
  org_id uuid,
  p_type text,
  p_party uuid,
  p_from date default null,
  p_to date default null
)
returns table (
  entry_date date,
  entry_type text,
  reference text,
  description text,
  increase numeric,
  decrease numeric,
  balance numeric
)
language plpgsql
stable
set search_path = public
as $$
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
$$;

-- ============================================================
-- 14. Dashboard totals = the same numbers as report_summary
--     total_sales  = net sales (after discounts and returns, tax excluded)
--     total_profit = net profit (after returns, expenses and commissions)
-- ============================================================
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
-- 15. report_timeseries — returns are netted in the bucket they happen
-- ============================================================
create or replace function report_timeseries(org_id uuid, p_from date default null, p_to date default null, p_bucket text default 'day')
returns table (bucket date, net_sales numeric, gross_profit numeric, expenses numeric)
language plpgsql
stable
set search_path = public
as $$
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
    from sales_invoices i
    where i.organization_id = org_id
      and (p_from is null or i.invoice_date >= p_from)
      and (p_to is null or i.invoice_date <= p_to)
    group by 1
  ), rt as (
    select date_trunc(p_bucket, r.return_date::timestamp)::date as b,
           sum(r.subtotal_reversed) as rs,
           sum(r.profit_reversed) as rp
    from sales_returns r
    where r.organization_id = org_id
      and (p_from is null or r.return_date >= p_from)
      and (p_to is null or r.return_date <= p_to)
    group by 1
  ), e as (
    select date_trunc(p_bucket, x.expense_date::timestamp)::date as b,
           sum(x.amount) as ex
    from expenses x
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
$$;

-- ============================================================
-- 16. Returnable-items RPCs expose the net value and tax share so the
--     return form can preview exactly what the server will credit
-- ============================================================
drop function if exists get_returnable_items(uuid, uuid);
create function get_returnable_items(org_id uuid, p_sales_invoice_id uuid)
returns table (
  sales_invoice_item_id uuid,
  product_id uuid,
  product_name text,
  quantity numeric,
  already_returned numeric,
  returnable numeric,
  unit_price numeric,
  line_total numeric,
  net_line_total numeric,
  tax_alloc numeric
)
language plpgsql
stable
set search_path = public
as $fn$
begin
  if auth.uid() is null then
    raise exception 'يجب تسجيل الدخول أولاً';
  end if;
  if not is_org_member(org_id) then
    raise exception 'أنت لست عضوًا في هذه المؤسسة';
  end if;
  if not exists (select 1 from sales_invoices where id = p_sales_invoice_id and organization_id = org_id) then
    raise exception 'هذه الفاتورة لا تنتمي إلى هذه المؤسسة';
  end if;

  return query
  select
    it.id,
    it.product_id,
    p.name,
    it.quantity::numeric,
    coalesce(ret.qty, 0)::numeric,
    (it.quantity - coalesce(ret.qty, 0))::numeric,
    ((it.line_total - it.discount_alloc) / it.quantity)::numeric,
    it.line_total::numeric,
    (it.line_total - it.discount_alloc)::numeric,
    it.tax_alloc::numeric
  from sales_invoice_items it
  join products p on p.id = it.product_id
  left join (
    select sri.sales_invoice_item_id, sum(sri.quantity) as qty
    from sales_return_items sri
    group by sri.sales_invoice_item_id
  ) ret on ret.sales_invoice_item_id = it.id
  where it.sales_invoice_id = p_sales_invoice_id and it.organization_id = org_id
  order by p.name;
end;
$fn$;
revoke all on function get_returnable_items(uuid, uuid) from public, anon;
grant execute on function get_returnable_items(uuid, uuid) to authenticated;

drop function if exists get_returnable_purchase_items(uuid, uuid);
create function get_returnable_purchase_items(org_id uuid, p_purchase_invoice_id uuid)
returns table (
  purchase_invoice_item_id uuid,
  product_id uuid,
  product_name text,
  quantity numeric,
  already_returned numeric,
  returnable numeric,
  on_hand numeric,
  unit_cost numeric,
  line_total numeric,
  net_line_total numeric,
  tax_alloc numeric
)
language plpgsql
stable
set search_path = public
as $fn$
begin
  if auth.uid() is null then
    raise exception 'يجب تسجيل الدخول أولاً';
  end if;
  if not is_org_member(org_id) then
    raise exception 'أنت لست عضوًا في هذه المؤسسة';
  end if;
  if not exists (select 1 from purchase_invoices where id = p_purchase_invoice_id and organization_id = org_id) then
    raise exception 'هذه الفاتورة لا تنتمي إلى هذه المؤسسة';
  end if;

  return query
  select
    it.id,
    it.product_id,
    p.name,
    it.quantity::numeric,
    coalesce(ret.qty, 0)::numeric,
    (it.quantity - coalesce(ret.qty, 0))::numeric,
    coalesce(stk.quantity, 0)::numeric,
    ((it.line_total - it.discount_alloc) / it.quantity)::numeric,
    it.line_total::numeric,
    (it.line_total - it.discount_alloc)::numeric,
    it.tax_alloc::numeric
  from purchase_invoice_items it
  join products p on p.id = it.product_id
  join purchase_invoices pi on pi.id = it.purchase_invoice_id
  left join (
    select pri.purchase_invoice_item_id, sum(pri.quantity) as qty
    from purchase_return_items pri
    group by pri.purchase_invoice_item_id
  ) ret on ret.purchase_invoice_item_id = it.id
  left join inventory_stock stk on stk.product_id = it.product_id and stk.warehouse_id = pi.warehouse_id and stk.organization_id = org_id
  where it.purchase_invoice_id = p_purchase_invoice_id and it.organization_id = org_id
  order by p.name;
end;
$fn$;
revoke all on function get_returnable_purchase_items(uuid, uuid) from public, anon;
grant execute on function get_returnable_purchase_items(uuid, uuid) to authenticated;

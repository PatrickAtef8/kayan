-- Kayan — Reports package, Phase 4: sales reports (by rep, by channel, by product)
--
--   * report_sales_by(group = rep | channel | product | customer, date range, warehouse, rep, channel)
--       one function, one definition of "sold", so the three screens always agree.
--   * sales_invoices.sales_channel   wholesale | retail | social
--
-- Sales channel
--   A reporting label only — it does NOT change pricing, stock, costing or commission.
--   New invoices: chosen on the sales form (optional); when it is not given the database fills it
--   from the customer's price tier (retail → retail; wholesale / distributor → wholesale).
--   Existing invoices are NOT touched (no backfill UPDATE): while sales_channel is NULL the report
--   derives it from the customer's price tier, exactly as the trigger would have. "social" can only
--   come from an explicit choice, so historical invoices never appear under it.
--
-- Definitions (shared with the existing sales report, report_sales_breakdown)
--   * Period      = the INVOICE date. A return is netted against the invoice it came from, so it
--                   moves that invoice's revenue/units, not the period it was returned in.
--   * Revenue     = Σ (line_total − allocated_discount) − Σ revenue_reversed on returns
--                   (net of line discounts, invoice-level discounts and returns; tax excluded).
--   * Units       = billed (quantity of paid lines) + free units (bonus_quantity on a line, plus
--                   lines flagged is_bonus) − returned (all conditions, free units included —
--                   the system cannot tell which returned units were the free ones).
--   * Cartons     = Σ net units ÷ units_per_carton, over products that HAVE a carton size.
--                   Net units of products without one are reported separately as loose units —
--                   never guessed into cartons. A product's own row also splits into whole cartons
--                   + remainder units.
--   * No double counting: returns are summed per invoice ITEM first and joined 1:1 to that item;
--                   every total is summed at item level (never from invoice headers that repeat per
--                   item); invoices / customers / products are COUNT(DISTINCT …).
--   * Cancelled invoices: the system has no cancel/void for sales invoices (reversal is done with
--                   returns, which the report nets). There is nothing to exclude; if cancellation
--                   is ever added it must be excluded in `ln` below.
--   * Permissions: runs as the caller. Restricted reps only ever see their own customers' invoices
--                   (existing rep_scope row-level policies), so every figure is already scoped.
--                   No cost or profit is exposed.

-- ============================================================
-- 1. Sales channel
-- ============================================================
alter table sales_invoices add column if not exists sales_channel text;
alter table sales_invoices drop constraint if exists sales_invoices_sales_channel_chk;
alter table sales_invoices add constraint sales_invoices_sales_channel_chk
  check (sales_channel is null or sales_channel in ('wholesale', 'retail', 'social'));
grant select (sales_channel) on sales_invoices to authenticated;
create index if not exists sales_invoices_channel_idx on sales_invoices (organization_id, invoice_date, sales_channel);

create or replace function _default_sales_channel() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.sales_channel is null then
    select case c.price_tier when 'retail' then 'retail' else 'wholesale' end into new.sales_channel
    from customers c where c.id = new.customer_id;
  end if;
  return new;
end $$;
drop trigger if exists c_default_sales_channel on sales_invoices;
create trigger c_default_sales_channel before insert on sales_invoices
  for each row execute function _default_sales_channel();

-- ============================================================
-- 2. create_sales_invoice: optional p_sales_channel (last parameter, default NULL)
--    — the previous definition with only the marked lines added
-- ============================================================
drop function if exists create_sales_invoice(uuid, uuid, uuid, text, date, jsonb, numeric, numeric, numeric, text, text, uuid, numeric, jsonb);
CREATE OR REPLACE FUNCTION public.create_sales_invoice(org_id uuid, p_customer_id uuid, p_warehouse_id uuid, p_invoice_number text, p_invoice_date date, items jsonb, p_discount_pct numeric, p_tax_total numeric, p_amount_collected numeric, p_payment_method text, p_notes text, p_sales_rep_id uuid DEFAULT NULL::uuid, p_cash_discount_pct numeric DEFAULT 0, p_bonus_items jsonb DEFAULT '[]'::jsonb, p_sales_channel text DEFAULT NULL::text)
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
  v_product_id uuid; v_q numeric(14,3); v_price numeric(14,2); v_ldisc numeric(14,2); v_pct numeric;
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
  if is_restricted_rep(org_id) and not has_permission(org_id, 'sales.assign_any_rep') then
    v_rep := current_rep_id(org_id);
    -- an explicit request for a DIFFERENT rep is refused loudly (it used to be silently replaced by the caller's own rep)
    if p_sales_rep_id is not null and p_sales_rep_id is distinct from v_rep then
      raise exception 'يمكنك تسجيل الفواتير باسمك فقط — لا يمكنك تعيين مندوب آخر لهذه الفاتورة';
    end if;
    if v_cust_rep is distinct from v_rep then raise exception 'هذا العميل غير تابع لك'; end if;
  elsif v_rep is null then
    v_rep := v_cust_rep;
  end if;
  if v_rep is not null and not exists (select 1 from sales_representatives where id = v_rep and organization_id = org_id) then
    raise exception 'هذا المندوب لا ينتمي إلى هذه المؤسسة';
  end if;

  v_pr := _pricing(org_id, 'sales', items, p_discount_pct, p_cash_discount_pct, p_amount_collected, p_tax_total, p_bonus_items);
  v_bonus := v_pr->'bonus';
  v_gross := (v_pr->>'gross')::numeric;
  v_base_sum := (v_pr->>'base')::numeric;
  v_level := (v_pr->>'invoice_level_discount')::numeric;
  v_disc_total := (v_pr->>'discount_total')::numeric;
  v_net := (v_pr->>'net')::numeric;
  v_total := (v_pr->>'total')::numeric;
  v_n := jsonb_array_length(items);

  -- [channel] optional reporting label; NULL lets the database derive it from the customer's price tier
  p_sales_channel := nullif(btrim(coalesce(p_sales_channel, '')), '');
  if p_sales_channel is not null and p_sales_channel not in ('wholesale', 'retail', 'social') then
    raise exception 'قناة البيع غير صحيحة';
  end if;

  insert into sales_invoices (organization_id, customer_id, warehouse_id, invoice_number, invoice_date, notes, created_by, sales_rep_id, payment_method, sales_channel)
  values (org_id, p_customer_id, p_warehouse_id, nullif(p_invoice_number, ''), coalesce(p_invoice_date, current_date), nullif(p_notes, ''), auth.uid(), v_rep, nullif(p_payment_method, ''), p_sales_channel)
  returning id into new_invoice_id;

  for e in select * from jsonb_array_elements(items) loop
    v_idx := v_idx + 1;
    v_product_id := (e->>'product_id')::uuid;
    v_q := (e->>'quantity')::numeric;
    v_price := (e->>'unit_price')::numeric;
    v_pct := coalesce((e->>'discount_pct')::numeric, 0);
    v_ldisc := _line_discount(v_q, v_price, v_pct);

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

    insert into sales_invoice_items (organization_id, sales_invoice_id, product_id, quantity, unit_price, discount, discount_pct, line_total,
                                     bonus_quantity, allocated_discount, net_total, effective_unit_price)
    values (org_id, new_invoice_id, v_product_id, v_q, v_price, v_ldisc, v_pct, v_base_line,
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
      invoice_discount_pct = (v_pr->>'invoice_discount_pct')::numeric,
      cash_discount_pct = (v_pr->>'cash_discount_pct')::numeric,
      tier_discount_pct = (v_pr->>'tier_discount_pct')::numeric,
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
revoke all on function create_sales_invoice(uuid, uuid, uuid, text, date, jsonb, numeric, numeric, numeric, text, text, uuid, numeric, jsonb, text) from public, anon;
grant execute on function create_sales_invoice(uuid, uuid, uuid, text, date, jsonb, numeric, numeric, numeric, text, text, uuid, numeric, jsonb, text) to authenticated;

-- ============================================================
-- 3. report_sales_by
-- ============================================================
create or replace function report_sales_by(
  org_id uuid, p_group text,
  p_from date default null, p_to date default null,
  p_warehouse uuid default null, p_rep uuid default null, p_channel text default null,
  p_limit int default 200, p_offset int default 0
)
returns table (
  group_id text, group_label text,
  invoices bigint, customers bigint, products bigint,
  billed_qty numeric, bonus_qty numeric, returned_qty numeric, net_qty numeric,
  units_per_carton numeric, whole_cartons numeric, remainder_units numeric,   -- product rows only
  cartons numeric, loose_units numeric,
  gross_sales numeric, discounts numeric, returns_value numeric, net_revenue numeric,
  total_count bigint
)
language plpgsql stable set search_path = public as $$
declare
  v_limit int := least(greatest(coalesce(p_limit, 200), 1), 1000);
  v_off   int := greatest(coalesce(p_offset, 0), 0);
  v_chan  text := nullif(btrim(coalesce(p_channel, '')), '');
begin
  perform assert_report_access(org_id, false);
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
           coalesce(inv.sales_channel, case c.price_tier when 'retail' then 'retail' else 'wholesale' end) as chan,
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
end $$;

grant execute on function report_sales_by(uuid, text, date, date, uuid, uuid, text, int, int) to authenticated;

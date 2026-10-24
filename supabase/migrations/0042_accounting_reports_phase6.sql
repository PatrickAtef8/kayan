-- Kayan — Reports package, Phase 6: accounting reports
--
-- What ALREADY existed and is reused, not rebuilt:
--   * report_summary            — the accrual profit calculation (net sales − COGS − operating expenses − earned commissions)
--   * report_treasury_summary   — cash opening / in / out / closing and in/out by category
--   * rep_monthly_performance, invoice_commissions, rep_commission_balances — the commission model
--   * operating_expenses view, customer_balances / supplier_balances, treasury_balances
--
-- What this migration adds (every new figure is tested to reconcile with the above):
--   1. Return REASON   sales_return_items.return_reason  (+ create_sales_return accepts an optional "reason" per line)
--                      report_returns_by_reason
--   2. report_profit_loss        the profit & loss STATEMENT (period or by month) — accrual basis only
--   3. report_expenses           expenses classified by category / type / month
--   4. report_rep_payroll        per rep and month: base salary, sales commission, collection commission, payouts
--      report_rep_collections    the dates of the collections attributed to each rep
--   5. report_cash_reconciliation  treasury movements vs the documents that created them
--
-- Profit and cash are kept apart on purpose: nothing here mixes them. Profit (accrual) comes from invoices,
-- returns, expenses and EARNED commissions by their own dates; cash comes from treasury_movements.
-- Commission PAYOUTS are cash (an expense row of type commission_payout) and are NOT a second deduction in the
-- profit: the profit deducts the commission when it is earned, exactly as report_summary does.
--
-- Not invented (no such data exists in the system):
--   * employees other than sales reps (there is no employee table; 'salary' expenses must name a rep),
--   * a history of base-salary changes (sales_representatives holds only the CURRENT fixed salary/allowance),
--   * future collection due dates (customer invoices have no due date). The payroll report shows the
--     collection DATES that actually happened.
--   Returns recorded before this migration have no reason: they appear as "غير مصنّف", never guessed.

-- ============================================================
-- 1. Return reason
-- ============================================================
alter table sales_return_items add column if not exists return_reason text;
alter table sales_return_items drop constraint if exists sales_return_items_reason_chk;
alter table sales_return_items add constraint sales_return_items_reason_chk
  check (return_reason is null or return_reason in ('damaged', 'expired', 'slow_moving', 'other'));
grant select (return_reason) on sales_return_items to authenticated;

-- create_sales_return: the previous definition with only the marked lines added.
-- Each item may carry an optional "reason": damaged | expired | slow_moving | other. Nothing else changes
-- (stock, cost, refund, commission logic are untouched); a call without a reason behaves exactly as before.
CREATE OR REPLACE FUNCTION public.create_sales_return(org_id uuid, p_sales_invoice_id uuid, p_return_date date, items jsonb, p_cash_refund numeric DEFAULT 0, p_notes text DEFAULT NULL::text, p_full_return boolean DEFAULT false, p_condition text DEFAULT 'resalable'::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  new_return_id uuid; v_customer_id uuid; v_warehouse_id uuid; v_inv_rep uuid; account_id uuid;
  item jsonb; v_items jsonb;
  v_item_id uuid; v_quantity numeric(14,3); v_condition text; v_orig record; v_reason text;
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
    -- [reason] optional: why the goods came back (damaged | expired | slow_moving | other)
    v_reason := nullif(btrim(coalesce(item->>'reason', '')), '');
    if v_reason is not null and v_reason not in ('damaged', 'expired', 'slow_moving', 'other') then raise exception 'سبب المرتجع غير صحيح'; end if;
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
        select s.quantity, coalesce(sc.avg_cost, 0) into v_old_qty, v_old_avg
        from inventory_stock s left join stock_costs sc on sc.stock_id = s.id
        where s.product_id = v_orig.product_id and s.warehouse_id = v_warehouse_id for update of s;
        if not found then
          v_old_qty := 0; v_old_avg := 0;
          insert into inventory_stock (organization_id, product_id, warehouse_id, quantity) values (org_id, v_orig.product_id, v_warehouse_id, 0);
        end if;
        perform set_config('kayan.batch_return', p_sales_invoice_id::text, true);   -- [batches] back to the batches it was sold from
        update inventory_stock
        set quantity = v_old_qty + v_quantity, updated_at = now()
        where product_id = v_orig.product_id and warehouse_id = v_warehouse_id;
        perform set_config('kayan.batch_return', '', true);
        insert into stock_costs (stock_id, avg_cost)
        select id, case when (v_old_qty + v_quantity) > 0
                        then ((greatest(v_old_qty, 0) * v_old_avg) + v_cost) / (greatest(v_old_qty, 0) + v_quantity) else v_old_avg end
        from inventory_stock where product_id = v_orig.product_id and warehouse_id = v_warehouse_id
        on conflict (stock_id) do update set avg_cost = excluded.avg_cost, updated_at = now();
        insert into inventory_movements (organization_id, product_id, warehouse_id, movement_type, quantity_delta, unit_cost, reference_type, reference_id, created_by)
        values (org_id, v_orig.product_id, v_warehouse_id, 'sale_return', v_quantity, v_cost / v_quantity, 'sales_return', new_return_id, auth.uid());
      end if;
    end if;

    insert into sales_return_items (organization_id, sales_return_id, sales_invoice_item_id, product_id, quantity, condition, unit_price, revenue_reversed, tax_reversed, return_reason)
    values (org_id, new_return_id, v_item_id, v_orig.product_id, v_quantity, v_condition, v_orig.effective_unit_price, v_revenue, v_tax, v_reason)
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
-- 2. Returns by reason
-- ============================================================
-- Period = the RETURN date (a returns report shows when goods came back). Value = revenue reversed (before tax),
-- the same figure the sales returns documents store (subtotal_reversed), so Σ value = Σ returns in the period.
create or replace function report_returns_by_reason(
  org_id uuid, p_from date default null, p_to date default null,
  p_group text default 'reason', p_reason text default null,
  p_warehouse uuid default null, p_rep uuid default null,
  p_limit int default 500, p_offset int default 0
)
returns table (
  group_id text, group_label text,
  returns bigint, lines bigint, customers bigint,
  units numeric, resalable_units numeric, damaged_units numeric,
  value numeric, share_pct numeric, total_count bigint
)
language plpgsql stable set search_path = public as $$
declare
  v_limit int := least(greatest(coalesce(p_limit, 500), 1), 1000);
  v_off   int := greatest(coalesce(p_offset, 0), 0);
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  perform assert_report_access(org_id, false);
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
end $$;
grant execute on function report_returns_by_reason(uuid, date, date, text, text, uuid, uuid, int, int) to authenticated;

-- ============================================================
-- 3. Profit & loss statement (accrual basis)
-- ============================================================
-- Same sources and formulas as report_summary (tested equal for any period):
--   net sales        = Σ subtotal − Σ discounts − Σ returns reversed
--   cost of goods    = Σ cogs of invoices − Σ cost of returned (resalable) goods   [damaged returns recover no cost — existing rule]
--   gross profit     = net sales − cost of goods
--   operating exp.   = expenses except commission payouts (view operating_expenses; includes recorded salaries and rep expenses)
--   commissions      = commissions EARNED on the period's invoices (rep targets applied), not what was paid
--   net profit       = gross profit − operating expenses − commissions
-- Each line uses its own document date (invoice / return / expense date). With p_by_month the periods are calendar months
-- and the last row is the total of the whole range.
create or replace function report_profit_loss(org_id uuid, p_from date default null, p_to date default null, p_by_month boolean default false)
returns table (
  period_start date, is_total boolean,
  gross_sales numeric, discounts numeric, returns_value numeric, net_sales numeric,
  cogs numeric, gross_profit numeric, operating_expenses numeric, commissions numeric, net_profit numeric
)
language plpgsql stable set search_path = public as $$
begin
  perform assert_report_access(org_id, true);
  return query
  with s as (
    select date_trunc('month', v.invoice_date)::date as m, sum(v.subtotal) as gs, sum(v.discount_total) as dc, sum(v.cogs_total) as cg
    from v_sales_invoices v
    where v.organization_id = org_id and (p_from is null or v.invoice_date >= p_from) and (p_to is null or v.invoice_date <= p_to)
    group by 1
  ),
  r as (
    select date_trunc('month', v.return_date)::date as m, sum(v.subtotal_reversed) as rv, sum(v.cost_reversed) as rc
    from v_sales_returns v
    where v.organization_id = org_id and (p_from is null or v.return_date >= p_from) and (p_to is null or v.return_date <= p_to)
    group by 1
  ),
  e as (
    select date_trunc('month', x.expense_date)::date as m, sum(x.amount) as ex
    from operating_expenses x
    where x.organization_id = org_id and (p_from is null or x.expense_date >= p_from) and (p_to is null or x.expense_date <= p_to)
    group by 1
  ),
  c as (
    select date_trunc('month', ic.invoice_date)::date as m, sum(ic.earned_commission) as cm
    from invoice_commissions ic
    where ic.organization_id = org_id and (p_from is null or ic.invoice_date >= p_from) and (p_to is null or ic.invoice_date <= p_to)
    group by 1
  ),
  months as (select s.m from s union select r.m from r union select e.m from e union select c.m from c),
  per as (
    select mo.m,
           coalesce(s.gs, 0) as gs, coalesce(s.dc, 0) as dc, coalesce(r.rv, 0) as rv,
           coalesce(s.cg, 0) - coalesce(r.rc, 0) as cg, coalesce(e.ex, 0) as ex, coalesce(c.cm, 0) as cm
    from months mo left join s on s.m = mo.m left join r on r.m = mo.m left join e on e.m = mo.m left join c on c.m = mo.m
  ),
  tot as (
    select null::date as m, coalesce(sum(per.gs), 0) as gs, coalesce(sum(per.dc), 0) as dc, coalesce(sum(per.rv), 0) as rv,
           coalesce(sum(per.cg), 0) as cg, coalesce(sum(per.ex), 0) as ex, coalesce(sum(per.cm), 0) as cm
    from per
  ),
  lines as (
    select per.m, false as is_t, per.gs, per.dc, per.rv, per.cg, per.ex, per.cm from per where p_by_month
    union all
    select tot.m, true, tot.gs, tot.dc, tot.rv, tot.cg, tot.ex, tot.cm from tot
  )
  select q.m, q.is_t, q.gs::numeric, q.dc::numeric, q.rv::numeric, (q.gs - q.dc - q.rv)::numeric,
         q.cg::numeric, (q.gs - q.dc - q.rv - q.cg)::numeric, q.ex::numeric, q.cm::numeric,
         (q.gs - q.dc - q.rv - q.cg - q.ex - q.cm)::numeric
  from lines q
  order by q.is_t, q.m;
end $$;
grant execute on function report_profit_loss(uuid, date, date, boolean) to authenticated;

-- ============================================================
-- 4. Expenses classified
-- ============================================================
-- Every recorded expense, grouped by category (expense_categories), by type, or by month.
-- in_profit_loss is the part that is an operating expense in the profit & loss; commission payouts are listed
-- (they are real cash out) but are NOT in that column — the commission was already deducted when it was earned.
create or replace function report_expenses(org_id uuid, p_from date default null, p_to date default null, p_group text default 'category')
returns table (group_id text, group_label text, expense_count bigint, total numeric, in_profit_loss numeric)
language plpgsql stable set search_path = public as $$
begin
  perform assert_report_access(org_id, true);
  if p_group is null or p_group not in ('category', 'type', 'month') then raise exception 'نوع التقرير غير صحيح'; end if;
  return query
  select t.k, t.lbl, count(*), sum(t.amt)::numeric,
         coalesce(sum(t.amt) filter (where t.etype <> 'commission_payout'), 0)::numeric
  from (
    select (case p_group when 'category' then coalesce(x.category_id::text, 'none') when 'type' then x.expense_type
                         else to_char(date_trunc('month', x.expense_date), 'YYYY-MM') end) as k,
           (case p_group when 'category' then coalesce(c.name, 'بدون تصنيف') when 'type' then x.expense_type
                         else to_char(date_trunc('month', x.expense_date), 'YYYY-MM') end) as lbl,
           x.amount as amt, x.expense_type as etype
    from expenses x
    left join expense_categories c on c.id = x.category_id
    where x.organization_id = org_id and (p_from is null or x.expense_date >= p_from) and (p_to is null or x.expense_date <= p_to)
  ) t
  group by t.k, t.lbl
  order by (case when p_group = 'month' then 0 else 1 end), (case when p_group = 'month' then null else sum(t.amt) end) desc nulls last, t.lbl;
end $$;
grant execute on function report_expenses(uuid, date, date, text) to authenticated;

-- ============================================================
-- 5. Rep payroll (per rep and month)
-- ============================================================
-- Base salary / transport allowance: the rep's CURRENT terms (there is no salary history to read).
-- Salary paid / commission paid / rep expenses: what was actually recorded as expenses in the month.
-- Commissions use the existing model: each invoice stores the rep's basis and rate AT THAT TIME and its
-- commission_amount; the monthly target decides eligibility (rep_monthly_performance). Split by that stored basis:
--   collection commission = invoices whose basis is 'collected_amount' (earned on cash collected)
--   sales commission      = every other basis (sales value / net sales / gross profit)
-- sales_commission + collection_commission = rep_monthly_performance.earned_commission (tested).
-- The commission belongs to the INVOICE month; collections that arrive later raise it (existing recompute rule).
-- commission_payable = cumulative earned − cumulative paid (rep_commission_balances, all months).
create or replace function report_rep_payroll(org_id uuid, p_month date default null)
returns table (
  rep_id uuid, rep_name text, is_active boolean,
  fixed_salary numeric, transportation_allowance numeric, commission_basis text, commission_rate numeric,
  invoices bigint, net_sales numeric, commission_eligible boolean,
  sales_commission numeric, collection_commission numeric, earned_commission numeric,
  salary_paid numeric, commission_paid numeric, rep_expenses_paid numeric,
  collections_count bigint, collected_amount numeric, first_collection_date date, last_collection_date date,
  commission_payable numeric
)
language plpgsql stable set search_path = public as $$
declare
  v_m   date := date_trunc('month', coalesce(p_month, cairo_today()))::date;
  v_end date := (date_trunc('month', coalesce(p_month, cairo_today())) + interval '1 month - 1 day')::date;
begin
  perform assert_report_access(org_id, true);
  return query
  with perf as (select * from rep_monthly_performance pm where pm.organization_id = org_id and pm.month = v_m),
  inv as (
    select i.sales_rep_id as rid,
           coalesce(sum(i.commission_amount) filter (where coalesce(i.commission_basis_snapshot, '') <> 'collected_amount'), 0) as pot_sales,
           coalesce(sum(i.commission_amount) filter (where i.commission_basis_snapshot = 'collected_amount'), 0) as pot_coll
    from sales_invoices i
    where i.organization_id = org_id and i.sales_rep_id is not null and i.invoice_date between v_m and v_end
    group by i.sales_rep_id
  ),
  pay as (
    select x.sales_rep_id as rid,
           coalesce(sum(x.amount) filter (where x.expense_type = 'salary'), 0) as sal,
           coalesce(sum(x.amount) filter (where x.expense_type = 'commission_payout'), 0) as cp,
           coalesce(sum(x.amount) filter (where x.expense_type = 'rep_expense'), 0) as re
    from expenses x
    where x.organization_id = org_id and x.sales_rep_id is not null and x.expense_date between v_m and v_end
    group by x.sales_rep_id
  ),
  col as (   -- same attribution as rep_monthly_performance: the invoice's rep, else the customer's rep
    select coalesce(i.sales_rep_id, cu.sales_rep_id) as rid, count(*) as n, sum(c.amount) as amt, min(c.collection_date) as d1, max(c.collection_date) as d2
    from customer_collections c
    left join sales_invoices i on i.id = c.sales_invoice_id
    join customers cu on cu.id = c.customer_id
    where c.organization_id = org_id and c.collection_date between v_m and v_end and coalesce(i.sales_rep_id, cu.sales_rep_id) is not null
    group by 1
  )
  select sr.id, sr.name, sr.is_active,
         sr.fixed_salary::numeric, sr.transportation_allowance::numeric, sr.commission_basis, sr.commission_rate::numeric,
         coalesce(perf.invoices, 0)::bigint, coalesce(perf.net_sales, 0)::numeric,
         coalesce(perf.commission_eligible, sr.min_target_for_commission <= 0),
         (case when coalesce(perf.commission_eligible, sr.min_target_for_commission <= 0) then coalesce(inv.pot_sales, 0) else 0 end)::numeric,
         (case when coalesce(perf.commission_eligible, sr.min_target_for_commission <= 0) then coalesce(inv.pot_coll, 0) else 0 end)::numeric,
         coalesce(perf.earned_commission, 0)::numeric,
         coalesce(pay.sal, 0)::numeric, coalesce(pay.cp, 0)::numeric, coalesce(pay.re, 0)::numeric,
         coalesce(col.n, 0)::bigint, coalesce(col.amt, 0)::numeric, col.d1, col.d2,
         coalesce(cb.payable, 0)::numeric
  from sales_representatives sr
  left join perf on perf.rep_id = sr.id
  left join inv on inv.rid = sr.id
  left join pay on pay.rid = sr.id
  left join col on col.rid = sr.id
  left join rep_commission_balances cb on cb.rep_id = sr.id and cb.organization_id = org_id
  where sr.organization_id = org_id and (sr.is_active or perf.rep_id is not null or pay.rid is not null or col.rid is not null)
  order by sr.name;
end $$;
grant execute on function report_rep_payroll(uuid, date) to authenticated;

-- The dates of the collections attributed to each rep (the "collection schedule" as it actually happened).
-- counts_for_commission: the collection is linked to an invoice whose commission basis is collected_amount.
create or replace function report_rep_collections(org_id uuid, p_from date default null, p_to date default null, p_rep uuid default null,
                                                  p_limit int default 500, p_offset int default 0)
returns table (
  collection_id uuid, collection_date date, rep_id uuid, rep_name text, customer_id uuid, customer_name text,
  amount numeric, payment_method text, reference text, invoice_number text,
  commission_basis text, counts_for_commission boolean, total_count bigint, total_amount numeric
)
language plpgsql stable set search_path = public as $$
declare
  v_limit int := least(greatest(coalesce(p_limit, 500), 1), 2000);
  v_off   int := greatest(coalesce(p_offset, 0), 0);
begin
  perform assert_report_access(org_id, true);
  return query
  select c.id, c.collection_date, sr.id, sr.name, cu.id, cu.name,
         c.amount::numeric, c.payment_method, c.reference, i.invoice_number,
         i.commission_basis_snapshot, (i.commission_basis_snapshot = 'collected_amount'),
         count(*) over (), (sum(c.amount) over ())::numeric
  from customer_collections c
  left join sales_invoices i on i.id = c.sales_invoice_id
  join customers cu on cu.id = c.customer_id
  join sales_representatives sr on sr.id = coalesce(i.sales_rep_id, cu.sales_rep_id)
  where c.organization_id = org_id
    and (p_from is null or c.collection_date >= p_from) and (p_to is null or c.collection_date <= p_to)
    and (p_rep is null or sr.id = p_rep)
  order by c.collection_date desc, sr.name, c.created_at desc, c.id
  limit v_limit offset v_off;
end $$;
grant execute on function report_rep_collections(uuid, date, date, uuid, int, int) to authenticated;

-- ============================================================
-- 6. Treasury vs source documents
-- ============================================================
-- Every collection, supplier payment, expense, partner withdrawal and cash refund posts a treasury movement
-- through its own function. This puts each movement total next to the documents that should have created it;
-- a non-zero difference means a movement or a document was created outside those functions.
-- (Manual treasury movements have no source document and are not part of this check.)
-- Date of both sides = the document's own date, which is also the movement date.
create or replace function report_cash_reconciliation(org_id uuid, p_from date default null, p_to date default null)
returns table (check_key text, check_label text, treasury_amount numeric, source_amount numeric, difference numeric)
language plpgsql stable set search_path = public as $$
begin
  perform assert_report_access(org_id, true);
  return query
  with t as (
    select m.category, m.direction, sum(m.amount) as s from treasury_movements m
    where m.organization_id = org_id and (p_from is null or m.movement_date >= p_from) and (p_to is null or m.movement_date <= p_to)
    group by m.category, m.direction
  ),
  chk as (
    select 1 as ord, 'customer_receipts'::text as k, 'تحصيلات العملاء (شاملة المقبوض وقت الفاتورة)'::text as l,
           coalesce((select sum(t.s) from t where t.direction = 'in' and t.category in ('customer_collection', 'sales_cash')), 0) as ta,
           coalesce((select sum(c.amount) from customer_collections c where c.organization_id = org_id and (p_from is null or c.collection_date >= p_from) and (p_to is null or c.collection_date <= p_to)), 0) as sa
    union all
    select 2, 'supplier_payments', 'مدفوعات الموردين',
           coalesce((select sum(t.s) from t where t.direction = 'out' and t.category = 'supplier_payment'), 0),
           coalesce((select sum(p.amount) from supplier_payments p where p.organization_id = org_id and (p_from is null or p.payment_date >= p_from) and (p_to is null or p.payment_date <= p_to)), 0)
    union all
    select 3, 'expenses', 'المصروفات (شاملة مدفوعات العمولات والمرتبات)',
           coalesce((select sum(t.s) from t where t.direction = 'out' and t.category = 'expense'), 0),
           coalesce((select sum(x.amount) from expenses x where x.organization_id = org_id and (p_from is null or x.expense_date >= p_from) and (p_to is null or x.expense_date <= p_to)), 0)
    union all
    select 4, 'partner_withdrawals', 'مسحوبات الشركاء',
           coalesce((select sum(t.s) from t where t.direction = 'out' and t.category = 'partner_withdrawal'), 0),
           coalesce((select sum(w.amount) from partner_withdrawals w where w.organization_id = org_id and (p_from is null or w.withdrawal_date >= p_from) and (p_to is null or w.withdrawal_date <= p_to)), 0)
    union all
    select 5, 'customer_refunds', 'مبالغ رُدّت نقدًا للعملاء',
           coalesce((select sum(t.s) from t where t.direction = 'out' and t.category = 'sales_return'), 0),
           coalesce((select sum(r.cash_refunded) from sales_returns r where r.organization_id = org_id and (p_from is null or r.return_date >= p_from) and (p_to is null or r.return_date <= p_to)), 0)
    union all
    select 6, 'supplier_refunds', 'مبالغ استُردّت نقدًا من الموردين',
           coalesce((select sum(t.s) from t where t.direction = 'in' and t.category = 'purchase_return'), 0),
           coalesce((select sum(r.cash_refunded) from purchase_returns r where r.organization_id = org_id and (p_from is null or r.return_date >= p_from) and (p_to is null or r.return_date <= p_to)), 0)
  )
  select chk.k, chk.l, chk.ta::numeric, chk.sa::numeric, (chk.ta - chk.sa)::numeric from chk order by chk.ord;
end $$;
grant execute on function report_cash_reconciliation(uuid, date, date) to authenticated;

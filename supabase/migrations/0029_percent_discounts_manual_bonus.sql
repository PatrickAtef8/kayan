-- ============================================================
-- 0029 — Percentage discounts, "immediate payment" discount, manual bonus
--
--  1. EVERY discount is a percentage (line, invoice, immediate-payment, tier).
--     The EGP amounts stored on invoices are computed from the percentages,
--     so reports and balances keep working on money columns as before.
--  2. The "cash" discount means PAYING NOW: it applies when an amount is paid
--     / collected on the invoice itself, whatever the payment method.
--  3. Bonus is never automatic. The user lists the bonus items by hand on the
--     invoice (product + quantity). A bonus of a product that is also a paid
--     line is folded into that line (lower effective price, as before); any
--     other product becomes its own zero-value line. bonus_rules are no longer
--     read by anything (the table is kept, untouched).
--
--  How the percentages combine: line discount % comes off each line first;
--  then invoice % + immediate-payment % + tier % are each taken from that
--  same base (they add up, they do not compound) and must total ≤ 100%.
-- ============================================================

-- ---------- 0. Prerequisite check ----------
do $$
begin
  if not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'sales_return_items' and column_name = 'tax_reversed')
     or not exists (select 1 from pg_proc where proname = 'allocate_invoice_tax') then
    raise exception '0029 cannot run yet: migration 0028_calculation_fixes is not applied on this database. Apply 0028 first, then run 0029 again. Nothing was changed.';
  end if;
end $$;

-- ---------- 1. Columns ----------
alter table sales_invoices         add column if not exists invoice_discount_pct numeric(5,2) not null default 0,
                                   add column if not exists cash_discount_pct    numeric(5,2) not null default 0,
                                   add column if not exists tier_discount_pct    numeric(5,2) not null default 0;
alter table purchase_invoices      add column if not exists invoice_discount_pct numeric(5,2) not null default 0,
                                   add column if not exists cash_discount_pct    numeric(5,2) not null default 0,
                                   add column if not exists tier_discount_pct    numeric(5,2) not null default 0;
alter table sales_invoice_items    add column if not exists discount_pct numeric(5,2) not null default 0;
alter table purchase_invoice_items add column if not exists discount_pct numeric(5,2) not null default 0;

-- Tiers: the discount is now a percentage. Existing EGP tiers are converted to the
-- percentage they represent AT their threshold (e.g. "1,000 → 50 EGP" becomes 5%).
-- Review them in Settings → Discounts.
alter table discount_tiers add column if not exists discount_pct numeric(5,2);
update discount_tiers
set discount_pct = least(greatest(round(discount_amount / min_amount * 100, 2), 0.01), 100)
where discount_pct is null and discount_amount is not null;
alter table discount_tiers alter column discount_amount drop not null;
do $$
declare c text;
begin
  for c in select conname from pg_constraint
           where conrelid = 'discount_tiers'::regclass and contype = 'c' and pg_get_constraintdef(oid) ilike '%discount_amount%'
  loop
    execute format('alter table discount_tiers drop constraint %I', c);
  end loop;
end $$;
alter table discount_tiers alter column discount_pct set not null;
alter table discount_tiers drop constraint if exists discount_tiers_discount_pct_check;
alter table discount_tiers add constraint discount_tiers_discount_pct_check check (discount_pct > 0 and discount_pct <= 100);

-- ---------- 2. Helper ----------
create or replace function _line_discount(p_qty numeric, p_price numeric, p_pct numeric)
returns numeric
language sql
immutable
as $$
  select round(round(p_qty * p_price, 2) * coalesce(p_pct, 0) / 100, 2);
$$;

-- ---------- 3. The pricing engine ----------
drop function if exists _pricing(uuid, text, jsonb, numeric, numeric, text, numeric, numeric);
drop function if exists pricing_preview(uuid, text, jsonb, numeric, numeric, text, numeric, numeric);

create or replace function _pricing(
  org_id uuid, p_applies text, items jsonb,
  p_invoice_discount_pct numeric, p_cash_discount_pct numeric,
  p_amount_paid numeric, p_tax numeric,
  p_bonus_items jsonb default '[]'::jsonb
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  e jsonb; b jsonb;
  v_q numeric; v_p numeric; v_pct numeric;
  v_gross numeric(14,2) := 0;
  v_line_disc numeric(14,2) := 0;
  v_base numeric(14,2);
  v_inv_pct numeric := coalesce(p_invoice_discount_pct, 0);
  v_cash_pct numeric := 0;
  v_tier_pct numeric := 0;
  v_inv numeric(14,2); v_cash numeric(14,2); v_tier numeric(14,2);
  v_level numeric(14,2); v_diff numeric(14,2);
  v_pids uuid[] := '{}';
  v_bp uuid; v_bq numeric;
  v_bonus jsonb := '[]'::jsonb;
  v_disc numeric(14,2);
  v_net numeric(14,2);
begin
  if p_applies not in ('sales', 'purchases') then raise exception 'نوع العملية غير مدعوم'; end if;
  if v_inv_pct < 0 or v_inv_pct > 100 then raise exception 'نسبة الخصم يجب أن تكون بين 0 و 100'; end if;
  if coalesce(p_cash_discount_pct, 0) < 0 or coalesce(p_cash_discount_pct, 0) > 100 then raise exception 'نسبة خصم الدفع الفوري يجب أن تكون بين 0 و 100'; end if;
  if coalesce(p_tax, 0) < 0 then raise exception 'الضريبة لا يمكن أن تكون سالبة'; end if;
  if coalesce(p_amount_paid, 0) < 0 then raise exception 'المبلغ لا يمكن أن يكون سالبًا'; end if;
  if items is null or jsonb_array_length(items) = 0 then
    raise exception 'يجب إضافة صنف واحد على الأقل للفاتورة';
  end if;

  for e in select * from jsonb_array_elements(items) loop
    v_q := (e->>'quantity')::numeric;
    v_p := case p_applies when 'sales' then (e->>'unit_price')::numeric else (e->>'unit_cost')::numeric end;
    if coalesce((e->>'discount')::numeric, 0) <> 0 then
      raise exception 'الخصم يجب أن يكون نسبة مئوية (discount_pct) وليس مبلغًا';
    end if;
    v_pct := coalesce((e->>'discount_pct')::numeric, 0);
    if v_q is null or v_q <= 0 then raise exception 'يجب أن تكون الكمية أكبر من صفر'; end if;
    if v_p is null or v_p < 0 then raise exception 'السعر غير صحيح'; end if;
    if v_pct < 0 or v_pct > 100 then raise exception 'نسبة خصم الصنف يجب أن تكون بين 0 و 100'; end if;
    v_gross := v_gross + round(v_q * v_p, 2);
    v_line_disc := v_line_disc + _line_discount(v_q, v_p, v_pct);
    v_pids := v_pids || (e->>'product_id')::uuid;
  end loop;
  v_base := v_gross - v_line_disc;

  -- tier: the highest reached threshold wins (tiers do not stack); its % comes off the base
  select t.discount_pct into v_tier_pct
  from discount_tiers t
  where t.organization_id = org_id and t.applies_to = p_applies and t.is_active and t.min_amount <= v_base
  order by t.min_amount desc limit 1;
  v_tier_pct := coalesce(v_tier_pct, 0);

  -- immediate-payment discount: applies when something is paid on the invoice itself
  if coalesce(p_amount_paid, 0) > 0 then
    v_cash_pct := coalesce(p_cash_discount_pct, 0);
  end if;

  if v_inv_pct + v_cash_pct + v_tier_pct > 100 then
    raise exception 'إجمالي نسب الخصم أكبر من 100%%';
  end if;
  v_inv  := round(v_base * v_inv_pct / 100, 2);
  v_cash := round(v_base * v_cash_pct / 100, 2);
  v_tier := round(v_base * v_tier_pct / 100, 2);
  -- the pieces must add up to the combined % exactly (a cent of rounding goes to the first non-zero piece)
  v_level := round(v_base * (v_inv_pct + v_cash_pct + v_tier_pct) / 100, 2);
  v_diff := v_level - (v_inv + v_cash + v_tier);
  if v_diff <> 0 then
    if v_inv <> 0 then v_inv := v_inv + v_diff;
    elsif v_cash <> 0 then v_cash := v_cash + v_diff;
    else v_tier := v_tier + v_diff; end if;
  end if;

  -- manual bonus: exactly what the user listed, nothing computed
  if p_bonus_items is not null and jsonb_typeof(p_bonus_items) not in ('array', 'null') then
    raise exception 'صيغة الـBonus غير صحيحة';
  end if;
  if p_bonus_items is not null and jsonb_typeof(p_bonus_items) = 'array' then
    for b in select * from jsonb_array_elements(p_bonus_items) loop
      v_bp := nullif(b->>'product_id', '')::uuid;
      continue when v_bp is null;
      v_bq := (b->>'quantity')::numeric;
      if v_bq is null or v_bq <= 0 then raise exception 'كمية الـBonus يجب أن تكون أكبر من صفر'; end if;
      if not exists (select 1 from products where id = v_bp and organization_id = org_id) then
        raise exception 'أحد المنتجات المختارة لا ينتمي إلى هذه المؤسسة';
      end if;
      v_bonus := v_bonus || jsonb_build_object(
        'trigger', case when v_bp = any (v_pids) then v_bp else '00000000-0000-0000-0000-000000000000'::uuid end,
        'product', v_bp, 'qty', v_bq);
    end loop;
  end if;

  v_disc := v_line_disc + v_level;
  v_net := v_gross - v_disc;
  if coalesce(p_tax, 0) > 0 and v_net <= 0 then raise exception 'لا يمكن إضافة ضريبة على فاتورة قيمتها صفر'; end if;
  return jsonb_build_object(
    'gross', v_gross, 'line_discount', v_line_disc, 'base', v_base,
    'tier_discount', v_tier, 'invoice_discount', v_inv, 'cash_discount', v_cash,
    'tier_discount_pct', v_tier_pct, 'invoice_discount_pct', v_inv_pct, 'cash_discount_pct', v_cash_pct,
    'invoice_level_discount', v_level,
    'discount_total', v_disc, 'net', v_net,
    'tax', coalesce(p_tax, 0), 'total', v_net + coalesce(p_tax, 0),
    'bonus', v_bonus
  );
end $$;
revoke all on function _pricing(uuid, text, jsonb, numeric, numeric, numeric, numeric, jsonb) from public, anon, authenticated;

create or replace function pricing_preview(
  org_id uuid, p_applies text, items jsonb,
  p_invoice_discount_pct numeric default 0, p_cash_discount_pct numeric default 0,
  p_amount_paid numeric default 0, p_tax numeric default 0,
  p_bonus_items jsonb default '[]'::jsonb
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'يجب تسجيل الدخول أولاً'; end if;
  if not is_org_member(org_id) then raise exception 'أنت لست عضوًا في هذه المؤسسة'; end if;
  return _pricing(org_id, p_applies, items, p_invoice_discount_pct, p_cash_discount_pct, p_amount_paid, p_tax, p_bonus_items);
end $$;
revoke all on function pricing_preview(uuid, text, jsonb, numeric, numeric, numeric, numeric, jsonb) from public, anon;
grant execute on function pricing_preview(uuid, text, jsonb, numeric, numeric, numeric, numeric, jsonb) to authenticated;

-- ============================================================
-- 4. create_sales_invoice — % discounts, immediate-payment discount, manual bonus
-- ============================================================
drop function if exists create_sales_invoice(uuid, uuid, uuid, text, date, jsonb, numeric, numeric, numeric, text, text, uuid, numeric);
CREATE OR REPLACE FUNCTION public.create_sales_invoice(org_id uuid, p_customer_id uuid, p_warehouse_id uuid, p_invoice_number text, p_invoice_date date, items jsonb, p_discount_pct numeric, p_tax_total numeric, p_amount_collected numeric, p_payment_method text, p_notes text, p_sales_rep_id uuid DEFAULT NULL::uuid, p_cash_discount_pct numeric DEFAULT 0, p_bonus_items jsonb DEFAULT '[]'::jsonb)
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
  if is_restricted_rep(org_id) then
    v_rep := current_rep_id(org_id);
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

  insert into sales_invoices (organization_id, customer_id, warehouse_id, invoice_number, invoice_date, notes, created_by, sales_rep_id, payment_method)
  values (org_id, p_customer_id, p_warehouse_id, nullif(p_invoice_number, ''), coalesce(p_invoice_date, current_date), nullif(p_notes, ''), auth.uid(), v_rep, nullif(p_payment_method, ''))
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
revoke all on function create_sales_invoice(uuid, uuid, uuid, text, date, jsonb, numeric, numeric, numeric, text, text, uuid, numeric, jsonb) from public, anon;
grant execute on function create_sales_invoice(uuid, uuid, uuid, text, date, jsonb, numeric, numeric, numeric, text, text, uuid, numeric, jsonb) to authenticated;

-- ============================================================
-- 5. create_purchase_invoice — % discounts, immediate-payment discount, manual bonus
-- ============================================================
drop function if exists create_purchase_invoice(uuid, uuid, uuid, text, date, jsonb, numeric, numeric, numeric, text, text, numeric);
CREATE OR REPLACE FUNCTION public.create_purchase_invoice(org_id uuid, p_supplier_id uuid, p_warehouse_id uuid, p_invoice_number text, p_invoice_date date, items jsonb, p_discount_pct numeric, p_tax_total numeric, p_amount_paid numeric, p_payment_method text, p_notes text, p_cash_discount_pct numeric DEFAULT 0, p_bonus_items jsonb DEFAULT '[]'::jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  new_invoice_id uuid; account_id uuid;
  e jsonb; b record; v_pr jsonb; v_bonus jsonb;
  v_product_id uuid; v_q numeric(14,3); v_cost numeric(14,2); v_ldisc numeric(14,2); v_pct numeric;
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

  v_pr := _pricing(org_id, 'purchases', items, p_discount_pct, p_cash_discount_pct, p_amount_paid, p_tax_total, p_bonus_items);
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
    v_pct := coalesce((e->>'discount_pct')::numeric, 0);
    v_ldisc := _line_discount(v_q, v_cost, v_pct);
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

    insert into purchase_invoice_items (organization_id, purchase_invoice_id, product_id, quantity, unit_cost, discount, discount_pct, line_total,
                                        bonus_quantity, allocated_discount, net_total, effective_unit_cost)
    values (org_id, new_invoice_id, v_product_id, v_q, v_cost, v_ldisc, v_pct, v_base_line, v_same, v_alloc, v_net_line, v_net_line / v_units);

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
      invoice_discount_pct = (v_pr->>'invoice_discount_pct')::numeric, cash_discount_pct = (v_pr->>'cash_discount_pct')::numeric, tier_discount_pct = (v_pr->>'tier_discount_pct')::numeric,
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
revoke all on function create_purchase_invoice(uuid, uuid, uuid, text, date, jsonb, numeric, numeric, numeric, text, text, numeric, jsonb) from public, anon;
grant execute on function create_purchase_invoice(uuid, uuid, uuid, text, date, jsonb, numeric, numeric, numeric, text, text, numeric, jsonb) to authenticated;

-- Kayan — Phase 35: a restricted sales rep who names ANOTHER rep now gets a clear error.
-- Before: create_sales_invoice silently replaced the requested rep with the caller's own record,
-- so a mistaken (or malicious) request looked like it had succeeded.
-- After: the request is refused with an explicit message and nothing is created.
-- Naming themselves, or no rep at all, still works; holders of sales.assign_any_rep are unaffected.
-- This is the ONLY change to the function (one added guard); the rest is the live definition from 0033.
-- Depends on 0033. Re-runnable.

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

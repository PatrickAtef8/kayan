-- Kayan — Phase 33: (1) only the Owner may sell below cost, (2) reps can only assign to themselves
-- Depends on 0032. Re-runnable. Both rules are triggers on the tables the invoice RPC writes,
-- so they hold no matter which function (or direct write) produces the row.

-- ============================================================
-- helpers
-- ============================================================
-- True only for the system "owner" role in that organization (not admin, not a custom copy).
create or replace function is_org_owner(p_org uuid) returns boolean
language sql security definer stable set search_path = public as $$
  select exists (
    select 1
    from organization_users ou
    join roles r on r.id = ou.role_id
    where ou.organization_id = p_org and ou.user_id = auth.uid() and ou.status = 'active'
      and r.key = 'owner' and r.organization_id is null)
$$;
revoke all on function is_org_owner(uuid) from public, anon;
grant execute on function is_org_owner(uuid) to authenticated;

-- The sales-rep record linked to the calling user (sales_representatives.user_id), if any.
create or replace function own_rep_id(p_org uuid) returns uuid
language sql security definer stable set search_path = public as $$
  select id from sales_representatives
  where organization_id = p_org and user_id = auth.uid() and is_active
  order by created_at limit 1
$$;
revoke all on function own_rep_id(uuid) from public, anon;
grant execute on function own_rep_id(uuid) to authenticated;

-- ============================================================
-- 1. Below-cost selling: Owner only.
--    sales_item_financials is written once per invoice line with the REAL unit cost the
--    stock engine used (average cost at sale time). Compared with the line's net selling
--    total (after every discount) for the units the customer paid for. Free manual-bonus
--    lines are governed by the bonus permission (0031), not by this rule.
--    The message is deliberately generic: it must not reveal the cost.
-- ============================================================
create or replace function guard_below_cost() returns trigger
language plpgsql security definer set search_path = public as $$
declare v record;
begin
  if auth.uid() is null then return NEW; end if;            -- internal / service jobs
  select organization_id, quantity, net_total, is_bonus into v
  from sales_invoice_items where id = NEW.sales_invoice_item_id;
  if not found or v.is_bonus then return NEW; end if;
  if is_org_owner(v.organization_id) then return NEW; end if;
  if v.net_total < round(NEW.unit_cost * v.quantity, 2) - 0.01 then
    raise exception 'لا يُسمح بالبيع بأقل من التكلفة — هذه الصلاحية للمالك فقط';
  end if;
  return NEW;
end $$;
revoke all on function guard_below_cost() from public, anon;

drop trigger if exists guard_below_cost on sales_item_financials;
create trigger guard_below_cost before insert on sales_item_financials
  for each row execute function guard_below_cost();

-- ============================================================
-- 2. Rep assignment. New explicit override permission: sales.assign_any_rep
--    (default: owner, admin). Without it:
--      * a user LINKED to a rep record can only create invoices / assign customers to THEMSELVES
--      * an unlinked user may only keep the customer's own default rep (or none)
--    Enforced on sales_invoices (insert + rep change) and customers.sales_rep_id.
-- ============================================================
insert into permissions (key, description, category)
select 'sales.assign_any_rep', 'Assign invoices and customers to any sales rep (override)',
       (select category from permissions where key = 'sales.create')
on conflict (key) do nothing;

insert into role_permissions (role_id, permission_key)
select r.id, 'sales.assign_any_rep' from roles r
where r.organization_id is null and r.key in ('owner', 'admin')
on conflict do nothing;

create or replace function guard_rep_assignment() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_own uuid; v_default uuid;
begin
  if auth.uid() is null then return NEW; end if;
  if TG_OP = 'UPDATE' and NEW.sales_rep_id is not distinct from OLD.sales_rep_id then return NEW; end if;
  if has_permission(NEW.organization_id, 'sales.assign_any_rep') then return NEW; end if;

  v_own := own_rep_id(NEW.organization_id);

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
      raise exception 'تعيين مندوب للعميل يحتاج صلاحية خاصة';
    end if;
  end if;
  return NEW;
end $$;
revoke all on function guard_rep_assignment() from public, anon;

drop trigger if exists guard_rep_assignment on sales_invoices;
drop trigger if exists guard_rep_assignment on customers;
create trigger guard_rep_assignment before insert or update of sales_rep_id on sales_invoices
  for each row execute function guard_rep_assignment();
create trigger guard_rep_assignment before insert or update of sales_rep_id on customers
  for each row execute function guard_rep_assignment();

-- ============================================================
-- 3. create_sales_invoice forced "restricted" reps (sales role + linked rep record) onto their own
--    rep with no way out. Honour the explicit override permission there too. This is the ONLY change
--    to the function (one condition); everything else is the live definition from 0029.
-- ============================================================
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

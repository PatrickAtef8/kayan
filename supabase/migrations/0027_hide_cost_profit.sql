-- Kayan — Phase 27: cost & profit are invisible to representatives AT THE DATABASE
--
-- Row-level security cannot hide a column, so the sensitive figures move into
-- companion tables whose own policies decide who can read them:
--     readable only by members holding `view_financial`, and never by a member
--     restricted to their own data (Sales Representative linked to a rep record).
-- The base tables keep everything a rep legitimately needs (prices, quantities,
-- discounts, net totals). Postings write the companions inside the same
-- SECURITY DEFINER RPCs; reports read through security-invoker views that rejoin
-- them, so a caller without the right simply sees NULL there — and the report
-- functions already withhold profit/cost from such callers.
--
-- Inventory cost (stock avg cost, stock movements, transfers) and the product
-- cost price are blocked for restricted reps outright; their selling prices come
-- from a dedicated view.

create or replace function fin_org_ids() returns setof uuid
language sql security definer stable set search_path = public as $$
  select ou.organization_id
  from organization_users ou
  join role_permissions rp on rp.role_id = ou.role_id
  where ou.user_id = auth.uid() and ou.status = 'active' and rp.permission_key = 'view_financial'
$$;
revoke all on function fin_org_ids() from public, anon;
grant execute on function fin_org_ids() to authenticated;

create table sales_invoice_financials (
  sales_invoice_id uuid primary key references sales_invoices(id) on delete cascade,
  organization_id  uuid not null references organizations(id) on delete cascade,
  cogs_total       numeric(14,2) not null default 0,
  profit_total     numeric(14,2) not null default 0,
  bonus_cost       numeric(14,2) not null default 0
);
create table sales_item_financials (
  sales_invoice_item_id uuid primary key references sales_invoice_items(id) on delete cascade,
  organization_id uuid not null references organizations(id) on delete cascade,
  unit_cost       numeric(14,2) not null default 0,
  cost_total      numeric(14,2) not null default 0,
  profit          numeric(14,2) not null default 0
);
create table sales_return_financials (
  sales_return_id uuid primary key references sales_returns(id) on delete cascade,
  organization_id uuid not null references organizations(id) on delete cascade,
  cost_reversed   numeric(14,2) not null default 0,
  profit_reversed numeric(14,2) not null default 0
);
create table sales_return_item_financials (
  sales_return_item_id uuid primary key references sales_return_items(id) on delete cascade,
  organization_id uuid not null references organizations(id) on delete cascade,
  unit_cost       numeric(14,2) not null default 0,
  cost_reversed   numeric(14,2) not null default 0,
  profit_reversed numeric(14,2) not null default 0
);
create index sales_invoice_financials_org on sales_invoice_financials(organization_id);
create index sales_item_financials_org on sales_item_financials(organization_id);
create index sales_return_financials_org on sales_return_financials(organization_id);
create index sales_return_item_financials_org on sales_return_item_financials(organization_id);

insert into sales_invoice_financials select id, organization_id, cogs_total, profit_total, bonus_cost from sales_invoices;
insert into sales_item_financials select id, organization_id, unit_cost, cost_total, profit from sales_invoice_items;
insert into sales_return_financials select id, organization_id, cost_reversed, profit_reversed from sales_returns;
insert into sales_return_item_financials select id, organization_id, unit_cost, cost_reversed, profit_reversed from sales_return_items;

alter table sales_invoices      drop column cogs_total, drop column profit_total, drop column bonus_cost;
alter table sales_invoice_items drop column unit_cost, drop column cost_total, drop column profit;
alter table sales_returns       drop column cost_reversed, drop column profit_reversed;
alter table sales_return_items  drop column unit_cost, drop column cost_reversed, drop column profit_reversed;

do $$
declare t text;
begin
  foreach t in array array['sales_invoice_financials','sales_item_financials','sales_return_financials','sales_return_item_financials']
  loop
    execute format('alter table %I enable row level security', t);
    execute format('create policy fin_select on %I for select using (organization_id in (select fin_org_ids()))', t);
    execute format('create policy rep_scope on %I as restrictive for select using (organization_id not in (select restricted_rep_org_ids()))', t);
    execute format('grant select on %I to authenticated', t);
  end loop;
end $$;

-- Rejoining views for the reports (caller's own RLS applies to both sides).
create view v_sales_invoices with (security_invoker = true) as
  select i.*, f.cogs_total, f.profit_total, f.bonus_cost
  from sales_invoices i left join sales_invoice_financials f on f.sales_invoice_id = i.id;
create view v_sales_invoice_items with (security_invoker = true) as
  select it.*, f.unit_cost, f.cost_total, f.profit
  from sales_invoice_items it left join sales_item_financials f on f.sales_invoice_item_id = it.id;
create view v_sales_returns with (security_invoker = true) as
  select r.*, f.cost_reversed, f.profit_reversed
  from sales_returns r left join sales_return_financials f on f.sales_return_id = r.id;
create view v_sales_return_items with (security_invoker = true) as
  select ri.*, f.unit_cost, f.cost_reversed, f.profit_reversed
  from sales_return_items ri left join sales_return_item_financials f on f.sales_return_item_id = ri.id;
grant select on v_sales_invoices, v_sales_invoice_items, v_sales_returns, v_sales_return_items to authenticated;

-- Inventory cost + product cost price: blocked for restricted reps.
do $$
declare t text;
begin
  foreach t in array array['inventory_stock','inventory_movements','stock_transfers','stock_transfer_items','product_prices']
  loop
    execute format('create policy rep_scope on %I as restrictive for select using (organization_id not in (select restricted_rep_org_ids()))', t);
  end loop;
end $$;

-- Selling prices only (no cost) for the invoice screen.
create view product_sale_prices as
  select pp.product_id, pp.organization_id, pp.selling_price, pp.wholesale_price, pp.distributor_price
  from product_prices pp
  where pp.organization_id in (select user_org_ids());
grant select on product_sale_prices to authenticated;


-- ===== postings =====
create or replace function create_sales_invoice(
  org_id uuid, p_customer_id uuid, p_warehouse_id uuid, p_invoice_number text, p_invoice_date date,
  items jsonb, p_discount_total numeric, p_tax_total numeric, p_amount_collected numeric,
  p_payment_method text, p_notes text,
  p_sales_rep_id uuid default null, p_cash_discount numeric default 0
)
returns uuid
language plpgsql security definer set search_path = public
as $$
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
  v_units numeric(14,3); v_unit_cost numeric(14,2); v_cost_total numeric(14,2); v_net_line numeric(14,2);
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
  v_collected := least(coalesce(p_amount_collected, 0), v_total);
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

  update sales_invoices
  set subtotal = v_gross, discount_total = v_disc_total,
      line_discount_total = (v_pr->>'line_discount')::numeric,
      invoice_discount = (v_pr->>'invoice_discount')::numeric,
      cash_discount = (v_pr->>'cash_discount')::numeric,
      tier_discount = (v_pr->>'tier_discount')::numeric,
      bonus_units = v_bonus_units,
      tax_total = coalesce(p_tax_total, 0), total = v_total,
      amount_paid = v_collected, payment_status = v_status,
      commission_basis_snapshot = v_commission_basis, commission_amount = v_commission,
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

  return new_invoice_id;
end $$;

create or replace function create_sales_return(
  org_id uuid, p_sales_invoice_id uuid, p_return_date date, items jsonb,
  p_cash_refund numeric default 0, p_notes text default null,
  p_full_return boolean default false, p_condition text default 'resalable'
)
returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  new_return_id uuid; v_customer_id uuid; v_warehouse_id uuid; v_inv_rep uuid; account_id uuid;
  item jsonb; v_items jsonb;
  v_item_id uuid; v_quantity numeric(14,3); v_condition text; v_orig record;
  v_already numeric(14,3); v_remaining numeric(14,3); v_units numeric(14,3); v_prior numeric(14,2);
  v_revenue numeric(14,2); v_cost numeric(14,2); v_profit numeric(14,2);
  v_track boolean; v_old_qty numeric(14,3); v_old_avg numeric(14,2); v_unit_cost numeric(14,2); v_ri_id uuid;
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

    select unit_cost into v_unit_cost from sales_item_financials where sales_invoice_item_id = v_item_id;
    v_unit_cost := coalesce(v_unit_cost, 0);

    select coalesce(sum(quantity), 0), coalesce(sum(revenue_reversed), 0) into v_already, v_prior
    from sales_return_items where sales_invoice_item_id = v_item_id;
    v_units := v_orig.quantity + v_orig.bonus_quantity;
    v_remaining := v_units - v_already;
    if v_quantity > v_remaining then
      raise exception 'الكمية المطلوب إرجاعها أكبر من المتاح لهذا الصنف (المتبقي: %)', v_remaining;
    end if;

    v_revenue := case when v_quantity = v_remaining then v_orig.net_total - v_prior
                      else round(v_orig.net_total * v_quantity / v_units, 2) end;
    v_cost := case when v_condition = 'resalable' then round(v_unit_cost * v_quantity, 2) else 0 end;
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
                            then ((v_old_qty * v_old_avg) + (v_quantity * v_unit_cost)) / (v_old_qty + v_quantity) else v_old_avg end,
            updated_at = now()
        where product_id = v_orig.product_id and warehouse_id = v_warehouse_id;
        insert into inventory_movements (organization_id, product_id, warehouse_id, movement_type, quantity_delta, unit_cost, reference_type, reference_id, created_by)
        values (org_id, v_orig.product_id, v_warehouse_id, 'sale_return', v_quantity, v_unit_cost, 'sales_return', new_return_id, auth.uid());
      end if;
    end if;

    insert into sales_return_items (organization_id, sales_return_id, sales_invoice_item_id, product_id, quantity, condition, unit_price, revenue_reversed)
    values (org_id, new_return_id, v_item_id, v_orig.product_id, v_quantity, v_condition, v_orig.effective_unit_price, v_revenue)
    returning id into v_ri_id;
    insert into sales_return_item_financials (sales_return_item_id, organization_id, unit_cost, cost_reversed, profit_reversed)
    values (v_ri_id, org_id, v_unit_cost, v_cost, v_profit);

    v_subtotal := v_subtotal + v_revenue; v_cost_total := v_cost_total + v_cost; v_profit_total := v_profit_total + v_profit;
  end loop;

  if p_cash_refund > v_subtotal then raise exception 'قيمة الاسترجاع النقدي أكبر من قيمة المرتجع'; end if;

  update sales_returns
  set subtotal_reversed = v_subtotal, total = v_subtotal, cash_refunded = p_cash_refund, updated_at = now()
  where id = new_return_id;
  insert into sales_return_financials (sales_return_id, organization_id, cost_reversed, profit_reversed)
  values (new_return_id, org_id, v_cost_total, v_profit_total);

  if p_cash_refund > 0 then
    account_id := ensure_default_treasury_account(org_id);
    insert into treasury_movements (organization_id, treasury_account_id, direction, amount, category, movement_date, source_type, source_id, description, created_by)
    values (org_id, account_id, 'out', p_cash_refund, 'sales_return', coalesce(p_return_date, current_date), 'sales_return', new_return_id, nullif(p_notes, ''), auth.uid());
  end if;
  return new_return_id;
end $$;

-- ===== reports (read through the rejoining views) =====
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
    (select coalesce(sum(ic.earned_commission), 0) from invoice_commissions ic
     where ic.organization_id = org_id
       and (p_from is null or ic.invoice_date >= p_from)
       and (p_to is null or ic.invoice_date <= p_to)) as commissions
  into s
  from v_sales_invoices
  where organization_id = org_id
    and (p_from is null or invoice_date >= p_from)
    and (p_to is null or invoice_date <= p_to);

  select coalesce(sum(total), 0), coalesce(sum(cost_reversed), 0), coalesce(sum(profit_reversed), 0)
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
$$;

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
    from v_sales_invoices i
    where i.organization_id = org_id
      and (p_from is null or i.invoice_date >= p_from)
      and (p_to is null or i.invoice_date <= p_to)
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
  select coalesce(s.b, e.b),
         coalesce(s.ns, 0)::numeric,
         case when fin then coalesce(s.gp, 0)::numeric end,
         case when fin then coalesce(e.ex, 0)::numeric end
  from s full join e on e.b = s.b
  order by 1;
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
           coalesce((select sum(r.total) from v_sales_returns r where r.sales_invoice_id = i.id), 0) as ret_total,
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
$$;

create or replace function dashboard_sales_totals(org_id uuid, p_from date default null)
returns table (total_sales numeric, total_profit numeric)
language plpgsql
stable
set search_path = public
as $$
begin
  perform assert_report_access(org_id, false);
  return query
  select
    coalesce(sum(i.total), 0)::numeric,
    case when has_permission(org_id, 'view_financial')
         then coalesce(sum(i.profit_total), 0)::numeric
         else 0::numeric end
  from v_sales_invoices i
  where i.organization_id = org_id
    and (p_from is null or i.invoice_date >= p_from);
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
    from v_sales_invoices i
    left join (
      select r.sales_invoice_id, sum(r.total) as ret_total, sum(r.profit_reversed) as ret_profit
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
$$;

revoke all on function create_sales_invoice(uuid, uuid, uuid, text, date, jsonb, numeric, numeric, numeric, text, text, uuid, numeric) from public, anon;
grant execute on function create_sales_invoice(uuid, uuid, uuid, text, date, jsonb, numeric, numeric, numeric, text, text, uuid, numeric) to authenticated;
revoke all on function create_sales_return(uuid, uuid, date, jsonb, numeric, text, boolean, text) from public, anon;
grant execute on function create_sales_return(uuid, uuid, date, jsonb, numeric, text, boolean, text) to authenticated;
revoke all on function report_summary(uuid, date, date) from public, anon;
grant execute on function report_summary(uuid, date, date) to authenticated;
revoke all on function report_timeseries(uuid, date, date, text) from public, anon;
grant execute on function report_timeseries(uuid, date, date, text) to authenticated;
revoke all on function report_sales_breakdown(uuid, date, date, text, int, int) from public, anon;
grant execute on function report_sales_breakdown(uuid, date, date, text, int, int) to authenticated;

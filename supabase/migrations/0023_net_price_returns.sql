-- Kayan — Phase 23: returns at the real net price (partial + full), sales report fix
--
-- A returned unit is valued at   net_total / (quantity + bonus_quantity)   of
-- its original line, i.e. AFTER every discount and after spreading the line over
-- the free (bonus) units too:  12 × 100, 1 bonus → 1200 / 13 = 92.31 per piece.
-- Returning the last remaining units takes "net_total − already returned" so a
-- full return gives back exactly the net amount (no rounding drift).
-- Resalable stock re-enters at the line's historical cost; damaged stock does
-- not (revenue reverses, cost does not), unchanged from Phase 8.

-- ============================================================
-- 1. Sales returns
-- ============================================================
drop function if exists get_returnable_items(uuid, uuid);
create or replace function get_returnable_items(org_id uuid, p_sales_invoice_id uuid)
returns table (
  sales_invoice_item_id uuid, product_id uuid, product_name text,
  quantity numeric, bonus_quantity numeric, is_bonus boolean,
  already_returned numeric, returnable numeric,
  unit_price numeric, line_total numeric
)
language plpgsql stable set search_path = public
as $$
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
         it.net_total::numeric
  from sales_invoice_items it
  join products p on p.id = it.product_id
  left join (
    select sri.sales_invoice_item_id, sum(sri.quantity) as qty
    from sales_return_items sri group by sri.sales_invoice_item_id
  ) ret on ret.sales_invoice_item_id = it.id
  where it.sales_invoice_id = p_sales_invoice_id and it.organization_id = org_id
  order by it.is_bonus, p.name;
end $$;
revoke all on function get_returnable_items(uuid, uuid) from public, anon;
grant execute on function get_returnable_items(uuid, uuid) to authenticated;

drop function if exists create_sales_return(uuid, uuid, date, jsonb, numeric, text);
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
  v_track boolean; v_old_qty numeric(14,3); v_old_avg numeric(14,2);
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

    select coalesce(sum(quantity), 0), coalesce(sum(revenue_reversed), 0) into v_already, v_prior
    from sales_return_items where sales_invoice_item_id = v_item_id;
    v_units := v_orig.quantity + v_orig.bonus_quantity;
    v_remaining := v_units - v_already;
    if v_quantity > v_remaining then
      raise exception 'الكمية المطلوب إرجاعها أكبر من المتاح لهذا الصنف (المتبقي: %)', v_remaining;
    end if;

    v_revenue := case when v_quantity = v_remaining then v_orig.net_total - v_prior
                      else round(v_orig.net_total * v_quantity / v_units, 2) end;
    v_cost := case when v_condition = 'resalable' then round(v_orig.unit_cost * v_quantity, 2) else 0 end;
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
                            then ((v_old_qty * v_old_avg) + (v_quantity * v_orig.unit_cost)) / (v_old_qty + v_quantity) else v_old_avg end,
            updated_at = now()
        where product_id = v_orig.product_id and warehouse_id = v_warehouse_id;
        insert into inventory_movements (organization_id, product_id, warehouse_id, movement_type, quantity_delta, unit_cost, reference_type, reference_id, created_by)
        values (org_id, v_orig.product_id, v_warehouse_id, 'sale_return', v_quantity, v_orig.unit_cost, 'sales_return', new_return_id, auth.uid());
      end if;
    end if;

    insert into sales_return_items (organization_id, sales_return_id, sales_invoice_item_id, product_id, quantity, condition, unit_price, unit_cost, revenue_reversed, cost_reversed, profit_reversed)
    values (org_id, new_return_id, v_item_id, v_orig.product_id, v_quantity, v_condition, v_orig.effective_unit_price, v_orig.unit_cost, v_revenue, v_cost, v_profit);

    v_subtotal := v_subtotal + v_revenue; v_cost_total := v_cost_total + v_cost; v_profit_total := v_profit_total + v_profit;
  end loop;

  if p_cash_refund > v_subtotal then raise exception 'قيمة الاسترجاع النقدي أكبر من قيمة المرتجع'; end if;

  update sales_returns
  set subtotal_reversed = v_subtotal, cost_reversed = v_cost_total, profit_reversed = v_profit_total,
      total = v_subtotal, cash_refunded = p_cash_refund, updated_at = now()
  where id = new_return_id;

  if p_cash_refund > 0 then
    account_id := ensure_default_treasury_account(org_id);
    insert into treasury_movements (organization_id, treasury_account_id, direction, amount, category, movement_date, source_type, source_id, description, created_by)
    values (org_id, account_id, 'out', p_cash_refund, 'sales_return', coalesce(p_return_date, current_date), 'sales_return', new_return_id, nullif(p_notes, ''), auth.uid());
  end if;
  return new_return_id;
end $$;
revoke all on function create_sales_return(uuid, uuid, date, jsonb, numeric, text, boolean, text) from public, anon;
grant execute on function create_sales_return(uuid, uuid, date, jsonb, numeric, text, boolean, text) to authenticated;

-- ============================================================
-- 2. Purchase returns
-- ============================================================
drop function if exists get_returnable_purchase_items(uuid, uuid);
create or replace function get_returnable_purchase_items(org_id uuid, p_purchase_invoice_id uuid)
returns table (
  purchase_invoice_item_id uuid, product_id uuid, product_name text,
  quantity numeric, bonus_quantity numeric, is_bonus boolean,
  already_returned numeric, returnable numeric, on_hand numeric,
  unit_cost numeric, line_total numeric
)
language plpgsql stable set search_path = public
as $$
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
         it.net_total::numeric
  from purchase_invoice_items it
  join products p on p.id = it.product_id
  join purchase_invoices pi on pi.id = it.purchase_invoice_id
  left join (select pri.purchase_invoice_item_id, sum(pri.quantity) as qty from purchase_return_items pri group by 1) ret on ret.purchase_invoice_item_id = it.id
  left join inventory_stock stk on stk.product_id = it.product_id and stk.warehouse_id = pi.warehouse_id and stk.organization_id = org_id
  where it.purchase_invoice_id = p_purchase_invoice_id and it.organization_id = org_id
  order by it.is_bonus, p.name;
end $$;
revoke all on function get_returnable_purchase_items(uuid, uuid) from public, anon;
grant execute on function get_returnable_purchase_items(uuid, uuid) to authenticated;

drop function if exists create_purchase_return(uuid, uuid, date, jsonb, numeric, text);
create or replace function create_purchase_return(
  org_id uuid, p_purchase_invoice_id uuid, p_return_date date, items jsonb,
  p_cash_refund numeric default 0, p_notes text default null,
  p_full_return boolean default false
)
returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  new_return_id uuid; v_supplier_id uuid; v_warehouse_id uuid; account_id uuid;
  item jsonb; v_items jsonb; v_item_id uuid; v_quantity numeric(14,3); v_orig record;
  v_already numeric(14,3); v_remaining numeric(14,3); v_units numeric(14,3); v_prior numeric(14,2);
  v_line_total numeric(14,2); v_track boolean; v_current_qty numeric(14,3); v_subtotal numeric(14,2) := 0;
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

    select track_inventory into v_track from products where id = v_orig.product_id and organization_id = org_id;
    if v_track then
      select quantity into v_current_qty from inventory_stock
      where product_id = v_orig.product_id and warehouse_id = v_warehouse_id for update;
      if not found or coalesce(v_current_qty, 0) < v_quantity then
        raise exception 'الكمية المتاحة بالمخزون أقل من كمية المرتجع لهذا الصنف';
      end if;
      update inventory_stock set quantity = quantity - v_quantity, updated_at = now()
      where product_id = v_orig.product_id and warehouse_id = v_warehouse_id;
      insert into inventory_movements (organization_id, product_id, warehouse_id, movement_type, quantity_delta, unit_cost, reference_type, reference_id, created_by)
      values (org_id, v_orig.product_id, v_warehouse_id, 'purchase_return', -v_quantity, v_orig.effective_unit_cost, 'purchase_return', new_return_id, auth.uid());
    end if;

    insert into purchase_return_items (organization_id, purchase_return_id, purchase_invoice_item_id, product_id, quantity, unit_cost, line_total)
    values (org_id, new_return_id, v_item_id, v_orig.product_id, v_quantity, v_orig.effective_unit_cost, v_line_total);
    v_subtotal := v_subtotal + v_line_total;
  end loop;

  if p_cash_refund > v_subtotal then raise exception 'قيمة الاسترجاع النقدي أكبر من قيمة المرتجع'; end if;
  update purchase_returns set total = v_subtotal, cash_refunded = p_cash_refund, updated_at = now() where id = new_return_id;

  if p_cash_refund > 0 then
    account_id := ensure_default_treasury_account(org_id);
    insert into treasury_movements (organization_id, treasury_account_id, direction, amount, category, movement_date, source_type, source_id, description, created_by)
    values (org_id, account_id, 'in', p_cash_refund, 'purchase_return', coalesce(p_return_date, current_date), 'purchase_return', new_return_id, nullif(p_notes, ''), auth.uid());
  end if;
  return new_return_id;
end $$;
revoke all on function create_purchase_return(uuid, uuid, date, jsonb, numeric, text, boolean) from public, anon;
grant execute on function create_purchase_return(uuid, uuid, date, jsonb, numeric, text, boolean) to authenticated;

-- ============================================================
-- 3. Sales-by-product report: read the STORED allocation of the
--    invoice-level discount instead of re-deriving it at read time.
-- ============================================================
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
           coalesce((select sum(r.total) from sales_returns r where r.sales_invoice_id = i.id), 0) as ret_total,
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
revoke all on function report_sales_breakdown(uuid, date, date, text, int, int) from public, anon;
grant execute on function report_sales_breakdown(uuid, date, date, text, int, int) to authenticated;

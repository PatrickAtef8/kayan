-- Kayan — Reports package, Phase 2.1: batch-faithful sales returns + batch-specific disposal
--
-- (1) Sales returns go back to the batch they were sold from.
--     Every sale records which batches it drew from, per (invoice, product, warehouse, batch)
--     in sales_batch_allocations (quantity + how much has been returned so far). A resalable
--     return restores quantity to those batches — to the very same batch row (same id) when it
--     still exists, otherwise the batch is re-created with its ORIGINAL id, expiry date and
--     source purchase invoice. Only what cannot be traced (invoices sold before this migration,
--     or a return larger than what was allocated) falls back to an undated batch.
--     A batch that has expired in the meantime goes back as an expired batch — that is the truth
--     of the goods, and it is then blocked from sale and can be disposed of.
--
-- (2) Disposal that cannot touch valid stock.
--     A plain negative adjustment is FEFO (earliest expiry first, expired included), so a large
--     enough quantity would spill from the expired batch into valid stock. dispose_stock_batch()
--     takes ONE batch id and a quantity ≤ that batch's quantity — it can neither exceed the
--     batch nor touch any other batch. It works on any batch (expired, damaged, recalled …).
--
-- Both are done inside the same trigger-driven design as 0037: stock_batches is still written
-- only by the inventory_stock trigger, and Σ batches = stock on hand is still an invariant.
--
-- Context passed to the trigger (transaction-local, always reset):
--   kayan.batch_sale_ref   sales invoice id while a sale deducts   (records the allocation)
--   kayan.batch_return     sales invoice id while a resalable return restocks
--   kayan.batch_target     batch id while dispose_stock_batch deducts

-- ============================================================
-- 1. What each sale took from which batch
-- ============================================================
create table if not exists sales_batch_allocations (
  id                  uuid primary key default gen_random_uuid(),
  organization_id     uuid not null references organizations(id) on delete cascade,
  sales_invoice_id    uuid not null references sales_invoices(id) on delete cascade,
  product_id          uuid not null references products(id) on delete restrict,
  warehouse_id        uuid not null references warehouses(id) on delete restrict,
  batch_id            uuid not null,                      -- the batch's id at the time of the sale (the row may be gone since)
  expiry_date         date,                               -- snapshot, used to re-create the batch if needed
  purchase_invoice_id uuid references purchase_invoices(id) on delete set null,
  quantity            numeric(14,3) not null check (quantity > 0 and quantity < 1000000000),
  returned_quantity   numeric(14,3) not null default 0 check (returned_quantity >= 0 and returned_quantity <= quantity),
  created_at          timestamptz not null default now(),
  unique (sales_invoice_id, product_id, warehouse_id, batch_id)
);
create index if not exists sales_batch_alloc_lookup on sales_batch_allocations (sales_invoice_id, product_id, warehouse_id);
create index if not exists sales_batch_alloc_org on sales_batch_allocations (organization_id);

alter table sales_batch_allocations enable row level security;
drop policy if exists sales_batch_alloc_select on sales_batch_allocations;
create policy sales_batch_alloc_select on sales_batch_allocations for select using (organization_id in (select user_org_ids()));
revoke all on sales_batch_allocations from public, anon, authenticated;
grant select on sales_batch_allocations to authenticated;

-- ============================================================
-- 2. Helpers
-- ============================================================
-- _batch_take gains p_sale_ref: when given, each chunk taken is recorded as an allocation.
create or replace function _batch_take(p_org uuid, p_product uuid, p_wh uuid, p_qty numeric,
                                       p_skip_expired boolean, p_prefer uuid, p_sale_ref uuid)
returns numeric language plpgsql security definer set search_path = public as $$
declare b record; v_left numeric := p_qty; v_take numeric; v_today date := (now() at time zone 'Africa/Cairo')::date;
begin
  for b in
    select id, quantity, expiry_date, purchase_invoice_id from stock_batches
    where organization_id = p_org and product_id = p_product and warehouse_id = p_wh
      and (not p_skip_expired or expiry_date is null or expiry_date >= v_today)
    order by (case when p_prefer is not null and purchase_invoice_id = p_prefer then 0 else 1 end),
             expiry_date nulls last, created_at, id
    for update
  loop
    exit when v_left <= 0;
    v_take := least(b.quantity, v_left);
    if v_take >= b.quantity then delete from stock_batches where id = b.id;
    else update stock_batches set quantity = quantity - v_take where id = b.id; end if;
    if p_sale_ref is not null then
      insert into sales_batch_allocations (organization_id, sales_invoice_id, product_id, warehouse_id, batch_id, expiry_date, purchase_invoice_id, quantity)
      values (p_org, p_sale_ref, p_product, p_wh, b.id, b.expiry_date, b.purchase_invoice_id, v_take)
      on conflict (sales_invoice_id, product_id, warehouse_id, batch_id)
      do update set quantity = sales_batch_allocations.quantity + excluded.quantity;
    end if;
    v_left := v_left - v_take;
  end loop;
  return greatest(v_left, 0);
end $$;

-- Resalable return → back into the batches the invoice drew from (same id / expiry / invoice).
create or replace function _batch_restore(p_org uuid, p_product uuid, p_wh uuid, p_qty numeric, p_invoice uuid)
returns void language plpgsql security definer set search_path = public as $$
declare a record; v_left numeric := p_qty; v_take numeric;
begin
  for a in
    select * from sales_batch_allocations
    where organization_id = p_org and sales_invoice_id = p_invoice and product_id = p_product and warehouse_id = p_wh
      and quantity > returned_quantity
    order by expiry_date nulls last, created_at, id
    for update
  loop
    exit when v_left <= 0;
    v_take := least(a.quantity - a.returned_quantity, v_left);
    -- 1) the very same batch row, if it still exists
    update stock_batches set quantity = quantity + v_take
    where id = a.batch_id and organization_id = p_org and product_id = p_product and warehouse_id = p_wh;
    if not found then
      -- 2) an identical batch (same expiry, same source invoice) that took its place
      update stock_batches set quantity = quantity + v_take
      where organization_id = p_org and product_id = p_product and warehouse_id = p_wh
        and expiry_date is not distinct from a.expiry_date and purchase_invoice_id is not distinct from a.purchase_invoice_id;
      if not found then
        -- 3) the batch was used up and deleted: re-create it with its original id
        insert into stock_batches (id, organization_id, product_id, warehouse_id, expiry_date, quantity, purchase_invoice_id)
        values (a.batch_id, p_org, p_product, p_wh, a.expiry_date, v_take, a.purchase_invoice_id);
      end if;
    end if;
    update sales_batch_allocations set returned_quantity = returned_quantity + v_take where id = a.id;
    v_left := v_left - v_take;
  end loop;
  -- untraceable remainder (invoice older than this migration, or more than was allocated)
  if v_left > 0 then perform _batch_add(p_org, p_product, p_wh, v_left, null, null); end if;
end $$;

-- Disposal: deduct from exactly one batch.
create or replace function _batch_take_target(p_batch uuid, p_qty numeric)
returns void language plpgsql security definer set search_path = public as $$
declare v_qty numeric;
begin
  select quantity into v_qty from stock_batches where id = p_batch for update;
  if v_qty is null then raise exception 'الدفعة غير موجودة'; end if;
  if p_qty > v_qty then raise exception 'الكمية أكبر من كمية الدفعة (المتاح: %)', v_qty; end if;
  if p_qty >= v_qty then delete from stock_batches where id = p_batch;
  else update stock_batches set quantity = quantity - p_qty where id = p_batch; end if;
end $$;

-- ============================================================
-- 3. The trigger learns the three new contexts
-- ============================================================
create or replace function _stock_batches_sync() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_delta numeric; v_expiry date; v_ref uuid; v_prefer uuid; v_return uuid; v_target uuid; v_sale_ref uuid;
begin
  if coalesce(current_setting('kayan.batch_skip', true), '') = '1' then return new; end if;
  v_delta := new.quantity - (case when tg_op = 'UPDATE' then old.quantity else 0 end);
  if v_delta = 0 then return new; end if;

  if v_delta > 0 then
    v_return := nullif(current_setting('kayan.batch_return', true), '')::uuid;
    if v_return is not null then
      perform _batch_restore(new.organization_id, new.product_id, new.warehouse_id, v_delta, v_return);
    else
      v_expiry := nullif(current_setting('kayan.batch_expiry', true), '')::date;
      v_ref    := nullif(current_setting('kayan.batch_ref', true), '')::uuid;
      perform _batch_add(new.organization_id, new.product_id, new.warehouse_id, v_delta, v_expiry, v_ref);
    end if;
  else
    v_target := nullif(current_setting('kayan.batch_target', true), '')::uuid;
    if v_target is not null then
      perform _batch_take_target(v_target, -v_delta);
    else
      v_prefer   := nullif(current_setting('kayan.batch_prefer', true), '')::uuid;
      v_sale_ref := nullif(current_setting('kayan.batch_sale_ref', true), '')::uuid;
      perform _batch_take(new.organization_id, new.product_id, new.warehouse_id, -v_delta,
                          coalesce(current_setting('kayan.batch_sale', true), '') = '1', v_prefer, v_sale_ref);
    end if;
  end if;
  return new;
end $$;

drop function if exists _batch_take(uuid, uuid, uuid, numeric, boolean, uuid);

-- ============================================================
-- 4. dispose_stock_batch — batch-specific, can never touch other batches
-- ============================================================
create or replace function dispose_stock_batch(org_id uuid, p_batch_id uuid, p_quantity numeric, p_reason text)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_batch stock_batches%rowtype;
  v_stock record;
  v_avg numeric(14,6);
  v_movement uuid;
begin
  if auth.uid() is null then raise exception 'يجب تسجيل الدخول أولاً'; end if;
  if not is_org_member(org_id) then raise exception 'أنت لست عضوًا في هذه المؤسسة'; end if;
  if not has_permission(org_id, 'inventory.adjust') then raise exception 'ليس لديك صلاحية تسوية المخزون'; end if;
  if p_quantity is null or p_quantity <= 0 or p_quantity >= 1000000000 then raise exception 'الكمية يجب أن تكون أكبر من صفر'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'سبب الإعدام مطلوب'; end if;

  select * into v_batch from stock_batches where id = p_batch_id and organization_id = org_id for update;
  if not found then raise exception 'الدفعة غير موجودة'; end if;
  if p_quantity > v_batch.quantity then
    raise exception 'الكمية أكبر من كمية الدفعة (المتاح: %)', v_batch.quantity;
  end if;

  select s.id, s.quantity into v_stock from inventory_stock s
  where s.product_id = v_batch.product_id and s.warehouse_id = v_batch.warehouse_id and s.organization_id = org_id for update;
  if not found or v_stock.quantity < p_quantity then raise exception 'رصيد المخزن لا يغطي الكمية'; end if;

  select coalesce(avg_cost, 0) into v_avg from stock_costs where stock_id = v_stock.id;
  v_avg := coalesce(v_avg, 0);

  perform set_config('kayan.batch_target', p_batch_id::text, true);
  update inventory_stock set quantity = quantity - p_quantity, updated_at = now() where id = v_stock.id;
  perform set_config('kayan.batch_target', '', true);

  insert into inventory_movements (organization_id, product_id, warehouse_id, movement_type, quantity_delta, unit_cost, reference_type, reference_id, note, created_by)
  values (org_id, v_batch.product_id, v_batch.warehouse_id, 'adjustment', -p_quantity, v_avg, 'batch_disposal', p_batch_id,
          trim(p_reason) || case when v_batch.expiry_date is null then ' (دفعة بدون تاريخ صلاحية)' else ' (دفعة صلاحيتها ' || v_batch.expiry_date::text || ')' end,
          auth.uid())
  returning id into v_movement;
  return v_movement;
end $$;

revoke all on function dispose_stock_batch(uuid, uuid, numeric, text) from public, anon;
grant execute on function dispose_stock_batch(uuid, uuid, numeric, text) to authenticated;

-- ============================================================
-- 5. Sales functions, patched to hand their invoice id to the trigger
-- ============================================================

CREATE OR REPLACE FUNCTION public._consume_stock(org_id uuid, p_product uuid, p_wh uuid, p_qty numeric, p_ref uuid)
 RETURNS numeric
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_track boolean; v_old_qty numeric(14,3); v_old_avg numeric(14,6); v_cost numeric(14,6); v_expired numeric(14,3);
begin
  select track_inventory into v_track from products where id = p_product and organization_id = org_id;
  if not found then raise exception 'أحد المنتجات المختارة لا ينتمي إلى هذه المؤسسة'; end if;
  if v_track then
    select s.quantity, coalesce(sc.avg_cost, 0) into v_old_qty, v_old_avg
    from inventory_stock s left join stock_costs sc on sc.stock_id = s.id
    where s.product_id = p_product and s.warehouse_id = p_wh for update of s;
    if not found then
      v_old_qty := 0; v_old_avg := 0;
      insert into inventory_stock (organization_id, product_id, warehouse_id, quantity) values (org_id, p_product, p_wh, 0);
    end if;
    if v_old_qty < p_qty then
      raise exception 'الكمية المتاحة بالمخزون أقل من الكمية المطلوبة (المتاح: %)', greatest(v_old_qty, 0);
    end if;
    -- [batches] expired stock is never sold: only non-expired (or undated) stock counts as available
    select coalesce(sum(quantity), 0) into v_expired from stock_batches
    where organization_id = org_id and product_id = p_product and warehouse_id = p_wh and expiry_date < cairo_today();
    if v_old_qty - v_expired < p_qty then
      raise exception 'لا يمكن بيع بضاعة منتهية الصلاحية — المتاح للبيع (غير المنتهي): %، المنتهي الصلاحية في المخزن: %', greatest(v_old_qty - v_expired, 0), v_expired;
    end if;
    v_cost := v_old_avg;
    perform set_config('kayan.batch_sale', '1', true);   -- [batches] FEFO, skipping expired
    perform set_config('kayan.batch_sale_ref', coalesce(p_ref::text, ''), true);   -- [batches] remember which batches this sale used
    update inventory_stock set quantity = v_old_qty - p_qty, updated_at = now() where product_id = p_product and warehouse_id = p_wh;
    perform set_config('kayan.batch_sale', '', true);
    perform set_config('kayan.batch_sale_ref', '', true);
    insert into inventory_movements (organization_id, product_id, warehouse_id, movement_type, quantity_delta, unit_cost, reference_type, reference_id, created_by)
    values (org_id, p_product, p_wh, 'sale', -p_qty, v_cost, 'sales_invoice', p_ref, auth.uid());
  else
    select coalesce(pc.cost, 0) into v_cost from product_costs pc where pc.product_id = p_product limit 1;
    v_cost := coalesce(v_cost, 0);
  end if;
  return v_cost;
end $function$;

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

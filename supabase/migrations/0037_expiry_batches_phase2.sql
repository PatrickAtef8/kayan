-- Kayan — Reports package, Phase 2: expiry dates tracked per inventory BATCH
--
-- A batch = one quantity of one product in one warehouse with an OPTIONAL expiry date.
-- The same product can hold many batches with different expiry dates (or none).
--
--   * stock_batches            — the batches. Invariant: for every (product, warehouse),
--                                Σ batch quantity = inventory_stock.quantity.
--   * Written only by a trigger on inventory_stock, so EVERY path that changes stock
--     (purchase, sale, returns, transfers, adjustments — and any future one) keeps the
--     batches in step. Nothing in the app writes to stock_batches directly.
--   * Receiving   : a purchase line may carry an optional "expiry_date" in its JSON; no date
--                   → an undated batch ("لا يوجد تاريخ صلاحية مسجل" in the reports).
--   * Selling     : FEFO — first-expired-first-out. Earliest expiry is deducted first, undated
--                   batches last. Expired batches are NEVER sold: if the non-expired stock
--                   is not enough the sale is refused with a clear message.
--   * Purchase return : deducts first from the batches that came in on the returned invoice
--                   (that is the physical stock going back to the supplier), expired or not.
--   * Sales return (resalable): the goods come back as an undated batch — the original batch
--                   is not tracked per sale line (kept simple on purpose).
--   * Adjustment  : + creates a batch (optional expiry date); − deducts FEFO *including*
--                   expired batches, which is exactly how expired stock is written off.
--   * Transfer    : moves batches FEFO and keeps each batch's expiry date at the destination.
--
-- Existing stock is backfilled as undated batches so the invariant holds from day one.
--
-- Transaction-local settings used to pass context to the trigger (always reset after use):
--   kayan.batch_expiry  expiry for the next receipt     kayan.batch_ref     purchase invoice id
--   kayan.batch_sale    '1' while a sale deducts stock   kayan.batch_prefer  invoice to deduct from first
--   kayan.batch_skip    '1' while a transfer moves batches by itself

-- ============================================================
-- 1. Table
-- ============================================================
create table if not exists stock_batches (
  id                  uuid primary key default gen_random_uuid(),
  organization_id     uuid not null references organizations(id) on delete cascade,
  product_id          uuid not null references products(id) on delete restrict,
  warehouse_id        uuid not null references warehouses(id) on delete restrict,
  expiry_date         date,
  quantity            numeric(14,3) not null check (quantity > 0 and quantity < 1000000000),
  purchase_invoice_id uuid references purchase_invoices(id) on delete set null,
  created_at          timestamptz not null default now(),
  constraint stock_batches_expiry_sane check (expiry_date is null or expiry_date between date '2000-01-01' and date '2100-12-31')
);

-- one row per (product, warehouse, expiry, source invoice): receipts of the same kind merge
create unique index if not exists stock_batches_key
  on stock_batches (product_id, warehouse_id, coalesce(expiry_date, 'infinity'::date), coalesce(purchase_invoice_id, '00000000-0000-0000-0000-000000000000'::uuid));
create index if not exists stock_batches_lookup on stock_batches (organization_id, product_id, warehouse_id);
create index if not exists stock_batches_expiry on stock_batches (organization_id, expiry_date) where expiry_date is not null;

alter table stock_batches enable row level security;
drop policy if exists stock_batches_select on stock_batches;
create policy stock_batches_select on stock_batches for select using (organization_id in (select user_org_ids()));
revoke all on stock_batches from public, anon, authenticated;
grant select on stock_batches to authenticated;   -- read-only for everyone; the trigger (definer) writes

-- ============================================================
-- 2. Helpers
-- ============================================================
create or replace function cairo_today() returns date
language sql stable as $$ select (now() at time zone 'Africa/Cairo')::date $$;
grant execute on function cairo_today() to authenticated;

create or replace function _batch_add(p_org uuid, p_product uuid, p_wh uuid, p_qty numeric, p_expiry date, p_ref uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_qty is null or p_qty <= 0 then return; end if;
  update stock_batches set quantity = quantity + p_qty
  where organization_id = p_org and product_id = p_product and warehouse_id = p_wh
    and expiry_date is not distinct from p_expiry and purchase_invoice_id is not distinct from p_ref;
  if not found then
    insert into stock_batches (organization_id, product_id, warehouse_id, expiry_date, quantity, purchase_invoice_id)
    values (p_org, p_product, p_wh, p_expiry, p_qty, p_ref);
  end if;
end $$;

-- FEFO deduction. Returns what could NOT be deducted (0 normally). p_skip_expired = sales.
-- A non-zero remainder only happens if batches ever drift below stock; it is tolerated here
-- (the sale path checks availability up front and the test-suite asserts the invariant).
create or replace function _batch_take(p_org uuid, p_product uuid, p_wh uuid, p_qty numeric, p_skip_expired boolean, p_prefer uuid)
returns numeric language plpgsql security definer set search_path = public as $$
declare b record; v_left numeric := p_qty; v_take numeric; v_today date := (now() at time zone 'Africa/Cairo')::date;
begin
  for b in
    select id, quantity from stock_batches
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
    v_left := v_left - v_take;
  end loop;
  return greatest(v_left, 0);
end $$;

-- Transfer: FEFO out of the source, same expiry (and source invoice) into the destination.
create or replace function _batch_move(p_org uuid, p_product uuid, p_from uuid, p_to uuid, p_qty numeric)
returns void language plpgsql security definer set search_path = public as $$
declare b record; v_left numeric := p_qty; v_take numeric;
begin
  for b in
    select id, quantity, expiry_date, purchase_invoice_id from stock_batches
    where organization_id = p_org and product_id = p_product and warehouse_id = p_from
    order by expiry_date nulls last, created_at, id
    for update
  loop
    exit when v_left <= 0;
    v_take := least(b.quantity, v_left);
    if v_take >= b.quantity then delete from stock_batches where id = b.id;
    else update stock_batches set quantity = quantity - v_take where id = b.id; end if;
    perform _batch_add(p_org, p_product, p_to, v_take, b.expiry_date, b.purchase_invoice_id);
    v_left := v_left - v_take;
  end loop;
  if v_left > 0 then perform _batch_add(p_org, p_product, p_to, v_left, null, null); end if;
end $$;

-- ============================================================
-- 3. The trigger: every change of inventory_stock.quantity is mirrored in the batches
-- ============================================================
create or replace function _stock_batches_sync() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_delta numeric; v_expiry date; v_ref uuid; v_prefer uuid;
begin
  if coalesce(current_setting('kayan.batch_skip', true), '') = '1' then return new; end if;
  v_delta := new.quantity - (case when tg_op = 'UPDATE' then old.quantity else 0 end);
  if v_delta = 0 then return new; end if;

  if v_delta > 0 then
    v_expiry := nullif(current_setting('kayan.batch_expiry', true), '')::date;
    v_ref    := nullif(current_setting('kayan.batch_ref', true), '')::uuid;
    perform _batch_add(new.organization_id, new.product_id, new.warehouse_id, v_delta, v_expiry, v_ref);
  else
    v_prefer := nullif(current_setting('kayan.batch_prefer', true), '')::uuid;
    perform _batch_take(new.organization_id, new.product_id, new.warehouse_id, -v_delta,
                        coalesce(current_setting('kayan.batch_sale', true), '') = '1', v_prefer);
  end if;
  return new;
end $$;

drop trigger if exists inventory_stock_batches on inventory_stock;
create trigger inventory_stock_batches
  after insert or update of quantity on inventory_stock
  for each row execute function _stock_batches_sync();

-- ============================================================
-- 4. Backfill — idempotent: tops each stock row up to its quantity with an undated batch
-- ============================================================
create or replace function _backfill_stock_batches() returns integer
language plpgsql security definer set search_path = public as $$
declare r record; n integer := 0;
begin
  for r in
    select s.organization_id, s.product_id, s.warehouse_id, s.quantity - coalesce(sum(b.quantity), 0) as missing
    from inventory_stock s
    left join stock_batches b on b.product_id = s.product_id and b.warehouse_id = s.warehouse_id
    where s.quantity > 0
    group by s.organization_id, s.product_id, s.warehouse_id, s.quantity
    having s.quantity - coalesce(sum(b.quantity), 0) > 0
  loop
    perform _batch_add(r.organization_id, r.product_id, r.warehouse_id, r.missing, null, null);
    n := n + 1;
  end loop;
  return n;
end $$;


-- ============================================================
-- 5. Stock-changing functions, patched to pass batch context to the trigger
--    (each is the previous definition with only the marked lines added)
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
    update inventory_stock set quantity = v_old_qty - p_qty, updated_at = now() where product_id = p_product and warehouse_id = p_wh;
    perform set_config('kayan.batch_sale', '', true);
    insert into inventory_movements (organization_id, product_id, warehouse_id, movement_type, quantity_delta, unit_cost, reference_type, reference_id, created_by)
    values (org_id, p_product, p_wh, 'sale', -p_qty, v_cost, 'sales_invoice', p_ref, auth.uid());
  else
    select coalesce(pc.cost, 0) into v_cost from product_costs pc where pc.product_id = p_product limit 1;
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
  select s.quantity, coalesce(sc.avg_cost, 0) into v_old_qty, v_old_avg
  from inventory_stock s left join stock_costs sc on sc.stock_id = s.id
  where s.product_id = p_product and s.warehouse_id = p_wh for update of s;
  if not found then
    v_old_qty := 0; v_old_avg := 0;
    insert into inventory_stock (organization_id, product_id, warehouse_id, quantity) values (org_id, p_product, p_wh, 0);
  end if;
  v_new_qty := v_old_qty + p_qty;
  v_new_avg := case when greatest(v_old_qty, 0) + p_qty = 0 then v_old_avg
                    else ((greatest(v_old_qty, 0) * v_old_avg) + (p_qty * p_unit_cost)) / (greatest(v_old_qty, 0) + p_qty) end;
  perform set_config('kayan.batch_ref', coalesce(p_ref::text, ''), true);   -- [batches] expiry was set by the caller
  update inventory_stock set quantity = v_new_qty, updated_at = now() where product_id = p_product and warehouse_id = p_wh;
  perform set_config('kayan.batch_ref', '', true);
  perform set_config('kayan.batch_expiry', '', true);
  insert into stock_costs (stock_id, avg_cost)
  select id, v_new_avg from inventory_stock where product_id = p_product and warehouse_id = p_wh
  on conflict (stock_id) do update set avg_cost = excluded.avg_cost, updated_at = now();
  insert into inventory_movements (organization_id, product_id, warehouse_id, movement_type, quantity_delta, unit_cost, reference_type, reference_id, created_by)
  values (org_id, p_product, p_wh, 'purchase', p_qty, p_unit_cost, 'purchase_invoice', p_ref, auth.uid());
  insert into product_costs (product_id, cost)
  select id, v_new_avg from products where id = p_product and organization_id = org_id
  on conflict (product_id) do update set cost = excluded.cost, updated_at = now();
end $function$;

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
  v_bonus_units numeric(14,3) := 0; v_paid numeric(14,2); v_status text; v_expiry date;
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
    -- [batches] optional expiry date for this line's batch
    begin
      v_expiry := nullif(btrim(coalesce(e->>'expiry_date', '')), '')::date;
    exception when others then
      raise exception 'تاريخ الصلاحية غير صحيح';
    end;
    if v_expiry is not null and (v_expiry < date '2000-01-01' or v_expiry > date '2100-12-31') then
      raise exception 'تاريخ الصلاحية غير صحيح';
    end if;
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

    perform set_config('kayan.batch_expiry', coalesce(v_expiry::text, ''), true);   -- [batches]
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
      select s.quantity, coalesce(sc.avg_cost, 0) into v_current_qty, v_current_avg
      from inventory_stock s left join stock_costs sc on sc.stock_id = s.id
      where s.product_id = v_orig.product_id and s.warehouse_id = v_warehouse_id for update of s;
      if not found or coalesce(v_current_qty, 0) < v_quantity then
        raise exception 'الكمية المتاحة بالمخزون أقل من كمية المرتجع لهذا الصنف';
      end if;
      -- the returned units leave the weighted-average pool at the value they entered with
      perform set_config('kayan.batch_prefer', p_purchase_invoice_id::text, true);   -- [batches]
      update inventory_stock set quantity = quantity - v_quantity, updated_at = now()
      where product_id = v_orig.product_id and warehouse_id = v_warehouse_id;
      perform set_config('kayan.batch_prefer', '', true);
      insert into stock_costs (stock_id, avg_cost)
      select id, case when (v_current_qty - v_quantity) > 0
                      then greatest((v_current_qty * v_current_avg) - v_line_total, 0) / (v_current_qty - v_quantity)
                      else v_current_avg end
      from inventory_stock where product_id = v_orig.product_id and warehouse_id = v_warehouse_id
      on conflict (stock_id) do update set avg_cost = excluded.avg_cost, updated_at = now();
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

    select s.quantity, coalesce(sc.avg_cost, 0) into v_source_qty, v_source_avg
    from inventory_stock s left join stock_costs sc on sc.stock_id = s.id
    where s.product_id = v_product_id and s.warehouse_id = p_from_warehouse_id and s.organization_id = org_id
    for update of s;

    if not found or coalesce(v_source_qty, 0) < v_quantity then
      raise exception 'الكمية المتاحة بمخزن المصدر أقل من كمية النقل لهذا الصنف';
    end if;

    perform set_config('kayan.batch_skip', '1', true);   -- [batches] the transfer moves batches itself
    update inventory_stock
    set quantity = quantity - v_quantity, updated_at = now()
    where product_id = v_product_id and warehouse_id = p_from_warehouse_id and organization_id = org_id;

    select s.quantity, coalesce(sc.avg_cost, 0) into v_dest_qty, v_dest_avg
    from inventory_stock s left join stock_costs sc on sc.stock_id = s.id
    where s.product_id = v_product_id and s.warehouse_id = p_to_warehouse_id and s.organization_id = org_id
    for update of s;

    if not found then
      v_dest_qty := 0;
      v_dest_avg := 0;
      insert into inventory_stock (organization_id, product_id, warehouse_id, quantity)
      values (org_id, v_product_id, p_to_warehouse_id, 0);
    end if;

    -- Weighted-average blend at the destination (§21), same formula a
    -- purchase uses — the transferred stock brings its cost basis with it.
    if v_dest_qty + v_quantity > 0 then
      v_new_dest_avg := round(((v_dest_qty * v_dest_avg) + (v_quantity * v_source_avg)) / (v_dest_qty + v_quantity), 6);
    else
      v_new_dest_avg := v_source_avg;
    end if;

    update inventory_stock
    set quantity = v_dest_qty + v_quantity, updated_at = now()
    where product_id = v_product_id and warehouse_id = p_to_warehouse_id and organization_id = org_id;
    perform _batch_move(org_id, v_product_id, p_from_warehouse_id, p_to_warehouse_id, v_quantity);   -- [batches]
    insert into stock_costs (stock_id, avg_cost)
    select id, v_new_dest_avg from inventory_stock
    where product_id = v_product_id and warehouse_id = p_to_warehouse_id and organization_id = org_id
    on conflict (stock_id) do update set avg_cost = excluded.avg_cost, updated_at = now();

    insert into inventory_movements (organization_id, product_id, warehouse_id, movement_type, quantity_delta, unit_cost, reference_type, reference_id, created_by)
    values (org_id, v_product_id, p_from_warehouse_id, 'transfer_out', -v_quantity, v_source_avg, 'stock_transfer', new_transfer_id, auth.uid());
    insert into inventory_movements (organization_id, product_id, warehouse_id, movement_type, quantity_delta, unit_cost, reference_type, reference_id, created_by)
    values (org_id, v_product_id, p_to_warehouse_id, 'transfer_in', v_quantity, v_source_avg, 'stock_transfer', new_transfer_id, auth.uid());

    v_line_total := v_quantity * v_source_avg;
    insert into stock_transfer_items (organization_id, stock_transfer_id, product_id, quantity, unit_cost, line_total)
    values (org_id, new_transfer_id, v_product_id, v_quantity, v_source_avg, v_line_total);

    v_total := v_total + v_line_total;
    perform set_config('kayan.batch_skip', '', true);   -- [batches]
  end loop;

  update stock_transfers set total_value = v_total where id = new_transfer_id;

  return new_transfer_id;
end;
$function$;

drop function if exists adjust_inventory_stock(uuid, uuid, uuid, numeric, text);

CREATE OR REPLACE FUNCTION public.adjust_inventory_stock(org_id uuid, p_product_id uuid, p_warehouse_id uuid, p_quantity_delta numeric, p_reason text, p_expiry_date date DEFAULT NULL::date)
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
  -- [batches] an expiry date only makes sense on an increase (it creates a batch)
  if p_expiry_date is not null then
    if p_quantity_delta < 0 then raise exception 'تاريخ الصلاحية يُسجَّل مع الزيادة فقط'; end if;
    if p_expiry_date < date '2000-01-01' or p_expiry_date > date '2100-12-31' then raise exception 'تاريخ الصلاحية غير صحيح'; end if;
  end if;

  select s.quantity, coalesce(sc.avg_cost, 0) into v_old_qty, v_avg
  from inventory_stock s left join stock_costs sc on sc.stock_id = s.id
  where s.product_id = p_product_id and s.warehouse_id = p_warehouse_id and s.organization_id = org_id
  for update of s;

  if not found then
    v_old_qty := 0;
    v_avg := 0;
    insert into inventory_stock (organization_id, product_id, warehouse_id, quantity)
    values (org_id, p_product_id, p_warehouse_id, 0);
  end if;

  if v_old_qty + p_quantity_delta < 0 then
    raise exception 'لا يمكن أن يصبح رصيد المخزون سالبًا بسبب التسوية';
  end if;

  perform set_config('kayan.batch_expiry', coalesce(p_expiry_date::text, ''), true);   -- [batches]
  update inventory_stock
  set quantity = v_old_qty + p_quantity_delta, updated_at = now()
  where product_id = p_product_id and warehouse_id = p_warehouse_id and organization_id = org_id;
  perform set_config('kayan.batch_expiry', '', true);

  insert into inventory_movements (organization_id, product_id, warehouse_id, movement_type, quantity_delta, unit_cost, reference_type, note, created_by)
  values (org_id, p_product_id, p_warehouse_id, 'adjustment', p_quantity_delta, v_avg, 'manual_adjustment', trim(p_reason), auth.uid())
  returning id into v_movement_id;

  return v_movement_id;
end;
$function$;

revoke all on function adjust_inventory_stock(uuid, uuid, uuid, numeric, text, date) from public, anon;
grant execute on function adjust_inventory_stock(uuid, uuid, uuid, numeric, text, date) to authenticated;


-- ============================================================
-- 6. تقرير المنتجات وصلاحيتها
-- ============================================================
-- One row per batch. status: expired | expiring (expires within p_days) | ok | no_expiry.
-- p_status filters on exactly that value. Sorted by expiry (soonest first), undated last.
create or replace function report_expiry(
  org_id uuid, p_warehouse uuid default null, p_status text default null,
  p_days int default 90, p_limit int default 500, p_offset int default 0
)
returns table (
  batch_id uuid, product_id uuid, product_name text, sku text, barcode text, unit text,
  warehouse_id uuid, warehouse_name text,
  expiry_date date, quantity numeric, days_to_expiry integer, status text, total_count bigint
)
language plpgsql stable set search_path = public as $$
declare
  v_days  int := least(greatest(coalesce(p_days, 90), 1), 3650);
  v_limit int := least(greatest(coalesce(p_limit, 500), 1), 2000);
  v_off   int := greatest(coalesce(p_offset, 0), 0);
  v_today date := cairo_today();
begin
  perform assert_report_access(org_id, false);
  return query
  with x as (
    select b.id as bid, p.id as pid, p.name as pname, p.sku as psku, p.barcode as pbarcode, p.unit as punit,
           w.id as wid, w.name as wname, b.expiry_date as exp, b.quantity::numeric as qty,
           (b.expiry_date - v_today)::integer as days,
           (case when b.expiry_date is null then 'no_expiry'
                 when b.expiry_date < v_today then 'expired'
                 when b.expiry_date <= v_today + v_days then 'expiring'
                 else 'ok' end)::text as st
    from stock_batches b
    join products p on p.id = b.product_id
    join warehouses w on w.id = b.warehouse_id
    where b.organization_id = org_id
      and (p_warehouse is null or b.warehouse_id = p_warehouse)
  )
  select x.bid, x.pid, x.pname, x.psku, x.pbarcode, x.punit, x.wid, x.wname, x.exp, x.qty, x.days, x.st,
         count(*) over ()
  from x
  where p_status is null or p_status = '' or x.st = p_status
  order by x.exp nulls last, x.pname, x.bid
  limit v_limit offset v_off;
end $$;

-- Totals per status for the summary cards (quantities and batch counts).
create or replace function report_expiry_summary(org_id uuid, p_warehouse uuid default null, p_days int default 90)
returns jsonb
language plpgsql stable set search_path = public as $$
declare
  v_days int := least(greatest(coalesce(p_days, 90), 1), 3650);
  v_today date := cairo_today();
  r jsonb;
begin
  perform assert_report_access(org_id, false);
  select jsonb_build_object(
    'expired',   jsonb_build_object('batches', count(*) filter (where b.expiry_date < v_today),
                                    'quantity', coalesce(sum(b.quantity) filter (where b.expiry_date < v_today), 0)),
    'expiring',  jsonb_build_object('batches', count(*) filter (where b.expiry_date >= v_today and b.expiry_date <= v_today + v_days),
                                    'quantity', coalesce(sum(b.quantity) filter (where b.expiry_date >= v_today and b.expiry_date <= v_today + v_days), 0)),
    'ok',        jsonb_build_object('batches', count(*) filter (where b.expiry_date > v_today + v_days),
                                    'quantity', coalesce(sum(b.quantity) filter (where b.expiry_date > v_today + v_days), 0)),
    'no_expiry', jsonb_build_object('batches', count(*) filter (where b.expiry_date is null),
                                    'quantity', coalesce(sum(b.quantity) filter (where b.expiry_date is null), 0)))
  into r
  from stock_batches b
  where b.organization_id = org_id and (p_warehouse is null or b.warehouse_id = p_warehouse);
  return r;
end $$;

grant execute on function report_expiry(uuid, uuid, text, int, int, int) to authenticated;
grant execute on function report_expiry_summary(uuid, uuid, int) to authenticated;

-- ============================================================
-- 7. Backfill existing stock as undated batches
-- ============================================================
select _backfill_stock_batches();

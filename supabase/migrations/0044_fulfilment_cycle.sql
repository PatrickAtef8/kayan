-- Kayan — Phase 44: stock moves when the STOREKEEPER confirms (dispatch for sales, receiving for purchases)
-- Depends on 0043. Re-runnable.  TAKE A DATABASE BACKUP FIRST.
--
-- WHAT CHANGES
--   Posting an invoice no longer moves stock.  It
--     * sales:     RESERVES the units (available = on hand − reserved, so the same units can never be sold twice),
--     * purchases: records the EXPECTED units, their net unit cost and expiry.
--   Money is untouched: totals, balances, COGS, profit, commission, the supplier payable are computed at
--   posting exactly as before (the cost used for COGS is the weighted-average cost at posting, as before).
--   Stock (inventory_stock, batches/expiry, inventory_movements, weighted-average cost) changes ONLY when the
--   storekeeper confirms, with the quantity he actually handled.  Partial confirmations are allowed; the
--   remainder stays open.  Excess is refused.  A confirmation can never be repeated: each line only has its
--   open quantity left to confirm, and the invoice row is locked while confirming.
--
-- WHAT DOES NOT CHANGE
--   * Stock that exists today stays exactly as it is, and every invoice that exists today counts as already
--     dispatched/received (a constant column default is stored virtually — no existing row is rewritten).
--   * Returns:  units that never left (sales) / never arrived (purchases) are first RELEASED from the open
--     quantity (no stock movement at all); only the remainder moves physical stock, as before.
--   * Reports: the financial position / summary value stock as  on-hand − sold-not-dispatched + bought-not-received,
--     so goods in transit are neither lost from nor double-counted in the books.

-- ============================================================
-- 1. Status columns
-- ============================================================
alter table sales_invoices
  add column if not exists dispatch_status text not null default 'dispatched',
  add column if not exists dispatched_at timestamptz,
  add column if not exists dispatched_by uuid references auth.users(id);
alter table sales_invoices drop constraint if exists sales_invoices_dispatch_status_chk;
alter table sales_invoices add constraint sales_invoices_dispatch_status_chk check (dispatch_status in ('pending', 'partial', 'dispatched', 'cancelled'));
alter table sales_invoices alter column dispatch_status set default 'pending';

alter table purchase_invoices
  add column if not exists receipt_status text not null default 'received',
  add column if not exists received_at timestamptz,
  add column if not exists received_by uuid references auth.users(id);
alter table purchase_invoices drop constraint if exists purchase_invoices_receipt_status_chk;
alter table purchase_invoices add constraint purchase_invoices_receipt_status_chk check (receipt_status in ('pending', 'partial', 'received', 'cancelled'));
alter table purchase_invoices alter column receipt_status set default 'pending';

create index if not exists sales_invoices_dispatch_open_idx on sales_invoices (organization_id, created_at) where dispatch_status in ('pending', 'partial');
create index if not exists purchase_invoices_receipt_open_idx on purchase_invoices (organization_id, created_at) where receipt_status in ('pending', 'partial');

-- ============================================================
-- 2. The work lines: one row per invoice line that needs a physical movement
--    open = ordered − fulfilled − cancelled.  Sales: open units are the reservation.
--    Purchases: open units are goods bought but not yet received.
-- ============================================================
create table if not exists invoice_stock_lines (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  kind            text not null check (kind in ('sales', 'purchase')),
  invoice_id      uuid not null,
  product_id      uuid not null references products(id),
  warehouse_id    uuid not null references warehouses(id),
  ordered_units   numeric(14,3) not null check (ordered_units > 0 and ordered_units <> 'NaN'::numeric),
  fulfilled_units numeric(14,3) not null default 0 check (fulfilled_units >= 0 and fulfilled_units <> 'NaN'::numeric),
  cancelled_units numeric(14,3) not null default 0 check (cancelled_units >= 0 and cancelled_units <> 'NaN'::numeric),
  unit_cost       numeric(14,6) check (unit_cost is null or unit_cost <> 'NaN'::numeric),   -- purchases: net cost per unit
  expiry_date     date,                                                                    -- purchases
  created_at      timestamptz not null default now(),
  seq             bigint generated always as identity,
  check (fulfilled_units + cancelled_units <= ordered_units)
);
create index if not exists invoice_stock_lines_invoice_idx on invoice_stock_lines (kind, invoice_id);
create index if not exists invoice_stock_lines_open_idx on invoice_stock_lines (organization_id, kind, product_id, warehouse_id)
  where ordered_units > fulfilled_units + cancelled_units;

create table if not exists fulfilment_events (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  kind            text not null check (kind in ('sales', 'purchase')),
  invoice_id      uuid not null,
  line_id         uuid not null references invoice_stock_lines(id),
  product_id      uuid not null references products(id),
  event_type      text not null check (event_type in ('confirm', 'release')),   -- confirm = storekeeper moved stock; release = a return cancelled the open units
  quantity        numeric(14,3) not null check (quantity > 0),
  confirmed_by    uuid references auth.users(id),
  confirmed_at    timestamptz not null default now(),
  confirmation_id uuid not null,
  note            text
);
create index if not exists fulfilment_events_invoice_idx on fulfilment_events (kind, invoice_id, confirmed_at);

-- Nobody reads or writes these tables directly: every access goes through the definer functions below.
alter table invoice_stock_lines enable row level security;
alter table invoice_stock_lines force row level security;
alter table fulfilment_events enable row level security;
alter table fulfilment_events force row level security;
revoke all on invoice_stock_lines, fulfilment_events from public, anon, authenticated;

-- ============================================================
-- 3. Internal helpers
-- ============================================================
create or replace function _stock_reserved(p_org uuid, p_product uuid, p_wh uuid) returns numeric
language sql security definer stable set search_path = public as $$
  select coalesce(sum(ordered_units - fulfilled_units - cancelled_units), 0)
  from invoice_stock_lines
  where organization_id = p_org and kind = 'sales' and product_id = p_product and warehouse_id = p_wh
    and ordered_units > fulfilled_units + cancelled_units
$$;

-- keeps the invoice header in step with its lines
create or replace function _fulfil_refresh(p_kind text, p_invoice uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_ord numeric; v_ful numeric; v_can numeric; v_status text;
begin
  select coalesce(sum(ordered_units), 0), coalesce(sum(fulfilled_units), 0), coalesce(sum(cancelled_units), 0)
  into v_ord, v_ful, v_can from invoice_stock_lines where kind = p_kind and invoice_id = p_invoice;
  if v_ord = 0 then return; end if;
  if p_kind = 'sales' then
    v_status := case when v_ord - v_ful - v_can <= 0 then (case when v_ful > 0 then 'dispatched' else 'cancelled' end)
                     when v_ful > 0 then 'partial' else 'pending' end;
    update sales_invoices set dispatch_status = v_status,
      dispatched_at = case when v_status = 'dispatched' then coalesce(dispatched_at, now()) else dispatched_at end,
      dispatched_by = case when v_status = 'dispatched' then coalesce(dispatched_by, auth.uid()) else dispatched_by end
    where id = p_invoice;
  else
    v_status := case when v_ord - v_ful - v_can <= 0 then (case when v_ful > 0 then 'received' else 'cancelled' end)
                     when v_ful > 0 then 'partial' else 'pending' end;
    update purchase_invoices set receipt_status = v_status,
      received_at = case when v_status = 'received' then coalesce(received_at, now()) else received_at end,
      received_by = case when v_status = 'received' then coalesce(received_by, auth.uid()) else received_by end
    where id = p_invoice;
  end if;
end $$;

-- A return releases the units that never moved (oldest open line first). Returns how many were released.
create or replace function _fulfil_cancel(p_kind text, p_org uuid, p_invoice uuid, p_product uuid, p_qty numeric) returns numeric
language plpgsql security definer set search_path = public as $$
declare l record; v_left numeric := p_qty; v_take numeric; v_done numeric := 0; v_conf uuid := gen_random_uuid();
begin
  if p_qty is null or p_qty <= 0 then return 0; end if;
  for l in
    select id, ordered_units - fulfilled_units - cancelled_units as open_units from invoice_stock_lines
    where organization_id = p_org and kind = p_kind and invoice_id = p_invoice and product_id = p_product
      and ordered_units > fulfilled_units + cancelled_units
    order by seq for update
  loop
    exit when v_left <= 0;
    v_take := least(l.open_units, v_left);
    update invoice_stock_lines set cancelled_units = cancelled_units + v_take where id = l.id;
    insert into fulfilment_events (organization_id, kind, invoice_id, line_id, product_id, event_type, quantity, confirmed_by, confirmation_id, note)
    values (p_org, p_kind, p_invoice, l.id, p_product, 'release', v_take, auth.uid(), v_conf, 'مرتجع على كمية لم تُصرف/تُستلم بعد');
    v_left := v_left - v_take; v_done := v_done + v_take;
  end loop;
  if v_done > 0 then perform _fulfil_refresh(p_kind, p_invoice); end if;
  return v_done;
end $$;

-- value of goods owned but not on the shelf (bought, not received) minus goods sold but still on the shelf
create or replace function _stock_value_pending(p_org uuid) returns numeric
language sql security definer stable set search_path = public as $$
  select coalesce((select sum((ordered_units - fulfilled_units - cancelled_units) * coalesce(unit_cost, 0))
                   from invoice_stock_lines where organization_id = p_org and kind = 'purchase'
                     and ordered_units > fulfilled_units + cancelled_units), 0)
       - coalesce((select sum((l.ordered_units - l.fulfilled_units - l.cancelled_units) * coalesce(sc.avg_cost, 0))
                   from invoice_stock_lines l
                   left join inventory_stock s on s.product_id = l.product_id and s.warehouse_id = l.warehouse_id
                   left join stock_costs sc on sc.stock_id = s.id
                   where l.organization_id = p_org and l.kind = 'sales'
                     and l.ordered_units > l.fulfilled_units + l.cancelled_units), 0)
$$;

revoke all on function _stock_reserved(uuid, uuid, uuid), _fulfil_refresh(text, uuid), _fulfil_cancel(text, uuid, uuid, uuid, numeric),
                       _stock_value_pending(uuid) from public, anon, authenticated;

-- ============================================================
-- 4. Posting an invoice now reserves / expects instead of moving stock
--    (the old bodies live on as *_core and are what a confirmation runs)
-- ============================================================
do $$ begin
  if not exists (select 1 from pg_proc where proname = '_consume_stock_core' and pronamespace = 'public'::regnamespace) then
    alter function _consume_stock(uuid, uuid, uuid, numeric, uuid) rename to _consume_stock_core;
  end if;
  if not exists (select 1 from pg_proc where proname = '_receive_stock_core' and pronamespace = 'public'::regnamespace) then
    alter function _receive_stock(uuid, uuid, uuid, numeric, numeric, uuid) rename to _receive_stock_core;
  end if;
end $$;

create or replace function _consume_stock(org_id uuid, p_product uuid, p_wh uuid, p_qty numeric, p_ref uuid)
returns numeric language plpgsql security definer set search_path = public as $$
declare v_track boolean; v_old_qty numeric(14,3); v_old_avg numeric(14,6); v_cost numeric(14,6); v_expired numeric(14,3); v_reserved numeric(14,3);
begin
  select track_inventory into v_track from products where id = p_product and organization_id = org_id;
  if not found then raise exception 'أحد المنتجات المختارة لا ينتمي إلى هذه المؤسسة'; end if;
  if v_track then
    select s.quantity, coalesce(sc.avg_cost, 0) into v_old_qty, v_old_avg
    from inventory_stock s left join stock_costs sc on sc.stock_id = s.id
    where s.product_id = p_product and s.warehouse_id = p_wh for update of s;     -- serialises every sale of this product/warehouse
    if not found then
      v_old_qty := 0; v_old_avg := 0;
      insert into inventory_stock (organization_id, product_id, warehouse_id, quantity) values (org_id, p_product, p_wh, 0);
    end if;
    v_reserved := _stock_reserved(org_id, p_product, p_wh);
    if v_old_qty - v_reserved < p_qty then
      raise exception 'الكمية المتاحة بالمخزون أقل من الكمية المطلوبة (المتاح: %، منها محجوز لفواتير لم تُصرف: %)', greatest(v_old_qty - v_reserved, 0), v_reserved;
    end if;
    select coalesce(sum(quantity), 0) into v_expired from stock_batches
    where organization_id = org_id and product_id = p_product and warehouse_id = p_wh and expiry_date < cairo_today();
    if v_old_qty - v_reserved - v_expired < p_qty then
      raise exception 'لا يمكن بيع بضاعة منتهية الصلاحية — المتاح للبيع (غير المنتهي): %، المنتهي الصلاحية في المخزن: %', greatest(v_old_qty - v_reserved - v_expired, 0), v_expired;
    end if;
    v_cost := v_old_avg;
    insert into invoice_stock_lines (organization_id, kind, invoice_id, product_id, warehouse_id, ordered_units)
    values (org_id, 'sales', p_ref, p_product, p_wh, p_qty);
  else
    select coalesce(pc.cost, 0) into v_cost from product_costs pc where pc.product_id = p_product limit 1;
    v_cost := coalesce(v_cost, 0);
  end if;
  return v_cost;
end $$;

create or replace function _receive_stock(org_id uuid, p_product uuid, p_wh uuid, p_qty numeric, p_unit_cost numeric, p_ref uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_exp date;
begin
  v_exp := nullif(current_setting('kayan.batch_expiry', true), '')::date;   -- set by create_purchase_invoice for this line
  perform set_config('kayan.batch_expiry', '', true);
  insert into invoice_stock_lines (organization_id, kind, invoice_id, product_id, warehouse_id, ordered_units, unit_cost, expiry_date)
  values (org_id, 'purchase', p_ref, p_product, p_wh, p_qty, p_unit_cost, v_exp);
end $$;

revoke all on function _consume_stock(uuid, uuid, uuid, numeric, uuid), _receive_stock(uuid, uuid, uuid, numeric, numeric, uuid),
                       _consume_stock_core(uuid, uuid, uuid, numeric, uuid), _receive_stock_core(uuid, uuid, uuid, numeric, numeric, uuid)
  from public, anon, authenticated;

-- an invoice with nothing to move (services / untracked products) is complete at once
create or replace function _fulfil_init() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if TG_TABLE_NAME = 'sales_invoices' then
    if not exists (select 1 from invoice_stock_lines where kind = 'sales' and invoice_id = NEW.id) then
      update sales_invoices set dispatch_status = 'dispatched', dispatched_at = now() where id = NEW.id and dispatch_status = 'pending';
    end if;
  else
    if not exists (select 1 from invoice_stock_lines where kind = 'purchase' and invoice_id = NEW.id) then
      update purchase_invoices set receipt_status = 'received', received_at = now() where id = NEW.id and receipt_status = 'pending';
    end if;
  end if;
  return NEW;
end $$;
revoke all on function _fulfil_init() from public, anon, authenticated;
drop trigger if exists z_fulfil_init on sales_invoices;
create constraint trigger z_fulfil_init after insert on sales_invoices deferrable initially deferred for each row execute function _fulfil_init();
drop trigger if exists z_fulfil_init on purchase_invoices;
create constraint trigger z_fulfil_init after insert on purchase_invoices deferrable initially deferred for each row execute function _fulfil_init();

-- ============================================================
-- 5. Returns: release what never moved, move only the rest
--    (bodies are the live definitions with ONLY the marked changes)
-- ============================================================

CREATE OR REPLACE FUNCTION public.create_sales_return(org_id uuid, p_sales_invoice_id uuid, p_return_date date, items jsonb, p_cash_refund numeric DEFAULT 0, p_notes text DEFAULT NULL::text, p_full_return boolean DEFAULT false, p_condition text DEFAULT 'resalable'::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_cancel numeric(14,3); v_phys numeric(14,3);
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
    -- [fulfilment] units that were never dispatched are released from the reservation; only the rest moves stock
    v_cancel := _fulfil_cancel('sales', org_id, p_sales_invoice_id, v_orig.product_id, v_quantity);
    v_phys := v_quantity - v_cancel;

    if v_condition = 'resalable' and v_phys > 0 then
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
        set quantity = v_old_qty + v_phys, updated_at = now()
        where product_id = v_orig.product_id and warehouse_id = v_warehouse_id;
        perform set_config('kayan.batch_return', '', true);
        insert into stock_costs (stock_id, avg_cost)
        select id, case when (v_old_qty + v_phys) > 0
                        then ((greatest(v_old_qty, 0) * v_old_avg) + (v_cost * v_phys / v_quantity)) / (greatest(v_old_qty, 0) + v_phys) else v_old_avg end
        from inventory_stock where product_id = v_orig.product_id and warehouse_id = v_warehouse_id
        on conflict (stock_id) do update set avg_cost = excluded.avg_cost, updated_at = now();
        insert into inventory_movements (organization_id, product_id, warehouse_id, movement_type, quantity_delta, unit_cost, reference_type, reference_id, created_by)
        values (org_id, v_orig.product_id, v_warehouse_id, 'sale_return', v_phys, v_cost / v_quantity, 'sales_return', new_return_id, auth.uid());
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
end $function$
;

CREATE OR REPLACE FUNCTION public.create_purchase_return(org_id uuid, p_purchase_invoice_id uuid, p_return_date date, items jsonb, p_cash_refund numeric DEFAULT 0, p_notes text DEFAULT NULL::text, p_full_return boolean DEFAULT false)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_cancel numeric(14,3); v_phys numeric(14,3);
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

    -- [fulfilment] units that never arrived are released from the expected receipt; only the rest leaves stock
    v_cancel := _fulfil_cancel('purchase', org_id, p_purchase_invoice_id, v_orig.product_id, v_quantity);
    v_phys := v_quantity - v_cancel;
    select track_inventory into v_track from products where id = v_orig.product_id and organization_id = org_id;
    if v_track and v_phys > 0 then
      select s.quantity, coalesce(sc.avg_cost, 0) into v_current_qty, v_current_avg
      from inventory_stock s left join stock_costs sc on sc.stock_id = s.id
      where s.product_id = v_orig.product_id and s.warehouse_id = v_warehouse_id for update of s;
      if not found or coalesce(v_current_qty, 0) - _stock_reserved(org_id, v_orig.product_id, v_warehouse_id) < v_phys then
        raise exception 'الكمية المتاحة بالمخزون أقل من كمية المرتجع لهذا الصنف';
      end if;
      -- the returned units leave the weighted-average pool at the value they entered with
      perform set_config('kayan.batch_prefer', p_purchase_invoice_id::text, true);   -- [batches]
      update inventory_stock set quantity = quantity - v_phys, updated_at = now()
      where product_id = v_orig.product_id and warehouse_id = v_warehouse_id;
      perform set_config('kayan.batch_prefer', '', true);
      insert into stock_costs (stock_id, avg_cost)
      select id, case when (v_current_qty - v_phys) > 0
                      then greatest((v_current_qty * v_current_avg) - (v_line_total * v_phys / v_quantity), 0) / (v_current_qty - v_phys)
                      else v_current_avg end
      from inventory_stock where product_id = v_orig.product_id and warehouse_id = v_warehouse_id
      on conflict (stock_id) do update set avg_cost = excluded.avg_cost, updated_at = now();
      insert into inventory_movements (organization_id, product_id, warehouse_id, movement_type, quantity_delta, unit_cost, reference_type, reference_id, created_by)
      values (org_id, v_orig.product_id, v_warehouse_id, 'purchase_return', -v_phys, v_orig.effective_unit_cost, 'purchase_return', new_return_id, auth.uid());
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
end $function$
;

-- ============================================================
-- 6. Nothing else may take stock that is already promised to a sale
-- ============================================================

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

    if not found or coalesce(v_source_qty, 0) - _stock_reserved(org_id, v_product_id, p_from_warehouse_id) < v_quantity then
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
$function$
;

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
  if p_quantity_delta < 0 and v_old_qty + p_quantity_delta < _stock_reserved(org_id, p_product_id, p_warehouse_id) then
    raise exception 'الرصيد بعد التسوية أقل من الكميات المحجوزة لفواتير بيع لم تُصرف بعد (المحجوز: %)', _stock_reserved(org_id, p_product_id, p_warehouse_id);
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
$function$
;

CREATE OR REPLACE FUNCTION public.dispose_stock_batch(org_id uuid, p_batch_id uuid, p_quantity numeric, p_reason text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  if v_stock.quantity - p_quantity < _stock_reserved(org_id, v_batch.product_id, v_batch.warehouse_id) then
    raise exception 'الكمية المتبقية بعد الإعدام أقل من المحجوز لفواتير بيع لم تُصرف بعد';
  end if;

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
end $function$
;

-- ============================================================
-- 7. Books: stock is valued as  on hand − sold-not-dispatched + bought-not-received
-- ============================================================
create or replace function _stock_value_pending(p_org uuid) returns numeric
language plpgsql security definer stable set search_path = public as $$
begin
  if auth.uid() is null or not has_permission(p_org, 'view_financial') then return 0; end if;
  return coalesce((select sum((ordered_units - fulfilled_units - cancelled_units) * coalesce(unit_cost, 0))
                   from invoice_stock_lines where organization_id = p_org and kind = 'purchase'
                     and ordered_units > fulfilled_units + cancelled_units), 0)
       - coalesce((select sum((l.ordered_units - l.cancelled_units - l.fulfilled_units) * coalesce(sc.avg_cost, 0))
                   from invoice_stock_lines l
                   left join inventory_stock s on s.product_id = l.product_id and s.warehouse_id = l.warehouse_id
                   left join stock_costs sc on sc.stock_id = s.id
                   where l.organization_id = p_org and l.kind = 'sales'
                     and l.ordered_units > l.fulfilled_units + l.cancelled_units), 0);
end $$;
revoke all on function _stock_value_pending(uuid) from public, anon;
grant execute on function _stock_value_pending(uuid) to authenticated;


CREATE OR REPLACE FUNCTION public.report_financial_position(org_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
declare
  v_inventory numeric;
  v_negative int;
  v_receivables numeric;
  v_cash numeric;
  v_payables numeric;
  v_other_assets numeric;
  v_other_liabilities numeric;
  v_items jsonb;
begin
  perform assert_report_access(org_id, true);

  select coalesce(sum(s.quantity * coalesce(sc.avg_cost, 0)), 0) + _stock_value_pending(org_id), count(*) filter (where s.quantity < 0)
  into v_inventory, v_negative
  from inventory_stock s left join stock_costs sc on sc.stock_id = s.id where s.organization_id = org_id;

  select coalesce(sum(balance), 0) into v_receivables from customer_balances where organization_id = org_id;
  select coalesce(sum(balance), 0) into v_cash from treasury_balances where organization_id = org_id;
  select coalesce(sum(balance), 0) into v_payables from supplier_balances where organization_id = org_id;

  select
    coalesce(sum(amount) filter (where kind = 'asset'), 0),
    coalesce(sum(amount) filter (where kind = 'liability'), 0)
  into v_other_assets, v_other_liabilities
  from other_balances where organization_id = org_id and is_active;

  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'kind', kind, 'name', name, 'amount', amount, 'notes', notes) order by created_at desc), '[]'::jsonb)
  into v_items
  from other_balances where organization_id = org_id and is_active;

  return jsonb_build_object(
    'inventory_value', v_inventory,
    'receivables', v_receivables,
    'cash', v_cash,
    'other_assets', v_other_assets,
    'payables', v_payables,
    'other_liabilities', v_other_liabilities,
    'net_position', v_inventory + v_receivables + v_cash + v_other_assets - v_payables - v_other_liabilities,
    'general_capital', v_inventory + v_receivables + v_cash - v_payables - v_other_liabilities,
    'negative_stock_items', v_negative,
    'other_items', v_items
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.report_summary(org_id uuid, p_from date DEFAULT NULL::date, p_to date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
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
  perform assert_sales_report_access(org_id);
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

  select coalesce(sum(subtotal_reversed), 0), coalesce(sum(cost_reversed), 0), coalesce(sum(profit_reversed), 0)
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
  select coalesce(sum(st.quantity * coalesce(stc.avg_cost, 0)), 0) + _stock_value_pending(org_id) into v_inventory from inventory_stock st left join stock_costs stc on stc.stock_id = st.id where st.organization_id = org_id;
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
$function$
;

-- ============================================================
-- 8. The storekeeper's queue — items and quantities only (no price, total, discount, payment, note, rep, profit)
-- ============================================================
create or replace function _warehouse_guard(org_id uuid) returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'يجب تسجيل الدخول أولاً'; end if;
  if not is_org_member(org_id) then raise exception 'أنت لست عضوًا في هذه المؤسسة'; end if;
  if not has_permission(org_id, 'warehouse.fulfill') then raise exception 'ليس لديك صلاحية متابعة أوامر المخزن'; end if;
end $$;
revoke all on function _warehouse_guard(uuid) from public, anon, authenticated;

-- p_status: open (pending + partial) | done | cancelled | all.   p_invoice narrows to a single invoice.
create or replace function warehouse_sales_orders(
  org_id uuid, p_status text default 'open', p_search text default null, p_limit integer default 50, p_offset integer default 0, p_invoice uuid default null
) returns table (
  id uuid, invoice_number text, invoice_date date, created_at timestamptz, customer_name text,
  warehouse_id uuid, warehouse_name text, status text, completed_at timestamptz, completed_by text,
  lines jsonb, history jsonb, total_count bigint
)
language plpgsql stable security definer set search_path = public as $$
declare v_limit int := least(greatest(coalesce(p_limit, 50), 1), 200); v_offset int := greatest(coalesce(p_offset, 0), 0);
begin
  perform _warehouse_guard(org_id);
  if p_status not in ('open', 'done', 'cancelled', 'all') then raise exception 'حالة غير صحيحة'; end if;
  return query
  with base as (
    select i.id, i.invoice_number, i.invoice_date, i.created_at, i.customer_id, i.warehouse_id, i.dispatch_status, i.dispatched_at, i.dispatched_by
    from sales_invoices i
    where i.organization_id = org_id
      and (p_invoice is null or i.id = p_invoice)
      and (case p_status when 'open' then i.dispatch_status in ('pending', 'partial')
                         when 'done' then i.dispatch_status = 'dispatched'
                         when 'cancelled' then i.dispatch_status = 'cancelled' else true end)
      and (coalesce(trim(p_search), '') = '' or i.invoice_number ilike '%' || trim(p_search) || '%')
  )
  select b.id, b.invoice_number, b.invoice_date, b.created_at, c.name, b.warehouse_id, w.name, b.dispatch_status, b.dispatched_at, u.email::text,
         (select coalesce(jsonb_agg(jsonb_build_object(
                   'line_id', l.id, 'product_id', l.product_id, 'product_name', p.name, 'unit', p.unit,
                   'ordered', l.ordered_units, 'fulfilled', l.fulfilled_units, 'released', l.cancelled_units,
                   'open', l.ordered_units - l.fulfilled_units - l.cancelled_units) order by l.seq), '[]'::jsonb)
          from invoice_stock_lines l join products p on p.id = l.product_id
          where l.kind = 'sales' and l.invoice_id = b.id),
         (select coalesce(jsonb_agg(jsonb_build_object(
                   'at', e.confirmed_at, 'by', eu.email, 'type', e.event_type, 'product_name', p2.name, 'quantity', e.quantity, 'note', e.note)
                 order by e.confirmed_at, e.id), '[]'::jsonb)
          from fulfilment_events e join products p2 on p2.id = e.product_id left join auth.users eu on eu.id = e.confirmed_by
          where e.kind = 'sales' and e.invoice_id = b.id),
         count(*) over ()
  from base b
  left join customers c on c.id = b.customer_id
  left join warehouses w on w.id = b.warehouse_id
  left join auth.users u on u.id = b.dispatched_by
  order by (case when p_status = 'open' then extract(epoch from b.created_at) else -extract(epoch from b.created_at) end), b.id
  limit v_limit offset v_offset;
end $$;

create or replace function warehouse_purchase_orders(
  org_id uuid, p_status text default 'open', p_search text default null, p_limit integer default 50, p_offset integer default 0, p_invoice uuid default null
) returns table (
  id uuid, invoice_number text, invoice_date date, created_at timestamptz, supplier_name text,
  warehouse_id uuid, warehouse_name text, status text, completed_at timestamptz, completed_by text,
  lines jsonb, history jsonb, total_count bigint
)
language plpgsql stable security definer set search_path = public as $$
declare v_limit int := least(greatest(coalesce(p_limit, 50), 1), 200); v_offset int := greatest(coalesce(p_offset, 0), 0);
begin
  perform _warehouse_guard(org_id);
  if p_status not in ('open', 'done', 'cancelled', 'all') then raise exception 'حالة غير صحيحة'; end if;
  return query
  with base as (
    select i.id, i.invoice_number, i.invoice_date, i.created_at, i.supplier_id, i.warehouse_id, i.receipt_status, i.received_at, i.received_by
    from purchase_invoices i
    where i.organization_id = org_id
      and (p_invoice is null or i.id = p_invoice)
      and (case p_status when 'open' then i.receipt_status in ('pending', 'partial')
                         when 'done' then i.receipt_status = 'received'
                         when 'cancelled' then i.receipt_status = 'cancelled' else true end)
      and (coalesce(trim(p_search), '') = '' or i.invoice_number ilike '%' || trim(p_search) || '%')
  )
  select b.id, b.invoice_number, b.invoice_date, b.created_at, s.name, b.warehouse_id, w.name, b.receipt_status, b.received_at, u.email::text,
         (select coalesce(jsonb_agg(jsonb_build_object(
                   'line_id', l.id, 'product_id', l.product_id, 'product_name', p.name, 'unit', p.unit, 'expiry_date', l.expiry_date,
                   'ordered', l.ordered_units, 'fulfilled', l.fulfilled_units, 'released', l.cancelled_units,
                   'open', l.ordered_units - l.fulfilled_units - l.cancelled_units) order by l.seq), '[]'::jsonb)
          from invoice_stock_lines l join products p on p.id = l.product_id
          where l.kind = 'purchase' and l.invoice_id = b.id),
         (select coalesce(jsonb_agg(jsonb_build_object(
                   'at', e.confirmed_at, 'by', eu.email, 'type', e.event_type, 'product_name', p2.name, 'quantity', e.quantity, 'note', e.note)
                 order by e.confirmed_at, e.id), '[]'::jsonb)
          from fulfilment_events e join products p2 on p2.id = e.product_id left join auth.users eu on eu.id = e.confirmed_by
          where e.kind = 'purchase' and e.invoice_id = b.id),
         count(*) over ()
  from base b
  left join suppliers s on s.id = b.supplier_id
  left join warehouses w on w.id = b.warehouse_id
  left join auth.users u on u.id = b.received_by
  order by (case when p_status = 'open' then extract(epoch from b.created_at) else -extract(epoch from b.created_at) end), b.id
  limit v_limit offset v_offset;
end $$;

create or replace function warehouse_pending_counts(org_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform _warehouse_guard(org_id);
  return jsonb_build_object(
    'sales',     (select count(*) from sales_invoices    where organization_id = org_id and dispatch_status in ('pending', 'partial')),
    'purchases', (select count(*) from purchase_invoices where organization_id = org_id and receipt_status  in ('pending', 'partial')));
end $$;

-- on hand / reserved / incoming per product & warehouse (quantities only)
create or replace function inventory_reservations(org_id uuid)
returns table (product_id uuid, warehouse_id uuid, on_hand numeric, reserved numeric, incoming numeric, available numeric)
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'يجب تسجيل الدخول أولاً'; end if;
  if not is_org_member(org_id) then raise exception 'أنت لست عضوًا في هذه المؤسسة'; end if;
  if is_restricted_rep(org_id) then raise exception 'ليس لديك صلاحية عرض المخزون'; end if;
  return query
  select s.product_id, s.warehouse_id, s.quantity::numeric,
         coalesce(r.units, 0)::numeric, coalesce(i.units, 0)::numeric, (s.quantity - coalesce(r.units, 0))::numeric
  from inventory_stock s
  left join (select l.product_id, l.warehouse_id, sum(l.ordered_units - l.fulfilled_units - l.cancelled_units) units
             from invoice_stock_lines l where l.organization_id = org_id and l.kind = 'sales'
               and l.ordered_units > l.fulfilled_units + l.cancelled_units group by 1, 2) r on r.product_id = s.product_id and r.warehouse_id = s.warehouse_id
  left join (select l.product_id, l.warehouse_id, sum(l.ordered_units - l.fulfilled_units - l.cancelled_units) units
             from invoice_stock_lines l where l.organization_id = org_id and l.kind = 'purchase'
               and l.ordered_units > l.fulfilled_units + l.cancelled_units group by 1, 2) i on i.product_id = s.product_id and i.warehouse_id = s.warehouse_id
  where s.organization_id = org_id;
end $$;

-- ============================================================
-- 9. Confirm dispatch / receiving (the ONLY place stock moves for an invoice)
--    p_lines = [{line_id, quantity}]; null = everything still open.
-- ============================================================
create or replace function _confirm_fulfilment(p_kind text, org_id uuid, p_invoice uuid, p_lines jsonb, p_note text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_status text; v_conf uuid := gen_random_uuid(); l record; e jsonb; v_q numeric; v_open numeric;
  v_todo jsonb := '[]'::jsonb; v_seen uuid[] := '{}'; v_id uuid; v_count int := 0; v_new text;
begin
  perform _warehouse_guard(org_id);
  if p_kind = 'sales' then
    select dispatch_status into v_status from sales_invoices where id = p_invoice and organization_id = org_id for update;
  else
    select receipt_status into v_status from purchase_invoices where id = p_invoice and organization_id = org_id for update;
  end if;
  if not found then raise exception 'الفاتورة غير موجودة'; end if;
  if v_status in ('dispatched', 'received') then
    raise exception '%', case when p_kind = 'sales' then 'تم صرف بضاعة هذه الفاتورة بالفعل' else 'تم استلام بضاعة هذه الفاتورة بالفعل' end;
  end if;
  if v_status = 'cancelled' then raise exception 'لا توجد كميات مفتوحة في هذه الفاتورة (أُلغيت بمرتجع)'; end if;

  if p_lines is null then
    for l in select id, ordered_units - fulfilled_units - cancelled_units as open_units from invoice_stock_lines
             where kind = p_kind and invoice_id = p_invoice and organization_id = org_id
               and ordered_units > fulfilled_units + cancelled_units order by seq
    loop
      v_todo := v_todo || jsonb_build_object('line_id', l.id, 'quantity', l.open_units);
    end loop;
  else
    if jsonb_typeof(p_lines) <> 'array' then raise exception 'صيغة الكميات غير صحيحة'; end if;
    v_todo := p_lines;
  end if;

  for e in select * from jsonb_array_elements(v_todo) loop
    begin
      v_id := (e->>'line_id')::uuid; v_q := (e->>'quantity')::numeric;
    exception when others then raise exception 'صيغة الكميات غير صحيحة'; end;
    if v_q is null or v_q = 'NaN'::numeric or v_q < 0 then raise exception 'الكمية غير صحيحة'; end if;
    continue when v_q = 0;                                  -- a line left at 0 is simply not handled in this confirmation
    if v_q <> round(v_q, 3) then raise exception 'الكمية تقبل 3 خانات عشرية كحد أقصى'; end if;
    if v_id = any (v_seen) then raise exception 'نفس البند مكرر في التأكيد'; end if;
    v_seen := v_seen || v_id;

    select * into l from invoice_stock_lines where id = v_id and kind = p_kind and invoice_id = p_invoice and organization_id = org_id for update;
    if not found then raise exception 'بند غير موجود في هذه الفاتورة'; end if;
    v_open := l.ordered_units - l.fulfilled_units - l.cancelled_units;
    if v_q > v_open then
      raise exception 'الكمية أكبر من المتبقي لهذا الصنف (المتبقي: %) — لا يمكن تأكيد كمية زائدة', v_open;
    end if;

    if p_kind = 'sales' then
      perform _consume_stock_core(org_id, l.product_id, l.warehouse_id, v_q, p_invoice);
    else
      perform set_config('kayan.batch_expiry', coalesce(l.expiry_date::text, ''), true);
      perform _receive_stock_core(org_id, l.product_id, l.warehouse_id, v_q, coalesce(l.unit_cost, 0), p_invoice);
    end if;
    update invoice_stock_lines set fulfilled_units = fulfilled_units + v_q where id = l.id;
    insert into fulfilment_events (organization_id, kind, invoice_id, line_id, product_id, event_type, quantity, confirmed_by, confirmation_id, note)
    values (org_id, p_kind, p_invoice, l.id, l.product_id, 'confirm', v_q, auth.uid(), v_conf, nullif(btrim(coalesce(p_note, '')), ''));
    v_count := v_count + 1;
  end loop;

  if v_count = 0 then raise exception 'لم تُحدَّد أي كمية للتأكيد'; end if;
  perform _fulfil_refresh(p_kind, p_invoice);

  if p_kind = 'sales' then select dispatch_status into v_new from sales_invoices where id = p_invoice;
  else select receipt_status into v_new from purchase_invoices where id = p_invoice; end if;
  insert into audit_logs (organization_id, user_id, action, entity, entity_id, after_data)
  values (org_id, auth.uid(), case when p_kind = 'sales' then 'sales_invoice.dispatch_confirmed' else 'purchase_invoice.receipt_confirmed' end,
          case when p_kind = 'sales' then 'sales_invoice' else 'purchase_invoice' end, p_invoice,
          jsonb_build_object('status', v_new, 'lines_confirmed', v_count, 'note', nullif(btrim(coalesce(p_note, '')), '')));
  return jsonb_build_object('status', v_new, 'lines_confirmed', v_count);
end $$;
revoke all on function _confirm_fulfilment(text, uuid, uuid, jsonb, text) from public, anon, authenticated;

create or replace function confirm_sales_dispatch(org_id uuid, p_invoice_id uuid, p_lines jsonb default null, p_note text default null) returns jsonb
language sql security definer set search_path = public as $$ select _confirm_fulfilment('sales', org_id, p_invoice_id, p_lines, p_note) $$;
create or replace function confirm_purchase_receipt(org_id uuid, p_invoice_id uuid, p_lines jsonb default null, p_note text default null) returns jsonb
language sql security definer set search_path = public as $$ select _confirm_fulfilment('purchase', org_id, p_invoice_id, p_lines, p_note) $$;

revoke all on function warehouse_sales_orders(uuid, text, text, integer, integer, uuid),
                       warehouse_purchase_orders(uuid, text, text, integer, integer, uuid),
                       warehouse_pending_counts(uuid), inventory_reservations(uuid),
                       confirm_sales_dispatch(uuid, uuid, jsonb, text), confirm_purchase_receipt(uuid, uuid, jsonb, text) from public, anon;
grant execute on function warehouse_sales_orders(uuid, text, text, integer, integer, uuid),
                          warehouse_purchase_orders(uuid, text, text, integer, integer, uuid),
                          warehouse_pending_counts(uuid), inventory_reservations(uuid),
                          confirm_sales_dispatch(uuid, uuid, jsonb, text), confirm_purchase_receipt(uuid, uuid, jsonb, text) to authenticated;

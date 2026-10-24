-- Kayan — Reports package, Phase 3: stock count (جرد المخزن) and reconciliation report
--
-- A stock count is its own workflow, separate from adjustments:
--
--   1. START      start_stocktake()   snapshots every batch in one warehouse (system quantity).
--   2. COUNT      save_stocktake_counts() / add_stocktake_found()   record the ACTUAL quantities,
--                 per batch (so per expiry date). Stock that is physically there but unknown to
--                 the system is added as a "found" line with an optional expiry date.
--   3. REVIEW     report_stocktake() / stocktake_summary()   system vs actual vs variance, and the
--                 financial impact, before anything is approved.
--   4. APPROVE    apply_stocktake()   only now does inventory change — one adjustment per
--                 variance, batch-specific: a shortage comes out of THAT batch (never FEFO),
--                 a surplus goes into that batch (or a new batch with the found expiry date).
--
-- NOTHING in inventory (stock, batches, costs, movements) changes in steps 1-3.
--
-- Stale counts
--   While a count is open, sales/purchases/returns/transfers continue as usual (the warehouse is
--   not frozen). apply_stocktake() refuses to run if ANY of these happened to a counted product:
--     (a) a stock movement in that warehouse after the count started   (even one that nets to 0),
--     (b) a counted batch changed quantity or disappeared,
--     (c) a new batch appeared that the count never saw.
--   The check runs after the stock rows are locked (the same lock every sale/return/transfer
--   takes), so nothing can slip in between the check and the writes. reconcile_stocktake()
--   refreshes the affected products to the current system quantities and clears THEIR counted
--   quantities (they must be recounted); products that did not move keep their counts.
--
-- What is deliberately reused, not reimplemented
--   * adjustments are inventory_movements rows of type 'adjustment' (so the existing audit trigger
--     audit_stock_adjustments, cost diversion and stock rules all apply) tagged reference_type
--     'stocktake', and they go through the same inventory_stock → batch trigger as everything else;
--   * costing: adjustments never change the weighted-average cost (same as adjust_inventory_stock);
--     the financial impact = variance × current average cost, read through the existing cost
--     protection (stock_costs / product_costs RLS) — users who cannot see costs get NULL values;
--   * permissions: counting uses inventory.adjust (unchanged); APPROVING needs the new permission
--     inventory.stocktake_approve (default: owner, admin) so the person who counts is not
--     automatically the person who approves. Give it to any role in the role editor.

-- ============================================================
-- 1. Permission
-- ============================================================
insert into permissions (key, description, category)
select 'inventory.stocktake_approve', 'Approve a stock count and apply its adjustments (audited)',
       (select category from permissions where key = 'inventory.adjust')
on conflict (key) do nothing;

insert into role_permissions (role_id, permission_key)
select r.id, 'inventory.stocktake_approve' from roles r
where r.organization_id is null and r.key in ('owner', 'admin')
on conflict do nothing;

-- ============================================================
-- 2. Tables (written only by the RPCs below)
-- ============================================================
create table if not exists stocktakes (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  warehouse_id    uuid not null references warehouses(id) on delete restrict,
  status          text not null default 'counting' check (status in ('counting', 'applied', 'cancelled')),
  notes           text check (notes is null or length(notes) <= 500),
  started_at      timestamptz not null default clock_timestamp(),   -- staleness baseline
  started_by      uuid references auth.users(id),
  closed_at       timestamptz,
  closed_by       uuid references auth.users(id),
  created_at      timestamptz not null default now()
);
-- one open count per warehouse: two parallel counts of the same shelves would contradict each other
create unique index if not exists stocktakes_one_open_per_warehouse on stocktakes (warehouse_id) where status = 'counting';
create index if not exists stocktakes_org on stocktakes (organization_id, created_at desc);

create table if not exists stocktake_lines (
  id                  uuid primary key default gen_random_uuid(),
  organization_id     uuid not null references organizations(id) on delete cascade,
  stocktake_id        uuid not null references stocktakes(id) on delete cascade,
  product_id          uuid not null references products(id) on delete restrict,
  batch_id            uuid,                       -- the system batch being counted; NULL = "found" stock
  expiry_date         date,                       -- snapshot of the batch's expiry / the found batch's expiry
  purchase_invoice_id uuid references purchase_invoices(id) on delete set null,   -- lets a surplus merge back into the same batch
  system_qty          numeric(14,3) not null default 0 check (system_qty >= 0 and system_qty < 1000000000),
  counted_qty         numeric(14,3) check (counted_qty is null or (counted_qty >= 0 and counted_qty < 1000000000)),
  applied_variance    numeric(14,3),              -- filled in when the count is approved
  created_at          timestamptz not null default now(),
  constraint stocktake_lines_expiry_sane check (expiry_date is null or expiry_date between date '2000-01-01' and date '2100-12-31')
);
create unique index if not exists stocktake_lines_batch_uniq on stocktake_lines (stocktake_id, batch_id) where batch_id is not null;
create index if not exists stocktake_lines_lookup on stocktake_lines (stocktake_id, product_id);

alter table stocktakes enable row level security;
alter table stocktake_lines enable row level security;
drop policy if exists stocktakes_select on stocktakes;
drop policy if exists stocktake_lines_select on stocktake_lines;
create policy stocktakes_select on stocktakes for select using (organization_id in (select user_org_ids()));
create policy stocktake_lines_select on stocktake_lines for select using (organization_id in (select user_org_ids()));
revoke all on stocktakes, stocktake_lines from public, anon, authenticated;
grant select on stocktakes, stocktake_lines to authenticated;

-- the count itself is audited (created / status changes); the adjustments it makes are audited
-- as stock adjustments by the existing trigger on inventory_movements
drop trigger if exists audit_stocktakes on stocktakes;
create trigger audit_stocktakes after insert or update on stocktakes
  for each row execute function audit_row_change('stocktake', '');

-- ============================================================
-- 3. Staleness
-- ============================================================
-- One row per (counted product, reason). reason: movement | batch_changed | new_batch.
create or replace function stocktake_stale(p_stocktake_id uuid)
returns table (product_id uuid, reason text)
language sql stable set search_path = public as $$
  -- (a) any stock movement in the warehouse after the count started
  select m.product_id, 'movement'::text
  from stocktakes st
  join inventory_movements m on m.organization_id = st.organization_id and m.warehouse_id = st.warehouse_id and m.created_at > st.started_at
  where st.id = p_stocktake_id and st.status = 'counting'
    and m.product_id in (select l.product_id from stocktake_lines l where l.stocktake_id = st.id)
  group by m.product_id
  union
  -- (b) a counted batch changed quantity or no longer exists
  select l.product_id, 'batch_changed'::text
  from stocktakes st
  join stocktake_lines l on l.stocktake_id = st.id and l.batch_id is not null
  left join stock_batches b on b.id = l.batch_id
  where st.id = p_stocktake_id and st.status = 'counting' and (b.id is null or b.quantity <> l.system_qty)
  union
  -- (c) a batch appeared in this warehouse that the count never saw
  select b.product_id, 'new_batch'::text
  from stocktakes st
  join stock_batches b on b.organization_id = st.organization_id and b.warehouse_id = st.warehouse_id
  where st.id = p_stocktake_id and st.status = 'counting'
    and b.product_id in (select l.product_id from stocktake_lines l where l.stocktake_id = st.id)
    and not exists (select 1 from stocktake_lines l where l.stocktake_id = st.id and l.batch_id = b.id)
$$;

-- ============================================================
-- 4. Workflow RPCs
-- ============================================================
create or replace function _stocktake_guard(org_id uuid, p_perm text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'يجب تسجيل الدخول أولاً'; end if;
  if not is_org_member(org_id) then raise exception 'أنت لست عضوًا في هذه المؤسسة'; end if;
  if not has_permission(org_id, p_perm) then
    if p_perm = 'inventory.stocktake_approve' then raise exception 'ليس لديك صلاحية اعتماد الجرد'; end if;
    raise exception 'ليس لديك صلاحية تسوية المخزون';
  end if;
end $$;

-- 1) START — snapshot only
create or replace function start_stocktake(org_id uuid, p_warehouse_id uuid, p_notes text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  perform _stocktake_guard(org_id, 'inventory.adjust');
  if not is_module_enabled(org_id, 'inventory') then raise exception 'هذه الوحدة غير مفعّلة لمؤسستك'; end if;
  if not exists (select 1 from warehouses where id = p_warehouse_id and organization_id = org_id) then
    raise exception 'هذا المخزن لا ينتمي إلى هذه المؤسسة';
  end if;
  if exists (select 1 from stocktakes where warehouse_id = p_warehouse_id and status = 'counting') then
    raise exception 'يوجد جرد مفتوح لهذا المخزن بالفعل — اعتمده أو ألغه أولًا';
  end if;

  begin
    insert into stocktakes (organization_id, warehouse_id, notes, started_at, started_by)
    values (org_id, p_warehouse_id, nullif(btrim(p_notes), ''), clock_timestamp(), auth.uid())
    returning id into v_id;
  exception when unique_violation then
    raise exception 'يوجد جرد مفتوح لهذا المخزن بالفعل — اعتمده أو ألغه أولًا';
  end;

  insert into stocktake_lines (organization_id, stocktake_id, product_id, batch_id, expiry_date, purchase_invoice_id, system_qty)
  select org_id, v_id, b.product_id, b.id, b.expiry_date, b.purchase_invoice_id, b.quantity
  from stock_batches b join products p on p.id = b.product_id
  where b.organization_id = org_id and b.warehouse_id = p_warehouse_id and p.track_inventory;
  return v_id;
end $$;

-- 2a) COUNT — record actual quantities: [{"line_id": "...", "counted_qty": 12.5}] (null clears a line)
create or replace function save_stocktake_counts(org_id uuid, p_stocktake_id uuid, p_counts jsonb)
returns integer language plpgsql security definer set search_path = public as $$
declare st stocktakes%rowtype; e jsonb; v_q numeric; v_n int := 0;
begin
  perform _stocktake_guard(org_id, 'inventory.adjust');
  select * into st from stocktakes where id = p_stocktake_id and organization_id = org_id for update;
  if not found then raise exception 'الجرد غير موجود'; end if;
  if st.status <> 'counting' then raise exception 'تم اعتماد هذا الجرد أو إلغاؤه مسبقًا'; end if;
  if p_counts is null or jsonb_typeof(p_counts) <> 'array' then raise exception 'بيانات الجرد غير صحيحة'; end if;

  for e in select * from jsonb_array_elements(p_counts) loop
    begin
      v_q := nullif(btrim(coalesce(e->>'counted_qty', '')), '')::numeric;
    exception when others then
      raise exception 'الكمية الفعلية غير صحيحة';
    end;
    if v_q is not null and (v_q < 0 or v_q >= 1000000000 or v_q = 'NaN'::numeric) then
      raise exception 'الكمية الفعلية يجب أن تكون صفرًا أو أكثر';
    end if;
    update stocktake_lines set counted_qty = v_q
    where id = (e->>'line_id')::uuid and stocktake_id = p_stocktake_id;
    if not found then raise exception 'سطر الجرد غير موجود في هذا الجرد'; end if;
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;

-- 2b) COUNT — stock that is physically there but not in the system (optional expiry date)
create or replace function add_stocktake_found(org_id uuid, p_stocktake_id uuid, p_product_id uuid, p_expiry date, p_counted numeric)
returns uuid language plpgsql security definer set search_path = public as $$
declare st stocktakes%rowtype; v_id uuid;
begin
  perform _stocktake_guard(org_id, 'inventory.adjust');
  select * into st from stocktakes where id = p_stocktake_id and organization_id = org_id for update;
  if not found then raise exception 'الجرد غير موجود'; end if;
  if st.status <> 'counting' then raise exception 'تم اعتماد هذا الجرد أو إلغاؤه مسبقًا'; end if;
  if not exists (select 1 from products where id = p_product_id and organization_id = org_id and track_inventory) then
    raise exception 'هذا المنتج غير موجود أو لا يتتبع المخزون';
  end if;
  if p_counted is null or p_counted <= 0 or p_counted >= 1000000000 then raise exception 'الكمية يجب أن تكون أكبر من صفر'; end if;
  if p_expiry is not null and (p_expiry < date '2000-01-01' or p_expiry > date '2100-12-31') then raise exception 'تاريخ الصلاحية غير صحيح'; end if;
  insert into stocktake_lines (organization_id, stocktake_id, product_id, batch_id, expiry_date, system_qty, counted_qty)
  values (org_id, p_stocktake_id, p_product_id, null, p_expiry, 0, p_counted)
  returning id into v_id;
  return v_id;
end $$;

create or replace function remove_stocktake_found(org_id uuid, p_line_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_st uuid; v_status text;
begin
  perform _stocktake_guard(org_id, 'inventory.adjust');
  select l.stocktake_id, s.status into v_st, v_status
  from stocktake_lines l join stocktakes s on s.id = l.stocktake_id
  where l.id = p_line_id and l.organization_id = org_id and l.batch_id is null;
  if v_st is null then raise exception 'سطر الجرد غير موجود'; end if;
  if v_status <> 'counting' then raise exception 'تم اعتماد هذا الجرد أو إلغاؤه مسبقًا'; end if;
  delete from stocktake_lines where id = p_line_id;
end $$;

-- Reconcile: bring every affected product back in line with the system and ask for a recount.
create or replace function reconcile_stocktake(org_id uuid, p_stocktake_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  st stocktakes%rowtype; v_products uuid[]; v_removed int := 0; v_refreshed int := 0; v_added int := 0;
begin
  perform _stocktake_guard(org_id, 'inventory.adjust');
  select * into st from stocktakes where id = p_stocktake_id and organization_id = org_id for update;
  if not found then raise exception 'الجرد غير موجود'; end if;
  if st.status <> 'counting' then raise exception 'تم اعتماد هذا الجرد أو إلغاؤه مسبقًا'; end if;

  select coalesce(array_agg(distinct product_id), '{}') into v_products from stocktake_stale(p_stocktake_id);
  if array_length(v_products, 1) is null then
    return jsonb_build_object('stale_products', 0, 'refreshed_lines', 0, 'removed_lines', 0, 'added_lines', 0);
  end if;

  -- batches that no longer exist (sold out / moved): drop their lines
  delete from stocktake_lines l
  where l.stocktake_id = p_stocktake_id and l.product_id = any (v_products) and l.batch_id is not null
    and not exists (select 1 from stock_batches b where b.id = l.batch_id);
  get diagnostics v_removed = row_count;

  -- batches that still exist: take today's quantity, ask for a recount
  update stocktake_lines l
  set system_qty = b.quantity, expiry_date = b.expiry_date, purchase_invoice_id = b.purchase_invoice_id, counted_qty = null
  from stock_batches b
  where l.stocktake_id = p_stocktake_id and l.product_id = any (v_products) and l.batch_id = b.id;
  get diagnostics v_refreshed = row_count;

  -- batches that appeared since the count started
  insert into stocktake_lines (organization_id, stocktake_id, product_id, batch_id, expiry_date, purchase_invoice_id, system_qty)
  select org_id, p_stocktake_id, b.product_id, b.id, b.expiry_date, b.purchase_invoice_id, b.quantity
  from stock_batches b
  where b.organization_id = org_id and b.warehouse_id = st.warehouse_id and b.product_id = any (v_products)
    and not exists (select 1 from stocktake_lines l where l.stocktake_id = p_stocktake_id and l.batch_id = b.id);
  get diagnostics v_added = row_count;

  -- found stock of an affected product must be re-confirmed too (the system may now know it)
  update stocktake_lines set counted_qty = null
  where stocktake_id = p_stocktake_id and product_id = any (v_products) and batch_id is null;

  -- unaffected products had no movement since the old baseline, so a fresh baseline is sound for them
  update stocktakes set started_at = clock_timestamp() where id = p_stocktake_id;

  return jsonb_build_object('stale_products', array_length(v_products, 1), 'refreshed_lines', v_refreshed,
                            'removed_lines', v_removed, 'added_lines', v_added);
end $$;

create or replace function cancel_stocktake(org_id uuid, p_stocktake_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare st stocktakes%rowtype;
begin
  perform _stocktake_guard(org_id, 'inventory.adjust');
  select * into st from stocktakes where id = p_stocktake_id and organization_id = org_id for update;
  if not found then raise exception 'الجرد غير موجود'; end if;
  if st.status <> 'counting' then raise exception 'تم اعتماد هذا الجرد أو إلغاؤه مسبقًا'; end if;
  update stocktakes set status = 'cancelled', closed_at = now(), closed_by = auth.uid() where id = p_stocktake_id;
end $$;

-- ============================================================
-- 5. APPROVE — the only step that touches inventory
-- ============================================================
-- One stock adjustment, batch-specific. Mirrors adjust_inventory_stock / dispose_stock_batch:
-- same row lock, same "never negative" rule, average cost left untouched, movement + audit.
create or replace function _stocktake_post(
  p_org uuid, p_product uuid, p_wh uuid, p_delta numeric, p_note text,
  p_expiry date, p_invoice uuid, p_batch uuid, p_stocktake uuid
) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_old numeric(14,3); v_avg numeric(14,6); v_movement uuid;
begin
  select s.quantity, coalesce(sc.avg_cost, 0) into v_old, v_avg
  from inventory_stock s left join stock_costs sc on sc.stock_id = s.id
  where s.product_id = p_product and s.warehouse_id = p_wh and s.organization_id = p_org
  for update of s;
  if not found then
    v_old := 0; v_avg := 0;
    insert into inventory_stock (organization_id, product_id, warehouse_id, quantity) values (p_org, p_product, p_wh, 0);
  end if;
  if v_old + p_delta < 0 then raise exception 'لا يمكن أن يصبح رصيد المخزون سالبًا بسبب الجرد'; end if;

  if p_delta < 0 then
    if p_batch is null then raise exception 'نقص بدون دفعة محددة'; end if;
    perform set_config('kayan.batch_target', p_batch::text, true);          -- comes out of THAT batch only
  else
    perform set_config('kayan.batch_expiry', coalesce(p_expiry::text, ''), true);   -- into that batch / a new dated batch
    perform set_config('kayan.batch_ref', coalesce(p_invoice::text, ''), true);
  end if;
  update inventory_stock set quantity = v_old + p_delta, updated_at = now()
  where product_id = p_product and warehouse_id = p_wh and organization_id = p_org;
  perform set_config('kayan.batch_target', '', true);
  perform set_config('kayan.batch_expiry', '', true);
  perform set_config('kayan.batch_ref', '', true);

  insert into inventory_movements (organization_id, product_id, warehouse_id, movement_type, quantity_delta, unit_cost, reference_type, reference_id, note, created_by)
  values (p_org, p_product, p_wh, 'adjustment', p_delta, v_avg, 'stocktake', p_stocktake, p_note, auth.uid())
  returning id into v_movement;
  return v_movement;
end $$;

create or replace function apply_stocktake(org_id uuid, p_stocktake_id uuid)
returns integer language plpgsql security definer set search_path = public as $$
declare st stocktakes%rowtype; l record; v_var numeric; v_n int := 0; v_stale int; v_counted int;
begin
  perform _stocktake_guard(org_id, 'inventory.stocktake_approve');
  select * into st from stocktakes where id = p_stocktake_id and organization_id = org_id for update;
  if not found then raise exception 'الجرد غير موجود'; end if;
  if st.status <> 'counting' then raise exception 'تم اعتماد هذا الجرد أو إلغاؤه مسبقًا'; end if;

  -- take the stock locks first: a sale/return/transfer in flight finishes before we look, a new one waits
  perform 1 from inventory_stock s
  where s.organization_id = org_id and s.warehouse_id = st.warehouse_id
    and s.product_id in (select product_id from stocktake_lines where stocktake_id = st.id)
  order by s.product_id for update;

  select count(distinct product_id) into v_stale from stocktake_stale(st.id);
  if v_stale > 0 then
    raise exception 'تغيّر المخزون بعد بدء الجرد (% صنف). اضغط «مطابقة» ثم أعد جرد الأصناف المتأثرة قبل الاعتماد', v_stale;
  end if;
  select count(*) into v_counted from stocktake_lines where stocktake_id = st.id and counted_qty is not null;
  if v_counted = 0 then raise exception 'لم تُسجَّل أي كمية فعلية'; end if;

  for l in
    select * from stocktake_lines where stocktake_id = st.id and counted_qty is not null
    order by product_id, expiry_date nulls last, id
  loop
    v_var := l.counted_qty - l.system_qty;
    update stocktake_lines set applied_variance = v_var where id = l.id;
    continue when v_var = 0;
    perform _stocktake_post(org_id, l.product_id, st.warehouse_id, v_var,
      'جرد مخزني — ' || case when l.expiry_date is null then 'دفعة بدون تاريخ صلاحية' else 'دفعة صلاحيتها ' || l.expiry_date::text end
        || case when l.batch_id is null then ' (بضاعة غير مسجلة بالنظام)' else '' end,
      l.expiry_date, l.purchase_invoice_id, l.batch_id, st.id);
    v_n := v_n + 1;
  end loop;

  update stocktakes set status = 'applied', closed_at = now(), closed_by = auth.uid() where id = st.id;
  return v_n;
end $$;

-- ============================================================
-- 6. Review (read-only, run as the caller → RLS and cost protection apply)
-- ============================================================
create or replace function report_stocktake(org_id uuid, p_stocktake_id uuid)
returns table (
  line_id uuid, product_id uuid, product_name text, sku text, barcode text, unit text,
  batch_id uuid, expiry_date date, is_found boolean,
  system_qty numeric,    -- quantity when the count started
  current_qty numeric,   -- quantity in the system right now
  counted_qty numeric,   -- actual (null = not counted yet)
  variance numeric,      -- counted − system (null until counted)
  unit_cost numeric,     -- average cost; NULL if the caller cannot see costs or none is known
  impact numeric,        -- variance × unit_cost
  state text,            -- uncounted | match | shortage | surplus
  stale boolean
)
language plpgsql stable set search_path = public as $$
declare st stocktakes%rowtype;
begin
  select * into st from stocktakes s where s.id = p_stocktake_id and s.organization_id = org_id;
  if not found then raise exception 'الجرد غير موجود'; end if;
  return query
  with stale as (select distinct x.product_id as pid from stocktake_stale(p_stocktake_id) x),
  cst as (
    select s.product_id as pid, sc.avg_cost as c
    from inventory_stock s join stock_costs sc on sc.stock_id = s.id
    where s.organization_id = org_id and s.warehouse_id = st.warehouse_id
  )
  select l.id, l.product_id, p.name, p.sku, p.barcode, p.unit, l.batch_id, l.expiry_date, (l.batch_id is null),
         l.system_qty::numeric, coalesce(b.quantity, 0)::numeric, l.counted_qty::numeric,
         (l.counted_qty - l.system_qty)::numeric,
         nullif(coalesce(nullif(cst.c, 0), pc.cost), 0)::numeric,
         round(((l.counted_qty - l.system_qty) * nullif(coalesce(nullif(cst.c, 0), pc.cost), 0))::numeric, 2),
         (case when l.counted_qty is null then 'uncounted'
               when l.counted_qty = l.system_qty then 'match'
               when l.counted_qty < l.system_qty then 'shortage' else 'surplus' end)::text,
         (l.product_id in (select pid from stale))
  from stocktake_lines l
  join products p on p.id = l.product_id
  left join stock_batches b on b.id = l.batch_id
  left join cst on cst.pid = l.product_id
  left join product_costs pc on pc.product_id = l.product_id
  where l.stocktake_id = p_stocktake_id
  order by p.name, l.expiry_date nulls last, l.id;
end $$;

create or replace function stocktake_summary(org_id uuid, p_stocktake_id uuid)
returns jsonb language plpgsql stable set search_path = public as $$
declare st stocktakes%rowtype; r jsonb; v_cost boolean; v_stale int; v_counted int;
begin
  select * into st from stocktakes s where s.id = p_stocktake_id and s.organization_id = org_id;
  if not found then raise exception 'الجرد غير موجود'; end if;
  v_cost := org_id in (select cost_org_ids());
  select count(distinct x.product_id) into v_stale from stocktake_stale(p_stocktake_id) x;

  select jsonb_build_object(
    'lines',          count(*),
    'counted',        count(*) filter (where q.counted_qty is not null),
    'uncounted',      count(*) filter (where q.counted_qty is null),
    'shortage_lines', count(*) filter (where q.state = 'shortage'),
    'surplus_lines',  count(*) filter (where q.state = 'surplus'),
    'shortage_qty',   coalesce(sum(-q.variance) filter (where q.state = 'shortage'), 0),
    'surplus_qty',    coalesce(sum(q.variance) filter (where q.state = 'surplus'), 0),
    'shortage_value', case when v_cost then coalesce(sum(-q.impact) filter (where q.state = 'shortage'), 0) end,
    'surplus_value',  case when v_cost then coalesce(sum(q.impact) filter (where q.state = 'surplus'), 0) end,
    'net_value',      case when v_cost then coalesce(sum(q.impact), 0) end,
    'lines_without_cost', case when v_cost then count(*) filter (where q.variance <> 0 and q.unit_cost is null) end)
  into r
  from report_stocktake(org_id, p_stocktake_id) q;

  v_counted := (r->>'counted')::int;
  return r || jsonb_build_object(
    'status', st.status, 'warehouse_id', st.warehouse_id, 'started_at', st.started_at, 'notes', st.notes,
    'costs_visible', v_cost,
    'stale_products', v_stale, 'stale', v_stale > 0,
    'can_apply', st.status = 'counting' and v_stale = 0 and v_counted > 0 and has_permission(org_id, 'inventory.stocktake_approve'));
end $$;

-- ============================================================
-- 7. Grants
-- ============================================================
revoke all on function _stocktake_guard(uuid, text) from public, anon, authenticated;
revoke all on function _stocktake_post(uuid, uuid, uuid, numeric, text, date, uuid, uuid, uuid) from public, anon, authenticated;

revoke all on function start_stocktake(uuid, uuid, text), save_stocktake_counts(uuid, uuid, jsonb),
  add_stocktake_found(uuid, uuid, uuid, date, numeric), remove_stocktake_found(uuid, uuid),
  reconcile_stocktake(uuid, uuid), cancel_stocktake(uuid, uuid), apply_stocktake(uuid, uuid) from public, anon;
grant execute on function start_stocktake(uuid, uuid, text), save_stocktake_counts(uuid, uuid, jsonb),
  add_stocktake_found(uuid, uuid, uuid, date, numeric), remove_stocktake_found(uuid, uuid),
  reconcile_stocktake(uuid, uuid), cancel_stocktake(uuid, uuid), apply_stocktake(uuid, uuid) to authenticated;
grant execute on function stocktake_stale(uuid), report_stocktake(uuid, uuid), stocktake_summary(uuid, uuid) to authenticated;

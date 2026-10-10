-- Kayan — Phase 34: protect COST data (read AND write) from Sales / Warehouse
-- Depends on 0033. Re-runnable.  TAKE A DATABASE BACKUP FIRST — this migration drops
-- product_prices.cost and inventory_stock.avg_cost (their values are copied first).
--
-- Cost leaked through FIVE sources readable by every member (found by scanning every
-- cost-like column as a warehouse user, not just the two that were reported):
--   product_prices.cost            -> product_costs
--   inventory_stock.avg_cost       -> stock_costs
--   inventory_movements.unit_cost  -> inventory_movement_costs   (kept nullable, always NULL, filled by trigger)
--   stock_transfer_items.unit_cost / line_total -> stock_transfer_item_costs
--   stock_transfers.total_value    -> stock_transfer_costs       (sum of cost x qty = cost in aggregate)
-- Row-level security cannot hide a single column, so each value now lives in its own
-- RLS-protected table:
--   READ  : view_financial, or the new permission products.view_cost   (default: owner, admin, accountant)
--   WRITE : only product_costs is user-writable (manage_settings, purchases.approve, view_financial);
--           the others are maintained by the stock functions only.

-- ---------------------------------------------------------------- permission + helpers
insert into permissions (key, description, category)
select 'products.view_cost', 'View product / stock cost and cost-derived values',
       (select category from permissions where key = 'view_financial')
on conflict (key) do nothing;

insert into role_permissions (role_id, permission_key)
select r.id, 'products.view_cost' from roles r
where r.organization_id is null and r.key in ('owner', 'admin', 'accountant')
on conflict do nothing;

create or replace function cost_org_ids() returns setof uuid
language sql security definer stable set search_path = public as $$
  select distinct ou.organization_id
  from organization_users ou
  join role_permissions rp on rp.role_id = ou.role_id
  where ou.user_id = auth.uid() and ou.status = 'active'
    and rp.permission_key in ('view_financial', 'products.view_cost')
$$;
create or replace function cost_edit_org_ids() returns setof uuid
language sql security definer stable set search_path = public as $$
  select distinct ou.organization_id
  from organization_users ou
  join role_permissions rp on rp.role_id = ou.role_id
  where ou.user_id = auth.uid() and ou.status = 'active'
    and rp.permission_key in ('view_financial', 'purchases.approve', 'manage_settings')
$$;
revoke all on function cost_org_ids(), cost_edit_org_ids() from public, anon;
grant execute on function cost_org_ids(), cost_edit_org_ids() to authenticated;

-- ---------------------------------------------------------------- protected tables
create table if not exists product_costs (
  product_id      uuid primary key references products(id) on delete cascade,
  organization_id uuid not null references organizations(id) on delete cascade,   -- stamped from the product (used by audit + tenant checks)
  cost       numeric(14,6) not null default 0
             check (cost <> 'NaN'::numeric and cost <> 'Infinity'::numeric and cost <> '-Infinity'::numeric),
  updated_at timestamptz not null default now()
);
create table if not exists stock_costs (
  stock_id   uuid primary key references inventory_stock(id) on delete cascade,
  avg_cost   numeric(14,6) not null default 0
             check (avg_cost <> 'NaN'::numeric and avg_cost <> 'Infinity'::numeric and avg_cost <> '-Infinity'::numeric),
  updated_at timestamptz not null default now()
);
-- the three below are filled by BEFORE INSERT triggers, so their parent row does not exist yet:
-- the foreign key is checked at commit (deferred)
create table if not exists inventory_movement_costs (
  movement_id uuid primary key references inventory_movements(id) on delete cascade deferrable initially deferred,
  unit_cost   numeric not null
              check (unit_cost <> 'NaN'::numeric and unit_cost <> 'Infinity'::numeric and unit_cost <> '-Infinity'::numeric)
);
create table if not exists stock_transfer_item_costs (
  item_id    uuid primary key references stock_transfer_items(id) on delete cascade deferrable initially deferred,
  unit_cost  numeric not null check (unit_cost <> 'NaN'::numeric and unit_cost <> 'Infinity'::numeric and unit_cost <> '-Infinity'::numeric),
  line_total numeric not null check (line_total <> 'NaN'::numeric and line_total <> 'Infinity'::numeric and line_total <> '-Infinity'::numeric)
);
create table if not exists stock_transfer_costs (
  transfer_id uuid primary key references stock_transfers(id) on delete cascade deferrable initially deferred,
  total_value numeric not null check (total_value <> 'NaN'::numeric and total_value <> 'Infinity'::numeric and total_value <> '-Infinity'::numeric)
);

create or replace function product_cost_stamp() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  select organization_id into NEW.organization_id from products where id = NEW.product_id;
  if NEW.organization_id is null then raise exception 'المنتج غير موجود'; end if;
  NEW.updated_at := now();
  return NEW;
end $$;
revoke all on function product_cost_stamp() from public, anon;
drop trigger if exists product_cost_stamp on product_costs;
create trigger product_cost_stamp before insert or update on product_costs for each row execute function product_cost_stamp();

-- ---------------------------------------------------------------- RLS
alter table product_costs             enable row level security;
alter table stock_costs               enable row level security;
alter table inventory_movement_costs  enable row level security;
alter table stock_transfer_item_costs enable row level security;
alter table stock_transfer_costs      enable row level security;
revoke all on product_costs, stock_costs, inventory_movement_costs, stock_transfer_item_costs, stock_transfer_costs from public, anon;
grant select on product_costs, stock_costs, inventory_movement_costs, stock_transfer_item_costs, stock_transfer_costs to authenticated;
grant insert, update, delete on product_costs to authenticated;

-- each policy goes through the parent row, so the parent's own RLS (tenant + restricted-rep scope) applies too
do $$
declare r record;
begin
  for r in select * from (values
    ('product_costs',            'product_id',  'products'),
    ('stock_costs',              'stock_id',    'inventory_stock'),
    ('inventory_movement_costs', 'movement_id', 'inventory_movements'),
    ('stock_transfer_item_costs','item_id',     'stock_transfer_items'),
    ('stock_transfer_costs',     'transfer_id', 'stock_transfers')) as v(t, k, parent)
  loop
    execute format('drop policy if exists cost_select on %I', r.t);
    execute format($p$create policy cost_select on %1$I for select using (
        exists (select 1 from %3$I p where p.id = %1$I.%2$I and p.organization_id in (select cost_org_ids())))$p$, r.t, r.k, r.parent);
  end loop;
end $$;

drop policy if exists cost_insert on product_costs;
drop policy if exists cost_update on product_costs;
drop policy if exists cost_delete on product_costs;
create policy cost_insert on product_costs for insert with check (
  exists (select 1 from products p where p.id = product_costs.product_id and p.organization_id in (select cost_edit_org_ids())));
create policy cost_update on product_costs for update
  using      (exists (select 1 from products p where p.id = product_costs.product_id and p.organization_id in (select cost_edit_org_ids())))
  with check (exists (select 1 from products p where p.id = product_costs.product_id and p.organization_id in (select cost_edit_org_ids())));
create policy cost_delete on product_costs for delete using (
  exists (select 1 from products p where p.id = product_costs.product_id and p.organization_id in (select cost_edit_org_ids())));

-- ---------------------------------------------------------------- copy existing data
do $$
begin
  if exists (select 1 from information_schema.columns where table_schema='public' and table_name='product_prices' and column_name='cost') then
    insert into product_costs (product_id, cost)
    select product_id, cost from product_prices where cost is not null
    on conflict (product_id) do nothing;
  end if;
  if exists (select 1 from information_schema.columns where table_schema='public' and table_name='inventory_stock' and column_name='avg_cost') then
    insert into stock_costs (stock_id, avg_cost)
    select id, avg_cost from inventory_stock where avg_cost is not null
    on conflict (stock_id) do nothing;
  end if;
end $$;

insert into inventory_movement_costs (movement_id, unit_cost)
select id, unit_cost from inventory_movements where unit_cost is not null
on conflict (movement_id) do nothing;
insert into stock_transfer_item_costs (item_id, unit_cost, line_total)
select id, unit_cost, line_total from stock_transfer_items where unit_cost is not null and line_total is not null
on conflict (item_id) do nothing;
insert into stock_transfer_costs (transfer_id, total_value)
select id, total_value from stock_transfers where total_value is not null
on conflict (transfer_id) do nothing;

-- audit manual cost edits (the old audit triggers on product_prices stop seeing cost)
drop trigger if exists audit_product_costs on product_costs;
create trigger audit_product_costs after insert or update or delete on product_costs
  for each row execute function audit_row_change('product_cost', 'product_id');

-- ---------------------------------------------------------------- divert future writes + clear the old values
alter table stock_transfer_items alter column unit_cost  drop not null;
alter table stock_transfer_items alter column line_total drop not null;
alter table stock_transfers      alter column total_value drop not null;

create or replace function divert_movement_cost() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if NEW.unit_cost is not null then
    insert into inventory_movement_costs (movement_id, unit_cost) values (NEW.id, NEW.unit_cost)
    on conflict (movement_id) do update set unit_cost = excluded.unit_cost;
    NEW.unit_cost := null;
  end if;
  return NEW;
end $$;
create or replace function divert_transfer_item_cost() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if NEW.unit_cost is not null or NEW.line_total is not null then
    insert into stock_transfer_item_costs (item_id, unit_cost, line_total) values (NEW.id, coalesce(NEW.unit_cost, 0), coalesce(NEW.line_total, 0))
    on conflict (item_id) do update set unit_cost = excluded.unit_cost, line_total = excluded.line_total;
    NEW.unit_cost := null; NEW.line_total := null;
  end if;
  return NEW;
end $$;
create or replace function divert_transfer_cost() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if NEW.total_value is not null then
    insert into stock_transfer_costs (transfer_id, total_value) values (NEW.id, NEW.total_value)
    on conflict (transfer_id) do update set total_value = excluded.total_value;
    NEW.total_value := null;
  end if;
  return NEW;
end $$;
revoke all on function divert_movement_cost(), divert_transfer_item_cost(), divert_transfer_cost() from public, anon;

drop trigger if exists divert_cost on inventory_movements;
drop trigger if exists divert_cost on stock_transfer_items;
drop trigger if exists divert_cost on stock_transfers;
create trigger divert_cost before insert on inventory_movements   for each row execute function divert_movement_cost();
create trigger divert_cost before insert on stock_transfer_items  for each row execute function divert_transfer_item_cost();
create trigger divert_cost before insert or update of total_value on stock_transfers for each row execute function divert_transfer_cost();

-- clear the legacy values without firing audit/duplicate-guard triggers
alter table inventory_movements  disable trigger user;
alter table stock_transfer_items disable trigger user;
alter table stock_transfers      disable trigger user;
update inventory_movements  set unit_cost = null where unit_cost is not null;
update stock_transfer_items set unit_cost = null, line_total = null where unit_cost is not null or line_total is not null;
update stock_transfers      set total_value = null where total_value is not null;
alter table inventory_movements  enable trigger user;
alter table stock_transfer_items enable trigger user;
alter table stock_transfers      enable trigger user;

-- these columns can never hold a cost again
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'inventory_movements_cost_diverted') then
    alter table inventory_movements add constraint inventory_movements_cost_diverted check (unit_cost is null);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'stock_transfer_items_cost_diverted') then
    alter table stock_transfer_items add constraint stock_transfer_items_cost_diverted check (unit_cost is null and line_total is null);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'stock_transfers_cost_diverted') then
    alter table stock_transfers add constraint stock_transfers_cost_diverted check (total_value is null);
  end if;
end $$;

-- ---------------------------------------------------------------- functions (cost now read from / written to the protected tables)
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
  update inventory_stock set quantity = v_new_qty, updated_at = now() where product_id = p_product and warehouse_id = p_wh;
  insert into stock_costs (stock_id, avg_cost)
  select id, v_new_avg from inventory_stock where product_id = p_product and warehouse_id = p_wh
  on conflict (stock_id) do update set avg_cost = excluded.avg_cost, updated_at = now();
  insert into inventory_movements (organization_id, product_id, warehouse_id, movement_type, quantity_delta, unit_cost, reference_type, reference_id, created_by)
  values (org_id, p_product, p_wh, 'purchase', p_qty, p_unit_cost, 'purchase_invoice', p_ref, auth.uid());
  insert into product_costs (product_id, cost)
  select id, v_new_avg from products where id = p_product and organization_id = org_id
  on conflict (product_id) do update set cost = excluded.cost, updated_at = now();
end $function$;

CREATE OR REPLACE FUNCTION public._consume_stock(org_id uuid, p_product uuid, p_wh uuid, p_qty numeric, p_ref uuid)
 RETURNS numeric
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_track boolean; v_old_qty numeric(14,3); v_old_avg numeric(14,6); v_cost numeric(14,6);
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
    v_cost := v_old_avg;
    update inventory_stock set quantity = v_old_qty - p_qty, updated_at = now() where product_id = p_product and warehouse_id = p_wh;
    insert into inventory_movements (organization_id, product_id, warehouse_id, movement_type, quantity_delta, unit_cost, reference_type, reference_id, created_by)
    values (org_id, p_product, p_wh, 'sale', -p_qty, v_cost, 'sales_invoice', p_ref, auth.uid());
  else
    select coalesce(pc.cost, 0) into v_cost from product_costs pc where pc.product_id = p_product limit 1;
    v_cost := coalesce(v_cost, 0);
  end if;
  return v_cost;
end $function$;

CREATE OR REPLACE FUNCTION public.adjust_inventory_stock(org_id uuid, p_product_id uuid, p_warehouse_id uuid, p_quantity_delta numeric, p_reason text)
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

  update inventory_stock
  set quantity = v_old_qty + p_quantity_delta, updated_at = now()
  where product_id = p_product_id and warehouse_id = p_warehouse_id and organization_id = org_id;

  insert into inventory_movements (organization_id, product_id, warehouse_id, movement_type, quantity_delta, unit_cost, reference_type, note, created_by)
  values (org_id, p_product_id, p_warehouse_id, 'adjustment', p_quantity_delta, v_avg, 'manual_adjustment', trim(p_reason), auth.uid())
  returning id into v_movement_id;

  return v_movement_id;
end;
$function$;

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
      update inventory_stock set quantity = quantity - v_quantity, updated_at = now()
      where product_id = v_orig.product_id and warehouse_id = v_warehouse_id;
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
        update inventory_stock
        set quantity = v_old_qty + v_quantity, updated_at = now()
        where product_id = v_orig.product_id and warehouse_id = v_warehouse_id;
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
  end loop;

  update stock_transfers set total_value = v_total where id = new_transfer_id;

  return new_transfer_id;
end;
$function$;

CREATE OR REPLACE FUNCTION public.report_inventory_stock(org_id uuid)
 RETURNS TABLE(product_id uuid, product_name text, sku text, unit text, warehouse_id uuid, warehouse_name text, quantity numeric, avg_cost numeric, stock_value numeric)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
declare
  fin boolean;
begin
  perform assert_report_access(org_id, false);
  fin := has_permission(org_id, 'view_financial');

  return query
  select
    s.product_id,
    p.name,
    p.sku,
    p.unit,
    s.warehouse_id,
    w.name,
    s.quantity::numeric,
    case when fin then coalesce(sc.avg_cost, 0)::numeric end,
    case when fin then (s.quantity * coalesce(sc.avg_cost, 0))::numeric end
  from inventory_stock s
  left join stock_costs sc on sc.stock_id = s.id
  join products p on p.id = s.product_id
  join warehouses w on w.id = s.warehouse_id
  where s.organization_id = org_id
    and s.quantity <> 0
  order by p.name, w.name;
end;
$function$;

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

  select coalesce(sum(s.quantity * coalesce(sc.avg_cost, 0)), 0), count(*) filter (where s.quantity < 0)
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
$function$;

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
  select coalesce(sum(st.quantity * coalesce(stc.avg_cost, 0)), 0) into v_inventory from inventory_stock st left join stock_costs stc on stc.stock_id = st.id where st.organization_id = org_id;
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
$function$;

CREATE OR REPLACE FUNCTION public.report_stock_movements(org_id uuid, p_from date DEFAULT NULL::date, p_to date DEFAULT NULL::date, p_product uuid DEFAULT NULL::uuid, p_warehouse uuid DEFAULT NULL::uuid, p_type text DEFAULT NULL::text, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0)
 RETURNS TABLE(id uuid, moved_at timestamp with time zone, product_name text, warehouse_name text, movement_type text, quantity_delta numeric, unit_cost numeric, reference_type text, note text, total_count bigint)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
declare
  fin boolean;
  v_limit int := least(greatest(coalesce(p_limit, 50), 1), 1000);
  v_offset int := greatest(coalesce(p_offset, 0), 0);
begin
  perform assert_report_access(org_id, false);
  fin := has_permission(org_id, 'view_financial');

  return query
  select
    m.id,
    m.created_at,
    p.name,
    w.name,
    m.movement_type,
    m.quantity_delta::numeric,
    case when fin then mc.unit_cost::numeric end,
    m.reference_type,
    m.note,
    count(*) over ()
  from inventory_movements m
  left join inventory_movement_costs mc on mc.movement_id = m.id
  join products p on p.id = m.product_id
  join warehouses w on w.id = m.warehouse_id
  where m.organization_id = org_id
    -- movements only carry a timestamp; compare on the business's local
    -- (Cairo) calendar day so "today" means today in Egypt, not in UTC.
    and (p_from is null or (m.created_at at time zone 'Africa/Cairo')::date >= p_from)
    and (p_to is null or (m.created_at at time zone 'Africa/Cairo')::date <= p_to)
    and (p_product is null or m.product_id = p_product)
    and (p_warehouse is null or m.warehouse_id = p_warehouse)
    and (p_type is null or p_type = '' or m.movement_type = p_type)
  order by m.created_at desc, m.id
  limit v_limit offset v_offset;
end;
$function$;

-- ---------------------------------------------------------------- drop the exposed columns
alter table product_prices drop column if exists cost;
alter table inventory_stock drop column if exists avg_cost;

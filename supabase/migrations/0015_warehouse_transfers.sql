-- Kayan — Phase 12: Warehouse Transfers (§19)
--
-- Multi-warehouse stock already existed (inventory_stock is keyed on
-- product+warehouse), but there was no way to move stock BETWEEN two of
-- an org's own warehouses — only in via a purchase, out via a sale/
-- adjustment. This closes that gap.
--
-- Design, consistent with the rest of §20/§21's costing rules:
--   1. Unlike a purchase/sales return (goods leaving the business, where
--      the weighted-average pool is deliberately left untouched — see
--      0012's header note), a transfer keeps the goods inside the
--      business. The destination warehouse's average cost SHOULD absorb
--      the transferred stock's cost basis, the same way a purchase blends
--      into an existing pool (§21). So a transfer recomputes the
--      destination's avg_cost as a proper weighted average of what was
--      already there and what arrived; the source warehouse's avg_cost is
--      left alone (only its quantity drops — the remaining stock's cost
--      basis hasn't changed).
--   2. Two inventory_movements rows per line (transfer_out at the source,
--      transfer_in at the destination), both tagged to the same
--      stock_transfer_id, so the existing inventory report can show both
--      sides of the same movement without special-casing anything.
--   3. Gated on `inventory.adjust` — same permission that already governs
--      every other stock-quantity change that isn't a sale/purchase
--      (0010's manual adjustment RPC uses the same key) — rather than
--      inventing a new permission for what is, at its core, still a
--      manual stock movement.
--   4. A transfer cannot take the source warehouse's on-hand quantity
--      negative, same rule as every other stock-decreasing operation in
--      this app.

alter table inventory_movements drop constraint inventory_movements_movement_type_check;
alter table inventory_movements add constraint inventory_movements_movement_type_check
  check (movement_type in ('purchase','purchase_return','sale','sale_return','adjustment','transfer_out','transfer_in'));

create table stock_transfers (
  id                uuid primary key default gen_random_uuid(),
  organization_id   uuid not null references organizations(id) on delete cascade,
  from_warehouse_id uuid not null references warehouses(id) on delete restrict,
  to_warehouse_id   uuid not null references warehouses(id) on delete restrict,
  transfer_date     date not null default current_date,
  total_value       numeric(14,2) not null default 0,  -- at source cost, for reference only
  notes             text,
  created_by        uuid references auth.users(id),
  created_at        timestamptz not null default now()
);
create index stock_transfers_org_idx on stock_transfers(organization_id, transfer_date);

create table stock_transfer_items (
  id                 uuid primary key default gen_random_uuid(),
  organization_id    uuid not null references organizations(id) on delete cascade,
  stock_transfer_id  uuid not null references stock_transfers(id) on delete cascade,
  product_id         uuid not null references products(id) on delete restrict,
  quantity           numeric(14,3) not null check (quantity > 0),
  unit_cost          numeric(14,2) not null default 0,  -- the source warehouse's avg_cost at transfer time
  line_total         numeric(14,2) not null default 0
);
create index stock_transfer_items_transfer_idx on stock_transfer_items(stock_transfer_id);
create index stock_transfer_items_product_idx on stock_transfer_items(organization_id, product_id);

alter table stock_transfers      enable row level security;
alter table stock_transfer_items enable row level security;

create policy stock_transfers_select on stock_transfers for select using (is_org_member(organization_id));
create policy stock_transfer_items_select on stock_transfer_items for select using (is_org_member(organization_id));

grant select on stock_transfers, stock_transfer_items to authenticated;
-- Written only by create_stock_transfer() below — same reasoning as every
-- other ledger-like table since Phase 7: no direct insert/update/delete.

create or replace function create_stock_transfer(
  org_id uuid,
  p_from_warehouse_id uuid,
  p_to_warehouse_id uuid,
  p_transfer_date date,
  items jsonb,  -- [{product_id, quantity}]
  p_notes text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  new_transfer_id uuid;
  item jsonb;
  v_product_id uuid;
  v_quantity numeric(14,3);
  v_track_inventory boolean;
  v_source_qty numeric(14,3);
  v_source_avg numeric(14,2);
  v_dest_qty numeric(14,3);
  v_dest_avg numeric(14,2);
  v_new_dest_avg numeric(14,2);
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

    select quantity, avg_cost into v_source_qty, v_source_avg
    from inventory_stock
    where product_id = v_product_id and warehouse_id = p_from_warehouse_id and organization_id = org_id
    for update;

    if not found or coalesce(v_source_qty, 0) < v_quantity then
      raise exception 'الكمية المتاحة بمخزن المصدر أقل من كمية النقل لهذا الصنف';
    end if;

    update inventory_stock
    set quantity = quantity - v_quantity, updated_at = now()
    where product_id = v_product_id and warehouse_id = p_from_warehouse_id and organization_id = org_id;

    select quantity, avg_cost into v_dest_qty, v_dest_avg
    from inventory_stock
    where product_id = v_product_id and warehouse_id = p_to_warehouse_id and organization_id = org_id
    for update;

    if not found then
      v_dest_qty := 0;
      v_dest_avg := 0;
      insert into inventory_stock (organization_id, product_id, warehouse_id, quantity, avg_cost)
      values (org_id, v_product_id, p_to_warehouse_id, 0, 0);
    end if;

    -- Weighted-average blend at the destination (§21), same formula a
    -- purchase uses — the transferred stock brings its cost basis with it.
    if v_dest_qty + v_quantity > 0 then
      v_new_dest_avg := round(((v_dest_qty * v_dest_avg) + (v_quantity * v_source_avg)) / (v_dest_qty + v_quantity), 2);
    else
      v_new_dest_avg := v_source_avg;
    end if;

    update inventory_stock
    set quantity = v_dest_qty + v_quantity, avg_cost = v_new_dest_avg, updated_at = now()
    where product_id = v_product_id and warehouse_id = p_to_warehouse_id and organization_id = org_id;

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
$$;

create trigger a_enforce_module before insert on stock_transfers for each row execute function enforce_module_enabled('inventory');
create trigger b_duplicate_guard before insert on stock_transfers for each row execute function guard_duplicate_submission('from_warehouse_id', 'to_warehouse_id', 'transfer_date');
create constraint trigger audit_stock_transfers after insert on stock_transfers deferrable initially deferred for each row execute function audit_row_change('stock_transfer', 'final');

revoke all on function create_stock_transfer(uuid, uuid, uuid, date, jsonb, text) from public, anon;
grant execute on function create_stock_transfer(uuid, uuid, uuid, date, jsonb, text) to authenticated;

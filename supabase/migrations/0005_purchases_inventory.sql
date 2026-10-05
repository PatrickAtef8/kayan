-- Kayan — Phase 3: Purchases & Inventory
-- Purchase invoices increase inventory and (via weighted-average costing,
-- §21 of the SRS) update each product's cost. Supplier balance follows
-- §23: Payable = Purchases − Payments − Purchase Returns (returns are not
-- in scope yet — see REDESIGN_NOTES-style comment below).
--
-- Writing across four tables (invoice, items, inventory_stock, movements)
-- from separate client requests would race under concurrent purchases
-- (§49 Concurrency & Idempotency), so — same pattern as create_organization
-- in 0002 — the whole invoice is created through one SECURITY DEFINER RPC
-- that runs as a single Postgres transaction.

-- ============================================================
-- 1. Purchase invoices
-- ============================================================
create table purchase_invoices (
  id                uuid primary key default gen_random_uuid(),
  organization_id   uuid not null references organizations(id) on delete cascade,
  supplier_id       uuid not null references suppliers(id) on delete restrict,
  warehouse_id      uuid not null references warehouses(id) on delete restrict,
  invoice_number    text,
  invoice_date      date not null default current_date,
  subtotal          numeric(14,2) not null default 0,
  discount_total    numeric(14,2) not null default 0,
  tax_total         numeric(14,2) not null default 0,
  total             numeric(14,2) not null default 0,
  amount_paid       numeric(14,2) not null default 0,
  payment_status    text not null default 'unpaid' check (payment_status in ('unpaid','partial','paid')),
  notes             text,
  created_by        uuid references auth.users(id),
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);
create index purchase_invoices_org_idx      on purchase_invoices(organization_id);
create index purchase_invoices_supplier_idx on purchase_invoices(supplier_id);

-- ============================================================
-- 2. Purchase invoice items
-- ============================================================
create table purchase_invoice_items (
  id                  uuid primary key default gen_random_uuid(),
  organization_id     uuid not null references organizations(id) on delete cascade,
  purchase_invoice_id uuid not null references purchase_invoices(id) on delete cascade,
  product_id          uuid not null references products(id) on delete restrict,
  quantity            numeric(14,3) not null check (quantity > 0),
  unit_cost           numeric(14,2) not null check (unit_cost >= 0),
  discount            numeric(14,2) not null default 0,
  line_total          numeric(14,2) not null default 0
);
create index purchase_invoice_items_invoice_idx on purchase_invoice_items(purchase_invoice_id);

-- ============================================================
-- 3. Inventory stock — running balance + weighted-average cost,
--    one row per (product, warehouse). §19: "Inventory must be
--    tracked by warehouse."
-- ============================================================
create table inventory_stock (
  id                uuid primary key default gen_random_uuid(),
  organization_id   uuid not null references organizations(id) on delete cascade,
  product_id        uuid not null references products(id) on delete cascade,
  warehouse_id      uuid not null references warehouses(id) on delete cascade,
  quantity          numeric(14,3) not null default 0,
  avg_cost          numeric(14,2) not null default 0,
  updated_at        timestamptz not null default now(),
  unique (organization_id, product_id, warehouse_id)
);
create index inventory_stock_org_idx on inventory_stock(organization_id);

-- ============================================================
-- 4. Inventory movements — audit trail. §20: "Manual stock editing
--    must be restricted and audited." §46 Audit Logging.
-- ============================================================
create table inventory_movements (
  id                uuid primary key default gen_random_uuid(),
  organization_id   uuid not null references organizations(id) on delete cascade,
  product_id        uuid not null references products(id) on delete restrict,
  warehouse_id      uuid not null references warehouses(id) on delete restrict,
  movement_type     text not null check (movement_type in ('purchase','purchase_return','sale','sale_return','adjustment')),
  quantity_delta    numeric(14,3) not null,
  unit_cost         numeric(14,2),
  reference_type    text,
  reference_id      uuid,
  note              text,
  created_by        uuid references auth.users(id),
  created_at        timestamptz not null default now()
);
create index inventory_movements_org_idx on inventory_movements(organization_id);
create index inventory_movements_product_idx on inventory_movements(product_id, warehouse_id);

-- ============================================================
-- 5. Supplier payments. §23.
-- ============================================================
create table supplier_payments (
  id                    uuid primary key default gen_random_uuid(),
  organization_id       uuid not null references organizations(id) on delete cascade,
  supplier_id           uuid not null references suppliers(id) on delete restrict,
  purchase_invoice_id   uuid references purchase_invoices(id) on delete set null,
  amount                numeric(14,2) not null check (amount > 0),
  payment_date          date not null default current_date,
  payment_method        text,
  reference             text,
  notes                 text,
  created_by            uuid references auth.users(id),
  created_at            timestamptz not null default now()
);
create index supplier_payments_org_idx      on supplier_payments(organization_id);
create index supplier_payments_supplier_idx on supplier_payments(supplier_id);

-- ============================================================
-- 6. Supplier balances — §23 formula, live (no purchase returns yet).
--    security_invoker so it still respects the caller's RLS instead of
--    running as the view owner.
-- ============================================================
create view supplier_balances
with (security_invoker = true) as
select
  s.id as supplier_id,
  s.organization_id,
  coalesce(p.total_purchases, 0) as total_purchases,
  coalesce(pay.total_paid, 0) as total_paid,
  coalesce(p.total_purchases, 0) - coalesce(pay.total_paid, 0) as balance
from suppliers s
left join (
  select supplier_id, sum(total) as total_purchases
  from purchase_invoices
  group by supplier_id
) p on p.supplier_id = s.id
left join (
  select supplier_id, sum(amount) as total_paid
  from supplier_payments
  group by supplier_id
) pay on pay.supplier_id = s.id;

-- ============================================================
-- 7. RLS
-- ============================================================
alter table purchase_invoices      enable row level security;
alter table purchase_invoice_items enable row level security;
alter table inventory_stock        enable row level security;
alter table inventory_movements    enable row level security;
alter table supplier_payments      enable row level security;

create policy purchase_invoices_select on purchase_invoices for select using (is_org_member(organization_id));
create policy purchase_invoices_write  on purchase_invoices for insert with check (has_permission(organization_id, 'purchases.create'));
create policy purchase_invoices_update on purchase_invoices for update using (has_permission(organization_id, 'purchases.create'));
create policy purchase_invoices_delete on purchase_invoices for delete using (has_permission(organization_id, 'purchases.approve'));

create policy purchase_invoice_items_select on purchase_invoice_items for select using (is_org_member(organization_id));
create policy purchase_invoice_items_write  on purchase_invoice_items for insert with check (has_permission(organization_id, 'purchases.create'));

create policy inventory_stock_select on inventory_stock for select using (is_org_member(organization_id));
create policy inventory_stock_write  on inventory_stock for insert with check (has_permission(organization_id, 'inventory.adjust'));
create policy inventory_stock_update on inventory_stock for update using (has_permission(organization_id, 'inventory.adjust'));

create policy inventory_movements_select on inventory_movements for select using (is_org_member(organization_id));
create policy inventory_movements_write  on inventory_movements for insert with check (has_permission(organization_id, 'inventory.adjust'));

create policy supplier_payments_select on supplier_payments for select using (is_org_member(organization_id));
create policy supplier_payments_write  on supplier_payments for insert with check (has_permission(organization_id, 'treasury.manage'));

-- ============================================================
-- 8. Grants
-- ============================================================
grant select, insert, update, delete on purchase_invoices      to authenticated;
grant select, insert             on purchase_invoice_items      to authenticated;
grant select, insert, update      on inventory_stock            to authenticated;
grant select, insert             on inventory_movements         to authenticated;
grant select, insert             on supplier_payments           to authenticated;
grant select on supplier_balances to authenticated;

-- ============================================================
-- 9. create_purchase_invoice — the atomic RPC.
--    items is a jsonb array: [{ "product_id": uuid, "quantity": number,
--    "unit_cost": number, "discount": number }, ...]
-- ============================================================
create or replace function create_purchase_invoice(
  org_id uuid,
  p_supplier_id uuid,
  p_warehouse_id uuid,
  p_invoice_number text,
  p_invoice_date date,
  items jsonb,
  p_discount_total numeric,
  p_tax_total numeric,
  p_amount_paid numeric,
  p_payment_method text,
  p_notes text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  new_invoice_id uuid;
  item jsonb;
  v_product_id uuid;
  v_quantity numeric(14,3);
  v_unit_cost numeric(14,2);
  v_discount numeric(14,2);
  v_line_total numeric(14,2);
  v_subtotal numeric(14,2) := 0;
  v_total numeric(14,2);
  v_old_qty numeric(14,3);
  v_old_avg numeric(14,2);
  v_new_qty numeric(14,3);
  v_new_avg numeric(14,2);
  v_payment_status text;
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;
  if not is_org_member(org_id) then
    raise exception 'not a member of this organization';
  end if;
  if not has_permission(org_id, 'purchases.create') then
    raise exception 'missing purchases.create permission';
  end if;
  if not exists (select 1 from suppliers where id = p_supplier_id and organization_id = org_id) then
    raise exception 'supplier does not belong to this organization';
  end if;
  if not exists (select 1 from warehouses where id = p_warehouse_id and organization_id = org_id) then
    raise exception 'warehouse does not belong to this organization';
  end if;
  if jsonb_array_length(items) = 0 then
    raise exception 'a purchase invoice needs at least one item';
  end if;

  insert into purchase_invoices (organization_id, supplier_id, warehouse_id, invoice_number, invoice_date, notes, created_by)
  values (org_id, p_supplier_id, p_warehouse_id, nullif(p_invoice_number, ''), coalesce(p_invoice_date, current_date), nullif(p_notes, ''), auth.uid())
  returning id into new_invoice_id;

  for item in select * from jsonb_array_elements(items)
  loop
    v_product_id := (item->>'product_id')::uuid;
    v_quantity := (item->>'quantity')::numeric;
    v_unit_cost := (item->>'unit_cost')::numeric;
    v_discount := coalesce((item->>'discount')::numeric, 0);

    if not exists (select 1 from products where id = v_product_id and organization_id = org_id) then
      raise exception 'product % does not belong to this organization', v_product_id;
    end if;
    if v_quantity <= 0 then
      raise exception 'quantity must be greater than zero';
    end if;

    v_line_total := (v_quantity * v_unit_cost) - v_discount;
    v_subtotal := v_subtotal + (v_quantity * v_unit_cost);

    insert into purchase_invoice_items (organization_id, purchase_invoice_id, product_id, quantity, unit_cost, discount, line_total)
    values (org_id, new_invoice_id, v_product_id, v_quantity, v_unit_cost, v_discount, v_line_total);

    -- Weighted-average costing (§21), locking the row so concurrent
    -- purchases of the same product/warehouse don't race each other.
    select quantity, avg_cost into v_old_qty, v_old_avg
    from inventory_stock
    where product_id = v_product_id and warehouse_id = p_warehouse_id
    for update;

    if not found then
      v_old_qty := 0;
      v_old_avg := 0;
      insert into inventory_stock (organization_id, product_id, warehouse_id, quantity, avg_cost)
      values (org_id, v_product_id, p_warehouse_id, 0, 0);
    end if;

    v_new_qty := v_old_qty + v_quantity;
    v_new_avg := case when v_new_qty = 0 then 0 else ((v_old_qty * v_old_avg) + (v_quantity * v_unit_cost)) / v_new_qty end;

    update inventory_stock
    set quantity = v_new_qty, avg_cost = v_new_avg, updated_at = now()
    where product_id = v_product_id and warehouse_id = p_warehouse_id;

    insert into inventory_movements (organization_id, product_id, warehouse_id, movement_type, quantity_delta, unit_cost, reference_type, reference_id, created_by)
    values (org_id, v_product_id, p_warehouse_id, 'purchase', v_quantity, v_unit_cost, 'purchase_invoice', new_invoice_id, auth.uid());

    -- Keep "what to charge/cost now" (§18) in step with the new average.
    update product_prices set cost = v_new_avg, updated_at = now()
    where product_id = v_product_id and organization_id = org_id;
  end loop;

  v_total := v_subtotal - coalesce(p_discount_total, 0) + coalesce(p_tax_total, 0);
  v_payment_status := case
    when coalesce(p_amount_paid, 0) <= 0 then 'unpaid'
    when p_amount_paid >= v_total then 'paid'
    else 'partial'
  end;

  update purchase_invoices
  set subtotal = v_subtotal,
      discount_total = coalesce(p_discount_total, 0),
      tax_total = coalesce(p_tax_total, 0),
      total = v_total,
      amount_paid = least(coalesce(p_amount_paid, 0), v_total),
      payment_status = v_payment_status,
      updated_at = now()
  where id = new_invoice_id;

  if coalesce(p_amount_paid, 0) > 0 then
    insert into supplier_payments (organization_id, supplier_id, purchase_invoice_id, amount, payment_date, payment_method, created_by)
    values (org_id, p_supplier_id, new_invoice_id, least(p_amount_paid, v_total), coalesce(p_invoice_date, current_date), nullif(p_payment_method, ''), auth.uid());
  end if;

  return new_invoice_id;
end;
$$;

grant execute on function create_purchase_invoice(uuid, uuid, uuid, text, date, jsonb, numeric, numeric, numeric, text, text) to authenticated;

-- ============================================================
-- 10. record_supplier_payment — a standalone payment against a
--     supplier's balance, optionally applied to one invoice.
-- ============================================================
create or replace function record_supplier_payment(
  org_id uuid,
  p_supplier_id uuid,
  p_purchase_invoice_id uuid,
  p_amount numeric,
  p_payment_date date,
  p_payment_method text,
  p_reference text,
  p_notes text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  new_payment_id uuid;
  v_total numeric(14,2);
  v_amount_paid numeric(14,2);
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;
  if not is_org_member(org_id) then
    raise exception 'not a member of this organization';
  end if;
  if not has_permission(org_id, 'treasury.manage') then
    raise exception 'missing treasury.manage permission';
  end if;
  if not exists (select 1 from suppliers where id = p_supplier_id and organization_id = org_id) then
    raise exception 'supplier does not belong to this organization';
  end if;
  if p_amount <= 0 then
    raise exception 'amount must be greater than zero';
  end if;

  insert into supplier_payments (organization_id, supplier_id, purchase_invoice_id, amount, payment_date, payment_method, reference, notes, created_by)
  values (org_id, p_supplier_id, p_purchase_invoice_id, p_amount, coalesce(p_payment_date, current_date), nullif(p_payment_method, ''), nullif(p_reference, ''), nullif(p_notes, ''), auth.uid())
  returning id into new_payment_id;

  if p_purchase_invoice_id is not null then
    select total, amount_paid into v_total, v_amount_paid
    from purchase_invoices
    where id = p_purchase_invoice_id and organization_id = org_id
    for update;

    if found then
      v_amount_paid := v_amount_paid + p_amount;
      update purchase_invoices
      set amount_paid = v_amount_paid,
          payment_status = case when v_amount_paid >= v_total then 'paid' when v_amount_paid <= 0 then 'unpaid' else 'partial' end,
          updated_at = now()
      where id = p_purchase_invoice_id;
    end if;
  end if;

  return new_payment_id;
end;
$$;

grant execute on function record_supplier_payment(uuid, uuid, uuid, numeric, date, text, text, text) to authenticated;

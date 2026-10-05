-- Kayan — Phase 4: Sales
-- Mirrors 0005's pattern: an atomic SECURITY DEFINER RPC creates a sales
-- invoice + items + inventory movements in one transaction, decrementing
-- inventory_stock (quantity only — weighted-average cost only moves on
-- purchases, per §21) and computing COGS/profit per §25–26 as it goes.
-- Sales returns (§27) are not in this pass — same call as deferring
-- purchase returns in 0005: reversing recognized profit correctly needs
-- its own careful pass rather than being bolted on here.

-- ============================================================
-- 1. Sales invoices
-- ============================================================
create table sales_invoices (
  id                uuid primary key default gen_random_uuid(),
  organization_id   uuid not null references organizations(id) on delete cascade,
  customer_id       uuid not null references customers(id) on delete restrict,
  warehouse_id      uuid not null references warehouses(id) on delete restrict,
  invoice_number    text,
  invoice_date      date not null default current_date,
  subtotal          numeric(14,2) not null default 0,  -- gross sales (qty × price), before discount
  discount_total    numeric(14,2) not null default 0,
  tax_total         numeric(14,2) not null default 0,
  total             numeric(14,2) not null default 0,   -- what the customer owes: net sales + tax
  cogs_total         numeric(14,2) not null default 0,
  profit_total       numeric(14,2) not null default 0,   -- net sales (subtotal - discount) - cogs, per §25
  amount_paid       numeric(14,2) not null default 0,
  payment_status    text not null default 'unpaid' check (payment_status in ('unpaid','partial','paid')),
  notes             text,
  created_by        uuid references auth.users(id),
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);
create index sales_invoices_org_idx      on sales_invoices(organization_id);
create index sales_invoices_customer_idx on sales_invoices(customer_id);

-- ============================================================
-- 2. Sales invoice items — §26 item-level profitability, stored
--    (not recomputed later) so historical cost stays intact even if a
--    product's average cost has since moved (§48 Historical Data Integrity).
-- ============================================================
create table sales_invoice_items (
  id                uuid primary key default gen_random_uuid(),
  organization_id   uuid not null references organizations(id) on delete cascade,
  sales_invoice_id  uuid not null references sales_invoices(id) on delete cascade,
  product_id        uuid not null references products(id) on delete restrict,
  quantity          numeric(14,3) not null check (quantity > 0),
  unit_price        numeric(14,2) not null check (unit_price >= 0),
  discount          numeric(14,2) not null default 0,
  line_total        numeric(14,2) not null default 0,  -- sales value: quantity×unit_price − discount
  unit_cost         numeric(14,2) not null default 0,  -- captured from inventory_stock.avg_cost at sale time
  cost_total        numeric(14,2) not null default 0,
  profit            numeric(14,2) not null default 0
);
create index sales_invoice_items_invoice_idx on sales_invoice_items(sales_invoice_id);

-- ============================================================
-- 3. Customer collections. §28.
-- ============================================================
create table customer_collections (
  id                    uuid primary key default gen_random_uuid(),
  organization_id       uuid not null references organizations(id) on delete cascade,
  customer_id           uuid not null references customers(id) on delete restrict,
  sales_invoice_id      uuid references sales_invoices(id) on delete set null,
  amount                numeric(14,2) not null check (amount > 0),
  collection_date       date not null default current_date,
  payment_method        text,
  reference             text,
  notes                 text,
  created_by            uuid references auth.users(id),
  created_at            timestamptz not null default now()
);
create index customer_collections_org_idx      on customer_collections(organization_id);
create index customer_collections_customer_idx on customer_collections(customer_id);

-- ============================================================
-- 4. Customer balances — §28 formula (no returns/credits yet).
-- ============================================================
create view customer_balances
with (security_invoker = true) as
select
  c.id as customer_id,
  c.organization_id,
  coalesce(s.total_sales, 0) as total_sales,
  coalesce(col.total_collected, 0) as total_collected,
  coalesce(s.total_sales, 0) - coalesce(col.total_collected, 0) as balance
from customers c
left join (
  select customer_id, sum(total) as total_sales
  from sales_invoices
  group by customer_id
) s on s.customer_id = c.id
left join (
  select customer_id, sum(amount) as total_collected
  from customer_collections
  group by customer_id
) col on col.customer_id = c.id;

-- ============================================================
-- 5. RLS
-- ============================================================
alter table sales_invoices       enable row level security;
alter table sales_invoice_items  enable row level security;
alter table customer_collections enable row level security;

create policy sales_invoices_select on sales_invoices for select using (is_org_member(organization_id));
create policy sales_invoices_write  on sales_invoices for insert with check (has_permission(organization_id, 'sales.create'));
create policy sales_invoices_update on sales_invoices for update using (has_permission(organization_id, 'sales.create'));
create policy sales_invoices_delete on sales_invoices for delete using (has_permission(organization_id, 'sales.approve'));

create policy sales_invoice_items_select on sales_invoice_items for select using (is_org_member(organization_id));
create policy sales_invoice_items_write  on sales_invoice_items for insert with check (has_permission(organization_id, 'sales.create'));

create policy customer_collections_select on customer_collections for select using (is_org_member(organization_id));
create policy customer_collections_write  on customer_collections for insert with check (has_permission(organization_id, 'treasury.manage'));

-- ============================================================
-- 6. Grants
-- ============================================================
grant select, insert, update, delete on sales_invoices       to authenticated;
grant select, insert                on sales_invoice_items    to authenticated;
grant select, insert                on customer_collections   to authenticated;
grant select on customer_balances to authenticated;

-- ============================================================
-- 7. create_sales_invoice — the atomic RPC.
--    items is a jsonb array: [{ "product_id": uuid, "quantity": number,
--    "unit_price": number, "discount": number }, ...]
-- ============================================================
create or replace function create_sales_invoice(
  org_id uuid,
  p_customer_id uuid,
  p_warehouse_id uuid,
  p_invoice_number text,
  p_invoice_date date,
  items jsonb,
  p_discount_total numeric,
  p_tax_total numeric,
  p_amount_collected numeric,
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
  v_unit_price numeric(14,2);
  v_discount numeric(14,2);
  v_line_total numeric(14,2);
  v_unit_cost numeric(14,2);
  v_cost_total numeric(14,2);
  v_line_profit numeric(14,2);
  v_track_inventory boolean;
  v_old_qty numeric(14,3);
  v_old_avg numeric(14,2);
  v_subtotal numeric(14,2) := 0;
  v_cogs numeric(14,2) := 0;
  v_total numeric(14,2);
  v_net_sales numeric(14,2);
  v_payment_status text;
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;
  if not is_org_member(org_id) then
    raise exception 'not a member of this organization';
  end if;
  if not has_permission(org_id, 'sales.create') then
    raise exception 'missing sales.create permission';
  end if;
  if not exists (select 1 from customers where id = p_customer_id and organization_id = org_id) then
    raise exception 'customer does not belong to this organization';
  end if;
  if not exists (select 1 from warehouses where id = p_warehouse_id and organization_id = org_id) then
    raise exception 'warehouse does not belong to this organization';
  end if;
  if jsonb_array_length(items) = 0 then
    raise exception 'a sales invoice needs at least one item';
  end if;

  insert into sales_invoices (organization_id, customer_id, warehouse_id, invoice_number, invoice_date, notes, created_by)
  values (org_id, p_customer_id, p_warehouse_id, nullif(p_invoice_number, ''), coalesce(p_invoice_date, current_date), nullif(p_notes, ''), auth.uid())
  returning id into new_invoice_id;

  for item in select * from jsonb_array_elements(items)
  loop
    v_product_id := (item->>'product_id')::uuid;
    v_quantity := (item->>'quantity')::numeric;
    v_unit_price := (item->>'unit_price')::numeric;
    v_discount := coalesce((item->>'discount')::numeric, 0);

    select track_inventory into v_track_inventory from products where id = v_product_id and organization_id = org_id;
    if not found then
      raise exception 'product % does not belong to this organization', v_product_id;
    end if;
    if v_quantity <= 0 then
      raise exception 'quantity must be greater than zero';
    end if;

    if v_track_inventory then
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

      v_unit_cost := v_old_avg;

      update inventory_stock
      set quantity = v_old_qty - v_quantity, updated_at = now()
      where product_id = v_product_id and warehouse_id = p_warehouse_id;

      insert into inventory_movements (organization_id, product_id, warehouse_id, movement_type, quantity_delta, unit_cost, reference_type, reference_id, created_by)
      values (org_id, v_product_id, p_warehouse_id, 'sale', -v_quantity, v_unit_cost, 'sales_invoice', new_invoice_id, auth.uid());
    else
      select coalesce(cost, 0) into v_unit_cost from product_prices where product_id = v_product_id and organization_id = org_id;
      v_unit_cost := coalesce(v_unit_cost, 0);
    end if;

    v_line_total := (v_quantity * v_unit_price) - v_discount;
    v_cost_total := v_quantity * v_unit_cost;
    v_line_profit := v_line_total - v_cost_total;

    insert into sales_invoice_items (organization_id, sales_invoice_id, product_id, quantity, unit_price, discount, line_total, unit_cost, cost_total, profit)
    values (org_id, new_invoice_id, v_product_id, v_quantity, v_unit_price, v_discount, v_line_total, v_unit_cost, v_cost_total, v_line_profit);

    v_subtotal := v_subtotal + (v_quantity * v_unit_price);
    v_cogs := v_cogs + v_cost_total;
  end loop;

  v_net_sales := v_subtotal - coalesce(p_discount_total, 0);
  v_total := v_net_sales + coalesce(p_tax_total, 0);
  v_payment_status := case
    when coalesce(p_amount_collected, 0) <= 0 then 'unpaid'
    when p_amount_collected >= v_total then 'paid'
    else 'partial'
  end;

  update sales_invoices
  set subtotal = v_subtotal,
      discount_total = coalesce(p_discount_total, 0),
      tax_total = coalesce(p_tax_total, 0),
      total = v_total,
      cogs_total = v_cogs,
      profit_total = v_net_sales - v_cogs,
      amount_paid = least(coalesce(p_amount_collected, 0), v_total),
      payment_status = v_payment_status,
      updated_at = now()
  where id = new_invoice_id;

  if coalesce(p_amount_collected, 0) > 0 then
    insert into customer_collections (organization_id, customer_id, sales_invoice_id, amount, collection_date, payment_method, created_by)
    values (org_id, p_customer_id, new_invoice_id, least(p_amount_collected, v_total), coalesce(p_invoice_date, current_date), nullif(p_payment_method, ''), auth.uid());
  end if;

  return new_invoice_id;
end;
$$;

grant execute on function create_sales_invoice(uuid, uuid, uuid, text, date, jsonb, numeric, numeric, numeric, text, text) to authenticated;

-- ============================================================
-- 8. record_customer_collection — a standalone collection against a
--    customer's balance, optionally applied to one invoice.
-- ============================================================
create or replace function record_customer_collection(
  org_id uuid,
  p_customer_id uuid,
  p_sales_invoice_id uuid,
  p_amount numeric,
  p_collection_date date,
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
  new_collection_id uuid;
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
  if not exists (select 1 from customers where id = p_customer_id and organization_id = org_id) then
    raise exception 'customer does not belong to this organization';
  end if;
  if p_amount <= 0 then
    raise exception 'amount must be greater than zero';
  end if;

  insert into customer_collections (organization_id, customer_id, sales_invoice_id, amount, collection_date, payment_method, reference, notes, created_by)
  values (org_id, p_customer_id, p_sales_invoice_id, p_amount, coalesce(p_collection_date, current_date), nullif(p_payment_method, ''), nullif(p_reference, ''), nullif(p_notes, ''), auth.uid())
  returning id into new_collection_id;

  if p_sales_invoice_id is not null then
    select total, amount_paid into v_total, v_amount_paid
    from sales_invoices
    where id = p_sales_invoice_id and organization_id = org_id
    for update;

    if found then
      v_amount_paid := v_amount_paid + p_amount;
      update sales_invoices
      set amount_paid = v_amount_paid,
          payment_status = case when v_amount_paid >= v_total then 'paid' when v_amount_paid <= 0 then 'unpaid' else 'partial' end,
          updated_at = now()
      where id = p_sales_invoice_id;
    end if;
  end if;

  return new_collection_id;
end;
$$;

grant execute on function record_customer_collection(uuid, uuid, uuid, numeric, date, text, text, text) to authenticated;

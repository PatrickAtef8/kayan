-- Kayan — Reports package, Phase 1: inventory reports (reorder level + item movement)
--
-- Adds the product master-data fields the new reports need, and two reports:
--
--   * report_reorder           تقرير حد الطلب       (daily shortages vs. the level set per product)
--   * report_product_movement  تقرير حركة الأصناف   (opening / sales / remaining, best & worst sellers)
--
-- Product fields (all optional, defaults keep every existing product valid):
--   barcode          الباركود            — unique per organization when present
--   reorder_level    حد الطلب            — 0 = no level set (the product never shows as a shortage)
--   units_per_carton عدد الوحدات بالكرتونة — used to show quantities in cartons (rep report, Phase 4)
--
-- Design notes
--   * Both reports are read-only and run as the caller (RLS applies), gated by
--     assert_report_access(org, false) exactly like report_inventory_stock: they expose
--     quantities only, never cost.
--   * Item movement is computed from the stock ledger (inventory_movements). Every RPC that
--     changes inventory_stock also writes a ledger row, so Σ ledger = stock on hand; the
--     test suite asserts that equality, so a future RPC that forgets the ledger is caught.
--   * Days are Cairo calendar days, the same convention as report_stock_movements.
--   * "Sold" = quantity leaving on sales invoices (bonus units included — they are stock
--     that left). Net sold = sold − resalable returns (damaged returns never re-enter stock,
--     so they are not in the ledger and cannot be netted here).

-- ============================================================
-- 1. Product fields
-- ============================================================
alter table products
  add column if not exists barcode          text,
  add column if not exists reorder_level    numeric(14,3) not null default 0,
  add column if not exists units_per_carton numeric(14,3);

alter table products drop constraint if exists products_reorder_level_chk;
alter table products add constraint products_reorder_level_chk
  check (reorder_level >= 0 and reorder_level < 1000000000);

alter table products drop constraint if exists products_units_per_carton_chk;
alter table products add constraint products_units_per_carton_chk
  check (units_per_carton is null or (units_per_carton > 0 and units_per_carton < 1000000000));

alter table products drop constraint if exists products_barcode_chk;
alter table products add constraint products_barcode_chk
  check (barcode is null or (length(btrim(barcode)) between 1 and 64));

-- one barcode = one product inside an organization
create unique index if not exists products_org_barcode_uniq
  on products (organization_id, barcode) where barcode is not null;

-- the users' table-level grants are column lists (see 0004/0034) — new columns need adding
grant select (barcode, reorder_level, units_per_carton) on products to authenticated;
grant insert (barcode, reorder_level, units_per_carton) on products to authenticated;
grant update (barcode, reorder_level, units_per_carton) on products to authenticated;

-- ============================================================
-- 2. تقرير حد الطلب — daily shortages
-- ============================================================
-- A product is listed when it is active, tracked, has a level > 0 and its stock is at or
-- below that level. With a warehouse chosen, stock and level are compared inside that
-- warehouse only; otherwise the level applies to the total across all warehouses.
create or replace function report_reorder(org_id uuid, p_warehouse uuid default null)
returns table (
  product_id    uuid,
  product_name  text,
  sku           text,
  barcode       text,
  unit          text,
  category_name text,
  current_qty   numeric,
  reorder_level numeric,
  shortage      numeric,   -- how far below the level (level − stock); for "out" it is the full level
  status        text       -- 'out' (stock <= 0) | 'low' (0 < stock <= level)
)
language plpgsql
stable
set search_path = public
as $$
begin
  perform assert_report_access(org_id, false);

  return query
  with stock as (
    select s.product_id, sum(s.quantity)::numeric as qty
    from inventory_stock s
    where s.organization_id = org_id
      and (p_warehouse is null or s.warehouse_id = p_warehouse)
    group by s.product_id
  )
  select p.id, p.name, p.sku, p.barcode, p.unit, c.name,
         greatest(coalesce(st.qty, 0), 0)::numeric,
         p.reorder_level::numeric,
         (p.reorder_level - greatest(coalesce(st.qty, 0), 0))::numeric,
         case when coalesce(st.qty, 0) <= 0 then 'out' else 'low' end
  from products p
  left join product_categories c on c.id = p.category_id
  left join stock st on st.product_id = p.id
  where p.organization_id = org_id
    and p.is_active
    and p.track_inventory
    and p.reorder_level > 0
    and coalesce(st.qty, 0) <= p.reorder_level
  order by (case when coalesce(st.qty, 0) <= 0 then 0 else 1 end),
           (p.reorder_level - greatest(coalesce(st.qty, 0), 0)) desc,
           p.name;
end;
$$;

-- ============================================================
-- 3. تقرير حركة الأصناف — opening, in, sold, remaining, rank
-- ============================================================
create or replace function report_product_movement(
  org_id       uuid,
  p_from       date default null,
  p_to         date default null,
  p_warehouse  uuid default null
)
returns table (
  product_id          uuid,
  product_name        text,
  sku                 text,
  barcode             text,
  unit                text,
  units_per_carton    numeric,
  opening_qty         numeric,   -- رصيد أول المدة (stock before p_from)
  purchased_qty       numeric,   -- مشتريات
  sale_returned_qty   numeric,   -- مرتجع مبيعات (resalable)
  sold_qty            numeric,   -- مبيعات الصنف (units that left on sales invoices)
  purchase_returned_qty numeric, -- مرتجع مشتريات
  other_net_qty       numeric,   -- تسويات + تحويلات (net)
  closing_qty         numeric,   -- المتبقي من الصنف (stock at end of period)
  net_sold_qty        numeric,   -- sold − resalable returns
  sales_rank          bigint     -- 1 = best seller (by net sold); ties share the lower name order
)
language plpgsql
stable
set search_path = public
as $$
begin
  perform assert_report_access(org_id, false);

  return query
  with mv as (
    select m.product_id as pid,
           (m.created_at at time zone 'Africa/Cairo')::date as d,
           m.movement_type as t,
           m.quantity_delta::numeric as q
    from inventory_movements m
    where m.organization_id = org_id
      and (p_warehouse is null or m.warehouse_id = p_warehouse)
      and (p_to is null or (m.created_at at time zone 'Africa/Cairo')::date <= p_to)
  ),
  agg as (
    select pid,
      coalesce(sum(q) filter (where p_from is not null and d < p_from), 0) as opening,
      coalesce(sum(q) filter (where (p_from is null or d >= p_from) and t = 'purchase'), 0) as purchased,
      coalesce(sum(q) filter (where (p_from is null or d >= p_from) and t = 'sale_return'), 0) as sale_ret,
      coalesce(-sum(q) filter (where (p_from is null or d >= p_from) and t = 'sale'), 0) as sold,
      coalesce(-sum(q) filter (where (p_from is null or d >= p_from) and t = 'purchase_return'), 0) as purch_ret,
      coalesce(sum(q) filter (where (p_from is null or d >= p_from) and t in ('adjustment', 'transfer_in', 'transfer_out')), 0) as other,
      coalesce(sum(q), 0) as closing
    from mv
    group by pid
  )
  select p.id, p.name, p.sku, p.barcode, p.unit, p.units_per_carton::numeric,
         coalesce(a.opening, 0), coalesce(a.purchased, 0), coalesce(a.sale_ret, 0), coalesce(a.sold, 0),
         coalesce(a.purch_ret, 0), coalesce(a.other, 0), coalesce(a.closing, 0),
         coalesce(a.sold, 0) - coalesce(a.sale_ret, 0),
         rank() over (order by coalesce(a.sold, 0) - coalesce(a.sale_ret, 0) desc)
  from products p
  left join agg a on a.pid = p.id
  where p.organization_id = org_id
    and p.is_active
    and p.track_inventory
  order by (coalesce(a.sold, 0) - coalesce(a.sale_ret, 0)) desc, p.name;
end;
$$;

grant execute on function report_reorder(uuid, uuid) to authenticated;
grant execute on function report_product_movement(uuid, date, date, uuid) to authenticated;

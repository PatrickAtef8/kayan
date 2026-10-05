-- Kayan — Phase 2: Master Data
-- Customers, suppliers, product catalog (with categories + per-company
-- pricing), and warehouses. Same pattern as Phase 1: every table carries
-- organization_id, RLS is enabled, and grants are included this time
-- (0003_grants.sql taught us not to forget this).

-- ============================================================
-- 1. Customers
-- ============================================================
create table customers (
  id                uuid primary key default gen_random_uuid(),
  organization_id   uuid not null references organizations(id) on delete cascade,
  name              text not null,
  phone             text,
  email             text,
  address           text,
  customer_type     text,                 -- e.g. 'retail' | 'wholesale' | 'market'
  credit_status     text not null default 'good' check (credit_status in ('good','watch','blocked')),
  is_active         boolean not null default true,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);
create index customers_org_idx on customers(organization_id);

-- ============================================================
-- 2. Suppliers
-- ============================================================
create table suppliers (
  id                uuid primary key default gen_random_uuid(),
  organization_id   uuid not null references organizations(id) on delete cascade,
  name              text not null,
  phone             text,
  email             text,
  address           text,
  is_active         boolean not null default true,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);
create index suppliers_org_idx on suppliers(organization_id);

-- ============================================================
-- 3. Product categories
-- ============================================================
create table product_categories (
  id                uuid primary key default gen_random_uuid(),
  organization_id   uuid not null references organizations(id) on delete cascade,
  name              text not null,
  created_at        timestamptz not null default now(),
  unique (organization_id, name)
);

-- ============================================================
-- 4. Products
-- ============================================================
create table products (
  id                uuid primary key default gen_random_uuid(),
  organization_id   uuid not null references organizations(id) on delete cascade,
  category_id       uuid references product_categories(id) on delete set null,
  name              text not null,
  sku               text,
  unit              text not null default 'قطعة', -- 'piece' by default; company can rename
  track_inventory   boolean not null default true,
  is_active         boolean not null default true,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  unique (organization_id, sku)
);
create index products_org_idx on products(organization_id);

-- ============================================================
-- 5. Product pricing (§18 — company-specific, never a shared global price)
-- ============================================================
-- One current price row per product. Historical invoice prices are captured
-- on the invoice line itself (Phase 4) — this table is "what to charge now",
-- not a price history log.
create table product_prices (
  id                uuid primary key default gen_random_uuid(),
  organization_id   uuid not null references organizations(id) on delete cascade,
  product_id        uuid not null references products(id) on delete cascade,
  cost              numeric(14,2) not null default 0,
  selling_price     numeric(14,2) not null default 0,
  updated_at        timestamptz not null default now(),
  unique (organization_id, product_id)
);

-- ============================================================
-- 6. Warehouses
-- ============================================================
create table warehouses (
  id                uuid primary key default gen_random_uuid(),
  organization_id   uuid not null references organizations(id) on delete cascade,
  name              text not null,
  location          text,
  is_active         boolean not null default true,
  created_at        timestamptz not null default now()
);
create index warehouses_org_idx on warehouses(organization_id);

-- ============================================================
-- 7. Row Level Security — same is_org_member()/has_permission() pattern
-- ============================================================
alter table customers          enable row level security;
alter table suppliers          enable row level security;
alter table product_categories enable row level security;
alter table products           enable row level security;
alter table product_prices     enable row level security;
alter table warehouses         enable row level security;

create policy customers_select on customers for select using (is_org_member(organization_id));
create policy customers_write  on customers for insert with check (is_org_member(organization_id));
create policy customers_update on customers for update using (is_org_member(organization_id));
create policy customers_delete on customers for delete using (has_permission(organization_id, 'manage_settings'));

create policy suppliers_select on suppliers for select using (is_org_member(organization_id));
create policy suppliers_write  on suppliers for insert with check (is_org_member(organization_id));
create policy suppliers_update on suppliers for update using (is_org_member(organization_id));
create policy suppliers_delete on suppliers for delete using (has_permission(organization_id, 'manage_settings'));

create policy categories_select on product_categories for select using (is_org_member(organization_id));
create policy categories_write  on product_categories for insert with check (is_org_member(organization_id));
create policy categories_update on product_categories for update using (is_org_member(organization_id));
create policy categories_delete on product_categories for delete using (has_permission(organization_id, 'manage_settings'));

create policy products_select on products for select using (is_org_member(organization_id));
create policy products_write  on products for insert with check (is_org_member(organization_id));
create policy products_update on products for update using (is_org_member(organization_id));
create policy products_delete on products for delete using (has_permission(organization_id, 'manage_settings'));

create policy prices_select on product_prices for select using (is_org_member(organization_id));
create policy prices_write  on product_prices for insert with check (is_org_member(organization_id));
create policy prices_update on product_prices for update using (is_org_member(organization_id));
create policy prices_delete on product_prices for delete using (has_permission(organization_id, 'manage_settings'));

create policy warehouses_select on warehouses for select using (is_org_member(organization_id));
create policy warehouses_write  on warehouses for insert with check (is_org_member(organization_id));
create policy warehouses_update on warehouses for update using (is_org_member(organization_id));
create policy warehouses_delete on warehouses for delete using (has_permission(organization_id, 'manage_settings'));

-- ============================================================
-- 8. Grants — do NOT repeat the Phase 1 mistake
-- ============================================================
grant select, insert, update, delete on customers          to authenticated;
grant select, insert, update, delete on suppliers          to authenticated;
grant select, insert, update, delete on product_categories to authenticated;
grant select, insert, update, delete on products            to authenticated;
grant select, insert, update, delete on product_prices      to authenticated;
grant select, insert, update, delete on warehouses           to authenticated;

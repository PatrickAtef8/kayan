-- Kayan — Phase 1: Foundation
-- Organizations, membership, roles/permissions, module toggles, audit log.
-- Every tenant-owned table carries organization_id and is protected by RLS.

create extension if not exists "pgcrypto";

-- ============================================================
-- 1. Organizations
-- ============================================================
create table organizations (
  id            uuid primary key default gen_random_uuid(),
  name          text not null,
  business_type text,
  country       text not null default 'EG',
  currency      text not null default 'EGP',
  language      text not null default 'ar',
  settings      jsonb not null default '{}'::jsonb,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

-- ============================================================
-- 2. Membership (the anchor every RLS policy checks against)
-- ============================================================
-- One row per (user, organization). A user can belong to more than one
-- organization; every request must be scoped to exactly one active org
-- via the app's "current organization" context (see lib/supabase).
create table organization_users (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  user_id         uuid not null references auth.users(id) on delete cascade,
  role_id         uuid, -- fk added after roles table exists
  status          text not null default 'active' check (status in ('active','invited','disabled')),
  created_at      timestamptz not null default now(),
  unique (organization_id, user_id)
);

-- ============================================================
-- 3. Roles & permissions
-- ============================================================
create table roles (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid references organizations(id) on delete cascade, -- null = system default role template
  name            text not null,
  key             text not null, -- 'owner' | 'admin' | 'accountant' | 'sales' | 'warehouse' | custom
  is_system       boolean not null default false,
  created_at      timestamptz not null default now(),
  unique (organization_id, key)
);

alter table organization_users
  add constraint organization_users_role_fk
  foreign key (role_id) references roles(id) on delete set null;

-- Static permission catalog (view/create/edit/delete/approve/export/manage_settings/view_financial, etc.)
create table permissions (
  key         text primary key,
  description text not null,
  category    text not null -- e.g. 'sales', 'finance', 'settings'
);

create table role_permissions (
  role_id         uuid not null references roles(id) on delete cascade,
  permission_key  text not null references permissions(key) on delete cascade,
  primary key (role_id, permission_key)
);

-- ============================================================
-- 4. Modules (per-company feature toggles)
-- ============================================================
create table organization_modules (
  organization_id uuid not null references organizations(id) on delete cascade,
  module_key      text not null, -- 'sales' | 'purchases' | 'inventory' | 'expenses' | 'treasury' | 'representatives' | 'partners' | 'offers' | 'reports'
  enabled         boolean not null default true,
  primary key (organization_id, module_key)
);

-- ============================================================
-- 5. Audit log
-- ============================================================
create table audit_logs (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  user_id         uuid references auth.users(id),
  action          text not null,       -- e.g. 'invoice.created'
  entity          text not null,       -- e.g. 'sales_invoice'
  entity_id       uuid,
  before_data     jsonb,
  after_data      jsonb,
  created_at      timestamptz not null default now()
);

-- ============================================================
-- 6. Tenant-isolation helper (SECURITY DEFINER avoids RLS recursion)
-- ============================================================
create or replace function is_org_member(target_org uuid)
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists (
    select 1 from organization_users ou
    where ou.organization_id = target_org
      and ou.user_id = auth.uid()
      and ou.status = 'active'
  );
$$;

create or replace function has_permission(target_org uuid, perm_key text)
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists (
    select 1
    from organization_users ou
    join role_permissions rp on rp.role_id = ou.role_id
    where ou.organization_id = target_org
      and ou.user_id = auth.uid()
      and ou.status = 'active'
      and rp.permission_key = perm_key
  );
$$;

-- ============================================================
-- 7. Row Level Security
-- ============================================================
alter table organizations         enable row level security;
alter table organization_users    enable row level security;
alter table roles                 enable row level security;
alter table organization_modules  enable row level security;
alter table audit_logs            enable row level security;

-- Organizations: visible only to members; created rows must be self-inserted then joined.
create policy org_select on organizations
  for select using (is_org_member(id));

create policy org_update on organizations
  for update using (has_permission(id, 'manage_settings'));

-- Anyone authenticated may create an organization (onboarding); they become
-- its first member via a follow-up insert into organization_users done in
-- the same server-side transaction as owner.
create policy org_insert on organizations
  for insert with check (auth.uid() is not null);

-- organization_users: members can see their own org's membership list.
create policy org_users_select on organization_users
  for select using (is_org_member(organization_id));

create policy org_users_manage on organization_users
  for insert with check (has_permission(organization_id, 'manage_settings') or not exists (
    select 1 from organization_users existing where existing.organization_id = organization_users.organization_id
  ));

create policy org_users_update on organization_users
  for update using (has_permission(organization_id, 'manage_settings'));

create policy org_users_delete on organization_users
  for delete using (has_permission(organization_id, 'manage_settings'));

-- roles: system role templates (organization_id is null) are readable by everyone
-- authenticated; org-specific custom roles are scoped.
create policy roles_select on roles
  for select using (organization_id is null or is_org_member(organization_id));

create policy roles_manage on roles
  for all using (organization_id is not null and has_permission(organization_id, 'manage_settings'))
  with check (organization_id is not null and has_permission(organization_id, 'manage_settings'));

-- modules
create policy modules_select on organization_modules
  for select using (is_org_member(organization_id));

create policy modules_manage on organization_modules
  for all using (has_permission(organization_id, 'manage_settings'))
  with check (has_permission(organization_id, 'manage_settings'));

-- audit logs: readable by members with an audit permission, insert-only otherwise (no update/delete)
create policy audit_select on audit_logs
  for select using (is_org_member(organization_id));

create policy audit_insert on audit_logs
  for insert with check (is_org_member(organization_id));

-- ============================================================
-- 8. Seed: system role templates + baseline permission catalog
-- ============================================================
insert into roles (organization_id, name, key, is_system) values
  (null, 'Owner', 'owner', true),
  (null, 'Admin', 'admin', true),
  (null, 'Accountant', 'accountant', true),
  (null, 'Sales Representative', 'sales', true),
  (null, 'Warehouse', 'warehouse', true);

insert into permissions (key, description, category) values
  ('view_dashboard', 'View dashboard', 'general'),
  ('view_financial', 'View financial figures (profit, margins, balances)', 'finance'),
  ('manage_settings', 'Manage organization, users, roles, modules', 'settings'),
  ('sales.create', 'Create sales invoices', 'sales'),
  ('sales.edit', 'Edit sales invoices', 'sales'),
  ('sales.approve', 'Approve/cancel sales invoices', 'sales'),
  ('purchases.create', 'Create purchase invoices', 'purchases'),
  ('purchases.approve', 'Approve purchase invoices', 'purchases'),
  ('treasury.manage', 'Record payments/collections/withdrawals', 'treasury'),
  ('inventory.adjust', 'Manually adjust stock (audited)', 'inventory'),
  ('reports.export', 'Export reports (CSV/Excel/PDF)', 'reports')
on conflict (key) do nothing;

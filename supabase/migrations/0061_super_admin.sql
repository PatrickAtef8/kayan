-- Kayan — 0061: platform (Super Admin) back office
--
-- WHAT THIS ADDS (nothing existing is changed)
--   * platform_pricing_config   — optional OVERRIDES of the package settings in src/config/pricing.config.ts (prices, modules,
--                                 limits). While this table is empty — which is how it ships — Kayan behaves exactly as it
--                                 does today: the values in the code are the configuration. Readable by everyone (the prices
--                                 are public on /pricing); writable only through the functions below.
--   * platform_pricing_history  — every save / reset / restore, with who and when, so any state can be restored.
--   * admin_audit_log           — everything a Super Admin does (config changes, deactivations, deletions, free licenses).
--   * organization_licenses.complimentary — a license granted by the platform owner at no charge (no payment, never expires).
--   * admin_* functions         — executable by the SERVICE ROLE only. The Next.js server calls them after it has verified,
--                                 server-side, that the signed-in user is a Super Admin (SUPER_ADMIN_USER_IDS / _EMAILS).
--                                 A browser session cannot call any of them.
--
-- WHAT IT DOES NOT TOUCH: no existing table, policy, function, trigger or row. RLS and tenant isolation are unchanged.

alter table organization_licenses add column if not exists complimentary boolean not null default false;

create table platform_pricing_config (
  id         smallint primary key check (id = 1),     -- a single row
  config     jsonb not null check (jsonb_typeof(config) = 'object'),
  updated_at timestamptz not null default now(),
  updated_by uuid
);

create table platform_pricing_history (
  id                  bigint generated always as identity primary key,
  action              text not null check (action in ('save', 'reset', 'restore')),
  config              jsonb,                           -- null for a reset (= back to the values in the code)
  applied_to_existing integer not null default 0,
  note                text,
  created_by          uuid,
  created_at          timestamptz not null default now()
);

create table admin_audit_log (
  id         bigint generated always as identity primary key,
  admin_id   uuid,
  action     text not null,
  target_type text,
  target_id  text,
  details    jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index admin_audit_log_created_idx on admin_audit_log (created_at desc);

alter table platform_pricing_config  enable row level security;
alter table platform_pricing_history enable row level security;
alter table admin_audit_log          enable row level security;

-- the package prices are public information (they are printed on /pricing): anyone may READ the override row
create policy pricing_config_public_read on platform_pricing_config for select to anon, authenticated using (true);

revoke all on platform_pricing_config, platform_pricing_history, admin_audit_log from public, anon, authenticated;
grant select on platform_pricing_config to anon, authenticated;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    grant select, insert, update, delete on platform_pricing_config, platform_pricing_history, admin_audit_log to service_role;
  end if;
end $$;

-- ============================================================
-- Functions (service role only)
-- ============================================================
create or replace function admin_audit(p_admin uuid, p_action text, p_type text, p_id text, p_details jsonb) returns void
language sql security definer set search_path = public as $$
  insert into admin_audit_log (admin_id, action, target_type, target_id, details) values (p_admin, p_action, p_type, p_id, coalesce(p_details, '{}'::jsonb))
$$;

-- Save the package settings. p_entitlements = {packageKey: {modules, max_members, max_warehouses}} for the same config; when
-- p_apply_existing is true it is ALSO written into the licenses of companies that already bought that package (never into
-- complimentary ones). Limits only ever apply on the way in, so lowering them disables nothing a company already has.
create or replace function admin_save_pricing_config(p_admin uuid, p_config jsonb, p_entitlements jsonb, p_apply_existing boolean, p_action text, p_note text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_key text; v_n int := 0; v_k int;
begin
  if p_action not in ('save', 'restore') then raise exception 'admin: invalid action'; end if;
  if p_config is null or jsonb_typeof(p_config) <> 'object' then raise exception 'admin: invalid config'; end if;

  insert into platform_pricing_config (id, config, updated_at, updated_by) values (1, p_config, now(), p_admin)
  on conflict (id) do update set config = excluded.config, updated_at = now(), updated_by = p_admin;

  if p_apply_existing and p_entitlements is not null and jsonb_typeof(p_entitlements) = 'object' then
    for v_key in select jsonb_object_keys(p_entitlements) loop
      update organization_licenses set entitlements = p_entitlements -> v_key, updated_at = now()
       where package_key = v_key and not complimentary and entitlements is distinct from (p_entitlements -> v_key);
      get diagnostics v_k = row_count;
      v_n := v_n + v_k;
    end loop;
  end if;

  insert into platform_pricing_history (action, config, applied_to_existing, note, created_by) values (p_action, p_config, v_n, left(p_note, 300), p_admin);
  perform admin_audit(p_admin, 'pricing.' || p_action, 'pricing', '1', jsonb_build_object('applied_to_existing', v_n, 'note', left(p_note, 300)));
  return jsonb_build_object('applied_to_existing', v_n);
end $$;

-- Back to the values written in the code (the shipped configuration).
create or replace function admin_reset_pricing_config(p_admin uuid, p_note text) returns void
language plpgsql security definer set search_path = public as $$
begin
  delete from platform_pricing_config where id = 1;
  insert into platform_pricing_history (action, config, note, created_by) values ('reset', null, left(p_note, 300), p_admin);
  perform admin_audit(p_admin, 'pricing.reset', 'pricing', '1', '{}'::jsonb);
end $$;

-- Companies with owner, team breakdown, warehouses, package and payment state. Paged, newest first.
create or replace function admin_companies_overview(p_search text, p_limit int, p_offset int) returns jsonb
language sql stable security definer set search_path = public as $$
  with q as (select lower(btrim(coalesce(p_search, ''))) as v),
  matched as (
    select o.id, o.created_at from organizations o, q
    where q.v = '' or position(q.v in lower(o.name)) > 0
       or exists (select 1 from organization_users ou join roles r on r.id = ou.role_id join auth.users u on u.id = ou.user_id
                  where ou.organization_id = o.id and r.key = 'owner' and position(q.v in lower(coalesce(u.email, ''))) > 0)
  ),
  page as (
    select id from matched order by created_at desc, id
    limit least(greatest(coalesce(p_limit, 25), 1), 100) offset greatest(coalesce(p_offset, 0), 0)
  )
  select jsonb_build_object(
    'total', (select count(*) from matched),
    'rows', coalesce((
      select jsonb_agg(row_to_json(t)::jsonb order by t.created_at desc, t.id) from (
        select o.id, o.name, o.created_at,
               own.email as owner_email, own.display_name as owner_name,
               (select count(*) from organization_users ou join roles r on r.id = ou.role_id where ou.organization_id = o.id and ou.status = 'active' and r.key = 'sales')     as reps,
               (select count(*) from organization_users ou join roles r on r.id = ou.role_id where ou.organization_id = o.id and ou.status = 'active' and r.key = 'warehouse') as keepers,
               (select count(*) from organization_users ou join roles r on r.id = ou.role_id where ou.organization_id = o.id and ou.status = 'active' and r.key not in ('owner', 'sales', 'warehouse')) as others,
               (select count(*) from organization_users ou where ou.organization_id = o.id and ou.status = 'active')  as members,
               (select count(*) from organization_users ou where ou.organization_id = o.id and ou.status = 'invited') as invited,
               (select count(*) from warehouses w where w.organization_id = o.id and w.is_active) as warehouses,
               l.package_key, l.payment_option, l.complimentary, l.access_paid_through, l.licensed_at,
               lo.status as last_order_status, lo.paid_at as last_order_paid_at
        from page pg join organizations o on o.id = pg.id
        left join lateral (select u.email, ou.display_name from organization_users ou join roles r on r.id = ou.role_id join auth.users u on u.id = ou.user_id
                           where ou.organization_id = o.id and r.key = 'owner' order by ou.created_at limit 1) own on true
        left join organization_licenses l on l.organization_id = o.id
        left join lateral (select b.status, b.paid_at from billing_orders b where b.organization_id = o.id order by b.created_at desc limit 1) lo on true
      ) t), '[]'::jsonb))
$$;

create or replace function admin_company_members(p_org uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('user_id', ou.user_id, 'email', u.email, 'name', ou.display_name,
           'role_key', r.key, 'role_name', r.name, 'status', ou.status, 'joined_at', ou.created_at) order by ou.created_at), '[]'::jsonb)
  from organization_users ou join roles r on r.id = ou.role_id left join auth.users u on u.id = ou.user_id
  where ou.organization_id = p_org
$$;

-- {userId: [{org_id, org_name, role_key, status}]} for a page of users
create or replace function admin_user_memberships(p_users uuid[]) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_object_agg(x.user_id, x.m), '{}'::jsonb) from (
    select ou.user_id, jsonb_agg(jsonb_build_object('org_id', o.id, 'org_name', o.name, 'role_key', r.key, 'status', ou.status) order by ou.created_at) as m
    from organization_users ou join organizations o on o.id = ou.organization_id join roles r on r.id = ou.role_id
    where ou.user_id = any (p_users) group by ou.user_id
  ) x
$$;

-- Why a user must NOT be permanently deleted. Anyone who is (or was) a working member of a company is part of that company's
-- records (invoices, stock movements, the audit trail…) and, if an owner, of its ownership: those users are deactivated, not erased.
-- Only accounts with no membership, or whose invitations were never accepted, can be erased.
create or replace function admin_user_delete_blockers(p_user uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('kind', 'membership', 'org_name', o.name, 'role_key', r.key, 'status', ou.status)), '[]'::jsonb)
  from organization_users ou join organizations o on o.id = ou.organization_id join roles r on r.id = ou.role_id
  where ou.user_id = p_user and ou.status <> 'invited'
$$;

-- Free access granted by the platform owner. Never replaces something a company paid for.
-- Result: granted | refreshed | has_paid_license | not_found
create or replace function admin_grant_complimentary_license(p_admin uuid, p_org uuid, p_package text, p_entitlements jsonb) returns text
language plpgsql security definer set search_path = public as $$
declare v_lic organization_licenses; v_existed boolean;
begin
  if not exists (select 1 from organizations where id = p_org) then return 'not_found'; end if;
  perform pg_advisory_xact_lock(hashtextextended('billing:' || p_org::text, 0));
  select * into v_lic from organization_licenses where organization_id = p_org;
  v_existed := found;
  if v_existed and not v_lic.complimentary then return 'has_paid_license'; end if;
  insert into organization_licenses (organization_id, package_key, payment_option, entitlements, licensed_at, access_paid_through, complimentary)
  values (p_org, p_package, 'one_time', p_entitlements, now(), timestamptz '2100-01-01', true)
  on conflict (organization_id) do update set package_key = excluded.package_key, entitlements = excluded.entitlements, updated_at = now();
  perform admin_audit(p_admin, 'license.grant_complimentary', 'organization', p_org::text, jsonb_build_object('package', p_package));
  return case when v_existed then 'refreshed' else 'granted' end;
end $$;

create or replace function admin_revoke_complimentary_license(p_admin uuid, p_org uuid) returns boolean
language plpgsql security definer set search_path = public as $$
declare v_n int;
begin
  delete from organization_licenses where organization_id = p_org and complimentary;
  get diagnostics v_n = row_count;
  if v_n = 1 then perform admin_audit(p_admin, 'license.revoke_complimentary', 'organization', p_org::text, '{}'::jsonb); end if;
  return v_n = 1;
end $$;

revoke all on function
  admin_audit(uuid, text, text, text, jsonb), admin_save_pricing_config(uuid, jsonb, jsonb, boolean, text, text),
  admin_reset_pricing_config(uuid, text), admin_companies_overview(text, int, int), admin_company_members(uuid),
  admin_user_memberships(uuid[]), admin_user_delete_blockers(uuid),
  admin_grant_complimentary_license(uuid, uuid, text, jsonb), admin_revoke_complimentary_license(uuid, uuid)
from public, anon, authenticated;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    grant execute on function
      admin_audit(uuid, text, text, text, jsonb), admin_save_pricing_config(uuid, jsonb, jsonb, boolean, text, text),
      admin_reset_pricing_config(uuid, text), admin_companies_overview(text, int, int), admin_company_members(uuid),
      admin_user_memberships(uuid[]), admin_user_delete_blockers(uuid),
      admin_grant_complimentary_license(uuid, uuid, text, jsonb), admin_revoke_complimentary_license(uuid, uuid)
    to service_role;
  end if;
end $$;

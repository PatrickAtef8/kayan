-- 0063: the integrated checkout / subscription / payment-gate / grace-period system.
--
-- ONE source of truth for "may this company use Kayan right now?":  organization_licenses.access_paid_through (written only by
-- billing_apply_payment after XPay's payment is verified server-side, or by the Super Admin's free-access function), judged
-- against the DATABASE clock (now()) and the platform grace settings below.
--
--   state      meaning                                                              open?
--   none       the company never paid (no license)                                  no
--   free       complimentary license granted by the platform                         yes
--   license_only  a license with no end date (license-only purchase)                  yes
--   active     now <= access_paid_through                                            yes
--   grace      access_paid_through < now <= access_paid_through + grace              yes (the application shows a warning)
--   expired    now >  access_paid_through + grace                                    no
--   grace = grace_hours when grace_enabled, else 0 (immediate lock; 0 hours behaves the same).
--
-- ENFORCEMENT IN THE DATABASE. Every table policy that isolates tenants goes through user_org_ids(), and every RPC authorises
-- through is_org_member() / has_permission() (directly, or via the _*_guard helpers that call them; verified by a test that walks
-- all org-scoped RPCs). Those three helpers now also require billing_org_open(): a company that has not paid, or whose paid period
-- plus grace is over, sees and changes NOTHING through the API — not through a page, a Server Action, a direct REST call or an RPC.
-- Deliberately NOT gated (an unpaid owner needs them to pay): organization_users (own membership row), organization_licenses and
-- billing_orders (owner read-only), my_role_key(), my_org_access(), the public pricing tables.
--
-- Clients cannot write any of it: platform_billing_settings has no grants for browser roles; organization_licenses / billing_orders
-- are SELECT-only for them (0060); the write paths are service-role-only functions.
--
-- Maintenance switch: platform_billing_settings.gate_enforced (default true). Set to false by SQL only (never exposed in the UI)
-- — used by the test-suite, whose fixtures create companies without licenses, and available as an emergency off-switch.

create table platform_billing_settings (
  id            integer primary key check (id = 1),
  grace_enabled boolean not null default true,
  grace_hours   integer not null default 24 check (grace_hours between 0 and 720),
  gate_enforced boolean not null default true,
  updated_at    timestamptz not null default now(),
  updated_by    uuid
);
insert into platform_billing_settings (id) values (1) on conflict do nothing;
alter table platform_billing_settings enable row level security;
revoke all on platform_billing_settings from public, anon, authenticated;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    grant select, insert, update, delete on platform_billing_settings to service_role;
  end if;
end $$;

-- The full judgement, at a given instant (the public entry points always pass now()).
create or replace function billing_access_state(p_org uuid, p_at timestamptz) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_enabled boolean; v_cfg_hours int; v_enforced boolean;
  v_found boolean := false; v_comp boolean; v_through timestamptz;
  v_hours int; v_end timestamptz; v_state text; v_left bigint;
begin
  select coalesce(grace_enabled, true), coalesce(grace_hours, 24), coalesce(gate_enforced, true)
    into v_enabled, v_cfg_hours, v_enforced from platform_billing_settings where id = 1;
  if v_enabled is null then v_enabled := true; v_cfg_hours := 24; v_enforced := true; end if;
  v_hours := case when v_enabled then v_cfg_hours else 0 end;

  select true, l.complimentary, l.access_paid_through into v_found, v_comp, v_through
    from organization_licenses l where l.organization_id = p_org;
  v_found := coalesce(v_found, false);

  if not v_found then v_state := 'none';
  elsif v_comp then v_state := 'free';
  elsif v_through is null then v_state := 'license_only';
  else
    v_end := v_through + make_interval(hours => v_hours);
    v_state := case when p_at <= v_through then 'active' when p_at <= v_end then 'grace' else 'expired' end;
  end if;
  if v_state = 'grace' then v_left := ceil(extract(epoch from (v_end - p_at)));
  elsif v_state = 'active' then v_left := ceil(extract(epoch from (v_through - p_at))); end if;

  return jsonb_build_object(
    'state', v_state,
    'open', (not v_enforced) or v_state in ('free', 'license_only', 'active', 'grace'),
    'paid_through', case when v_state in ('active', 'grace', 'expired') then v_through end,
    'grace_ends_at', case when v_state in ('active', 'grace', 'expired') then v_end end,
    'seconds_left', v_left,
    'grace_enabled', v_enabled, 'grace_hours', v_cfg_hours,
    'server_now', p_at);
end $$;

create or replace function billing_org_open(p_org uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((billing_access_state(p_org, now()) ->> 'open')::boolean, false)
$$;

revoke all on function billing_access_state(uuid, timestamptz), billing_org_open(uuid) from public, anon, authenticated;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    grant execute on function billing_access_state(uuid, timestamptz), billing_org_open(uuid) to service_role;
  end if;
end $$;

-- ---- the three central helpers: membership AND an open subscription -------------------------------------------------------
create or replace function user_org_ids()
returns setof uuid
language sql security definer set search_path = public stable as $$
  select ou.organization_id
  from organization_users ou
  where ou.user_id = auth.uid()
    and ou.status = 'active'
    and billing_org_open(ou.organization_id)
$$;

create or replace function is_org_member(target_org uuid)
returns boolean
language sql security definer set search_path = public stable as $$
  select exists (
    select 1 from organization_users ou
    where ou.organization_id = target_org
      and ou.user_id = auth.uid()
      and ou.status = 'active'
      and billing_org_open(ou.organization_id)
  );
$$;

create or replace function has_permission(target_org uuid, perm_key text)
returns boolean
language sql security definer set search_path = public stable as $$
  select exists (
    select 1
    from organization_users ou
    join role_permissions rp on rp.role_id = ou.role_id
    where ou.organization_id = target_org
      and ou.user_id = auth.uid()
      and ou.status = 'active'
      and rp.permission_key = perm_key
      and billing_org_open(ou.organization_id)
  );
$$;

-- ---- the other "which companies may this user act in" helpers used by PERMISSIVE policies ----------------------------------
-- Balances, costs and financial tables decide through their own permission-set functions (same shape as user_org_ids: active
-- membership + a permission). They get the same extra condition, patched from their live definition so nothing else about them
-- changes. (The helpers used only by RESTRICTIVE policies - restricted_rep_org_ids, storekeeper_org_ids, finance_org_ids,
-- purchasing_org_ids - are left alone on purpose: they only narrow access, and making them return fewer rows would WIDEN a
-- restrictive policy that is written as "not in ...".)
do $$
declare f text; def text; patched int := 0;
begin
  foreach f in array array['balance_edit_org_ids', 'balance_org_ids', 'fin_org_ids', 'cost_org_ids', 'cost_edit_org_ids'] loop
    for def in select pg_get_functiondef(p.oid) from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = f loop
      if def !~ 'billing_org_open' then
        if position('ou.status = ''active''' in def) = 0 then raise exception '0063: cannot patch % (unexpected body)', f; end if;
        execute replace(def, 'ou.status = ''active''', 'ou.status = ''active'' and billing_org_open(ou.organization_id)');
        patched := patched + 1;
      end if;
    end loop;
  end loop;
  if patched <> 5 then raise exception '0063: expected to patch 5 helpers, patched %', patched; end if;
end $$;

-- ---- what the application's gate and banners read (any ACTIVE member; replaces the 0062 version, same signature) -------------
create or replace function my_org_access(target_org uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select case
    when auth.uid() is null
      or not exists (select 1 from organization_users ou where ou.organization_id = target_org and ou.user_id = auth.uid() and ou.status = 'active')
    then null
    else jsonb_build_object(
      'org_name', (select o.name from organizations o where o.id = target_org),
      'license', (select jsonb_build_object('complimentary', l.complimentary, 'access_paid_through', l.access_paid_through,
                                            'payment_option', l.payment_option, 'package_key', l.package_key)
                  from organization_licenses l where l.organization_id = target_org),
      'owners', coalesce((select jsonb_agg(jsonb_build_object('id', ou.user_id, 'email', u.email, 'confirmed', u.email_confirmed_at is not null) order by ou.created_at)
                          from organization_users ou join roles r on r.id = ou.role_id left join auth.users u on u.id = ou.user_id
                          where ou.organization_id = target_org and ou.status = 'active' and r.key = 'owner'), '[]'::jsonb),
      'access', billing_access_state(target_org, now())
    )
  end
$$;

-- ---- back office ----------------------------------------------------------------------------------------------------------
create or replace function admin_save_billing_settings(p_admin uuid, p_enabled boolean, p_hours integer) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if p_enabled is null or p_hours is null or p_hours < 0 or p_hours > 720 then raise exception 'admin: invalid grace settings'; end if;
  insert into platform_billing_settings (id, grace_enabled, grace_hours, updated_at, updated_by)
  values (1, p_enabled, p_hours, now(), p_admin)
  on conflict (id) do update set grace_enabled = excluded.grace_enabled, grace_hours = excluded.grace_hours, updated_at = now(), updated_by = p_admin;
  perform admin_audit(p_admin, 'billing.grace_settings', 'billing', '1', jsonb_build_object('enabled', p_enabled, 'hours', p_hours));
  return jsonb_build_object('grace_enabled', p_enabled, 'grace_hours', p_hours);
end $$;

revoke all on function admin_save_billing_settings(uuid, boolean, integer) from public, anon, authenticated;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    grant execute on function admin_save_billing_settings(uuid, boolean, integer) to service_role;
  end if;
end $$;

-- Same companies overview as 0062, plus the company's access state (judged by the database clock).
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
               own.id as owner_id, own.email as owner_email, own.display_name as owner_name, coalesce(own.confirmed, false) as owner_confirmed,
               (select count(*) from organization_users ou join roles r on r.id = ou.role_id where ou.organization_id = o.id and ou.status = 'active' and r.key = 'sales')     as reps,
               (select count(*) from organization_users ou join roles r on r.id = ou.role_id where ou.organization_id = o.id and ou.status = 'active' and r.key = 'warehouse') as keepers,
               (select count(*) from organization_users ou join roles r on r.id = ou.role_id where ou.organization_id = o.id and ou.status = 'active' and r.key not in ('owner', 'sales', 'warehouse')) as others,
               (select count(*) from organization_users ou where ou.organization_id = o.id and ou.status = 'active')  as members,
               (select count(*) from organization_users ou where ou.organization_id = o.id and ou.status = 'invited') as invited,
               (select count(*) from warehouses w where w.organization_id = o.id and w.is_active) as warehouses,
               l.package_key, l.payment_option, l.complimentary, l.access_paid_through, l.licensed_at,
               lo.status as last_order_status, lo.paid_at as last_order_paid_at,
               billing_access_state(o.id, now()) ->> 'state' as access_state
        from page pg join organizations o on o.id = pg.id
        left join lateral (select u.id, u.email, (u.email_confirmed_at is not null) as confirmed, ou.display_name from organization_users ou join roles r on r.id = ou.role_id join auth.users u on u.id = ou.user_id
                           where ou.organization_id = o.id and r.key = 'owner' order by ou.created_at limit 1) own on true
        left join organization_licenses l on l.organization_id = o.id
        left join lateral (select b.status, b.paid_at from billing_orders b where b.organization_id = o.id order by b.created_at desc limit 1) lo on true
      ) t), '[]'::jsonb))
$$;

revoke all on function admin_companies_overview(text, int, int) from public, anon, authenticated;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    grant execute on function admin_companies_overview(text, int, int) to service_role;
  end if;
end $$;

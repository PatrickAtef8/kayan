-- Kayan — 0074: the free trial, and "hosting & maintenance = 0".
--
-- 1. FREE TRIAL.  A company can start a free trial of N days (N is set by the Super Admin, default 15). During the trial the
--    dashboard works normally, with every module. When it ends, the dashboard is closed (by the database, on every table and RPC —
--    exactly like an unpaid company) until the owner pays. Nothing is deleted: the company's data stays where it is, and as soon as a
--    payment is verified the company opens again with all of it.
--
--      state          meaning                                                         open?
--      trial          no license yet, trial running (now <= trial end)                yes
--      trial_expired  no license, trial over                                          NO — "subscribe to continue"
--      (all the other states are unchanged: none, free, license_only, active, grace, expired)
--
--    * A license always wins: once a company has a license (paid or complimentary) the trial row is ignored, so a trial can never
--      re-open a company whose paid period lapsed.
--    * The length is copied into the company's row when its trial starts: changing N later only affects trials that start afterwards
--      (the Super Admin can extend one company's trial with admin_extend_trial).
--    * One trial per account (a unique index on the user who started it) and one per company.
--    * The trial is started ONLY through billing_start_trial (service role; the server has verified the caller), never from a browser.
--
-- 2. HOSTING & MAINTENANCE = 0.  When the Super Admin sets the perpetual-license plan's monthly hosting price to 0, nobody pays hosting
--    or maintenance: a company that buys the license pays the license only and never has an end date, and companies that already own
--    the license are no longer closed for a missing hosting payment (billing_access_state reads the saved price; it is judged live,
--    so setting a price above 0 again restores the old rule for companies that still carry an end date).
--
-- Additive / replace-only. Safe to run twice. Run BEFORE deploying the application code.

-- ============================================================
-- 1. Settings: trial on/off and its length
-- ============================================================
alter table platform_billing_settings add column if not exists trial_enabled boolean not null default true;
alter table platform_billing_settings add column if not exists trial_days    integer not null default 15;
alter table platform_billing_settings drop constraint if exists platform_billing_settings_trial_days_check;
alter table platform_billing_settings add  constraint platform_billing_settings_trial_days_check check (trial_days between 1 and 365);

-- ============================================================
-- 2. One row per company that ever started a trial
-- ============================================================
create table if not exists organization_trials (
  organization_id uuid primary key references organizations(id) on delete cascade,
  started_by      uuid references auth.users(id) on delete set null,
  started_at      timestamptz not null default now(),
  ends_at         timestamptz not null,
  trial_days      integer not null check (trial_days between 1 and 365),
  extended_days   integer not null default 0 check (extended_days >= 0),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  check (ends_at > started_at)
);
-- one free trial per account, whatever company it is spent on
create unique index if not exists organization_trials_one_per_user on organization_trials (started_by) where started_by is not null;

-- RLS on, no policy, no grant for browser roles: only the database functions below (and the service role) see it. The application reads
-- the trial through my_org_access() / billing_access_state().
alter table organization_trials enable row level security;
revoke all on organization_trials from public, anon, authenticated;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    grant select, insert, update, delete on organization_trials to service_role;
  end if;
end $$;

drop trigger if exists audit_organization_trials on organization_trials;
create trigger audit_organization_trials after insert or update on organization_trials for each row execute function audit_row_change('trial', '');

-- ============================================================
-- 3. "Is hosting & maintenance free right now?"  (read live from the Super Admin's saved prices)
-- ============================================================
create or replace function billing_hosting_free() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((
    select case when (c.config #>> '{packages,one_time,pricing,hostingMonthlyEgp}') ~ '^[0-9]+(\.[0-9]+)?$'
                then (c.config #>> '{packages,one_time,pricing,hostingMonthlyEgp}')::numeric = 0
                else false end
    from platform_pricing_config c where c.id = 1
  ), false)
$$;

-- ============================================================
-- 4. The judgement (replaces the 0063 version; same signature) — adds trial / trial_expired and hosting_free
-- ============================================================
create or replace function billing_access_state(p_org uuid, p_at timestamptz) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_enabled boolean; v_cfg_hours int; v_enforced boolean;
  v_found boolean := false; v_comp boolean; v_through timestamptz; v_option text;
  v_hours int; v_end timestamptz; v_state text; v_left bigint;
  v_trial_start timestamptz; v_trial_end timestamptz; v_hosting_free boolean := false;
begin
  select coalesce(grace_enabled, true), coalesce(grace_hours, 24), coalesce(gate_enforced, true)
    into v_enabled, v_cfg_hours, v_enforced from platform_billing_settings where id = 1;
  if v_enabled is null then v_enabled := true; v_cfg_hours := 24; v_enforced := true; end if;
  v_hours := case when v_enabled then v_cfg_hours else 0 end;

  select true, l.complimentary, l.access_paid_through, l.payment_option into v_found, v_comp, v_through, v_option
    from organization_licenses l where l.organization_id = p_org;
  v_found := coalesce(v_found, false);

  if not v_found then
    -- no license: the free trial decides
    select t.started_at, t.ends_at into v_trial_start, v_trial_end from organization_trials t where t.organization_id = p_org;
    if v_trial_end is null then v_state := 'none';
    elsif p_at <= v_trial_end then v_state := 'trial'; v_left := ceil(extract(epoch from (v_trial_end - p_at)));
    else v_state := 'trial_expired'; end if;
  elsif v_comp then v_state := 'free';
  else
    if v_option = 'one_time' then v_hosting_free := billing_hosting_free(); end if;
    if v_hosting_free or v_through is null then v_state := 'license_only';
    else
      v_end := v_through + make_interval(hours => v_hours);
      v_state := case when p_at <= v_through then 'active' when p_at <= v_end then 'grace' else 'expired' end;
    end if;
  end if;
  if v_state = 'grace' then v_left := ceil(extract(epoch from (v_end - p_at)));
  elsif v_state = 'active' then v_left := ceil(extract(epoch from (v_through - p_at))); end if;

  return jsonb_build_object(
    'state', v_state,
    'open', (not v_enforced) or v_state in ('trial', 'free', 'license_only', 'active', 'grace'),
    'paid_through', case when v_state in ('active', 'grace', 'expired') then v_through end,
    'grace_ends_at', case when v_state in ('active', 'grace', 'expired') then v_end end,
    'seconds_left', v_left,
    'trial_started_at', case when v_state in ('trial', 'trial_expired') then v_trial_start end,
    'trial_ends_at', case when v_state in ('trial', 'trial_expired') then v_trial_end end,
    'hosting_free', v_hosting_free,
    'grace_enabled', v_enabled, 'grace_hours', v_cfg_hours,
    'server_now', p_at);
end $$;

revoke all on function billing_access_state(uuid, timestamptz), billing_org_open(uuid), billing_hosting_free() from public, anon, authenticated;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    grant execute on function billing_access_state(uuid, timestamptz), billing_org_open(uuid), billing_hosting_free() to service_role;
  end if;
end $$;

-- ============================================================
-- 5. What the application's gate reads (replaces the 0063 version; adds the trial offer)
-- ============================================================
--   trial_offer = {enabled, days, eligible}: may THIS caller's company start a free trial right now? (never paid, never had a trial,
--                 and the caller has not spent their one trial on another company)
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
      'access', billing_access_state(target_org, now()),
      'trial_offer', jsonb_build_object(
        'enabled', coalesce((select s.trial_enabled from platform_billing_settings s where s.id = 1), false),
        'days',    coalesce((select s.trial_days from platform_billing_settings s where s.id = 1), 15),
        'eligible', coalesce((select s.trial_enabled from platform_billing_settings s where s.id = 1), false)
                    and not exists (select 1 from organization_licenses l where l.organization_id = target_org)
                    and not exists (select 1 from organization_trials t where t.organization_id = target_org)
                    and not exists (select 1 from organization_trials t where t.started_by = auth.uid()))
    )
  end
$$;

-- ============================================================
-- 6. Start a trial (service role only; the server has already checked who the caller is)
-- ============================================================
-- Result: started | not_owner | disabled | has_license | already_started | trial_used
-- p_modules: the optional modules the trial switches on (the trial is the whole product); the three core modules need no switch.
create or replace function billing_start_trial(p_org uuid, p_user uuid, p_modules text[]) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_s   platform_billing_settings;
  v_end timestamptz;
  mk    text;
begin
  if not exists (
    select 1 from organization_users ou join roles r on r.id = ou.role_id
    where ou.organization_id = p_org and ou.user_id = p_user and ou.status = 'active' and r.key = 'owner'
  ) then
    return jsonb_build_object('result', 'not_owner');
  end if;

  perform pg_advisory_xact_lock(hashtextextended('billing:' || p_org::text, 0));

  select * into v_s from platform_billing_settings where id = 1;
  if not found or not v_s.trial_enabled then return jsonb_build_object('result', 'disabled'); end if;
  if exists (select 1 from organization_licenses where organization_id = p_org) then return jsonb_build_object('result', 'has_license'); end if;
  if exists (select 1 from organization_trials where organization_id = p_org) then return jsonb_build_object('result', 'already_started'); end if;
  if exists (select 1 from organization_trials where started_by = p_user) then return jsonb_build_object('result', 'trial_used'); end if;

  v_end := now() + make_interval(days => v_s.trial_days);
  begin
    insert into organization_trials (organization_id, started_by, started_at, ends_at, trial_days)
    values (p_org, p_user, now(), v_end, v_s.trial_days);
  exception when unique_violation then
    return jsonb_build_object('result', 'trial_used');   -- two companies of the same account racing
  end;

  foreach mk in array coalesce(p_modules, '{}') loop
    if mk ~ '^[a-z][a-z0-9_]{1,39}$' and not (mk = any (billing_ungated_modules())) then
      insert into organization_modules (organization_id, module_key, enabled)
      values (p_org, mk, true)
      on conflict (organization_id, module_key) do update set enabled = true;
    end if;
  end loop;

  return jsonb_build_object('result', 'started', 'ends_at', v_end, 'days', v_s.trial_days);
end $$;

-- ============================================================
-- 7. Back office
-- ============================================================
create or replace function admin_save_trial_settings(p_admin uuid, p_enabled boolean, p_days integer) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if p_enabled is null or p_days is null or p_days < 1 or p_days > 365 then raise exception 'admin: invalid trial settings'; end if;
  insert into platform_billing_settings (id, trial_enabled, trial_days, updated_at, updated_by)
  values (1, p_enabled, p_days, now(), p_admin)
  on conflict (id) do update set trial_enabled = excluded.trial_enabled, trial_days = excluded.trial_days, updated_at = now(), updated_by = p_admin;
  perform admin_audit(p_admin, 'billing.trial_settings', 'billing', '1', jsonb_build_object('enabled', p_enabled, 'days', p_days));
  return jsonb_build_object('trial_enabled', p_enabled, 'trial_days', p_days);
end $$;

-- Give one company more trial time: counted from the later of "now" and its current end (so extending an expired trial re-opens it
-- for p_days from today). Only a company that is still in its trial phase (no license) can be extended.
-- Result: extended | not_found | no_trial | has_license
create or replace function admin_extend_trial(p_admin uuid, p_org uuid, p_days integer) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_end timestamptz;
begin
  if p_days is null or p_days < 1 or p_days > 365 then raise exception 'admin: invalid trial extension'; end if;
  if not exists (select 1 from organizations where id = p_org) then return jsonb_build_object('result', 'not_found'); end if;
  perform pg_advisory_xact_lock(hashtextextended('billing:' || p_org::text, 0));
  if exists (select 1 from organization_licenses where organization_id = p_org) then return jsonb_build_object('result', 'has_license'); end if;
  update organization_trials
     set ends_at = greatest(ends_at, now()) + make_interval(days => p_days), extended_days = extended_days + p_days, updated_at = now()
   where organization_id = p_org
  returning ends_at into v_end;
  if not found then return jsonb_build_object('result', 'no_trial'); end if;
  perform admin_audit(p_admin, 'trial.extend', 'organization', p_org::text, jsonb_build_object('days', p_days, 'ends_at', v_end));
  return jsonb_build_object('result', 'extended', 'ends_at', v_end);
end $$;

-- How many companies are in a running / finished trial (no license yet)
create or replace function admin_trial_stats() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'active',  (select count(*) from organization_trials t where t.ends_at >  now() and not exists (select 1 from organization_licenses l where l.organization_id = t.organization_id)),
    'expired', (select count(*) from organization_trials t where t.ends_at <= now() and not exists (select 1 from organization_licenses l where l.organization_id = t.organization_id)))
$$;

-- "Waiting to pay" no longer counts a company whose free trial is still running (replaces the 0062 version; same signature)
create or replace function admin_unpaid_company_count(p_exclude_users uuid[], p_exclude_emails text[]) returns integer
language sql stable security definer set search_path = public as $$
  select count(*)::int from organizations o
  where not exists (select 1 from organization_licenses l where l.organization_id = o.id)
    and not exists (select 1 from organization_trials t where t.organization_id = o.id and t.ends_at > now())
    and exists (select 1 from organization_users ou join roles r on r.id = ou.role_id
                where ou.organization_id = o.id and ou.status = 'active' and r.key = 'owner')
    and not exists (select 1 from organization_users ou join roles r on r.id = ou.role_id join auth.users u on u.id = ou.user_id
                    where ou.organization_id = o.id and ou.status = 'active' and r.key = 'owner'
                      and (ou.user_id = any (coalesce(p_exclude_users, '{}'::uuid[]))
                           or (u.email_confirmed_at is not null and lower(u.email) = any (coalesce(p_exclude_emails, '{}'::text[])))))
$$;

-- Same companies overview as 0063, plus the company's trial end
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
               billing_access_state(o.id, now()) ->> 'state' as access_state,
               (select tr.ends_at from organization_trials tr where tr.organization_id = o.id) as trial_ends_at
        from page pg join organizations o on o.id = pg.id
        left join lateral (select u.id, u.email, (u.email_confirmed_at is not null) as confirmed, ou.display_name from organization_users ou join roles r on r.id = ou.role_id join auth.users u on u.id = ou.user_id
                           where ou.organization_id = o.id and r.key = 'owner' order by ou.created_at limit 1) own on true
        left join organization_licenses l on l.organization_id = o.id
        left join lateral (select b.status, b.paid_at from billing_orders b where b.organization_id = o.id order by b.created_at desc limit 1) lo on true
      ) t), '[]'::jsonb))
$$;

revoke all on function
  billing_start_trial(uuid, uuid, text[]), admin_save_trial_settings(uuid, boolean, integer), admin_extend_trial(uuid, uuid, integer),
  admin_trial_stats(), admin_unpaid_company_count(uuid[], text[]), admin_companies_overview(text, int, int)
from public, anon, authenticated;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    grant execute on function
      billing_start_trial(uuid, uuid, text[]), admin_save_trial_settings(uuid, boolean, integer), admin_extend_trial(uuid, uuid, integer),
      admin_trial_stats(), admin_unpaid_company_count(uuid[], text[]), admin_companies_overview(text, int, int)
    to service_role;
  end if;
end $$;

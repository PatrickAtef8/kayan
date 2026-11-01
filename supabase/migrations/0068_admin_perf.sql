-- 0068: admin-area performance. Read-only helper functions (service role only); nothing is changed in any table.
--   admin_users_page      the users list in ONE query (search, paging, memberships) instead of up to 5 Auth-API pages + a second call;
--                         the search is no longer capped at the first 1,000 accounts.
--   admin_overview_stats  the overview counters in one query instead of downloading every license row and calling the Auth API.
--   admin_license_stats   paid licenses per package, for the packages page (same reason).

create or replace function admin_users_page(p_search text, p_limit int, p_offset int) returns jsonb
language sql stable security definer set search_path = public as $$
  with q as (select lower(btrim(coalesce(p_search, ''))) as v),
  matched as (
    select u.id, u.email, u.created_at, u.last_sign_in_at, u.email_confirmed_at, u.banned_until
    from auth.users u, q
    where q.v = '' or position(q.v in lower(coalesce(u.email, ''))) > 0
  ),
  page as (
    select * from matched order by created_at desc, id
    limit least(greatest(coalesce(p_limit, 25), 1), 100) offset greatest(coalesce(p_offset, 0), 0)
  )
  select jsonb_build_object(
    'total', (select count(*) from matched),
    'rows', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', p.id, 'email', p.email, 'created_at', p.created_at, 'last_sign_in_at', p.last_sign_in_at,
        'email_confirmed_at', p.email_confirmed_at, 'banned_until', p.banned_until,
        'memberships', coalesce((
          select jsonb_agg(jsonb_build_object('org_id', o.id, 'org_name', o.name, 'role_key', r.key, 'status', ou.status) order by ou.created_at)
          from organization_users ou join organizations o on o.id = ou.organization_id join roles r on r.id = ou.role_id
          where ou.user_id = p.id), '[]'::jsonb)
      ) order by p.created_at desc, p.id) from page p), '[]'::jsonb))
$$;

create or replace function admin_overview_stats() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'companies', (select count(*) from organizations),
    'users', (select count(*) from auth.users),
    'paid', (select count(*) from organization_licenses where not complimentary),
    'complimentary', (select count(*) from organization_licenses where complimentary))
$$;

create or replace function admin_license_stats() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_object_agg(package_key, n), '{}'::jsonb)
  from (select package_key, count(*) as n from organization_licenses where not complimentary group by package_key) x
$$;

revoke all on function admin_users_page(text, int, int), admin_overview_stats(), admin_license_stats() from public, anon, authenticated;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    grant execute on function admin_users_page(text, int, int), admin_overview_stats(), admin_license_stats() to service_role;
  end if;
end $$;

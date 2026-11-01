-- 0062: the payment gate.
--
-- Until now a company that had not bought a package simply kept working. From this migration on, the application does not
-- open the company dashboard for a company that has not paid (see src/lib/billing/access-gate.ts). The gate itself lives in
-- the application layer; the database only has to answer one question for it, and answer it to ANY active member of the
-- company (the license table is readable by the owner alone, by design — a rep or a storekeeper must not see billing rows):
--
--   my_org_access(org)  →  null                         when the caller is not an active member of that company
--                       →  {license, owners}            otherwise
--        license : null (never paid) or {complimentary, access_paid_through, payment_option, package_key}
--        owners  : the company's active owners as [{id, email, confirmed}] — so the application can recognise a company owned
--                  by a platform administrator (a demo / test company), whose team members must not be locked out either.
--
-- It reveals nothing a member could not already infer (whether the company is paying) and never any amount or order.
--
-- Also here, for the platform back office (service role only):
--   admin_companies_overview  now also returns owner_id + owner_confirmed (to mark administrator-owned companies);
--   admin_unpaid_company_count(excluded users / emails)  how many companies with an owner are still waiting to pay.
--
-- Additive: no table, no policy and no existing function other than admin_companies_overview (extra columns) is touched.

create or replace function my_org_access(target_org uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select case
    when auth.uid() is null
      or not exists (select 1 from organization_users ou where ou.organization_id = target_org and ou.user_id = auth.uid() and ou.status = 'active')
    then null
    else jsonb_build_object(
      'license', (select jsonb_build_object('complimentary', l.complimentary, 'access_paid_through', l.access_paid_through,
                                            'payment_option', l.payment_option, 'package_key', l.package_key)
                  from organization_licenses l where l.organization_id = target_org),
      'owners', coalesce((select jsonb_agg(jsonb_build_object('id', ou.user_id, 'email', u.email, 'confirmed', u.email_confirmed_at is not null) order by ou.created_at)
                          from organization_users ou join roles r on r.id = ou.role_id left join auth.users u on u.id = ou.user_id
                          where ou.organization_id = target_org and ou.status = 'active' and r.key = 'owner'), '[]'::jsonb)
    )
  end
$$;

revoke all on function my_org_access(uuid) from public, anon;
grant execute on function my_org_access(uuid) to authenticated;

-- Same function as 0061 plus owner_id / owner_confirmed.
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
               lo.status as last_order_status, lo.paid_at as last_order_paid_at
        from page pg join organizations o on o.id = pg.id
        left join lateral (select u.id, u.email, (u.email_confirmed_at is not null) as confirmed, ou.display_name from organization_users ou join roles r on r.id = ou.role_id join auth.users u on u.id = ou.user_id
                           where ou.organization_id = o.id and r.key = 'owner' order by ou.created_at limit 1) own on true
        left join organization_licenses l on l.organization_id = o.id
        left join lateral (select b.status, b.paid_at from billing_orders b where b.organization_id = o.id order by b.created_at desc limit 1) lo on true
      ) t), '[]'::jsonb))
$$;

-- Companies that have an active owner, no license of any kind, and whose owner is not a platform administrator.
-- (Companies left without any owner — e.g. after their users were deleted — are not "waiting to pay".)
create or replace function admin_unpaid_company_count(p_exclude_users uuid[], p_exclude_emails text[]) returns integer
language sql stable security definer set search_path = public as $$
  select count(*)::int from organizations o
  where not exists (select 1 from organization_licenses l where l.organization_id = o.id)
    and exists (select 1 from organization_users ou join roles r on r.id = ou.role_id
                where ou.organization_id = o.id and ou.status = 'active' and r.key = 'owner')
    and not exists (select 1 from organization_users ou join roles r on r.id = ou.role_id join auth.users u on u.id = ou.user_id
                    where ou.organization_id = o.id and ou.status = 'active' and r.key = 'owner'
                      and (ou.user_id = any (coalesce(p_exclude_users, '{}'::uuid[]))
                           or (u.email_confirmed_at is not null and lower(u.email) = any (coalesce(p_exclude_emails, '{}'::text[])))))
$$;

revoke all on function admin_companies_overview(text, int, int), admin_unpaid_company_count(uuid[], text[]) from public, anon, authenticated;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    grant execute on function admin_companies_overview(text, int, int), admin_unpaid_company_count(uuid[], text[]) to service_role;
  end if;
end $$;

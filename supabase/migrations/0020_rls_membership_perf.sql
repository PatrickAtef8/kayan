-- Kayan — Phase 20: RLS membership check made set-based (performance)
--
-- PROBLEM (measured, not guessed)
--   Every tenant-isolation policy was `using (is_org_member(organization_id))`.
--   is_org_member() is a SECURITY DEFINER function, so PostgreSQL can not
--   inline it: the policy runs it ONCE PER ROW SCANNED, and each call
--   re-evaluates auth.uid() and probes organization_users. On a seeded
--   multi-tenant database (100k invoices / 300k invoice lines):
--
--       count(*) over 120k rows of one org, table owner (no RLS) :    7 ms
--       same query as a signed-in user (RLS)                     :  613 ms
--
--   That ~80x overhead sits underneath every list page, balance view,
--   dashboard KPI and report, and it grows with the size of the WHOLE
--   database (other tenants' rows are filtered per row too), not just the
--   caller's own data.
--
-- FIX
--   user_org_ids() returns the caller's active organizations once, as a
--   set. The policies become `organization_id in (select user_org_ids())`,
--   which PostgreSQL plans as a hashed sub-plan evaluated ONE time per
--   statement, and which also lets the planner use the
--   (organization_id, ...) indexes.
--
-- SEMANTICS ARE UNCHANGED
--   is_org_member(x)              = exists active membership (auth.uid(), x)
--   x in (select user_org_ids())  = exactly the same predicate, as a set.
--   NULL organization_id matches neither form. Only the policy *expression*
--   changes; who a policy applies to, and the command it covers, do not.
--   is_org_member() itself is kept (RPCs and non-organization_id policies
--   still use it). Policies are rewritten programmatically so none can be
--   missed or mistyped, and the block below aborts the migration if any
--   `is_org_member(organization_id)` policy is left behind.

create or replace function user_org_ids()
returns setof uuid
language sql
security definer
set search_path = public
stable
as $$
  select ou.organization_id
  from organization_users ou
  where ou.user_id = auth.uid()
    and ou.status = 'active';
$$;

revoke all on function user_org_ids() from public, anon;
grant execute on function user_org_ids() to authenticated;

do $$
declare
  pol record;
  new_qual text;
  new_check text;
  stmt text;
  rewritten int := 0;
  leftover int;
  pattern constant text := '(public\.)?is_org_member\(organization_id\)';
  replacement constant text := '(organization_id IN (SELECT public.user_org_ids()))';
begin
  for pol in
    select schemaname, tablename, policyname, qual, with_check
    from pg_policies
    where schemaname = 'public'
      and (coalesce(qual, '') ~ pattern or coalesce(with_check, '') ~ pattern)
  loop
    new_qual  := case when pol.qual       is null then null else regexp_replace(pol.qual,       pattern, replacement, 'g') end;
    new_check := case when pol.with_check is null then null else regexp_replace(pol.with_check, pattern, replacement, 'g') end;

    stmt := format('alter policy %I on %I.%I', pol.policyname, pol.schemaname, pol.tablename);
    if new_qual  is not null then stmt := stmt || format(' using (%s)', new_qual);       end if;
    if new_check is not null then stmt := stmt || format(' with check (%s)', new_check); end if;

    execute stmt;
    rewritten := rewritten + 1;
  end loop;

  select count(*) into leftover
  from pg_policies
  where schemaname = 'public'
    and (coalesce(qual, '') ~ pattern or coalesce(with_check, '') ~ pattern);

  if leftover <> 0 then
    raise exception '0020: % policies still call is_org_member(organization_id) — aborting', leftover;
  end if;

  raise notice '0020: rewrote % RLS policies to the set-based membership check', rewritten;
end $$;

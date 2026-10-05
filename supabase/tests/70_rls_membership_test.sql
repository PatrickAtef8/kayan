-- 0020: RLS tenant checks are set-based (`organization_id in (select user_org_ids())`)
-- instead of a per-row is_org_member() call. Same semantics, ~80x cheaper on
-- large tables. These tests pin the semantics so the optimisation can never
-- silently widen (or narrow) who can see what.

\set ON_ERROR_STOP on

select t.as_owner();
insert into auth.users (id, email) values
  ('e0000000-0000-0000-0000-00000000000a', 'p-owner-a@perf.test'),  -- owner of org A
  ('e0000000-0000-0000-0000-00000000000b', 'p-owner-b@perf.test'),  -- owner of org B
  ('e0000000-0000-0000-0000-00000000000c', 'p-both@perf.test'),     -- member of A and B
  ('e0000000-0000-0000-0000-00000000000d', 'p-nobody@perf.test');   -- member of nothing

select t.as_user('e0000000-0000-0000-0000-00000000000a');
select create_organization('أ', 'x', 'EG', 'EGP', 'ar', array['customers']) as id \gset orga_
select t.as_user('e0000000-0000-0000-0000-00000000000b');
select create_organization('ب', 'x', 'EG', 'EGP', 'ar', array['customers']) as id \gset orgb_

select t.as_owner();
insert into organization_users (organization_id, user_id, role_id, status)
select o, 'e0000000-0000-0000-0000-00000000000c', r.id, 'active'
from (values (:'orga_id'::uuid), (:'orgb_id'::uuid)) v(o), roles r
where r.key = 'sales' and r.organization_id is null;

insert into customers (organization_id, name) values (:'orga_id', 'عميل أ'), (:'orgb_id', 'عميل ب');

-- 1. The migration left no policy on the per-row function.
select t.eq((select count(*) from pg_policies
             where schemaname = 'public'
               and (coalesce(qual, '') ~ 'is_org_member\(organization_id\)'
                 or coalesce(with_check, '') ~ 'is_org_member\(organization_id\)')),
            0, 'no public policy still calls is_org_member(organization_id) per row');

-- 2. user_org_ids() is scoped to the caller.
select t.as_user('e0000000-0000-0000-0000-00000000000a');
select t.eq((select count(*) from user_org_ids()), 1, 'owner A sees exactly one organization id');
select t.ok((select user_org_ids() limit 1) = :'orga_id'::uuid, 'and it is org A');

select t.as_user('e0000000-0000-0000-0000-00000000000c');
select t.eq((select count(*) from user_org_ids()), 2, 'a member of two organizations gets both ids');
select t.eq((select count(*) from customers), 2, 'and sees customers of both organizations');

select t.as_user('e0000000-0000-0000-0000-00000000000d');
select t.eq((select count(*) from user_org_ids()), 0, 'a non-member gets no organization ids');
select t.eq((select count(*) from customers), 0, 'and sees no customers');

-- 3. Losing membership takes effect on the very next query.
select t.as_owner();
update organization_users set status = 'disabled'
where organization_id = :'orgb_id' and user_id = 'e0000000-0000-0000-0000-00000000000c';

select t.as_user('e0000000-0000-0000-0000-00000000000c');
select t.eq((select count(*) from user_org_ids()), 1, 'a disabled membership drops out of user_org_ids()');
select t.eq((select count(*) from customers where organization_id = :'orgb_id'), 0, 'and its rows disappear immediately');
select t.eq((select count(*) from customers where organization_id = :'orga_id'), 1, 'while the still-active organization is unaffected');

-- 4. Writes are still tenant-checked by the rewritten WITH CHECK.
select t.throws(format('insert into customers (organization_id, name) values (%L, %L)', :'orgb_id', 'تسلل'),
                'row-level security', 'cannot insert into an organization where membership is disabled');
select t.throws(format('insert into customers (organization_id, name) values (%L, %L)', :'orga_id'::uuid, null),
                'null value', 'sanity: normal constraints still apply to a legitimate insert');

-- 5. Anonymous callers cannot execute the helper.
select t.as_anon();
select t.throws('select * from user_org_ids()', 'permission denied', 'anon cannot call user_org_ids()');

select t.as_owner();

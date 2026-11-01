-- 0067: the platform administrator can delete a company (with its audit trail and everything inside) and a user who belongs to one.
\set ON_ERROR_STOP on
select t.autoconfirm_off();

select t.as_owner();
insert into auth.users (id, email) values
  ('11800000-0000-0000-0000-000000000001', 'del-owner@del.test'),
  ('11800000-0000-0000-0000-000000000002', 'del-other@del.test');

select t.as_user('11800000-0000-0000-0000-000000000001');
select create_organization('شركة للحذف', 'x', 'EG', 'EGP', 'ar', array['customers']) as id \gset d_
select t.as_user('11800000-0000-0000-0000-000000000002');
select create_organization('شركة تبقى', 'x', 'EG', 'EGP', 'ar', array['customers']) as id \gset k_

select t.as_owner();
insert into customers (organization_id, name) values (:'d_id', 'عميل');
select t.ok((select count(*) from audit_logs where organization_id = :'d_id') > 0, 'the company has audit rows before it is deleted');

-- the company goes, with its audit rows (which are immutable for everyone else)
select t.eq_text(admin_delete_company('11800000-0000-0000-0000-000000000002', :'d_id'), 'deleted', 'the company is deleted');
select t.eq((select count(*) from organizations where id = :'d_id'), 0, 'the company row is gone');
select t.eq((select count(*) from customers where organization_id = :'d_id'), 0, 'its data is gone');
select t.eq((select count(*) from audit_logs where organization_id = :'d_id'), 0, 'its audit trail is gone with it');
select t.eq((select count(*) from organizations where id = :'k_id'), 1, 'another company is untouched');
select t.eq((select count(*) from auth.users where id = '11800000-0000-0000-0000-000000000001'), 1, 'the members accounts remain');
select t.eq_text(admin_delete_company('11800000-0000-0000-0000-000000000002', :'d_id'), 'not_found', 'deleting twice reports not_found');

-- a user who belongs to a company: memberships go, the audit trail keeps its rows but loses the name
select admin_delete_user('11800000-0000-0000-0000-000000000001', '11800000-0000-0000-0000-000000000002');
select t.eq((select count(*) from organization_users where user_id = '11800000-0000-0000-0000-000000000002'), 0, 'the memberships are removed');
select t.eq((select count(*) from audit_logs where user_id = '11800000-0000-0000-0000-000000000002'), 0, 'nothing in the audit trail points at the user any more');
delete from auth.users where id = '11800000-0000-0000-0000-000000000002';
select t.eq((select count(*) from auth.users where id = '11800000-0000-0000-0000-000000000002'), 0, 'and the account itself can now be deleted');

-- a browser session cannot call them
select t.as_user('11800000-0000-0000-0000-000000000001');
select t.throws($q$select admin_delete_company(gen_random_uuid(), gen_random_uuid())$q$, 'permission denied', 'not callable from a signed-in session');
select t.throws($q$select admin_delete_user(gen_random_uuid(), gen_random_uuid())$q$, 'permission denied', 'not callable from a signed-in session');

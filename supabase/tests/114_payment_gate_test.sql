-- 0062: the payment gate. The application decides who may open a company's dashboard (src/lib/billing/access-gate.ts); the
-- database only answers my_org_access(org) — to ANY active member of that company, to nobody else — and hands the back office the
-- two things it needs: owner ids on the companies list, and a count of companies still waiting to pay that leaves out the ones
-- owned by a platform administrator and the ones left without an owner.
\set ON_ERROR_STOP on
select t.autoconfirm_off();
select t.as_owner();
-- the database is shared with the other test files: count companies waiting to pay BEFORE this file adds any
set role service_role;
select admin_unpaid_company_count('{}'::uuid[], '{}'::text[]) as n0 \gset
reset role;
insert into auth.users (id, email, email_confirmed_at) values
  ('11400000-0000-0000-0000-000000000001', 'owner@gate.test',  now()),   -- owner of A (never paid)
  ('11400000-0000-0000-0000-000000000002', 'rep@gate.test',    now()),   -- rep in A
  ('11400000-0000-0000-0000-000000000003', 'paid@gate.test',   now()),   -- owner of B (paid)
  ('11400000-0000-0000-0000-000000000004', 'boss@gate.test',   now()),   -- "platform administrator": owner of C (demo company)
  ('11400000-0000-0000-0000-000000000005', 'ghost@gate.test',  now()),   -- owner of D, who is then removed (ownerless company)
  ('11400000-0000-0000-0000-000000000006', 'noconf@gate.test', null),    -- owner of E, email never confirmed
  ('11400000-0000-0000-0000-000000000007', 'stranger@gate.test', now());
select t.as_user('11400000-0000-0000-0000-000000000001');
select create_organization('شركة أ', 'x', 'EG', 'EGP', 'ar', array['products','warehouses']) as id \gset a_
select t.as_user('11400000-0000-0000-0000-000000000003');
select create_organization('شركة ب', 'x', 'EG', 'EGP', 'ar', array['products','warehouses']) as id \gset b_
select t.as_user('11400000-0000-0000-0000-000000000004');
select create_organization('شركة ج', 'x', 'EG', 'EGP', 'ar', array['products','warehouses']) as id \gset c_
select t.as_user('11400000-0000-0000-0000-000000000005');
select create_organization('شركة د', 'x', 'EG', 'EGP', 'ar', array['products','warehouses']) as id \gset d_
select t.as_user('11400000-0000-0000-0000-000000000006');
select create_organization('شركة هـ', 'x', 'EG', 'EGP', 'ar', array['products','warehouses']) as id \gset e_
select t.as_owner();
insert into organization_users (organization_id, user_id, role_id, status)
select :'a_id', '11400000-0000-0000-0000-000000000002', r.id, 'active' from roles r where r.key = 'sales' and r.organization_id is null;
insert into organization_licenses (organization_id, package_key, payment_option, entitlements, access_paid_through)
values (:'b_id', 'monthly', 'monthly', '{"modules":["customers"],"max_members":3,"max_warehouses":2}', now() + interval '20 days');
delete from organization_users where organization_id = :'d_id';   -- what deleting its only user does to a company

-- 1. who may ask -----------------------------------------------------------------------------------------------------------
select t.as_user('11400000-0000-0000-0000-000000000001');
select my_org_access(:'a_id') as own \gset
select t.ok(:'own'::jsonb -> 'license' = 'null'::jsonb, 'a company that never paid: the license part is null');
select t.eq_text(:'own'::jsonb -> 'owners' -> 0 ->> 'email', 'owner@gate.test', 'and the owners are listed (the application recognises administrator-owned companies by them)');
select t.eq_text(:'own'::jsonb -> 'owners' -> 0 ->> 'confirmed', 'true', 'with whether the email is confirmed (the email allow-list honours confirmed emails only)');

select t.as_user('11400000-0000-0000-0000-000000000002');
select my_org_access(:'a_id') as asrep \gset
select t.ok(:'asrep'::jsonb is not null, 'a rep of the company can read its access state too (the license table itself stays owner-only)');

select t.eq((select count(*) from organization_licenses), 0, 'a rep still sees no license rows');

select t.as_user('11400000-0000-0000-0000-000000000007');
select t.ok(my_org_access(:'a_id') is null, 'someone who is not a member gets nothing');
select t.ok(my_org_access(gen_random_uuid()) is null, 'neither does an unknown company');

select t.as_anon();
select t.throws($q$select my_org_access(gen_random_uuid())$q$, 'permission denied', 'a visitor who is not signed in cannot call it');

-- 2. what it says after paying -----------------------------------------------------------------------------------------------
select t.as_user('11400000-0000-0000-0000-000000000003');
select my_org_access(:'b_id') as paid \gset
select t.eq_text(:'paid'::jsonb -> 'license' ->> 'package_key', 'monthly', 'a paid company shows its plan');
select t.eq_text(:'paid'::jsonb -> 'license' ->> 'complimentary', 'false', 'not free');
select t.ok((:'paid'::jsonb -> 'license' ->> 'access_paid_through')::timestamptz > now(), 'and how far it is paid');
select t.ok(not (:'paid'::jsonb -> 'license' ? 'entitlements'), 'never the entitlements or any amount');

select t.as_user('11400000-0000-0000-0000-000000000001');
select t.ok(my_org_access(:'b_id') is null, 'one company cannot read another one''s state');

-- 3. the back office -------------------------------------------------------------------------------------------------------
select t.as_user('11400000-0000-0000-0000-000000000001');
select t.throws($q$select admin_unpaid_company_count('{}'::uuid[], '{}'::text[])$q$, 'permission denied', 'an owner cannot call the unpaid-companies count');
select t.as_owner();
set role service_role;
select admin_companies_overview('', 100, 0) as ov \gset
select admin_unpaid_company_count('{}'::uuid[], '{}'::text[]) as n_all \gset
select admin_unpaid_company_count(array['11400000-0000-0000-0000-000000000004']::uuid[], '{}'::text[]) as n_ex_id \gset
select admin_unpaid_company_count('{}'::uuid[], array['boss@gate.test']::text[]) as n_ex_email \gset
select admin_unpaid_company_count('{}'::uuid[], array['noconf@gate.test']::text[]) as n_ex_unconfirmed \gset
reset role;
select (select r from jsonb_array_elements(:'ov'::jsonb -> 'rows') r where r ->> 'id' = :'c_id') as rc \gset
select t.eq_text(:'rc'::jsonb ->> 'owner_id', '11400000-0000-0000-0000-000000000004', 'the companies list now carries the owner id');
select t.eq_text(:'rc'::jsonb ->> 'owner_confirmed', 'true', 'and whether the owner''s email is confirmed');
select (select r from jsonb_array_elements(:'ov'::jsonb -> 'rows') r where r ->> 'id' = :'d_id') as rd \gset
select t.ok(:'rd'::jsonb -> 'owner_id' = 'null'::jsonb, 'a company left without an owner is listed with no owner');
-- unpaid + owned: A, C, E  (B paid; D has no owner)  → 3 more than before this file ran
select t.eq(:'n_all'::int - :'n0'::int, 3, 'companies waiting to pay: those with an owner and no license (a paid one and an ownerless one are not counted)');
select t.eq(:'n_ex_id'::int - :'n0'::int, 2, 'a company owned by an administrator (by id) is not counted');
select t.eq(:'n_ex_email'::int - :'n0'::int, 2, 'nor by a confirmed email');
select t.eq(:'n_ex_unconfirmed'::int - :'n0'::int, 3, 'an email that was never confirmed excludes nothing');

-- 4. a free license opens the gate's other door ---------------------------------------------------------------------------------
select t.as_owner();
set role service_role;
select admin_grant_complimentary_license('11400000-0000-0000-0000-000000000009', :'a_id', 'one_time', '{"modules":["sales"],"max_members":null,"max_warehouses":null}') as g \gset
select admin_unpaid_company_count('{}'::uuid[], '{}'::text[]) as n_after \gset
reset role;
select t.eq(:'n_after'::int - :'n0'::int, 2, 'granting a company free access takes it off the waiting list');
select t.as_user('11400000-0000-0000-0000-000000000002');
select t.eq_text(my_org_access(:'a_id') -> 'license' ->> 'complimentary', 'true', 'and its members see the free license');

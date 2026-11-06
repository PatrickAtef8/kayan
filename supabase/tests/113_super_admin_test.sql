-- 0061: the platform back office. Covers: the admin_* functions and the history/audit tables are unreachable from a browser
-- session (only the service role); the pricing override table is publicly readable but never writable; saving / resetting
-- the package settings (and the opt-in "apply to companies that already bought it"); the companies overview (owner, team
-- breakdown, warehouses, package, payment state, search, paging); free (complimentary) licenses never overwrite a paid one;
-- and which users may be erased.
\set ON_ERROR_STOP on
select t.autoconfirm_off();
select t.as_owner();
insert into auth.users (id, email) values
  ('11300000-0000-0000-0000-000000000001', 'boss@adm.test'),
  ('11300000-0000-0000-0000-000000000002', 'rep@adm.test'),
  ('11300000-0000-0000-0000-000000000003', 'keeper@adm.test'),
  ('11300000-0000-0000-0000-000000000004', 'acct@adm.test'),
  ('11300000-0000-0000-0000-000000000005', 'solo@adm.test'),
  ('11300000-0000-0000-0000-000000000006', 'invited@adm.test'),
  ('11300000-0000-0000-0000-000000000007', 'other@adm.test');
select t.as_user('11300000-0000-0000-0000-000000000001');
select create_organization('شركة النور', 'x', 'EG', 'EGP', 'ar', array['products','warehouses','customers','sales']) as id \gset a_
select t.as_user('11300000-0000-0000-0000-000000000007');
select create_organization('مؤسسة الأمل', 'x', 'EG', 'EGP', 'ar', array['products','warehouses']) as id \gset b_
select t.as_owner();
insert into organization_users (organization_id, user_id, role_id, status)
select :'a_id', u.id, r.id, u.st from (values
  ('11300000-0000-0000-0000-000000000002'::uuid, 'sales', 'active'), ('11300000-0000-0000-0000-000000000003', 'warehouse', 'active'),
  ('11300000-0000-0000-0000-000000000006', 'sales', 'invited')) u(id, k, st)
join roles r on r.key = u.k and r.organization_id is null;
insert into warehouses (organization_id, name) values (:'a_id', 'الرئيسي'), (:'a_id', 'الفرع');
update warehouses set is_active = false where organization_id = :'a_id' and name = 'الفرع';
update organization_users set display_name = 'أحمد المالك' where organization_id = :'a_id' and user_id = '11300000-0000-0000-0000-000000000001';

-- 1. only the service role -------------------------------------------------------------------------------------------
select t.as_user('11300000-0000-0000-0000-000000000001');
select t.throws($q$select admin_companies_overview('', 10, 0)$q$, 'permission denied', 'an owner cannot call the companies overview');
select t.throws($q$select admin_save_pricing_config(null, '{}'::jsonb, '{}'::jsonb, true, 'save', null)$q$, 'permission denied', 'nor save the pricing');
select t.throws($q$select admin_grant_complimentary_license(null, gen_random_uuid(), 'one_time', '{}'::jsonb)$q$, 'permission denied', 'nor grant a free license');
select t.throws($q$select admin_user_delete_blockers(gen_random_uuid())$q$, 'permission denied', 'nor probe users');
select t.throws($q$select * from admin_audit_log$q$, 'permission denied', 'the admin audit log is invisible');
select t.throws($q$select * from platform_pricing_history$q$, 'permission denied', 'so is the pricing history');
select t.throws($q$insert into platform_pricing_config (id, config) values (1, '{}')$q$, 'permission denied', 'an owner cannot write pricing');
select t.as_anon();
select t.throws($q$select admin_companies_overview('', 10, 0)$q$, 'permission denied', 'anon cannot call it either');
select t.eq((select count(*) from platform_pricing_config), 0, 'anon can read the (empty) pricing override table — the shipped state is "no overrides"');
select t.throws($q$update platform_pricing_config set config = '{}'$q$, 'permission denied', 'anon cannot write pricing');

-- 2. pricing save / apply / reset --------------------------------------------------------------------------------------
select t.as_owner();
insert into organization_licenses (organization_id, package_key, payment_option, entitlements)
values (:'a_id', 'monthly', 'monthly', '{"modules":["customers"],"max_members":3,"max_warehouses":2}');
set role service_role;
select admin_grant_complimentary_license('11300000-0000-0000-0000-000000000009', :'b_id', 'one_time', '{"modules":["sales"],"max_members":null,"max_warehouses":null}') as g \gset
select admin_save_pricing_config('11300000-0000-0000-0000-000000000009', '{"packages":{"monthly":{"limits":{"maxMembers":5}}}}', '{"monthly":{"modules":["customers","sales"],"max_members":5,"max_warehouses":2}}', false, 'save', 'raise monthly') as r \gset
reset role;
select t.eq_text(:'g', 'granted', 'a free license is granted to a company without one');
select t.eq((select (config -> 'packages' -> 'monthly' -> 'limits' ->> 'maxMembers')::int from platform_pricing_config), 5, 'the override is stored');
select t.eq_text((select entitlements ->> 'max_members' from organization_licenses where organization_id = :'a_id'), '3', 'WITHOUT the opt-in, companies that already bought keep what they bought');
select t.eq((select count(*) from platform_pricing_history where action = 'save'), 1, 'the change is in the history');
set role anon; select t.eq_text((select (config -> 'packages' -> 'monthly' -> 'limits' ->> 'maxMembers') from platform_pricing_config), '5', 'and everyone (the public pricing page) can read it'); reset role;

select count(*) as nb from organization_licenses where package_key = 'monthly' and not complimentary and entitlements is distinct from '{"modules":["customers","sales"],"max_members":5,"max_warehouses":2}'::jsonb \gset
set role service_role;
select admin_save_pricing_config('11300000-0000-0000-0000-000000000009', '{"packages":{"monthly":{"limits":{"maxMembers":5}}}}', '{"monthly":{"modules":["customers","sales"],"max_members":5,"max_warehouses":2}}', true, 'save', 'apply') ->> 'applied_to_existing' as n \gset
reset role;
select t.eq_text(:'n', :'nb', 'with the opt-in, every non-free company on that package is updated (and only those)');
select t.eq_text((select entitlements ->> 'max_members' from organization_licenses where organization_id = :'a_id'), '5', 'with the new limit');
select t.eq_text((select entitlements -> 'modules' ->> 0 from organization_licenses where organization_id = :'b_id'), 'sales', 'a complimentary license is never rewritten by a package change');

set role service_role; select admin_reset_pricing_config('11300000-0000-0000-0000-000000000009', 'back to code'); reset role;
select t.eq((select count(*) from platform_pricing_config), 0, 'reset removes the override: Kayan is back to the values in the code');
select t.eq((select count(*) from platform_pricing_history where action = 'reset'), 1, 'and the reset is recorded');
select t.ok((select count(*) from admin_audit_log where action like 'pricing.%') = 3, 'every pricing change is in the admin audit log');

-- 3. companies overview ---------------------------------------------------------------------------------------------------
set role service_role;
select admin_companies_overview('', 25, 0) as jall \gset
select admin_companies_overview('شركة النور', 25, 0) as j \gset
select admin_companies_overview('مؤسسة الأمل', 25, 0) as jb \gset
select admin_companies_overview('النور', 25, 0) as js \gset
select admin_companies_overview('BOSS@', 25, 0) as je \gset
select admin_companies_overview('', 1, 0) as jp \gset
select admin_companies_overview('%', 25, 0) as jw \gset
reset role;
select t.ok((:'jall'::jsonb ->> 'total')::int >= 2, 'companies are listed');
select (select r from jsonb_array_elements(:'j'::jsonb -> 'rows') r where r ->> 'id' = :'a_id') as ra \gset
select t.eq_text(:'ra'::jsonb ->> 'owner_email', 'boss@adm.test', 'the owner is shown');
select t.eq_text(:'ra'::jsonb ->> 'owner_name', 'أحمد المالك', 'with the name');
select t.eq_text((:'ra'::jsonb ->> 'reps') || '/' || (:'ra'::jsonb ->> 'keepers') || '/' || (:'ra'::jsonb ->> 'others'), '1/1/0', 'representatives / storekeepers / other team members (the app has three roles today, so "others" is 0)');
select t.eq_text((:'ra'::jsonb ->> 'members') || '/' || (:'ra'::jsonb ->> 'invited'), '3/1', 'active members (owner included) and pending invitations');
select t.eq_text(:'ra'::jsonb ->> 'warehouses', '1', 'only active warehouses are counted');
select t.eq_text((:'ra'::jsonb ->> 'package_key') || '/' || (:'ra'::jsonb ->> 'payment_option'), 'monthly/monthly', 'the current package');
select t.eq_text(:'js'::jsonb ->> 'total', '1', 'search by company name');
select t.eq_text(:'je'::jsonb ->> 'total', '1', 'search by owner email (case-insensitive)');
select t.ok((:'jp'::jsonb ->> 'total')::int >= 2 and jsonb_array_length(:'jp'::jsonb -> 'rows') = 1, 'paging: total stays, rows are limited');
select t.eq_text(:'jw'::jsonb ->> 'total', '0', 'LIKE wildcards in a search are plain characters');
select (select r from jsonb_array_elements(:'jb'::jsonb -> 'rows') r where r ->> 'id' = :'b_id') as rb \gset
select t.eq_text((:'rb'::jsonb ->> 'complimentary'), 'true', 'a free license shows as complimentary');

-- 4. free licenses never replace a paid one ----------------------------------------------------------------------------
set role service_role;
select admin_grant_complimentary_license('11300000-0000-0000-0000-000000000009', :'a_id', 'one_time', '{}'::jsonb) as g2 \gset
select admin_revoke_complimentary_license('11300000-0000-0000-0000-000000000009', :'a_id') as rv1 \gset
select admin_revoke_complimentary_license('11300000-0000-0000-0000-000000000009', :'b_id') as rv2 \gset
select admin_grant_complimentary_license('11300000-0000-0000-0000-000000000009', gen_random_uuid(), 'one_time', '{}'::jsonb) as g3 \gset
reset role;
select t.eq_text(:'g2', 'has_paid_license', 'a company with a paid license is never given a free one over it');
select t.ok(not :'rv1'::boolean, 'revoking only ever removes free licenses');
select t.eq((select count(*) from organization_licenses where organization_id = :'a_id'), 1, 'the paid license is untouched');
select t.ok(:'rv2'::boolean, 'a free license can be revoked');
select t.eq((select count(*) from organization_licenses where organization_id = :'b_id'), 0, 'the company returns to the no-license state');
select t.eq_text(:'g3', 'not_found', 'an unknown company is reported');

-- 5. who may be erased ----------------------------------------------------------------------------------------------------
set role service_role;
select admin_user_delete_blockers('11300000-0000-0000-0000-000000000001') as bo \gset
select admin_user_delete_blockers('11300000-0000-0000-0000-000000000002') as br \gset
select admin_user_delete_blockers('11300000-0000-0000-0000-000000000005') as bs \gset
select admin_user_delete_blockers('11300000-0000-0000-0000-000000000006') as bi \gset
select admin_company_members(:'a_id') as mem \gset
select admin_user_memberships(array['11300000-0000-0000-0000-000000000002']::uuid[]) as um \gset
reset role;
select t.eq(jsonb_array_length(:'bo'::jsonb), 1, 'a company owner cannot be erased');
select t.eq(jsonb_array_length(:'br'::jsonb), 1, 'nor a working member');
select t.eq(jsonb_array_length(:'bs'::jsonb), 0, 'an account with no company can be erased');
select t.eq(jsonb_array_length(:'bi'::jsonb), 0, 'and so can one whose invitation was never accepted');
select t.eq(jsonb_array_length(:'mem'::jsonb), 4, 'the company detail lists every member, invitations included');
select t.eq_text(:'um'::jsonb -> '11300000-0000-0000-0000-000000000002' -> 0 ->> 'role_key', 'sales', 'a user''s memberships can be listed');

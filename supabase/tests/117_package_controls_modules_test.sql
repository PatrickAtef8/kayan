-- 0066: the package decides the modules.
--   * a company created WITHOUT optional modules gets exactly the modules of the package it pays for;
--   * a company that ticked a module outside the package under the old sign-up is not blocked from paying for a smaller package
--     (before the first license the fit report ignores modules), and that module is switched off when the license is created;
--   * widening a package later switches the NEW modules on and switches nothing off.

\set ON_ERROR_STOP on
select t.autoconfirm_off();

select t.as_owner();
insert into auth.users (id, email) values
  ('11700000-0000-0000-0000-000000000001', 'pkg-a@mods.test'),
  ('11700000-0000-0000-0000-000000000002', 'pkg-b@mods.test');

select t.as_user('11700000-0000-0000-0000-000000000001');
select create_organization('شركة بلا وحدات', 'x', 'EG', 'EGP', 'ar', array[]::text[]) as id \gset a_
select t.as_user('11700000-0000-0000-0000-000000000002');
select create_organization('شركة قديمة', 'x', 'EG', 'EGP', 'ar', array['customers','partners']) as id \gset b_

select t.as_owner();
\set basic '{"modules":["customers","suppliers","sales"],"max_members":3,"max_warehouses":2}'
\set wider '{"modules":["customers","suppliers","sales","partners"],"max_members":3,"max_warehouses":2}'

-- A: nothing optional before paying
select t.eq((select count(*) from organization_modules where organization_id = :'a_id' and enabled and module_key in ('customers','suppliers','sales','partners')), 0, 'sign-up without modules: no optional module is on before payment');

-- B: no license yet -> the fit report does not count modules
select t.eq_text((billing_fit_report(:'b_id', :'basic'::jsonb) ->> 'ok'), 'true', 'before the first license, modules never block a package');

insert into organization_licenses (organization_id, package_key, payment_option, entitlements, licensed_at, access_paid_through)
values (:'a_id', 'basic', 'one_time', :'basic'::jsonb, now(), now() + interval '30 days'),
       (:'b_id', 'basic', 'one_time', :'basic'::jsonb, now(), now() + interval '30 days');

select t.eq((select count(*) from organization_modules where organization_id = :'a_id' and enabled and module_key in ('customers','suppliers','sales')), 3, 'the license switched on exactly the package modules');
select t.eq((select count(*) from organization_modules where organization_id = :'a_id' and enabled and module_key = 'partners'), 0, 'and nothing outside the package');
select t.eq_text((select enabled::text from organization_modules where organization_id = :'b_id' and module_key = 'partners'), 'false', 'a module ticked under the old sign-up that the package does not include is switched off');
select t.eq_text((select enabled::text from organization_modules where organization_id = :'b_id' and module_key = 'customers'), 'true', 'a module inside the package stays on');

-- widening the package later switches the NEW module on, and only that
update organization_licenses set entitlements = :'wider'::jsonb where organization_id = :'a_id';
select t.eq_text((select enabled::text from organization_modules where organization_id = :'a_id' and module_key = 'partners'), 'true', 'a module added to the package is switched on');
update organization_licenses set entitlements = :'basic'::jsonb where organization_id = :'a_id';
select t.eq_text((select enabled::text from organization_modules where organization_id = :'a_id' and module_key = 'partners'), 'true', 'narrowing the package never switches anything off');

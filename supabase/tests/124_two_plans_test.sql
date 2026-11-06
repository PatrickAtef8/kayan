-- 0073: two plans. package_key and payment_option are the same word; free access is the 'one_time' plan.
\set ON_ERROR_STOP on
select t.autoconfirm_off();

select t.as_owner();
insert into auth.users (id, email) values
  ('12400000-0000-0000-0000-000000000001', 'plans-a@two.test'),
  ('12400000-0000-0000-0000-000000000002', 'plans-b@two.test');
select t.as_user('12400000-0000-0000-0000-000000000001');
select create_organization('شركة الخطتين أ', 'x', 'EG', 'EGP', 'ar', array[]::text[]) as id \gset a_
select t.as_user('12400000-0000-0000-0000-000000000002');
select create_organization('شركة الخطتين ب', 'x', 'EG', 'EGP', 'ar', array[]::text[]) as id \gset b_
select t.as_owner();

-- 1. a license or an order whose plan and payment option disagree cannot exist (any old package name is refused too)
select t.throws(format($q$insert into organization_licenses (organization_id, package_key, payment_option, entitlements) values (%L, 'professional', 'monthly', '{}')$q$, :'a_id'),
  'plan_is_option', 'a license must carry the plan that matches its payment option');
select t.throws(format($q$insert into billing_orders (organization_id, package_key, payment_option, purpose, amount_total, lines, entitlements) values (%L, 'one_time', 'monthly', 'initial', 5, '[]', '{}')$q$, :'a_id'),
  'plan_is_option', 'and so must an order');

-- 2. the matching pair is accepted
insert into organization_licenses (organization_id, package_key, payment_option, entitlements)
values (:'a_id', 'monthly', 'monthly', '{"modules":["sales"],"max_members":null,"max_warehouses":null}');
select t.eq((select count(*) from organization_licenses where organization_id = :'a_id'), 1, 'a monthly license under the monthly plan is fine');

-- 3. free access is always written as the one_time plan, whatever the caller passes (old callers passed "complete")
set role service_role;
select admin_grant_complimentary_license('12400000-0000-0000-0000-000000000009', :'b_id', 'complete', '{"modules":["sales"],"max_members":null,"max_warehouses":null}') as g \gset
reset role;
select t.eq_text(:'g', 'granted', 'free access is granted');
select t.eq_text((select package_key || '/' || payment_option from organization_licenses where organization_id = :'b_id'), 'one_time/one_time', 'free access is the one_time plan, whatever name the caller passed');

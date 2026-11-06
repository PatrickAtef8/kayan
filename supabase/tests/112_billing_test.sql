-- 0060: pricing packages, licenses and XPay payments.
-- Covers: who may read billing rows (the owner of that organization only) and who may write them (nobody from a browser
-- session — only the service role, through the billing_* functions); starting an order (owner check, one open checkout
-- per organization, re-click reuse, replacing a different open checkout, "does this organization fit the package?");
-- activating a license ONLY with the right amount, exactly once however often the payment is reported (webhook
-- re-delivery / return-page race); renewals (extend from the paid-through date, or from today if it already lapsed);
-- closing unpaid orders without ever touching a paid one; webhook de-duplication; and the package limits the database
-- enforces (modules, team members, warehouses) with proof that an organization WITHOUT a license is unaffected.

\set ON_ERROR_STOP on
select t.autoconfirm_off();

select t.as_owner();
insert into auth.users (id, email) values
  ('11200000-0000-0000-0000-000000000001', 'owner@bill.test'),
  ('11200000-0000-0000-0000-000000000002', 'rep@bill.test'),
  ('11200000-0000-0000-0000-000000000003', 'keeper@bill.test'),
  ('11200000-0000-0000-0000-000000000004', 'other-owner@bill.test'),
  ('11200000-0000-0000-0000-000000000005', 'extra@bill.test'),
  ('11200000-0000-0000-0000-000000000006', 'extra2@bill.test');

select t.as_user('11200000-0000-0000-0000-000000000001');
select create_organization('شركة الفوترة', 'x', 'EG', 'EGP', 'ar',
  array['products','warehouses','customers','suppliers','sales','purchases','inventory','reports']) as id \gset org_
select t.as_user('11200000-0000-0000-0000-000000000004');
select create_organization('شركة أخرى', 'x', 'EG', 'EGP', 'ar', array['products','warehouses','customers','sales']) as id \gset oth_

select t.as_owner();
insert into organization_users (organization_id, user_id, role_id, status)
select :'org_id', u.id, r.id, 'active'
from (values ('11200000-0000-0000-0000-000000000002'::uuid, 'sales'), ('11200000-0000-0000-0000-000000000003', 'warehouse')) u(id, k)
join roles r on r.key = u.k and r.organization_id is null;

-- the package used below: five of the modules this organization already uses, three seats, two warehouses
\set basic '{"modules":["customers","suppliers","sales","purchases","inventory","expenses","treasury"],"max_members":3,"max_warehouses":2}'
\set tiny  '{"modules":["customers"],"max_members":1,"max_warehouses":1}'
\set lines '[{"id":"license","label":"license","amount":1200000},{"id":"hosting","label":"hosting","amount":45000}]'

-- ============================================================
-- 1. Nobody but the service role can call the billing functions
-- ============================================================
select t.as_user('11200000-0000-0000-0000-000000000001');
select t.throws(format($q$select billing_begin_order(%L::uuid, %L::uuid, 'one_time', 'one_time', 'initial', 'EGP', 1245000, 45000, %L::jsonb, %L::jsonb, 1)$q$,
  :'org_id', '11200000-0000-0000-0000-000000000001', :'lines', :'basic'), 'permission denied', 'the owner (signed-in browser session) cannot start an order directly');
select t.throws(format($q$select billing_apply_payment(gen_random_uuid(), 'cs_test_x', 'pi_x', 1245000, 'EGP')$q$), 'permission denied', 'nobody can activate a payment from a browser session');
select t.throws($q$select billing_mark_order(gen_random_uuid(), 'failed', 'x')$q$, 'permission denied', 'nobody can close an order from a browser session');
select t.throws($q$select billing_begin_webhook_event('evt_1', 'x', null)$q$, 'permission denied', 'nobody can write webhook events from a browser session');
select t.throws(format($q$select billing_fit_report(%L::uuid, '{}'::jsonb)$q$, :'org_id'), 'permission denied', 'the fit report is server-only too');
select t.as_anon();
select t.throws($q$select billing_apply_payment(gen_random_uuid(), 'cs_test_x', 'pi_x', 1, 'EGP')$q$, 'permission denied', 'anon cannot activate a payment');

-- ============================================================
-- 2. Starting an order
-- ============================================================
select t.as_owner();
set role service_role;
select billing_begin_order(:'org_id', '11200000-0000-0000-0000-000000000002', 'one_time', 'one_time', 'initial', 'EGP', 1245000, 45000, :'lines', :'basic', 1) ->> 'result' as r \gset
reset role;
select t.eq_text(:'r', 'not_owner', 'a sales member cannot start a purchase');

set role service_role;
select billing_begin_order(:'org_id', '11200000-0000-0000-0000-000000000001', 'tiny', 'one_time', 'initial', 'EGP', 1245000, 45000, :'lines', :'tiny', 1) as j \gset
reset role;
select t.eq_text(:'j'::jsonb ->> 'result', 'fit_failed', 'a package this organization already outgrew is refused BEFORE any payment');
select t.ok(not (:'j'::jsonb -> 'report' -> 'violations' @> '[{"kind":"modules"}]'::jsonb), 'before a first license the package itself decides the modules: they are not judged (0066)');
select t.ok(:'j'::jsonb -> 'report' -> 'violations' @> '[{"kind":"members","current":3,"max":1}]'::jsonb, 'the report names the team size that does not fit');
select t.eq((select count(*) from billing_orders where organization_id = :'org_id'), 0, 'a refused order leaves no row behind');

set role service_role;
select billing_begin_order(:'org_id', '11200000-0000-0000-0000-000000000001', 'one_time', 'one_time', 'initial', 'EGP', 1245000, 45000, :'lines', :'basic', 1) as j \gset
reset role;
select t.eq_text(:'j'::jsonb ->> 'result', 'created', 'the owner can start an order');
select (:'j'::jsonb -> 'order' ->> 'id') as o1 \gset
select t.eq_text((select status from billing_orders where id = :'o1'), 'pending', 'it starts pending');
select t.eq((select amount_total from billing_orders where id = :'o1'), 1245000, 'the amount is stored in piasters');

set role service_role;
select billing_begin_order(:'org_id', '11200000-0000-0000-0000-000000000001', 'one_time', 'one_time', 'initial', 'EGP', 1245000, 45000, :'lines', :'basic', 1) as j \gset
reset role;
select t.eq_text(:'j'::jsonb ->> 'result', 'reused', 'clicking pay again re-uses the open checkout');
select t.eq_text(:'j'::jsonb -> 'order' ->> 'id', :'o1', 'and it is the same order');
select t.eq((select count(*) from billing_orders where organization_id = :'org_id'), 1, 'never two orders for one click');

-- attaching the XPay session
set role service_role;
select billing_attach_session(:'o1', 'cs_test_one', 'https://checkout.xpay.app/c/cs_test_one') as a1 \gset
select billing_attach_session(:'o1', 'cs_test_other', 'https://checkout.xpay.app/c/cs_test_other') as a2 \gset
reset role;
select t.ok(:'a1'::boolean, 'the session is attached');
select t.ok(not :'a2'::boolean, 'a different session can never replace the attached one');

-- a DIFFERENT checkout replaces the open one and tells the server which XPay session to expire
set role service_role;
select billing_begin_order(:'org_id', '11200000-0000-0000-0000-000000000001', 'monthly', 'monthly', 'initial', 'EGP', 165000, 165000,
  '[{"id":"subscription","label":"s","amount":165000}]', :'basic', 1) as j \gset
reset role;
select t.eq_text(:'j'::jsonb ->> 'result', 'created', 'switching to the monthly option opens a new order');
select t.eq_text(:'j'::jsonb ->> 'superseded_session_id', 'cs_test_one', 'and reports the old session so it can be expired at XPay');
select t.eq_text((select status || '/' || failure_reason from billing_orders where id = :'o1'), 'canceled/superseded', 'the replaced order is closed');
select (:'j'::jsonb -> 'order' ->> 'id') as o2 \gset
select t.eq((select count(*) from billing_orders where organization_id = :'org_id' and status = 'pending'), 1, 'exactly one open checkout');
select t.throws(format($q$insert into billing_orders (organization_id, package_key, payment_option, purpose, amount_total, lines, entitlements) values (%L, 'monthly', 'monthly', 'initial', 5, '[]', '{}')$q$, :'org_id'),
  'billing_orders_one_pending', 'the database itself refuses a second open checkout');

-- ============================================================
-- 3. Activation: the right amount, exactly once
-- ============================================================
set role service_role;
select billing_attach_session(:'o2', 'cs_test_two', 'https://checkout.xpay.app/c/cs_test_two') as x \gset
-- a payment reported with the WRONG amount never activates anything
select billing_apply_payment(:'o2', 'cs_test_two', 'pi_two', 100, 'EGP') ->> 'result' as r \gset
reset role;
select t.eq_text(:'r', 'amount_mismatch', 'a wrong amount is refused');
select t.eq((select count(*) from organization_licenses where organization_id = :'org_id'), 0, 'and grants nothing');
select t.ok((select needs_review from billing_orders where id = :'o2'), 'it is flagged for a human to look at');
select t.eq_text((select status from billing_orders where id = :'o2'), 'failed', 'and closed');

set role service_role;
select billing_begin_order(:'org_id', '11200000-0000-0000-0000-000000000001', 'monthly', 'monthly', 'initial', 'EGP', 165000, 165000,
  '[{"id":"subscription","label":"s","amount":165000}]', :'basic', 1) ->> 'result' as r \gset
reset role;
select t.eq_text(:'r', 'created', 'after a failed attempt the owner can start a fresh checkout');
select id as o3 from billing_orders where organization_id = :'org_id' and status = 'pending' \gset

set role service_role;
select billing_attach_session(:'o3', 'cs_test_three', 'https://checkout.xpay.app/c/cs_test_three') as x \gset
select billing_apply_payment(:'o3', 'cs_test_WRONG', 'pi_three', 165000, 'EGP') ->> 'result' as r \gset
reset role;
select t.eq_text(:'r', 'session_mismatch', 'a payment from a different XPay session is not accepted for this order');
select t.eq((select count(*) from organization_licenses where organization_id = :'org_id'), 0, 'still nothing granted');

set role service_role;
select billing_apply_payment(:'o3', 'cs_test_three', 'pi_three', 165000, 'EGP') ->> 'result' as r \gset
reset role;
select t.eq_text(:'r', 'applied', 'the verified payment activates the license');
select t.eq_text((select package_key || '/' || payment_option from organization_licenses where organization_id = :'org_id'), 'monthly/monthly', 'with the package and option that were bought');
select t.ok((select access_paid_through between now() + interval '1 month' - interval '1 minute' and now() + interval '1 month' + interval '1 minute' from organization_licenses where organization_id = :'org_id'), 'paid through one month from now');
select t.eq_text((select status || '/' || xpay_payment_intent_id from billing_orders where id = :'o3'), 'paid/pi_three', 'the order is paid and remembers the XPay payment intent');
select access_paid_through as pt1 from organization_licenses where organization_id = :'org_id' \gset

-- the same payment reported again (webhook re-delivery, return page, retry): nothing changes
set role service_role;
select billing_apply_payment(:'o3', 'cs_test_three', 'pi_three', 165000, 'EGP') ->> 'result' as r \gset
select billing_apply_payment(:'o3', 'cs_test_three', 'pi_three', 165000, 'EGP') ->> 'result' as r2 \gset
reset role;
select t.eq_text(:'r', 'already_applied', 'a repeated report is recognised');
select t.eq_text(:'r2', 'already_applied', 'every time');
select t.ok((select access_paid_through = :'pt1'::timestamptz from organization_licenses where organization_id = :'org_id'), 'and never extends the access twice');
select t.eq((select count(*) from organization_licenses where organization_id = :'org_id'), 1, 'one license');

-- a paid order can never be closed afterwards
set role service_role;
select billing_mark_order(:'o3', 'failed', 'late failure event') as m \gset
reset role;
select t.ok(not :'m'::boolean, 'a late "failed" event cannot undo a paid order');
select t.eq_text((select status from billing_orders where id = :'o3'), 'paid', 'it stays paid');

-- a new initial purchase once a license exists is refused
set role service_role;
select billing_begin_order(:'org_id', '11200000-0000-0000-0000-000000000001', 'one_time', 'one_time', 'initial', 'EGP', 1245000, 45000, :'lines', :'basic', 1) ->> 'result' as r \gset
reset role;
select t.eq_text(:'r', 'license_exists', 'an organization that holds a license cannot buy a second one');

-- ============================================================
-- 4. Renewals
-- ============================================================
set role service_role;
select billing_begin_order(:'org_id', '11200000-0000-0000-0000-000000000001', 'one_time', 'one_time', 'renewal', 'EGP', 45000, 45000, '[{"id":"hosting","label":"h","amount":45000}]', :'basic', 1) ->> 'result' as r \gset
reset role;
select t.eq_text(:'r', 'mismatch', 'a renewal must be for the package and option the organization actually holds');

set role service_role;
select billing_begin_order(:'org_id', '11200000-0000-0000-0000-000000000001', 'monthly', 'monthly', 'renewal', 'EGP', 165000, 165000, '[{"id":"subscription","label":"s","amount":165000}]', :'basic', 1) ->> 'result' as r \gset
reset role;
select t.eq_text(:'r', 'created', 'the owner can renew');
select id as o4 from billing_orders where organization_id = :'org_id' and status = 'pending' \gset
set role service_role;
select billing_attach_session(:'o4', 'cs_test_four', 'u') as x \gset
select billing_apply_payment(:'o4', 'cs_test_four', 'pi_four', 165000, 'EGP') ->> 'result' as r \gset
reset role;
select t.eq_text(:'r', 'applied', 'the renewal is applied');
select t.ok((select access_paid_through = :'pt1'::timestamptz + interval '1 month' from organization_licenses where organization_id = :'org_id'), 'an early renewal ADDS a month to the date it was already paid through');
select t.eq_text((select period_start = :'pt1'::timestamptz and period_end = :'pt1'::timestamptz + interval '1 month' from billing_orders where id = :'o4')::text, 'true', 'the order records the period it bought');

-- a lapsed license renews from TODAY, not from the long-gone paid-through date
update organization_licenses set access_paid_through = now() - interval '40 days' where organization_id = :'org_id';
set role service_role;
select billing_begin_order(:'org_id', '11200000-0000-0000-0000-000000000001', 'monthly', 'monthly', 'renewal', 'EGP', 165000, 165000, '[{"id":"subscription","label":"s","amount":165000}]', :'basic', 1) ->> 'result' as r \gset
reset role;
select id as o5 from billing_orders where organization_id = :'org_id' and status = 'pending' \gset
set role service_role;
select billing_apply_payment(:'o5', 'cs_test_five', 'pi_five', 165000, 'EGP') ->> 'result' as r \gset
reset role;
select t.eq_text(:'r', 'applied', 'a lapsed license can be renewed (the session id is learned from the verified payment)');
select t.ok((select access_paid_through between now() + interval '1 month' - interval '1 minute' and now() + interval '1 month' + interval '1 minute' from organization_licenses where organization_id = :'org_id'), 'and is paid through one month from today');

-- unpaid ends: expired / failed, never touching a paid order
set role service_role;
select billing_begin_order(:'org_id', '11200000-0000-0000-0000-000000000001', 'monthly', 'monthly', 'renewal', 'EGP', 165000, 165000, '[{"id":"subscription","label":"s","amount":165000}]', :'basic', 1) ->> 'result' as r \gset
reset role;
select id as o6 from billing_orders where organization_id = :'org_id' and status = 'pending' \gset
set role service_role;
select billing_mark_order(:'o6', 'expired', 'session expired') as m1 \gset
select billing_mark_order(:'o6', 'failed', 'again') as m2 \gset
reset role;
select t.ok(:'m1'::boolean, 'an open order can be closed as expired');
select t.ok(not :'m2'::boolean, 'a closed order is not changed again');
select t.eq_text((select status from billing_orders where id = :'o6'), 'expired', 'it stays expired');
select t.eq((select count(*) from billing_orders where organization_id = :'org_id' and status = 'pending'), 0, 'and the organization can start a new checkout');

-- a late payment on an order that was closed locally is still honoured (the customer paid) when the amount is right
set role service_role;
select billing_apply_payment(:'o6', 'cs_test_late', 'pi_late', 165000, 'EGP') ->> 'result' as r \gset
reset role;
select t.eq_text(:'r', 'applied', 'money that really arrived for a locally-closed order is not lost');

-- ============================================================
-- 5. Webhook de-duplication
-- ============================================================
set role service_role;
select billing_begin_webhook_event('evt_a', 'checkout.session.completed', 'cs_test_three') as b1 \gset
select billing_begin_webhook_event('evt_a', 'checkout.session.completed', 'cs_test_three') as b2 \gset
select billing_finish_webhook_event('evt_a', 'applied');
select billing_begin_webhook_event('evt_a', 'checkout.session.completed', 'cs_test_three') as b3 \gset
reset role;
select t.ok(:'b1'::boolean, 'a new event is processed');
select t.ok(:'b2'::boolean, 'an event that arrived but never finished is processed again (the handler failed the first time)');
select t.ok(not :'b3'::boolean, 'an event that was processed completely is skipped');
select t.eq((select attempts from billing_webhook_events where event_id = 'evt_a'), 2, 'attempts are counted');

-- ============================================================
-- 6. Who can read what
-- ============================================================
select t.as_user('11200000-0000-0000-0000-000000000001');
select t.ok((select count(*) from organization_licenses) = 1, 'the owner sees the license of their organization');
select t.ok((select count(*) from billing_orders) >= 5, 'and its orders');
select t.throws($q$insert into billing_orders (organization_id, package_key, payment_option, purpose, amount_total, lines, entitlements) values (gen_random_uuid(), 'monthly', 'monthly', 'initial', 5, '[]', '{}')$q$, 'permission denied', 'the owner cannot write an order');
select t.throws(format($q$update organization_licenses set package_key = 'monthly' where organization_id = %L$q$, :'org_id'), 'permission denied', 'the owner cannot edit their own license');
select t.throws(format($q$delete from billing_orders where organization_id = %L$q$, :'org_id'), 'permission denied', 'or delete an order');
select t.throws($q$select * from billing_webhook_events$q$, 'permission denied', 'webhook events are invisible');
select t.as_user('11200000-0000-0000-0000-000000000004');
select t.empty('select 1 from organization_licenses', 'another organization''s owner sees no license of ours');
select t.empty('select 1 from billing_orders', 'and no orders');
select t.as_user('11200000-0000-0000-0000-000000000002');
select t.empty('select 1 from organization_licenses', 'a sales member sees no license');
select t.empty('select 1 from billing_orders', 'and no orders');
select t.as_user('11200000-0000-0000-0000-000000000003');
select t.empty('select 1 from billing_orders', 'a storekeeper sees no orders');
select t.as_anon();
select t.throws('select * from billing_orders', 'permission denied', 'anon cannot read orders');

-- ============================================================
-- 7. Package limits enforced by the database
--    (this organization now holds the "basic" license: 7 modules, 3 members, 2 warehouses)
-- ============================================================
select t.as_user('11200000-0000-0000-0000-000000000001');
select t.throws(format($q$insert into organization_modules (organization_id, module_key, enabled) values (%L, 'partners', true)$q$, :'org_id'),
  'غير مشمولة في باقتك', 'a module outside the package cannot be switched on');
select t.eq((select count(*) from organization_modules where organization_id = :'org_id' and module_key = 'partners'), 0, 'and no row is left behind');
-- 0066: paying switched ON every module of the package (expenses was not ticked at creation, the package gave it)
select t.eq_text((select enabled::text from organization_modules where organization_id = :'org_id' and module_key = 'expenses'), 'true', 'the package switched its own modules on when the license was created');
select t.eq((t.affected(format($q$insert into organization_modules (organization_id, module_key, enabled) values (%L, 'offers', true)$q$, :'org_id'))), 1, 'offers (a placeholder with no function) is never gated');
select t.eq((t.affected(format($q$update organization_modules set enabled = false where organization_id = %L and module_key = 'expenses'$q$, :'org_id'))), 1, 'switching a module OFF is always allowed');
select t.eq((t.affected(format($q$update organization_modules set enabled = true where organization_id = %L and module_key = 'expenses'$q$, :'org_id'))), 1, 'and back on while it is inside the package');

select t.as_owner();
-- three active members already (owner + rep + keeper)
select t.throws(format($q$insert into organization_users (organization_id, user_id, role_id, status) select %L, '11200000-0000-0000-0000-000000000005', r.id, 'active' from roles r where r.key = 'sales' and r.organization_id is null$q$, :'org_id'),
  'الحد الأقصى لعدد أعضاء الفريق', 'a fourth active member is refused at the package limit');
insert into organization_users (organization_id, user_id, role_id, status)
select :'org_id', '11200000-0000-0000-0000-000000000005', r.id, 'invited' from roles r where r.key = 'sales' and r.organization_id is null;
select t.ok(true, 'an invitation that is not active yet is not counted');
select t.throws(format($q$update organization_users set status = 'active' where organization_id = %L and user_id = '11200000-0000-0000-0000-000000000005'$q$, :'org_id'),
  'الحد الأقصى لعدد أعضاء الفريق', 'but accepting it past the limit is refused');
select t.eq((t.affected(format($q$update organization_users set status = 'disabled' where organization_id = %L and user_id = '11200000-0000-0000-0000-000000000003'$q$, :'org_id'))), 1, 'disabling a member frees a seat');
select t.eq((t.affected(format($q$update organization_users set status = 'active' where organization_id = %L and user_id = '11200000-0000-0000-0000-000000000005'$q$, :'org_id'))), 1, 'which the invited person can then take');

insert into warehouses (organization_id, name) values (:'org_id', 'مخزن 1'), (:'org_id', 'مخزن 2');
select t.throws(format($q$insert into warehouses (organization_id, name) values (%L, 'مخزن 3')$q$, :'org_id'), 'الحد الأقصى لعدد المخازن', 'a third warehouse is refused at the package limit');
update warehouses set is_active = false where organization_id = :'org_id' and name = 'مخزن 2';
insert into warehouses (organization_id, name) values (:'org_id', 'مخزن 3');
select t.ok(true, 'deactivating a warehouse frees a slot');
select t.throws(format($q$update warehouses set is_active = true where organization_id = %L and name = 'مخزن 2'$q$, :'org_id'), 'الحد الأقصى لعدد المخازن', 're-activating it past the limit is refused');
select t.eq((t.affected(format($q$update warehouses set name = 'مخزن 1 (معدّل)' where organization_id = %L and name = 'مخزن 1'$q$, :'org_id'))), 1, 'editing an existing warehouse is never blocked');

-- an organization WITHOUT a license is completely unaffected
select t.as_user('11200000-0000-0000-0000-000000000004');
select t.eq((t.affected(format($q$insert into organization_modules (organization_id, module_key, enabled) values (%L, 'partners', true)$q$, :'oth_id'))), 1, 'no license: any module can be enabled');
select t.eq((t.affected(format($q$insert into warehouses (organization_id, name) select %L, 'w' || g from generate_series(1, 6) g$q$, :'oth_id'))), 6, 'no license: any number of warehouses');
select t.as_owner();
alter table organization_users disable trigger zz_one_active_company;   -- this test deliberately puts members of other companies into this one
insert into organization_users (organization_id, user_id, role_id, status)
select :'oth_id', u, r.id, 'active' from unnest(array['11200000-0000-0000-0000-000000000002', '11200000-0000-0000-0000-000000000003', '11200000-0000-0000-0000-000000000006']::uuid[]) u
join roles r on r.key = 'warehouse' and r.organization_id is null;
alter table organization_users enable trigger zz_one_active_company;
select t.ok(true, 'no license: any number of members');

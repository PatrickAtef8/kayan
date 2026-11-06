-- 0074: the free trial (start, run, end, subscribe, extend) and "hosting & maintenance = 0", enforced IN THE DATABASE.
-- Like 115, this file switches the payment gate ON for its fixtures and OFF again at the end.
\set ON_ERROR_STOP on
select t.autoconfirm_off();
select t.as_owner();
update platform_billing_settings set gate_enforced = true, grace_enabled = true, grace_hours = 24, trial_enabled = true, trial_days = 15;
delete from platform_pricing_config where id = 1;
insert into auth.users (id, email, email_confirmed_at) values
  ('12500000-0000-0000-0000-000000000001', 'owner-a@trial.test', now()),   -- owner of A: starts a trial, it ends, subscribes
  ('12500000-0000-0000-0000-000000000002', 'rep-a@trial.test',   now()),   -- a member of A
  ('12500000-0000-0000-0000-000000000003', 'owner-b@trial.test', now()),   -- owner of B: never starts a trial; later owns the second company of A's owner
  ('12500000-0000-0000-0000-000000000004', 'owner-c@trial.test', now()),   -- owner of C: a trial under a changed length
  ('12500000-0000-0000-0000-000000000005', 'owner-d@trial.test', now());   -- owner of D: a paid company (hosting price tests)

select t.as_user('12500000-0000-0000-0000-000000000001');
select create_organization('شركة التجربة أ', 'x', 'EG', 'EGP', 'ar', array['products','warehouses','customers','sales']) as id \gset a_
select t.as_user('12500000-0000-0000-0000-000000000003');
select create_organization('شركة ب', 'x', 'EG', 'EGP', 'ar', array['products','warehouses','customers','sales']) as id \gset b_
select t.as_user('12500000-0000-0000-0000-000000000004');
select create_organization('شركة ج', 'x', 'EG', 'EGP', 'ar', array['products','warehouses','customers','sales']) as id \gset c_
select t.as_user('12500000-0000-0000-0000-000000000005');
select create_organization('شركة د', 'x', 'EG', 'EGP', 'ar', array['products','warehouses','customers','sales']) as id \gset d_
select t.as_owner();
insert into organization_users (organization_id, user_id, role_id, status)
select :'a_id', '12500000-0000-0000-0000-000000000002', r.id, 'active' from roles r where r.key = 'sales' and r.organization_id is null;
insert into customers (organization_id, name) values (:'a_id', 'عميل 1'), (:'a_id', 'عميل 2'), (:'b_id', 'عميل ب');

-- ============================================================
-- 1. Before any trial: closed, and the trial is on offer to the owner
-- ============================================================
select t.as_user('12500000-0000-0000-0000-000000000001');
select t.eq((select count(*) from customers), 0, 'no license, no trial: the company sees none of its data');
select t.eq_text(my_org_access(:'a_id') -> 'access' ->> 'state', 'none', 'state none');
select t.eq_text(my_org_access(:'a_id') -> 'trial_offer' ->> 'eligible', 'true', 'the trial is offered');
select t.eq_text(my_org_access(:'a_id') -> 'trial_offer' ->> 'days', '15', 'for 15 days by default');

-- ============================================================
-- 2. Nothing a browser can do starts, reads or extends a trial
-- ============================================================
select t.throws(format($q$select billing_start_trial(%L, %L, array['sales'])$q$, :'a_id', '12500000-0000-0000-0000-000000000001'), 'permission denied', 'a signed-in browser cannot start a trial');
select t.throws($q$select count(*) from organization_trials$q$, 'permission denied', 'nor read the trials table');
select t.throws($q$insert into organization_trials (organization_id, ends_at, trial_days) select id, now() + interval '99 days', 99 from organizations limit 1$q$, 'permission denied', 'nor write one');
select t.throws(format($q$select admin_extend_trial(%L, %L, 30)$q$, '12500000-0000-0000-0000-000000000001', :'a_id'), 'permission denied', 'nor extend one');
select t.throws($q$select admin_save_trial_settings('12500000-0000-0000-0000-000000000001', true, 400)$q$, 'permission denied', 'nor change the trial length');

-- ============================================================
-- 3. Starting: only the owner, once per company, once per account
-- ============================================================
select t.as_owner();
set role service_role;
select (billing_start_trial(:'a_id', '12500000-0000-0000-0000-000000000002', array['customers','sales']) ->> 'result') as r_rep \gset
select (billing_start_trial(:'a_id', '12500000-0000-0000-0000-000000000003', array['customers','sales']) ->> 'result') as r_stranger \gset
reset role;
select t.eq_text(:'r_rep', 'not_owner', 'a team member cannot start the trial');
select t.eq_text(:'r_stranger', 'not_owner', 'neither can the owner of another company');
select t.eq((select count(*) from organization_trials), 0, 'nothing was created by the refused attempts');

set role service_role;
select billing_start_trial(:'a_id', '12500000-0000-0000-0000-000000000001', array['customers','sales','not a module!','products']) as r_ok \gset
reset role;
select t.eq_text((:'r_ok'::jsonb) ->> 'result', 'started', 'the owner starts the trial');
select t.eq_text((:'r_ok'::jsonb) ->> 'days', '15', 'for the configured length');
select t.ok((select ends_at between now() + interval '15 days' - interval '1 minute' and now() + interval '15 days' + interval '1 minute' from organization_trials where organization_id = :'a_id'), 'ending 15 days from now');
select t.eq((select count(*) from organization_modules where organization_id = :'a_id' and enabled and module_key in ('customers', 'sales')), 2, 'the trial switches on the optional modules it was given');
select t.eq((select count(*) from organization_modules where organization_id = :'a_id' and module_key like '%!%'), 0, 'a malformed module name is ignored');
select t.eq((select count(*) from organization_modules where organization_id = :'a_id' and module_key = 'products' and enabled), (select count(*) from organization_modules where organization_id = :'b_id' and module_key = 'products' and enabled), 'core modules are not touched by the trial');

set role service_role;
select (billing_start_trial(:'a_id', '12500000-0000-0000-0000-000000000001', array['sales']) ->> 'result') as r_again \gset
reset role;
select t.eq_text(:'r_again', 'already_started', 'the same company cannot start a second trial');
-- an account owns one company at a time (create_organization enforces it), but the trial is bound to the ACCOUNT too: a second trial row for the same user is refused by the database
select t.throws(format($q$insert into organization_trials (organization_id, started_by, ends_at, trial_days) values (%L, %L, now() + interval '5 days', 5)$q$, :'b_id', '12500000-0000-0000-0000-000000000001'), 'organization_trials_one_per_user', 'one trial per account, enforced by a unique index');
select t.as_user('12500000-0000-0000-0000-000000000001');
select t.eq_text(my_org_access(:'a_id') -> 'trial_offer' ->> 'eligible', 'false', 'the offer is gone once the trial has started');

-- ============================================================
-- 4. During the trial everything works, for the owner and the team
-- ============================================================
select t.as_user('12500000-0000-0000-0000-000000000001');
select t.eq_text(my_org_access(:'a_id') -> 'access' ->> 'state', 'trial', 'state trial');
select t.eq_text(my_org_access(:'a_id') -> 'access' ->> 'open', 'true', 'open');
select t.ok((my_org_access(:'a_id') -> 'access' ->> 'seconds_left')::bigint between 15 * 86400 - 120 and 15 * 86400, 'the time left is counted from the trial end');
select t.eq((select count(*) from customers), 2, 'the owner sees the company data');
select t.ok(is_org_member(:'a_id'), 'is_org_member is true');
select t.as_user('12500000-0000-0000-0000-000000000002');
select t.ok(is_org_member(:'a_id'), 'so does the team');
select t.ok(has_permission(:'a_id', 'sales.create'), 'with its permissions');
select t.as_user('12500000-0000-0000-0000-000000000003');
select t.eq((select count(*) from customers), 0, 'a company that has not started a trial stays closed');

-- the changed length only affects trials that start LATER
select t.as_owner();
select admin_save_trial_settings('12500000-0000-0000-0000-000000000009', true, 7) as saved_settings \gset
select t.eq((select trial_days from platform_billing_settings where id = 1), 7, 'the length is saved');
select t.eq((select trial_days from organization_trials where organization_id = :'a_id'), 15, 'a trial already running keeps its own length');
set role service_role;
select (billing_start_trial(:'c_id', '12500000-0000-0000-0000-000000000004', array['sales']) ->> 'days') as c_days \gset
reset role;
select t.eq_text(:'c_days', '7', 'a trial that starts afterwards gets the new length');
select t.throws($q$select admin_save_trial_settings('12500000-0000-0000-0000-000000000009', true, 0)$q$, 'invalid trial settings', 'zero days is refused');
select t.throws($q$select admin_save_trial_settings('12500000-0000-0000-0000-000000000009', true, 366)$q$, 'invalid trial settings', 'more than a year is refused');
select t.throws($q$select admin_save_trial_settings('12500000-0000-0000-0000-000000000009', null, 7)$q$, 'invalid trial settings', 'a missing switch is refused');

-- switched off: nobody new can start one, running ones continue
select admin_save_trial_settings('12500000-0000-0000-0000-000000000009', false, 7) as off_settings \gset
set role service_role;
select (billing_start_trial(:'b_id', '12500000-0000-0000-0000-000000000003', array['sales']) ->> 'result') as r_off \gset
reset role;
select t.eq_text(:'r_off', 'disabled', 'with the trial switched off nobody can start one');
select t.as_user('12500000-0000-0000-0000-000000000003');
select t.eq_text(my_org_access(:'b_id') -> 'trial_offer' ->> 'eligible', 'false', 'and it is no longer offered');
select t.as_user('12500000-0000-0000-0000-000000000001');
select t.eq((select count(*) from customers), 2, 'a running trial is not cut short by switching the offer off');
select t.as_owner();
select admin_save_trial_settings('12500000-0000-0000-0000-000000000009', true, 15) as on_settings \gset

-- ============================================================
-- 5. The trial ends: closed everywhere, nothing deleted
-- ============================================================
update organization_trials set ends_at = now() - interval '1 second', started_at = now() - interval '15 days' where organization_id = :'a_id';
select t.as_user('12500000-0000-0000-0000-000000000001');
select t.eq_text(my_org_access(:'a_id') -> 'access' ->> 'state', 'trial_expired', 'state trial_expired');
select t.eq_text(my_org_access(:'a_id') -> 'access' ->> 'open', 'false', 'closed');
select t.eq((select count(*) from customers), 0, 'direct API read: nothing');
select t.throws(format($q$insert into customers (organization_id, name) values (%L, 'x')$q$, :'a_id'), 'row-level security', 'direct API write: refused');
select t.ok(not is_org_member(:'a_id'), 'is_org_member is false');
select t.throws(format($q$select warehouse_pending_counts(%L)$q$, :'a_id'), '', 'RPCs refuse');
select t.eq_text(my_org_access(:'a_id') -> 'trial_offer' ->> 'eligible', 'false', 'an ended trial is not offered again');
select t.as_user('12500000-0000-0000-0000-000000000002');
select t.ok(not is_org_member(:'a_id') and not has_permission(:'a_id', 'sales.create'), 'the team is closed out too');
select t.as_owner();
select t.eq((select count(*) from customers where organization_id = :'a_id'), 2, 'but the data is still there');
select ends_at as te from organization_trials where organization_id = :'a_id' \gset
select t.eq_text(billing_access_state(:'a_id', :'te') ->> 'state', 'trial', 'boundary: exactly at the trial end it is still open');
select t.eq_text(billing_access_state(:'a_id', (:'te'::timestamptz + interval '1 microsecond')) ->> 'state', 'trial_expired', 'one microsecond later it is over');

-- the Super Admin can give one company more time; it counts from today when the trial already ended
set role service_role;
select admin_extend_trial('12500000-0000-0000-0000-000000000009', :'a_id', 5) as ext \gset
select (admin_extend_trial('12500000-0000-0000-0000-000000000009', :'b_id', 5) ->> 'result') as ext_none \gset
reset role;
select t.eq_text((:'ext'::jsonb) ->> 'result', 'extended', 'an ended trial can be extended');
select t.ok((select ends_at between now() + interval '5 days' - interval '1 minute' and now() + interval '5 days' + interval '1 minute' from organization_trials where organization_id = :'a_id'), 'from today');
select t.eq((select extended_days from organization_trials where organization_id = :'a_id'), 5, 'and the extension is recorded');
select t.eq_text(:'ext_none', 'no_trial', 'a company that never started one has nothing to extend');
select t.as_user('12500000-0000-0000-0000-000000000001');
select t.eq((select count(*) from customers), 2, 'the company is open again with all its data');
select t.as_owner();

-- ============================================================
-- 6. Subscribing: the company opens with the data it already had; a license always wins over the trial
-- ============================================================
update organization_trials set ends_at = now() - interval '1 hour', started_at = now() - interval '15 days' where organization_id = :'a_id';
select t.as_user('12500000-0000-0000-0000-000000000001');
select t.eq((select count(*) from customers), 0, 'closed again');
select t.as_owner();
insert into organization_licenses (organization_id, package_key, payment_option, entitlements, access_paid_through)
values (:'a_id', 'monthly', 'monthly', '{"modules":["customers","sales"],"max_members":null,"max_warehouses":null}', now() + interval '30 days');
select t.as_user('12500000-0000-0000-0000-000000000001');
select t.eq_text(my_org_access(:'a_id') -> 'access' ->> 'state', 'active', 'the paid subscription is judged, not the trial');
select t.eq((select count(*) from customers), 2, 'the owner finds exactly the data the trial left');
select t.as_user('12500000-0000-0000-0000-000000000002');
select t.ok(is_org_member(:'a_id') and has_permission(:'a_id', 'sales.create'), 'and so does the team');

-- a lapsed paid company is NOT re-opened by an old (or extended) trial
select t.as_owner();
update organization_trials set ends_at = now() + interval '30 days' where organization_id = :'a_id';
update organization_licenses set access_paid_through = now() - interval '2 days' where organization_id = :'a_id';
select t.as_user('12500000-0000-0000-0000-000000000001');
select t.eq_text(my_org_access(:'a_id') -> 'access' ->> 'state', 'expired', 'a trial row cannot re-open a company whose subscription lapsed');
select t.eq((select count(*) from customers), 0, 'closed');
select t.as_owner();
select t.ok(billing_access_state(:'a_id', now()) ->> 'trial_ends_at' is null, 'and the trial is not even reported once there is a license');
update organization_licenses set access_paid_through = now() + interval '30 days' where organization_id = :'a_id';

-- ============================================================
-- 7. The back office numbers
-- ============================================================
update organization_trials set ends_at = now() + interval '3 days' where organization_id = :'c_id';
select t.eq_text(admin_trial_stats() ->> 'active', '1', 'one company in a running trial (A has a license now)');
update organization_trials set ends_at = now() - interval '1 day', started_at = now() - interval '8 days' where organization_id = :'c_id';
select t.eq_text(admin_trial_stats() ->> 'expired', '1', 'one company whose trial ended without paying');
select admin_unpaid_company_count(array[]::uuid[], array[]::text[]) as unpaid_with_expired \gset
update organization_trials set ends_at = now() + interval '3 days' where organization_id = :'c_id';
select admin_unpaid_company_count(array[]::uuid[], array[]::text[]) as unpaid_with_running \gset
select t.eq((:'unpaid_with_expired')::numeric - (:'unpaid_with_running')::numeric, 1, 'a company in a running trial is not counted as waiting to pay (an ended one is)');
select t.ok((select (o ->> 'trial_ends_at') is not null from jsonb_array_elements(admin_companies_overview('', 50, 0) -> 'rows') o where o ->> 'id' = :'c_id'), 'the companies list carries the trial end');
select t.eq_text((select o ->> 'access_state' from jsonb_array_elements(admin_companies_overview('', 50, 0) -> 'rows') o where o ->> 'id' = :'c_id'), 'trial', 'and the state');

-- ============================================================
-- 8. Hosting & maintenance = 0
-- ============================================================
insert into organization_licenses (organization_id, package_key, payment_option, entitlements, access_paid_through)
values (:'d_id', 'one_time', 'one_time', '{"modules":["customers"],"max_members":null,"max_warehouses":null}', now() - interval '3 days');   -- licence bought, hosting lapsed beyond the grace
insert into customers (organization_id, name) values (:'d_id', 'عميل د');
select t.ok(not billing_hosting_free(), 'with no saved price the hosting is not free');
select t.eq_text(billing_access_state(:'d_id', now()) ->> 'state', 'expired', 'a lapsed hosting payment closes the company');
select t.as_user('12500000-0000-0000-0000-000000000005');
select t.eq((select count(*) from customers), 0, 'and the data is hidden');
select t.as_owner();

insert into platform_pricing_config (id, config) values (1, '{"packages":{"one_time":{"pricing":{"licenseEgp":24000,"hostingMonthlyEgp":750}}}}');
select t.ok(not billing_hosting_free(), 'a saved hosting price above zero is not free');
update platform_pricing_config set config = '{"packages":{"one_time":{"pricing":{"licenseEgp":24000,"hostingMonthlyEgp":0}}}}' where id = 1;
select t.ok(billing_hosting_free(), 'a saved hosting price of 0 is free');
select t.eq_text(billing_access_state(:'d_id', now()) ->> 'state', 'license_only', 'the licence owner is open without any hosting payment');
select t.eq_text(billing_access_state(:'d_id', now()) ->> 'hosting_free', 'true', 'and the state says why');
select t.as_user('12500000-0000-0000-0000-000000000005');
select t.eq((select count(*) from customers), 1, 'the company sees its data');
select t.eq_text(my_org_access(:'d_id') -> 'access' ->> 'open', 'true', 'the dashboard opens');
select t.as_owner();

-- it only concerns the perpetual-licence plan
update organization_licenses set package_key = 'monthly', payment_option = 'monthly' where organization_id = :'d_id';
select t.eq_text(billing_access_state(:'d_id', now()) ->> 'state', 'expired', 'a monthly subscription still has to be paid whatever the hosting price is');
update organization_licenses set package_key = 'one_time', payment_option = 'one_time' where organization_id = :'d_id';

-- a malformed saved value never opens anything
update platform_pricing_config set config = '{"packages":{"one_time":{"pricing":{"hostingMonthlyEgp":"0; drop table x"}}}}' where id = 1;
select t.ok(not billing_hosting_free(), 'a malformed saved price is not free');
update platform_pricing_config set config = '{"packages":{"one_time":{"pricing":{}}}}' where id = 1;
select t.ok(not billing_hosting_free(), 'a missing saved price is not free');

-- the price goes back above zero: the end date applies again
update platform_pricing_config set config = '{"packages":{"one_time":{"pricing":{"licenseEgp":24000,"hostingMonthlyEgp":0}}}}' where id = 1;
select t.eq_text(billing_access_state(:'d_id', now()) ->> 'state', 'license_only', 'free again');
update platform_pricing_config set config = '{"packages":{"one_time":{"pricing":{"licenseEgp":24000,"hostingMonthlyEgp":500}}}}' where id = 1;
select t.eq_text(billing_access_state(:'d_id', now()) ->> 'state', 'expired', 'a price above zero brings the old rule back for a company that still has an end date');

-- a licence bought while hosting was free carries no end date, and a licence-only payment is applied by the normal payment function
update platform_pricing_config set config = '{"packages":{"one_time":{"pricing":{"licenseEgp":24000,"hostingMonthlyEgp":0}}}}' where id = 1;
insert into billing_orders (organization_id, created_by, package_key, payment_option, purpose, status, amount_total, lines, entitlements, grants_months, xpay_session_id)
values (:'b_id', '12500000-0000-0000-0000-000000000003', 'one_time', 'one_time', 'initial', 'pending', 2400000, '[{"id":"license","label":"x","amount":2400000}]',
        '{"modules":["customers"],"max_members":null,"max_warehouses":null}', 0, 'sess_free_hosting')
returning id as ord \gset
set role service_role;
select billing_apply_payment(:'ord', 'sess_free_hosting', 'pi_free_hosting', 2400000, 'EGP') as applied \gset
reset role;
select t.eq_text((:'applied'::jsonb) ->> 'result', 'applied', 'a licence-only order is applied');
select t.ok((select access_paid_through is null from organization_licenses where organization_id = :'b_id'), 'the new licence has no end date');
select t.eq_text(billing_access_state(:'b_id', now()) ->> 'state', 'license_only', 'and the company is open');
update platform_pricing_config set config = '{"packages":{"one_time":{"pricing":{"licenseEgp":24000,"hostingMonthlyEgp":750}}}}' where id = 1;
select t.eq_text(billing_access_state(:'b_id', now()) ->> 'state', 'license_only', 'a company that bought while hosting was free keeps that, whatever the price becomes');

-- ============================================================
-- housekeeping
-- ============================================================
delete from platform_pricing_config where id = 1;
update platform_billing_settings set gate_enforced = false, grace_enabled = true, grace_hours = 24, trial_enabled = true, trial_days = 15;

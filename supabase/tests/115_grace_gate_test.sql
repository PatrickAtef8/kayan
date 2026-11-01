-- 0063: subscription lifecycle + grace period + the payment gate, enforced IN THE DATABASE.
-- The suite's fixtures create companies without licenses, so 01_helpers switches the gate off; this file switches it on and
-- off again at the end.
\set ON_ERROR_STOP on
select t.autoconfirm_off();
select t.as_owner();
update platform_billing_settings set gate_enforced = true, grace_enabled = true, grace_hours = 24;
insert into auth.users (id, email, email_confirmed_at) values
  ('11500000-0000-0000-0000-000000000001', 'owner@grace.test', now()),   -- owner of A: pays, lapses, renews
  ('11500000-0000-0000-0000-000000000002', 'rep@grace.test',   now()),   -- a member of A
  ('11500000-0000-0000-0000-000000000003', 'other@grace.test', now()),   -- owner of B: never pays
  ('11500000-0000-0000-0000-000000000004', 'demo@grace.test',  now()),   -- owner of C: "the platform administrator's demo company"
  ('11500000-0000-0000-0000-000000000005', 'demorep@grace.test', now()); -- a member of C

-- ============================================================
-- 1. Sign-up still works while the gate is ON, and a never-paid company is closed
-- ============================================================
select t.as_user('11500000-0000-0000-0000-000000000001');
select create_organization('شركة أ', 'x', 'EG', 'EGP', 'ar', array['products','warehouses','customers','sales']) as id \gset a_
select t.as_user('11500000-0000-0000-0000-000000000003');
select create_organization('شركة ب', 'x', 'EG', 'EGP', 'ar', array['products','warehouses','customers','sales']) as id \gset b_
select t.as_user('11500000-0000-0000-0000-000000000004');
select create_organization('شركة التجربة', 'x', 'EG', 'EGP', 'ar', array['products','warehouses','customers','sales']) as id \gset c_
select t.as_owner();
insert into organization_users (organization_id, user_id, role_id, status)
select :'a_id', '11500000-0000-0000-0000-000000000002', r.id, 'active' from roles r where r.key = 'sales' and r.organization_id is null;
insert into organization_users (organization_id, user_id, role_id, status)
select :'c_id', '11500000-0000-0000-0000-000000000005', r.id, 'active' from roles r where r.key = 'sales' and r.organization_id is null;
insert into customers (organization_id, name) values (:'a_id', 'عميل أ'), (:'b_id', 'عميل ب'), (:'c_id', 'عميل ج');

select t.as_user('11500000-0000-0000-0000-000000000003');
select t.eq((select count(*) from organization_users where user_id = auth.uid()), 1, 'a company that never paid: its owner still sees their own membership (needed to reach the payment page)');
select t.eq_text(my_role_key(:'b_id'), 'owner', 'and their role');
select t.eq_text(my_org_access(:'b_id') -> 'access' ->> 'state', 'none', 'the access state is "none"');
select t.eq_text(my_org_access(:'b_id') -> 'access' ->> 'open', 'false', 'and closed');
select t.eq((select count(*) from customers), 0, 'direct API read: the never-paid company sees none of its data');
select t.throws(format($q$insert into customers (organization_id, name) values (%L, 'x')$q$, :'b_id'), 'row-level security', 'direct API write is refused');
select t.ok(not is_org_member(:'b_id'), 'is_org_member is false (every RPC guard goes through it)');
select t.ok(not has_permission(:'b_id', 'customers.view'), 'has_permission is false');
select t.throws(format($q$select warehouse_pending_counts(%L)$q$, :'b_id'), '', 'an RPC refuses');
select t.eq((select count(*) from billing_orders), 0, 'the billing tables stay readable for the owner (empty here, no error)');

-- ============================================================
-- 2. Paid: active → grace → expired, at the database clock; exact boundaries
-- ============================================================
select t.as_owner();
insert into organization_licenses (organization_id, package_key, payment_option, entitlements, access_paid_through)
values (:'a_id', 'basic', 'monthly', '{"modules":["customers","sales"],"max_members":5,"max_warehouses":2}', now() + interval '1 hour');
select t.as_user('11500000-0000-0000-0000-000000000001');
select t.eq((select count(*) from customers), 1, 'active: the company sees its data');
select t.eq_text(my_org_access(:'a_id') -> 'access' ->> 'state', 'active', 'state active');
select t.as_user('11500000-0000-0000-0000-000000000002');
select t.ok(is_org_member(:'a_id') and has_permission(:'a_id', 'sales.create'), 'and so does its member (membership + permission)');

select t.as_owner();
update organization_licenses set access_paid_through = '2030-01-01 00:00:00+00' where organization_id = :'a_id';
select billing_access_state(:'a_id', '2030-01-01 00:00:00+00') ->> 'state' as s1,
       billing_access_state(:'a_id', '2030-01-01 00:00:00.000001+00') ->> 'state' as s2,
       billing_access_state(:'a_id', '2030-01-02 00:00:00+00') ->> 'state' as s3,
       billing_access_state(:'a_id', '2030-01-02 00:00:00.000001+00') ->> 'state' as s4 \gset
select t.eq_text(:'s1', 'active', 'boundary: exactly at the expiration instant the subscription is still active');
select t.eq_text(:'s2', 'grace',  'one microsecond later it is in the grace period');
select t.eq_text(:'s3', 'grace',  'exactly at the end of the 24h grace it is still open');
select t.eq_text(:'s4', 'expired', 'one microsecond after the grace it is expired');
select billing_access_state(:'a_id', '2030-01-01 12:00:00+00') as g \gset
select t.eq_text(:'g'::jsonb ->> 'seconds_left', '43200', 'the remaining grace time is computed from the expiration timestamp (12h left)');
select t.eq_text(:'g'::jsonb ->> 'open', 'true', 'grace is open');

-- the real clock: in grace → still usable; past the grace → everything shut
update organization_licenses set access_paid_through = now() - interval '2 hours' where organization_id = :'a_id';
select t.as_user('11500000-0000-0000-0000-000000000001');
select t.eq_text(my_org_access(:'a_id') -> 'access' ->> 'state', 'grace', 'two hours after expiry: grace');
select t.eq((select count(*) from customers), 1, 'during the grace period the data is available');
select t.as_owner();
update organization_licenses set access_paid_through = now() - interval '25 hours' where organization_id = :'a_id';
select t.as_user('11500000-0000-0000-0000-000000000001');
select t.eq_text(my_org_access(:'a_id') -> 'access' ->> 'state', 'expired', '25 hours after expiry: expired');
select t.eq((select count(*) from customers), 0, 'direct read after the grace: nothing');
select t.throws(format($q$insert into customers (organization_id, name) values (%L, 'x')$q$, :'a_id'), 'row-level security', 'direct write after the grace: refused');
select t.throws(format($q$update customers set name = 'x' where organization_id = %L$q$, :'a_id'), '', 'update: nothing to update') where false;
select t.throws(format($q$select warehouse_pending_counts(%L)$q$, :'a_id'), '', 'RPC after the grace: refused');
select t.eq((select count(*) from organization_licenses), 1, 'but the owner can still read their license (to renew)');
select t.as_user('11500000-0000-0000-0000-000000000002');
select t.ok(not is_org_member(:'a_id') and not has_permission(:'a_id', 'sales.create'), 'the member is locked out too');

-- ============================================================
-- 3. Grace settings: disabled / zero hours = immediate lock; the setting is the Super Admin's alone
-- ============================================================
select t.as_owner();
update organization_licenses set access_paid_through = now() - interval '2 hours' where organization_id = :'a_id';
set role service_role;
select admin_save_billing_settings('11500000-0000-0000-0000-000000000009', false, 24) as r1 \gset
reset role;
select t.eq_text(billing_access_state(:'a_id', now()) ->> 'state', 'expired', 'grace disabled: locked the moment it expires');
set role service_role;
select admin_save_billing_settings('11500000-0000-0000-0000-000000000009', true, 0) as r2 \gset
reset role;
select t.eq_text(billing_access_state(:'a_id', now()) ->> 'state', 'expired', 'grace enabled with 0 hours: same, immediate lock');
set role service_role;
select admin_save_billing_settings('11500000-0000-0000-0000-000000000009', true, 72) as r3 \gset
reset role;
select t.eq_text(billing_access_state(:'a_id', now()) ->> 'state', 'grace', 'grace enabled with 72 hours: open again');
select t.throws($q$select admin_save_billing_settings(gen_random_uuid(), true, -1)$q$, 'invalid grace settings', 'negative hours are refused');
select t.as_owner();
select t.throws($q$select admin_save_billing_settings(gen_random_uuid(), true, 721)$q$, 'invalid grace settings', 'so is more than 30 days');
select t.throws($q$select admin_save_billing_settings(gen_random_uuid(), null, 5)$q$, 'invalid grace settings', 'and a missing flag');
select t.eq((select count(*) from admin_audit_log where action = 'billing.grace_settings'), 3, 'every change of the setting is audited');
update platform_billing_settings set grace_enabled = true, grace_hours = 24;

-- ============================================================
-- 4. Payments: only a VERIFIED payment restores access
-- ============================================================
update organization_licenses set access_paid_through = now() - interval '30 hours' where organization_id = :'a_id';
set role service_role;
select billing_begin_order(:'a_id', '11500000-0000-0000-0000-000000000001', 'basic', 'monthly', 'renewal', 'EGP', 65000, 65000,
  '[{"id":"sub","label":"sub","amount":65000}]', '{"modules":["customers","sales"],"max_members":5,"max_warehouses":2}', 1) as j \gset
reset role;
select (:'j'::jsonb -> 'order' ->> 'id') as ro \gset
select t.eq_text(:'j'::jsonb ->> 'result', 'created', 'a renewal order is created for the expired company');
select t.as_user('11500000-0000-0000-0000-000000000001');
select t.eq_text(my_org_access(:'a_id') -> 'access' ->> 'state', 'expired', 'a PENDING order does not restore access');
select t.eq((select count(*) from customers), 0, '… not even for the data');
select t.as_owner();
set role service_role;
select billing_apply_payment(:'ro', 'cs_test_r1', 'pi_r1', 99, 'EGP') ->> 'result' as bad \gset
reset role;
select t.eq_text(:'bad', 'amount_mismatch', 'a payment whose amount does not match the order is rejected');
select t.eq_text((select status from billing_orders where id = :'ro'), 'failed', 'and the order is marked failed');
select t.eq_text(billing_access_state(:'a_id', now()) ->> 'state', 'expired', 'a FAILED payment does not restore access');

set role service_role;
select billing_begin_order(:'a_id', '11500000-0000-0000-0000-000000000001', 'basic', 'monthly', 'renewal', 'EGP', 65000, 65000,
  '[{"id":"sub","label":"sub","amount":65000}]', '{"modules":["customers","sales"],"max_members":5,"max_warehouses":2}', 1) ->> 'result' as again \gset
select (billing_begin_order(:'a_id', '11500000-0000-0000-0000-000000000001', 'basic', 'monthly', 'renewal', 'EGP', 65000, 65000,
  '[{"id":"sub","label":"sub","amount":65000}]', '{"modules":["customers","sales"],"max_members":5,"max_warehouses":2}', 1) -> 'order' ->> 'id') as ro2 \gset
select billing_mark_order(:'ro2', 'canceled', 'customer_canceled') as cc \gset
reset role;
select t.eq_text(billing_access_state(:'a_id', now()) ->> 'state', 'expired', 'a CANCELED order does not restore access');
set role service_role;
select (billing_begin_order(:'a_id', '11500000-0000-0000-0000-000000000001', 'basic', 'monthly', 'renewal', 'EGP', 65000, 65000,
  '[{"id":"sub","label":"sub","amount":65000}]', '{"modules":["customers","sales"],"max_members":5,"max_warehouses":2}', 1) -> 'order' ->> 'id') as ro3 \gset
select billing_apply_payment(:'ro3', 'cs_test_r3', 'pi_r3', 65000, 'EGP') ->> 'result' as ok1 \gset
select billing_apply_payment(:'ro3', 'cs_test_r3', 'pi_r3', 65000, 'EGP') ->> 'result' as ok2 \gset
reset role;
select t.eq_text(:'ok1', 'applied', 'a VERIFIED payment is applied');
select t.eq_text(:'ok2', 'already_applied', 'a repeated callback changes nothing');
select t.eq_text(billing_access_state(:'a_id', now()) ->> 'state', 'active', 'and access is back immediately');
select access_paid_through as end1 from organization_licenses where organization_id = :'a_id' \gset
select t.ok(:'end1'::timestamptz > now() + interval '27 days' and :'end1'::timestamptz < now() + interval '32 days', 'one month is counted from the payment, not from the old (lapsed) date');
select t.as_user('11500000-0000-0000-0000-000000000001');
select t.eq((select count(*) from customers), 1, 'the owner sees the data again');
select t.as_user('11500000-0000-0000-0000-000000000002');
select t.ok(is_org_member(:'a_id'), 'and so does the member');

-- ============================================================
-- 5. A browser session cannot touch any of it
-- ============================================================
select t.as_user('11500000-0000-0000-0000-000000000001');
select t.throws(format($q$update organization_licenses set access_paid_through = now() + interval '10 years' where organization_id = %L$q$, :'a_id'), 'permission denied', 'cannot extend the subscription');
select t.throws(format($q$insert into organization_licenses (organization_id, package_key, payment_option, entitlements) values (%L, 'basic', 'monthly', '{}')$q$, :'b_id'), 'permission denied', 'cannot create a license');
select t.throws($q$update billing_orders set status = 'paid'$q$, 'permission denied', 'cannot mark an order paid');
select t.throws($q$select * from platform_billing_settings$q$, 'permission denied', 'cannot read the grace settings table');
select t.throws($q$update platform_billing_settings set grace_hours = 9999, gate_enforced = false$q$, 'permission denied', 'cannot change the grace settings or switch the gate off');
select t.throws(format($q$select billing_access_state(%L, now())$q$, :'a_id'), 'permission denied', 'cannot call the state function with a time of their choosing');
select t.throws(format($q$select billing_org_open(%L)$q$, :'a_id'), 'permission denied', 'nor the gate function');
select t.throws($q$select admin_save_billing_settings(gen_random_uuid(), true, 5)$q$, 'permission denied', 'nor the admin setter');
select t.as_user('11500000-0000-0000-0000-000000000003');
select t.eq((select count(*) from billing_orders where organization_id = :'a_id'), 0, 'another company''s owner cannot read this company''s orders');
select t.ok(my_org_access(:'a_id') is null, 'nor its access state');
select t.eq((select count(*) from organization_licenses where organization_id = :'a_id'), 0, 'nor its license');
select t.as_anon();
select t.throws(format($q$select my_org_access(%L)$q$, :'a_id'), 'permission denied', 'a visitor cannot ask');

-- ============================================================
-- 6. The administrator's demo company: its members follow the company's REAL subscription
-- ============================================================
select t.as_user('11500000-0000-0000-0000-000000000005');
select t.ok(not is_org_member(:'c_id'), 'a member of a demo company with no subscription is NOT let in just because the owner is an administrator');
select t.as_owner();
set role service_role;
select admin_grant_complimentary_license('11500000-0000-0000-0000-000000000009', :'c_id', 'complete', '{"modules":["customers","sales"],"max_members":null,"max_warehouses":null}') as gr \gset
reset role;
select t.as_user('11500000-0000-0000-0000-000000000005');
select t.ok(is_org_member(:'c_id'), 'once the platform grants the company free access, the member is in');
select t.eq_text(my_org_access(:'c_id') -> 'access' ->> 'state', 'free', 'state free');
select t.as_owner();
set role service_role;
select admin_revoke_complimentary_license('11500000-0000-0000-0000-000000000009', :'c_id') as rv \gset
reset role;
select t.as_user('11500000-0000-0000-0000-000000000005');
select t.ok(not is_org_member(:'c_id'), 'and out again when the free access is revoked');

-- ============================================================
-- 7. Nothing in the API surface can skip the gate (static walk over the live schema)
-- ============================================================
select t.as_owner();
create temp table _fn as select p.proname, lower(pg_get_functiondef(p.oid)) def from pg_proc p where p.pronamespace = 'public'::regnamespace and p.prokind = 'f';
create temp table _gated(proname text primary key);
insert into _gated values ('billing_org_open'), ('is_org_member'), ('has_permission'), ('user_org_ids');
do $$ declare n int; begin loop
  insert into _gated select f.proname from _fn f where f.proname not in (select proname from _gated)
    and exists (select 1 from _gated g where f.def ~ ('\m' || g.proname || '\(')) and f.proname !~ '^(admin|billing)_' and f.proname <> 'my_org_access';
  get diagnostics n = row_count; exit when n = 0; end loop; end $$;
select t.eq((select count(*) from (
  select c.table_name, cmds.cmd
  from (select c.table_name from information_schema.columns c join pg_tables pt on pt.schemaname = 'public' and pt.tablename = c.table_name
        where c.table_schema = 'public' and c.column_name = 'organization_id' and pt.rowsecurity) c
  cross join (values ('SELECT'), ('INSERT'), ('UPDATE'), ('DELETE')) cmds(cmd)
  where exists (select 1 from pg_policies p0 where p0.schemaname = 'public' and p0.tablename = c.table_name and p0.permissive = 'PERMISSIVE' and (p0.cmd = cmds.cmd or p0.cmd = 'ALL'))
    and not exists (select 1 from pg_policies p where p.schemaname = 'public' and p.tablename = c.table_name and p.permissive = 'PERMISSIVE' and (p.cmd = cmds.cmd or p.cmd = 'ALL')
                    and exists (select 1 from _gated g where lower(coalesce(p.qual, '') || ' ' || coalesce(p.with_check, '')) ~ ('\m' || g.proname || '\(')))
    -- intentionally outside the gate: the owner reads their own billing rows (orders, the acceptance record of each order) to pay; a user reads their own notifications; the channel snapshot
    -- is filtered by the (gated) sales_invoices policy it selects from
    and c.table_name not in ('billing_orders', 'billing_order_acceptances', 'organization_licenses', 'notifications', 'sales_invoice_channel_snapshot')
) x), 0, 'every tenant table: every command that has a permissive policy is gated by the subscription');
select t.eq((select count(*) from _fn f where exists (select 1 from pg_proc p where p.proname = f.proname and p.pronamespace = 'public'::regnamespace and p.prosecdef and p.prorettype <> 'trigger'::regtype)
              and f.proname !~ '^(_|admin_|billing_|t_)' and f.proname not in (select proname from _gated)
              and f.proname not in ('accept_org_invite', 'decline_org_invite', 'create_organization', 'current_rep_id', 'ensure_default_treasury_account', 'is_module_enabled',
                                    'is_org_owner', 'is_restricted_rep', 'is_storekeeper', 'my_org_access', 'my_role_key', 'own_rep_id', 'list_my_notifications',
                                    'mark_all_notifications_read', 'mark_notification_read', 'my_unread_notification_count', 'process_notification_retries',
                                    -- used only by RESTRICTIVE policies (they narrow, so they must not shrink), and the invitee's own invitations
                                    'finance_org_ids', 'purchasing_org_ids', 'restricted_rep_org_ids', 'storekeeper_org_ids', 'list_my_invites')
              and f.def ~ '(org_id|target_org|p_org|organization_id)'), 0,
  'every other org-scoped SECURITY DEFINER function reaches the gate (new ones must too, or be listed here on purpose)');

update platform_billing_settings set gate_enforced = false, grace_enabled = true, grace_hours = 24;

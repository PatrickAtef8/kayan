-- 0049: member names + notifications for everything the owner does to a rep / storekeeper / team member.
\set ON_ERROR_STOP on
select t.autoconfirm_off();

select t.as_owner();
insert into auth.users (id, email) values
  ('10500000-0000-0000-0000-000000000001', 'owner1@nm.test'),
  ('10500000-0000-0000-0000-000000000002', 'owner2@nm.test'),
  ('10500000-0000-0000-0000-000000000003', 'keeper@nm.test'),
  ('10500000-0000-0000-0000-000000000005', 'rep1@nm.test'),
  ('10500000-0000-0000-0000-000000000006', 'rep2@nm.test'),
  ('10500000-0000-0000-0000-000000000008', 'invitee@nm.test');

select t.as_user('10500000-0000-0000-0000-000000000001');
select create_organization('شركة الأسماء', 'x', 'EG', 'EGP', 'ar',
  array['products','warehouses','customers','suppliers','sales','purchases','inventory','representatives','treasury','reports']) as id \gset org_
select t.as_owner();
insert into organization_users (organization_id, user_id, role_id, status, display_name)
select :'org_id', u.id, r.id, 'active', u.nm
from (values ('10500000-0000-0000-0000-000000000002'::uuid, 'owner', 'المالك الثاني'), ('10500000-0000-0000-0000-000000000003', 'warehouse', 'سعيد أمين المخزن'),
             ('10500000-0000-0000-0000-000000000005', 'sales', 'أحمد المندوب'), ('10500000-0000-0000-0000-000000000006', 'sales', null)) u(id, k, nm)
join roles r on r.key = u.k and r.organization_id is null;
update organization_users set display_name = 'المالك الأول' where organization_id = :'org_id' and user_id = '10500000-0000-0000-0000-000000000001';
delete from notifications;

create or replace function t.n5(p_user text, p_type text) returns bigint language sql as $$
  select count(*) from notifications where recipient_user_id = ('10500000-0000-0000-0000-00000000000' || p_user)::uuid and type = p_type
$$;
grant execute on function t.n5(text, text) to authenticated;

select t.as_user('10500000-0000-0000-0000-000000000001');
insert into sales_representatives (organization_id, name, user_id) values (:'org_id', 'مندوب ١', '10500000-0000-0000-0000-000000000005') returning id as rep1 \gset
insert into sales_representatives (organization_id, name, user_id) values (:'org_id', 'مندوب ٢', '10500000-0000-0000-0000-000000000006') returning id as rep2 \gset
insert into sales_representatives (organization_id, name) values (:'org_id', 'مندوب بلا حساب') returning id as rep3 \gset
insert into customers (organization_id, name) values (:'org_id', 'عميل جديد') returning id as c1 \gset
select t.as_owner();
select t.eq(t.n5('5', 'rep_record_update'), 1, 'creating a rep record linked to a login tells that rep');
select t.eq(t.n5('2', 'team_activity'), 2, 'the other owner hears about both linked rep records (not the owner who did it)');
select t.eq(t.n5('1', 'team_activity'), 0, 'the acting owner is not told about his own action');
delete from notifications;

-- ============================================================
-- 1. the bug: owner assigns a customer to a rep -> the rep is told, with names
-- ============================================================
select t.as_user('10500000-0000-0000-0000-000000000001');
update customers set sales_rep_id = :'rep1' where id = :'c1';
select t.as_owner();
select t.eq(t.n5('5', 'rep_customer_assigned'), 1, 'the rep is notified when the owner assigns him a customer');
select t.eq_text((select payload->>'by' from notifications where type = 'rep_customer_assigned'), 'المالك الأول (owner1@nm.test)', 'the owner is shown as name (email)');
select t.eq_text((select title from notifications where type = 'rep_customer_assigned'), 'تم تعيين العميل عميل جديد لك', 'title names the customer');
select t.eq(t.n5('6', 'rep_customer_assigned'), 0, 'another rep is not told');
select t.eq(t.n5('3', 'rep_customer_assigned'), 0, 'the storekeeper is not told');
select t.eq(t.n5('2', 'assignment_made'), 1, 'the other owner is told');
select t.eq(t.n5('1', 'assignment_made'), 0, 'the acting owner is not');
select t.eq_text((select payload->>'rep' from notifications where type = 'assignment_made'), 'أحمد المندوب (rep1@nm.test)', 'the other owner sees the rep as name (email) — the user name wins over the record name');

-- reassign to rep 2: rep 2 told, rep 1 told he lost the customer (without learning who got it)
delete from notifications;
select t.as_user('10500000-0000-0000-0000-000000000001');
update customers set sales_rep_id = :'rep2' where id = :'c1';
select t.as_owner();
select t.eq(t.n5('6', 'rep_customer_assigned'), 1, 'new rep told');
select t.eq(t.n5('5', 'rep_customer_unassigned'), 1, 'old rep told that the customer was taken');
select t.ok((select not (payload ? 'old_rep') and not (payload ? 'new_rep') and payload->>'rep' like '%rep1@nm.test%' from notifications where type = 'rep_customer_unassigned'), 'the old rep is not told who took the customer');
select t.eq_text((select payload->>'rep' from notifications where type = 'rep_customer_assigned'), 'مندوب ٢ (rep2@nm.test)', 'a rep without a member name falls back to the record name + email');

-- same value again: nothing
delete from notifications;
select t.as_user('10500000-0000-0000-0000-000000000001');
update customers set sales_rep_id = :'rep2' where id = :'c1';
update customers set name = 'عميل جديد' where id = :'c1';
select t.as_owner();
select t.eq((select count(*) from notifications), 0, 'an unchanged assignment (or an unrelated edit) notifies nobody');

-- editing the customer's data: the assigned rep is told which fields (no values)
delete from notifications;
select t.as_user('10500000-0000-0000-0000-000000000001');
update customers set sales_rep_id = :'rep2' where id = :'c1';
update customers set phone = '0100000000', price_tier = 'wholesale' where id = :'c1';
select t.as_owner();
select t.eq(t.n5('6', 'rep_customer_updated'), 1, 'the rep is told the customer''s data changed');
select t.ok((select payload->'fields' @> '["الهاتف"]'::jsonb and payload->'fields' @> '["شريحة السعر"]'::jsonb and not (payload::text like '%0100000000%') from notifications where type = 'rep_customer_updated'), 'which fields — and not the values');
select t.eq(t.n5('2', 'rep_customer_updated'), 0, 'owners do not get the rep-side card');
select t.as_user('10500000-0000-0000-0000-000000000001');
update customers set sales_rep_id = :'rep2' where id = :'c1';
select t.as_user('10500000-0000-0000-0000-000000000006');
update customers set name = 'عميل جديد' where id = :'c1';   -- the rep himself (if allowed) is never told about his own edit
select t.as_owner();
select t.eq(t.n5('6', 'rep_customer_updated'), 1, 'no card for the rep''s own action');
delete from notifications;

-- unassign
select t.as_user('10500000-0000-0000-0000-000000000001');
update customers set sales_rep_id = null where id = :'c1';
select t.as_owner();
select t.eq(t.n5('6', 'rep_customer_unassigned'), 1, 'removing the rep tells the rep');

-- a rep without a login: no one to tell, owners still hear if another owner did it
delete from notifications;
select t.as_user('10500000-0000-0000-0000-000000000002');
update customers set sales_rep_id = :'rep3' where id = :'c1';
select t.as_owner();
select t.eq(t.n5('1', 'assignment_made'), 1, 'owner 1 hears that owner 2 assigned a customer to a rep without a login');
select t.eq((select count(*) from notifications), 1, 'and nobody else (no login to tell)');

-- ============================================================
-- 2. rep record changes
-- ============================================================
delete from notifications;
select t.as_user('10500000-0000-0000-0000-000000000001');
update sales_representatives set commission_rate = 7 where id = :'rep1';
update sales_representatives set is_active = false where id = :'rep1';
update sales_representatives set is_active = true where id = :'rep1';
select t.as_owner();
select t.eq(t.n5('5', 'rep_record_update'), 3, 'terms change + deactivate + activate each tell the rep');
select t.ok((select not (payload::text ~ '7') from notifications where type = 'rep_record_update' and payload->>'action' = 'terms'), 'the terms notification carries no numbers');
select t.eq(t.n5('2', 'team_activity'), 3, 'the other owner hears of each');

-- unlink + link to another login (rep3 has none yet; rep2's login is taken, so unlink rep2 first)
delete from notifications;
select t.as_user('10500000-0000-0000-0000-000000000001');
update sales_representatives set user_id = null where id = :'rep2';
update sales_representatives set user_id = '10500000-0000-0000-0000-000000000006' where id = :'rep3';
select t.as_owner();
select t.eq(t.n5('6', 'rep_record_update'), 2, 'rep 2 login: told he was unlinked, then told he was linked to another record');
select t.eq((select count(*) from notifications where type = 'rep_record_update' and payload->>'action' = 'unlinked'), 1, 'one unlink card');

-- ============================================================
-- 3. invoice reassignment (a sale made by rep 1 for a customer, then moved)
-- ============================================================
select t.as_user('10500000-0000-0000-0000-000000000001');
insert into warehouses (organization_id, name) values (:'org_id', 'المخزن') returning id as w \gset
insert into products (organization_id, name, unit) values (:'org_id', 'صنف', 'قطعة') returning id as p \gset
insert into product_prices (organization_id, product_id, selling_price) values (:'org_id', :'p', 20);
insert into product_costs (product_id, cost) values (:'p', 8);
insert into suppliers (organization_id, name) values (:'org_id', 'مورد') returning id as s \gset
select t.as_owner();
select t.autoconfirm_on();
select t.as_user('10500000-0000-0000-0000-000000000001');
select create_purchase_invoice(:'org_id', :'s', :'w', 'OPEN', '2026-01-01',
  jsonb_build_array(jsonb_build_object('product_id', :'p', 'quantity', 100, 'unit_cost', 8, 'discount', 0)), 0, 0, 0, 'نقدًا', null) as id \gset open_
select t.as_owner();
select t.autoconfirm_off();
update customers set sales_rep_id = :'rep1' where id = :'c1';
select t.as_user('10500000-0000-0000-0000-000000000001');
select create_sales_invoice(:'org_id', :'c1', :'w', 'N-1', '2026-02-01',
  jsonb_build_array(jsonb_build_object('product_id', :'p', 'quantity', 5, 'unit_price', 20, 'discount', 0)), 0, 0, 0, 'نقدًا', null, :'rep1') as id \gset n1_
select t.as_owner();
select t.eq(t.n5('5', 'rep_invoice_assigned'), 0, 'creating an invoice for a rep does not ALSO send an "assigned" card (the invoice card covers it)');
select t.eq(t.n5('5', 'rep_invoice_created'), 1, 'the creation card exists');
delete from notifications;
select t.as_owner();   -- no app role may UPDATE sales_invoices directly; this is the admin / definer-function path (no acting user)
update sales_invoices set sales_rep_id = :'rep3' where id = :'n1_id';
select t.as_owner();
select t.eq(t.n5('6', 'rep_invoice_assigned'), 1, 'the new rep (rep3 -> login 6) is told the invoice is his');
select t.eq(t.n5('5', 'rep_invoice_unassigned'), 1, 'the old rep is told it left him');
select t.eq(t.n5('1', 'assignment_made') + t.n5('2', 'assignment_made'), 2, 'both owners are told (no acting user)');

-- ============================================================
-- 4. team: names on invitations, joining, role change, removal
-- ============================================================
delete from notifications;
select t.as_user('10500000-0000-0000-0000-000000000001');
select id as sales_role from roles where key = 'sales' and organization_id is null \gset
select id as wh_role from roles where key = 'warehouse' and organization_id is null \gset
select add_team_member(:'org_id', 'invitee@nm.test', :'sales_role', '  محمود الجديد  ') as j \gset inv_
select t.eq_text(:'inv_j'::jsonb ->> 'status', 'added', 'existing account: invited');
select t.eq_text((select display_name from organization_users where organization_id = :'org_id' and user_id = '10500000-0000-0000-0000-000000000008'), 'محمود الجديد', 'the name is stored trimmed');
select t.eq_text((select display_name from list_org_members(:'org_id') where email = 'invitee@nm.test'), 'محمود الجديد', 'list_org_members returns it');
select t.as_owner();
select t.eq(t.n5('2', 'team_activity'), 1, 'the other owner hears of the invitation');
select t.eq_text((select payload->>'member' from notifications where type = 'team_activity'), 'محمود الجديد (invitee@nm.test)', 'with name + email');
delete from notifications;

select t.as_user('10500000-0000-0000-0000-000000000008');
select accept_org_invite(:'org_id');
select t.as_owner();
select t.eq(t.n5('1', 'team_activity'), 1, 'owner 1 hears that the invitee joined');
select t.eq(t.n5('2', 'team_activity'), 1, 'and owner 2');
select t.eq_text((select payload->>'by' from notifications where recipient_user_id = '10500000-0000-0000-0000-000000000001'), 'محمود الجديد (invitee@nm.test)', 'by = the joiner, name + email');
delete from notifications;

-- role change: the member is told, the other owner is told
select t.as_user('10500000-0000-0000-0000-000000000001');
update organization_users set role_id = :'wh_role' where organization_id = :'org_id' and user_id = '10500000-0000-0000-0000-000000000008';
select t.as_owner();
select t.eq(t.n5('8', 'role_changed'), 1, 'the member is told his role changed');
select t.ok((select title like '%أمين مخزن%' from notifications where type = 'role_changed'), 'with the new role name');
select t.eq(t.n5('2', 'team_activity'), 1, 'the other owner is told');
select t.eq(t.n5('1', 'team_activity'), 0, 'the acting owner is not');
select t.as_user('10500000-0000-0000-0000-000000000008');
select t.eq((select count(*) from list_my_notifications(:'org_id')), 1, 'the member can read the role_changed card under his new role');
select t.as_user('10500000-0000-0000-0000-000000000003');
select t.eq((select count(*) from list_my_notifications(:'org_id') where type in ('role_changed','team_activity','assignment_made')), 0, 'another storekeeper cannot read other people''s cards');

-- rename via update_member_name
select t.as_user('10500000-0000-0000-0000-000000000001');
select update_member_name(:'org_id', '10500000-0000-0000-0000-000000000006', 'خالد المندوب');
select t.eq_text((select display_name from organization_users where user_id = '10500000-0000-0000-0000-000000000006'), 'خالد المندوب', 'update_member_name works for owners');
select t.as_user('10500000-0000-0000-0000-000000000005');
select t.throws(format('select update_member_name(%L, %L, %L)', :'org_id', '10500000-0000-0000-0000-000000000006', 'x'), 'صلاحية', 'a rep cannot rename members');
select t.throws(format('select * from list_org_members(%L)', :'org_id'), 'صلاحية', 'a rep cannot list members (names/emails)');

-- removal: other owner told, the removed one cannot read anything any more
select t.as_owner();
delete from notifications;
select t.as_user('10500000-0000-0000-0000-000000000001');
delete from organization_users where organization_id = :'org_id' and user_id = '10500000-0000-0000-0000-000000000008';
select t.as_owner();
select t.eq(t.n5('2', 'team_activity'), 1, 'the other owner hears the removal');
select t.ok((select title like '%محمود الجديد%' from notifications where type = 'team_activity'), 'with the removed person''s name');

-- declined invitation
delete from notifications;
select t.as_user('10500000-0000-0000-0000-000000000001');
select add_team_member(:'org_id', 'invitee@nm.test', :'sales_role', 'محمود') as j \gset inv2_
select t.as_user('10500000-0000-0000-0000-000000000008');
select decline_org_invite(:'org_id');
select t.as_owner();
select t.eq((select count(*) from notifications where payload->>'action' = 'declined' and recipient_user_id = '10500000-0000-0000-0000-000000000001'), 1, 'owner 1 hears that the invitee declined');

-- ============================================================
-- 5. storekeeper: a return cancels what he was asked to dispatch
-- ============================================================
delete from notifications;
select t.as_user('10500000-0000-0000-0000-000000000001');
select create_sales_invoice(:'org_id', :'c1', :'w', 'N-2', '2026-02-05',
  jsonb_build_array(jsonb_build_object('product_id', :'p', 'quantity', 4, 'unit_price', 20, 'discount', 0)), 0, 0, 0, 'نقدًا', null, :'rep1') as id \gset n2_
select t.as_user('10500000-0000-0000-0000-000000000002');
select create_sales_return(:'org_id', :'n2_id', '2026-02-06', '[]'::jsonb, 0, null, true, 'resalable') as id \gset nr_
select t.as_owner();
select t.eq(t.n5('3', 'warehouse_task_cancelled'), 1, 'the storekeeper is told a return cancelled goods he was asked to dispatch');
select t.ok((select (payload->'released'->0->>'qty')::numeric = 4 from notifications where type = 'warehouse_task_cancelled'), 'with the cancelled quantity');
select t.ok((select not (payload::text ~* '(price|total|amount|customer|rep)') from notifications where type = 'warehouse_task_cancelled'), 'and no price, total, customer or rep');
select t.eq(t.n5('1', 'warehouse_task_cancelled'), 0, 'owners do not get the storekeeper card');
select t.as_user('10500000-0000-0000-0000-000000000005');
select t.eq((select count(*) from list_my_notifications(:'org_id') where type = 'warehouse_task_cancelled'), 0, 'a rep cannot read it');
select t.as_user('10500000-0000-0000-0000-000000000003');
select t.eq((select count(*) from list_my_notifications(:'org_id') where type in ('rep_customer_assigned','rep_record_update','assignment_made','team_activity')), 0, 'a storekeeper reads none of the rep / owner cards');

-- ============================================================
-- 6. isolation + reliability
-- ============================================================
select t.as_user('10500000-0000-0000-0000-000000000006');
select t.eq((select count(*) from list_my_notifications(:'org_id') where payload::text like '%rep1@nm.test%'), 0, 'a rep never sees another rep''s email in his cards');
select t.as_owner();
select t.eq((select count(*) from notification_failures where done_at is null and organization_id = :'org_id'), 0, 'no notification failed to build');
select t.eq((select count(*) from (select recipient_user_id, dedupe_key from notifications group by 1, 2 having count(*) > 1) d), 0, 'no duplicate notification');

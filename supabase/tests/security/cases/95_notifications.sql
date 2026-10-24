-- 0046: notifications are private to their recipient, follow the recipient's CURRENT role, never carry
-- money to the storekeeper, and can only be written by the database itself.  Everything goes through the
-- same entry points the REST API exposes (tables, RPCs), as each persona.
\set ON_ERROR_STOP on
select lab.as_owner() \gset
select * from lab.ctx \gset
select * from lab.u \gset

-- ---------------------------------------------------------------- data: the REP posts a sale (stock reserved, not moved)
select lab.as_owner() \gset
select lab.autoconfirm_off();
select lab.as_user(:'rep') \gset
select create_sales_invoice(org_id:=:'org_a', p_customer_id:=:'cust_a', p_warehouse_id:=:'wh_a', p_invoice_number:='NTF-1', p_invoice_date:=current_date,
  items:=jsonb_build_array(jsonb_build_object('product_id', :'prod_a', 'quantity', 3, 'unit_price', 100)), p_discount_pct:=0, p_tax_total:=0, p_amount_collected:=0,
  p_payment_method:='cash', p_notes:=null) as ntf_inv \gset
select lab.as_owner() \gset

-- ---------------------------------------------------------------- who sees what
select lab.as_user(:'owner_a') \gset
select lab.check('ntf', 'owner: gets the rep''s invoice notification (with the total)', (select count(*) from notifications where type = 'sales_invoice_created' and payload->>'invoice_number' = 'NTF-1' and (payload->>'total')::numeric = 300) = 1);
select lab.check('ntf', 'owner: the list function returns it too', (select count(*) from list_my_notifications(:'org_a') where type = 'sales_invoice_created' and payload->>'invoice_number' = 'NTF-1') = 1);

select lab.as_user(:'warehouse') \gset
select lab.check('ntf', 'storekeeper: sees only storekeeper-type notifications, and his task for the new sale', (select bool_and(type like 'warehouse%') from notifications) and (select count(*) from notifications where payload->>'invoice_number' = 'NTF-1') = 1);
select lab.check('ntf', 'storekeeper: the task has items and quantities', (select (payload->'lines'->0->>'remaining')::numeric = 3 from notifications where payload->>'invoice_number' = 'NTF-1'));
select lab.check('ntf', 'storekeeper: and no money, party or price anywhere in it',
  (select not (to_jsonb(n)::text ~* '(total|price|amount|balance|cost|discount|customer|عميل|300)') from notifications n where payload->>'invoice_number' = 'NTF-1'));
select lab.check('ntf', 'storekeeper: cannot read the owner''s money notification by id either', lab.val('select count(*) from notifications where type = ''sales_invoice_created''') = '0');

select lab.as_user(:'rep') \gset
select lab.check('ntf', 'rep: not notified about his own invoice', lab.val('select count(*) from notifications where payload->>''invoice_number'' = ''NTF-1''') = '0');
select lab.as_user(:'rep2') \gset
select lab.check('ntf', 'rep 2: sees nothing of rep 1''s business', lab.val('select count(*) from notifications where payload->>''invoice_number'' = ''NTF-1''') = '0');
select lab.as_user(:'plain') \gset
select lab.check('ntf', 'a sales user not linked to any rep: nothing', lab.val('select count(*) from notifications') = '0');
select lab.as_user(:'owner_b') \gset
select lab.check('ntf', 'another company''s owner: nothing', lab.val('select count(*) from notifications') = '0');
select lab.check('ntf', 'and the RPCs refuse the other company', lab.try(format('select * from list_my_notifications(%L)', :'org_a')) like 'denied%');
select lab.as_user(:'attacker') \gset
-- (0049: the attacker owns his OWN organization and rightly hears about its team events; what matters is org A)
select lab.check('ntf', 'an outsider: nothing of organization A', lab.val(format('select count(*) from notifications where organization_id = %L', :'org_a')) = '0');
select lab.check('ntf', 'an outsider: nor of organization A via the list function', lab.try(format('select * from list_my_notifications(%L)', :'org_a')) like 'denied%');
select lab.check('ntf', 'outsider: cannot count', lab.try(format('select my_unread_notification_count(%L)', :'org_a')) like 'denied%');
select lab.check('ntf', 'outsider: cannot mark all', lab.try(format('select mark_all_notifications_read(%L)', :'org_a')) like 'denied%');
select lab.as_anon() \gset
select lab.check('ntf', 'anonymous: no table access', lab.try('select * from notifications') like 'denied%');
select lab.check('ntf', 'anonymous: no RPC access', lab.try(format('select list_my_notifications(%L)', :'org_a')) like 'denied%');

-- ---------------------------------------------------------------- nobody writes except the database
select lab.as_user(:'owner_a') \gset
select lab.check('ntf', 'owner: no direct INSERT', lab.try(format('insert into notifications(organization_id, recipient_user_id, type, title, dedupe_key) values (%L, %L, ''customer_payment'', ''x'', ''k1'')', :'org_a', :'owner_a')) like 'denied%');
select lab.check('ntf', 'owner: no direct UPDATE', lab.try('update notifications set read_at = now()') like 'denied%');
select lab.check('ntf', 'owner: no direct DELETE', lab.try('delete from notifications') like 'denied%');
select lab.check('ntf', 'owner: cannot call the internal sender', lab.try(format('select _ntf_send(%L, %L, null, ''customer_payment'', ''x'', null, null, null, ''{}'', ''k2'')', :'org_a', :'owner_a')) like 'denied%');
select lab.check('ntf', 'owner: cannot call the internal refresh', lab.try(format('select _ntf_refresh_work(''sales'', %L, gen_random_uuid(), null)', :'org_a')) like 'denied%');
select lab.as_user(:'warehouse') \gset
select lab.check('ntf', 'storekeeper: no direct UPDATE (cannot fake "done" or "unread")', lab.try('update notifications set resolved_at = now(), read_at = null') like 'denied%');
select lab.as_user(:'rep') \gset
select lab.check('ntf', 'rep: cannot call the internal sender', lab.try(format('select _ntf_send(%L, %L, null, ''rep_payment'', ''x'', null, null, null, ''{}'', ''k3'')', :'org_a', :'rep')) like 'denied%');

-- ---------------------------------------------------------------- read state is per person
select lab.as_user(:'warehouse') \gset
select id as keeper_ntf from list_my_notifications(:'org_a') where payload->>'invoice_number' = 'NTF-1' \gset
select lab.as_user(:'owner_a') \gset
select id as owner_ntf from list_my_notifications(:'org_a') where payload->>'invoice_number' = 'NTF-1' and type = 'sales_invoice_created' \gset
select lab.as_user(:'warehouse') \gset
select my_unread_notification_count(:'org_a') as k_before \gset
select lab.check('ntf', 'storekeeper: marking the owner''s notification changes nothing for him', mark_notification_read(:'org_a', :'owner_ntf') = :k_before);
select lab.as_user(:'owner_a') \gset
select lab.check('ntf', '...the owner''s is still unread', (select read_at is null from list_my_notifications(:'org_a') where id = :'owner_ntf'));
select lab.as_user(:'warehouse') \gset
select lab.check('ntf', 'storekeeper: marks his own, the unread count drops by exactly one', mark_notification_read(:'org_a', :'keeper_ntf') = :k_before - 1);
select lab.check('ntf', 'reading the task does not complete it', (select resolved_at is null from list_my_notifications(:'org_a') where id = :'keeper_ntf'));
select lab.as_owner() \gset
select lab.check('ntf', 'nor does it dispatch anything', (select dispatch_status from sales_invoices where id = :'ntf_inv') = 'pending');

-- ---------------------------------------------------------------- a role change takes the old notifications away
select lab.as_owner() \gset
update organization_users set role_id = (select id from roles where key = 'warehouse' and organization_id is null) where organization_id = :'org_a' and user_id = :'accountant';
select lab.as_owner() \gset
select lab.check('ntf', 'the second owner has a copy of the money notification before the change', (select count(*) from notifications where recipient_user_id = :'accountant' and type = 'sales_invoice_created' and payload->>'invoice_number' = 'NTF-1') = 1);
select lab.as_user(:'accountant') \gset
select lab.check('ntf', 'after demotion to storekeeper he cannot read it', lab.val('select count(*) from notifications where type = ''sales_invoice_created''') = '0');
select lab.check('ntf', 'nor via the list function (only the 0049 "your role changed" card remains)', lab.val(format('select count(*) from list_my_notifications(%L) where type <> ''role_changed''', :'org_a')) = '0');
select lab.as_owner() \gset
update organization_users set role_id = (select id from roles where key = 'owner' and organization_id is null) where organization_id = :'org_a' and user_id = :'accountant';

-- ---------------------------------------------------------------- 0047: retry outbox
select lab.as_user(:'owner_a') \gset
select lab.check('ntf', 'owner: the failure log is not readable through the API', lab.try('select * from notification_failures') like 'denied%');
select lab.check('ntf', 'owner: nor the internal builders', lab.try(format('select _ntf_build_sales_invoice(%L)', :'ntf_inv')) like 'denied%');
select lab.check('ntf', 'owner: may run the retry for his own organization', lab.val(format('select process_notification_retries(%L) >= 0', :'org_a')) = 'true');
select lab.check('ntf', 'owner: not for another organization', lab.try(format('select process_notification_retries(%L)', :'org_b')) like 'denied%');
select lab.as_user(:'attacker') \gset
select lab.check('ntf', 'outsider: cannot run the retry', lab.try(format('select process_notification_retries(%L)', :'org_a')) like 'denied%');
select lab.as_anon() \gset
select lab.check('ntf', 'anonymous: cannot run the retry', lab.try(format('select process_notification_retries(%L)', :'org_a')) like 'denied%');
select lab.as_user(:'rep') \gset
select lab.check('ntf', 'rep: cannot read the failure log', lab.try('select * from notification_failures') like 'denied%');
select lab.check('ntf', 'rep: cannot call the backfill', lab.try('select _ntf_backfill_open_work()') like 'denied%');
select lab.as_owner() \gset

-- ---------------------------------------------------------------- 0049: names, assignments, team cards
select lab.as_user(:'rep') \gset
select lab.check('ntf', 'rep: cannot rename a member', lab.try(format('select update_member_name(%L, %L, %L)', :'org_a', :'rep2', 'x')) like 'denied%');
select lab.check('ntf', 'rep: cannot list members (emails)', lab.try(format('select * from list_org_members(%L)', :'org_a')) like 'denied%');
select lab.check('ntf', 'rep: cannot call the new internal builders', lab.try(format('select _ntf_build_customer_assign(%L, null, null, null, ''x'')', :'org_a')) like 'denied%');
select lab.check('ntf', 'rep: nor the label helpers (they read auth.users)', lab.try(format('select _ntf_person_label(%L, %L, null)', :'org_a', :'owner_a')) like 'denied%');
select lab.as_user(:'warehouse') \gset
select lab.check('ntf', 'storekeeper: cannot rename a member', lab.try(format('select update_member_name(%L, %L, %L)', :'org_a', :'rep2', 'x')) like 'denied%');
select lab.as_user(:'attacker') \gset
select lab.check('ntf', 'outsider: cannot rename a member of org A', lab.try(format('select update_member_name(%L, %L, %L)', :'org_a', :'rep2', 'x')) like 'denied%');
select lab.as_owner() \gset
-- an assignment card and a team card exist for the right people only, and the rep side never carries another rep
update customers set sales_rep_id = null where id = (select id from customers where organization_id = :'org_a' limit 1);
select lab.as_user(:'owner_a') \gset
select lab.val(format('select update_member_name(%L, %L, %L)', :'org_a', :'rep', 'مندوب الاختبار')) \gset
select lab.check('ntf', 'owner: can rename a member (and the name is kept)', lab.val(format('select display_name from organization_users where organization_id = %L and user_id = %L', :'org_a', :'rep')) = 'مندوب الاختبار');
select lab.as_owner() \gset

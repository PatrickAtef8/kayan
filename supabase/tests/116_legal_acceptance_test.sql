-- 0064/0065: legal documents (public, versioned, immutable), the contact settings, and the acceptance record kept against each payment order.
\set ON_ERROR_STOP on
select t.autoconfirm_off();
select t.as_owner();
insert into auth.users (id, email, email_confirmed_at) values
  ('11600000-0000-0000-0000-000000000001', 'owner@legal.test', now()),    -- owner of A
  ('11600000-0000-0000-0000-000000000002', 'rep@legal.test',   now()),    -- a rep in A
  ('11600000-0000-0000-0000-000000000003', 'other@legal.test', now());    -- owner of B
select t.as_user('11600000-0000-0000-0000-000000000001');
select create_organization('شركة أ', 'x', 'EG', 'EGP', 'ar', array['products','customers']) as id \gset a_
select t.as_user('11600000-0000-0000-0000-000000000003');
select create_organization('شركة ب', 'x', 'EG', 'EGP', 'ar', array['products','customers']) as id \gset b_
select t.as_owner();
insert into organization_users (organization_id, user_id, role_id, status)
select :'a_id', '11600000-0000-0000-0000-000000000002', r.id, 'active' from roles r where r.key = 'sales' and r.organization_id is null;

-- ============================================================ 1. the shipped drafts are in place (0065) and public
select t.as_anon();
select t.eq((select count(*) from legal_documents where version = 1 and doc_key in ('terms', 'privacy', 'refund')), 3, 'version 1 of the three documents is seeded');
select t.ok((select bool_and(length(body_ar) > 2500 and length(body_en) > 2500 and length(title_ar) > 0 and length(title_en) > 0) from legal_documents where version = 1), 'each in Arabic and English, with real content');
select t.ok((select body_ar like '%{{phone}}%' and body_en like '%{{phone}}%' from legal_documents where doc_key = 'terms' and version = 1), 'the contact number is a placeholder filled from the settings');
select t.ok(legal_current_versions() = '{"terms":1,"privacy":1,"refund":1}'::jsonb, 'visitors can read the current versions');
select t.eq((select count(*) from platform_legal_settings), 1, 'the settings row exists and is public (it feeds the footer)');

-- ============================================================ 2. nobody but the back office writes
select t.as_user('11600000-0000-0000-0000-000000000001');
select t.throws($q$insert into legal_documents (doc_key, version, title_ar, body_ar, title_en, body_en) values ('terms', 2, 'x', 'x', 'x', 'x')$q$, 'permission denied', 'an owner cannot add a document version');
select t.throws($q$update legal_documents set body_ar = 'x'$q$, 'permission denied', 'nor edit one');
select t.throws($q$delete from legal_documents$q$, 'permission denied', 'nor delete one');
select t.throws($q$update platform_legal_settings set lawyer_reviewed = true$q$, 'permission denied', 'nor change the settings (or the "reviewed by a lawyer" flag)');
select t.throws($q$select admin_save_legal_document(gen_random_uuid(), 'terms', 'a', 'b', 'c', 'd', null)$q$, 'permission denied', 'nor call the admin functions');
select t.throws($q$select admin_save_legal_settings(gen_random_uuid(), 'a', 'b', '', '', '', '', '', '', true)$q$, 'permission denied', 'either');
select t.throws($q$select billing_record_acceptance(gen_random_uuid(), gen_random_uuid(), '{}', 'ar', null, null)$q$, 'permission denied', 'nor write an acceptance by hand');
select t.as_anon();
select t.throws($q$update legal_documents set body_ar = 'x'$q$, 'permission denied', 'a visitor cannot either');

-- ============================================================ 3. the admin saves a NEW version; history is immutable
select t.as_owner();
set role service_role;
select admin_save_legal_document('11600000-0000-0000-0000-000000000009', 'terms', 'الشروط', 'نص جديد', 'Terms', 'new text', 'تعديل') ->> 'version' as v2 \gset
select admin_save_legal_document('11600000-0000-0000-0000-000000000009', 'terms', 'الشروط', 'نص جديد', 'Terms', 'new text', 'نفسه') ->> 'unchanged' as same \gset
reset role;
select t.eq_text(:'v2', '2', 'an edit creates version 2');
select t.eq_text(:'same', 'true', 'saving the same text again creates no empty version');
select t.ok(legal_current_versions() = '{"terms":2,"privacy":1,"refund":1}'::jsonb, 'only the edited document moved on');
select t.eq((select count(*) from legal_documents where doc_key = 'terms'), 2, 'version 1 is still there');
select t.ok((select body_ar like '%كيان%' from legal_documents where doc_key = 'terms' and version = 1), 'unchanged');
select t.throws($q$update legal_documents set body_ar = 'rewritten' where doc_key = 'terms' and version = 1$q$, 'immutable', 'history cannot be rewritten, even by the back office');
select t.throws($q$delete from legal_documents where doc_key = 'terms' and version = 1$q$, 'immutable', 'or deleted');
select t.throws($q$select admin_save_legal_document(gen_random_uuid(), 'nope', 'a', 'b', 'c', 'd', null)$q$, 'unknown legal document', 'an unknown document is refused');
select t.throws($q$select admin_save_legal_document(gen_random_uuid(), 'terms', 'a', '', 'c', 'd', null)$q$, 'required in both languages', 'an empty text is refused');
select t.eq((select count(*) from admin_audit_log where action = 'legal.document'), 1, 'the edit is audited');

-- settings: the contact number
set role service_role;
select admin_save_legal_settings('11600000-0000-0000-0000-000000000009', 'كيان للبرمجيات', 'Kayan Software', '+20 100 123 4567', 'hello@kayan.test', 'القاهرة', 'Cairo', '12345', '678', false) as ss \gset
reset role;
select t.eq_text((select contact_phone from platform_legal_settings), '+20 100 123 4567', 'the contact number is saved');
select t.eq_text((select lawyer_reviewed::text from platform_legal_settings), 'false', 'and the draft notice stays on until a lawyer has reviewed');
select t.throws($q$select admin_save_legal_settings(gen_random_uuid(), 'a', 'b', 'call me', '', '', '', '', '', false)$q$, 'invalid phone', 'a phone number must look like one');
select t.throws($q$select admin_save_legal_settings(gen_random_uuid(), 'a', 'b', '', 'not-an-email', '', '', '', '', false)$q$, 'invalid email', 'an email must look like one');
select t.throws($q$select admin_save_legal_settings(gen_random_uuid(), '', 'b', '', '', '', '', '', '', false)$q$, 'company name is required', 'the name is required');

-- ============================================================ 4. the acceptance record, against the order
set role service_role;
select billing_begin_order(:'a_id', '11600000-0000-0000-0000-000000000001', 'monthly', 'monthly', 'initial', 'EGP', 65000, 65000,
  '[{"id":"sub","label":"sub","amount":65000}]', '{"modules":["customers"],"max_members":5,"max_warehouses":2}', 1) -> 'order' ->> 'id' as ord \gset
select billing_begin_order(:'b_id', '11600000-0000-0000-0000-000000000003', 'monthly', 'monthly', 'initial', 'EGP', 65000, 65000,
  '[{"id":"sub","label":"sub","amount":65000}]', '{"modules":["customers"],"max_members":5,"max_warehouses":2}', 1) -> 'order' ->> 'id' as ordb \gset
select billing_record_acceptance(:'ord', '11600000-0000-0000-0000-000000000001', '{"terms":2,"privacy":1,"refund":1}', 'ar', '203.0.113.7', 'Mozilla/5.0 test') as ok1 \gset
select billing_record_acceptance(:'ord', '11600000-0000-0000-0000-000000000001', '{"terms":1,"privacy":1,"refund":1}', 'ar', null, null) as stale \gset
select billing_record_acceptance(:'ord', '11600000-0000-0000-0000-000000000001', '{"terms":"x"}', 'ar', null, null) as bad \gset
select billing_record_acceptance(:'ord', '11600000-0000-0000-0000-000000000001', '{}', 'ar', null, null) as empty \gset
select billing_record_acceptance(:'ord', '11600000-0000-0000-0000-000000000002', '{"terms":2,"privacy":1,"refund":1}', 'ar', null, null) as rep \gset
select billing_record_acceptance(:'ord', '11600000-0000-0000-0000-000000000003', '{"terms":2,"privacy":1,"refund":1}', 'ar', null, null) as foreign \gset
select billing_record_acceptance(gen_random_uuid(), '11600000-0000-0000-0000-000000000001', '{"terms":2,"privacy":1,"refund":1}', 'ar', null, null) as nofound \gset
select billing_record_acceptance(:'ord', '11600000-0000-0000-0000-000000000001', '{"terms":2,"privacy":1,"refund":1}', 'en', repeat('9', 200), repeat('u', 900)) as again \gset
reset role;
select t.eq_text(:'ok1', 'recorded', 'the current versions are recorded against the order');
select t.eq_text(:'stale', 'stale', 'an old version is refused');
select t.eq_text(:'bad', 'stale', 'a malformed version is refused');
select t.eq_text(:'empty', 'stale', 'an empty acceptance is refused');
select t.eq_text(:'rep', 'not_owner', 'a rep of the company cannot accept for it');
select t.eq_text(:'foreign', 'not_owner', 'nor can the owner of another company');
select t.eq_text(:'nofound', 'not_found', 'an unknown order is refused');
select t.eq_text(:'again', 'recorded', 'a resumed payment adds another (append-only) record');
select t.eq((select count(*) from billing_order_acceptances where order_id = :'ord'), 2, 'two records for the order, none for the refused attempts');
select t.eq((select terms_version from billing_order_acceptances where order_id = :'ord' order by id limit 1), 2, 'with the accepted versions');
select t.ok((select accepted_at > now() - interval '1 minute' and ip_address = '203.0.113.7' and user_agent = 'Mozilla/5.0 test' and locale = 'ar' from billing_order_acceptances where order_id = :'ord' order by id limit 1), 'the time (database clock), network address, browser and language');
select t.ok((select length(ip_address) = 64 and length(user_agent) = 300 from billing_order_acceptances where order_id = :'ord' order by id desc limit 1), 'long evidence is truncated, never stored unbounded');
select t.throws(format($q$update billing_order_acceptances set terms_version = 9 where order_id = %L$q$, :'ord'), 'immutable', 'a record cannot be edited, even by the back office');

-- who can read it
select t.as_user('11600000-0000-0000-0000-000000000001');
select t.eq((select count(*) from billing_order_acceptances), 2, 'the owner can read their own company''s acceptances');
select t.throws($q$insert into billing_order_acceptances (order_id, organization_id, user_id, terms_version, privacy_version, refund_version, locale) values (gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), 1, 1, 1, 'ar')$q$, 'permission denied', 'but cannot write one');
select t.throws($q$delete from billing_order_acceptances$q$, 'permission denied', 'nor delete one');
select t.as_user('11600000-0000-0000-0000-000000000002');
select t.eq((select count(*) from billing_order_acceptances), 0, 'a rep sees none');
select t.as_user('11600000-0000-0000-0000-000000000003');
select t.eq((select count(*) from billing_order_acceptances where order_id = :'ord'), 0, 'another company''s owner cannot read them');

-- ============================================================ 5. when the documents are missing nothing is accepted
select t.as_owner();
create temp table _saved as select * from legal_documents;
alter table legal_documents disable trigger legal_documents_immutable;
delete from legal_documents where doc_key = 'refund';
set role service_role;
select billing_record_acceptance(:'ord', '11600000-0000-0000-0000-000000000001', '{"terms":2,"privacy":1,"refund":1}', 'ar', null, null) as gone \gset
reset role;
select t.eq_text(:'gone', 'legal_unavailable', 'with a document missing, no acceptance can be recorded');
insert into legal_documents select * from _saved where doc_key = 'refund';
alter table legal_documents enable trigger legal_documents_immutable;
select t.ok(legal_current_versions() = '{"terms":2,"privacy":1,"refund":1}'::jsonb, 'restored');

-- ============================================================ 6. an order's removal takes its acceptances with it (the repair script deletes whole companies)
select t.as_owner();
delete from billing_orders where id = :'ordb';
select t.eq((select count(*) from billing_order_acceptances where order_id = :'ordb'), 0, 'deleting an order cascades (updates stay blocked)');

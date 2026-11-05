-- 0072: one active company per user, organization validation, and the deletion archive.
\set ON_ERROR_STOP on
select t.autoconfirm_off();
select t.as_owner();
insert into auth.users (id, email) values
  ('12100000-0000-0000-0000-000000000001', 'g1@guard.test'),
  ('12100000-0000-0000-0000-000000000002', 'g2@guard.test'),
  ('12100000-0000-0000-0000-000000000003', 'g3@guard.test');

-- one company per user
select t.as_user('12100000-0000-0000-0000-000000000001');
select create_organization('شركة الأولى', 'x', 'EG', 'EGP', 'ar', array['customers']) as id \gset a_
select t.throws($q$select create_organization('شركة ثانية', 'x', 'EG', 'EGP', 'ar', array['customers'])$q$, 'أكثر من شركة', 'a second company for the same account is refused');
select t.as_user('12100000-0000-0000-0000-000000000002');
select create_organization('شركة ب', 'x', 'EG', 'EGP', 'ar', array['customers']) as id \gset b_

-- an invitation can be recorded for someone who already has a company, but accepting it is refused
select t.as_user('12100000-0000-0000-0000-000000000001');
select add_team_member(:'a_id', 'g2@guard.test', (select id from roles where key = 'sales' and organization_id is null), 'ب');
select t.as_user('12100000-0000-0000-0000-000000000002');
select t.throws($q$select accept_org_invite((select organization_id from organization_users where user_id = '12100000-0000-0000-0000-000000000002' and status = 'invited'))$q$, 'أكثر من شركة', 'accepting an invitation into a second company is refused');
-- but a person without a company can accept
select t.as_user('12100000-0000-0000-0000-000000000001');
select add_team_member(:'a_id', 'g3@guard.test', (select id from roles where key = 'sales' and organization_id is null), 'ج');
select t.as_user('12100000-0000-0000-0000-000000000003');
select accept_org_invite(:'a_id');
select t.eq((select count(*) from organization_users where user_id = '12100000-0000-0000-0000-000000000003' and status = 'active'), 1, 'a person without a company can accept');

-- grandfathered: existing multi-membership rows are not touched by the rule (only NEW activations are checked)
select t.as_owner();
alter table organization_users disable trigger zz_one_active_company;
insert into organization_users (organization_id, user_id, role_id, status) select :'b_id', '12100000-0000-0000-0000-000000000003', id, 'active' from roles where key = 'sales' and organization_id is null;
alter table organization_users enable trigger zz_one_active_company;
update organization_users set display_name = 'اسم' where user_id = '12100000-0000-0000-0000-000000000003';
select t.ok(true, 'updating an existing multi-company user (not a status change) still works');

-- validation
select t.as_owner();
select t.throws($q$insert into organizations (name) values ('  ')$q$, 'اسم الشركة', 'an empty company name is refused');
select t.throws($q$insert into organizations (name, currency) values ('شركة', 'EGPP')$q$, 'العملة', 'a bad currency code is refused');
select t.throws($q$insert into organizations (name, language) values ('شركة', 'fr')$q$, 'اللغة', 'an unsupported language is refused');

-- deletion keeps an archive
select t.as_owner();
insert into customers (organization_id, name) values (:'b_id', 'عميل');
select count(*) as n from audit_logs where organization_id = :'b_id' \gset al_
select t.ok(:al_n > 0, 'the company has audit rows');
select t.eq_text(admin_delete_company('12100000-0000-0000-0000-000000000001', :'b_id'), 'deleted', 'deleted');
select t.eq((select count(*) from audit_logs where organization_id = :'b_id'), 0, 'live audit rows are gone with the company');
select t.eq((select count(*) from company_audit_archive where source_org_id = :'b_id'), :al_n, 'but every audit row was archived first');
select t.eq((select audit_log_count from company_deletion_archive where source_org_id = :'b_id'), :al_n, 'the archive records the count');
select t.eq_text((select org_name from company_deletion_archive where source_org_id = :'b_id'), 'شركة ب', 'and the company name');

-- the archive is invisible to browser sessions
select t.as_user('12100000-0000-0000-0000-000000000001');
select t.throws($q$select * from company_audit_archive$q$, 'permission denied', 'archive: no access from a signed-in session');
select t.throws($q$select * from company_deletion_archive$q$, 'permission denied', 'archive: no access from a signed-in session');
select t.throws($q$select * from email_log$q$, 'permission denied', 'email_log: no access from a signed-in session');

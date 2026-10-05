-- SRS §14/§54 Settings & Team management: listing members, adding an
-- existing user by email, completing an invite for a brand-new user,
-- permission gating, and the existing owner-protection/audit machinery
-- (Phase 7) still applying to these new entry points.

\set ON_ERROR_STOP on

select t.as_owner();
insert into auth.users (id, email) values
  ('f0000000-0000-0000-0000-000000000001', 'owner@team.test'),
  ('f0000000-0000-0000-0000-000000000002', 'existing@team.test'),   -- already has a Supabase account
  ('f0000000-0000-0000-0000-000000000003', 'sales@team.test'),
  ('f0000000-0000-0000-0000-000000000010', 'brandnew@team.test');   -- simulates a freshly-admin-invited user

select t.as_user('f0000000-0000-0000-0000-000000000001');
select create_organization('شركة الفريق', 'x', 'EG', 'EGP', 'ar', array['sales']) as id \gset org_
select t.as_owner();
insert into organization_users (organization_id, user_id, role_id, status)
select :'org_id', 'f0000000-0000-0000-0000-000000000003', id, 'active' from roles where key = 'sales' and organization_id is null;
select id as accountant_role from roles where key = 'accountant' and organization_id is null \gset
select id as sales_role from roles where key = 'sales' and organization_id is null \gset
select id as owner_role from roles where key = 'owner' and organization_id is null \gset
select t.as_user('f0000000-0000-0000-0000-000000000001');

-- ============================================================
-- list_org_members
-- ============================================================
select t.eq((select count(*) from list_org_members(:'org_id')), 2, 'two members exist so far (owner + the sales rep)');
select t.eq_text((select email from list_org_members(:'org_id') where role_key = 'owner'), 'owner@team.test', 'the owner''s email is listed');
select t.ok((select is_self from list_org_members(:'org_id') where role_key = 'owner'), 'the caller is flagged as themselves');

-- A plain sales role has no manage_settings — cannot see the team list at all.
select t.as_user('f0000000-0000-0000-0000-000000000003');
select t.throws(format('select * from list_org_members(%L)', :'org_id'), 'صلاحية عرض أعضاء الفريق', 'a plain sales role cannot list team members');
select t.as_user('f0000000-0000-0000-0000-000000000001');

-- ============================================================
-- add_team_member — existing Supabase user, found by email (no admin
-- invite needed)
-- ============================================================
select add_team_member(:'org_id', 'EXISTING@Team.test', :'accountant_role') as j \gset add1_
select t.eq_text(:'add1_j'::jsonb ->> 'status', 'added', 'an existing user is added immediately (email lookup is case-insensitive)');
select t.eq((select count(*) from organization_users where organization_id = :'org_id' and user_id = 'f0000000-0000-0000-0000-000000000002'), 1, 'the existing user is now a member');
select t.ok((select role_id from organization_users where organization_id = :'org_id' and user_id = 'f0000000-0000-0000-0000-000000000002') = :'accountant_role'::uuid, 'with the chosen role');
select t.eq((select count(*) from audit_logs where organization_id = :'org_id' and entity = 'user' and entity_id = (select id from organization_users where organization_id = :'org_id' and user_id = 'f0000000-0000-0000-0000-000000000002')), 1, 'adding a member is audited (§46 user creation)');

-- Adding the same person again is refused, not silently duplicated.
select t.throws(format('select add_team_member(%L, ''existing@team.test'', %L)', :'org_id', :'accountant_role'), 'عضو بالفعل', 'adding an already-existing member a second time is refused');

-- ============================================================
-- add_team_member — brand-new email: signals the caller to fall back to
-- the admin-invite path, and does NOT create a membership row itself.
-- ============================================================
select add_team_member(:'org_id', 'nobody-yet@team.test', :'sales_role') as j \gset add2_
select t.eq_text(:'add2_j'::jsonb ->> 'status', 'needs_invite', 'an email with no existing account signals needs_invite');
select t.eq((select count(*) from organization_users where organization_id = :'org_id'), 3, 'no membership row is created for an email that does not exist yet (still 3: owner, sales rep, existing)');

-- ============================================================
-- complete_team_invite — the server action calls this after Supabase
-- Auth's admin API has created the brand-new account and returned its id.
-- ============================================================
select complete_team_invite(:'org_id', 'f0000000-0000-0000-0000-000000000010', :'sales_role');
select t.eq((select count(*) from organization_users where organization_id = :'org_id' and user_id = 'f0000000-0000-0000-0000-000000000010'), 1, 'the newly-invited user is now a member');
select t.eq((select count(*) from list_org_members(:'org_id')), 4, 'the team now has 4 members');

-- ============================================================
-- Permission gating on both add paths
-- ============================================================
select t.as_user('f0000000-0000-0000-0000-000000000003');
select t.throws(format('select add_team_member(%L, ''someone@else.test'', %L)', :'org_id', :'sales_role'), 'صلاحية إضافة أعضاء', 'a plain sales role cannot add a team member');
select t.throws(format('select complete_team_invite(%L, %L, %L)', :'org_id', 'f0000000-0000-0000-0000-000000000010', :'sales_role'), 'صلاحية إضافة أعضاء', 'a plain sales role cannot complete an invite either');
select t.as_user('f0000000-0000-0000-0000-000000000001');

-- Nobody may hand out the owner role through this generic path unless
-- they are already an owner themselves; Phase 7's protect_org_owners
-- trigger still applies here even though this is a new entry point. Use
-- an existing user (not a brand-new email) so add_team_member actually
-- reaches its INSERT, where the trigger fires.
select t.as_owner();
insert into auth.users (id, email) values
  ('f0000000-0000-0000-0000-000000000004', 'admin@team.test'),
  ('f0000000-0000-0000-0000-000000000005', 'freshexisting@team.test');
insert into organization_users (organization_id, user_id, role_id, status)
select :'org_id', 'f0000000-0000-0000-0000-000000000004', id, 'active' from roles where key = 'admin' and organization_id is null;
select t.as_user('f0000000-0000-0000-0000-000000000004');
select t.throws(format('select add_team_member(%L, ''freshexisting@team.test'', %L)', :'org_id', :'owner_role'),
  'إضافة مالك', 'an admin (manage_settings, but not owner) cannot hand out the owner role via add_team_member');
select t.eq((select count(*) from organization_users where organization_id = :'org_id' and user_id = 'f0000000-0000-0000-0000-000000000005'), 0, 'the blocked insert leaves no partial membership row behind');
select t.as_user('f0000000-0000-0000-0000-000000000001');

-- ============================================================
-- Tenant isolation: an org B admin cannot list or add to org A's team
-- ============================================================
select t.as_owner();
insert into auth.users (id, email) values ('f0000000-0000-0000-0000-000000000099', 'other-owner@team.test');
select t.as_user('f0000000-0000-0000-0000-000000000099');
select create_organization('شركة ب', 'x', 'EG', 'EGP', 'ar', array['sales']) as id \gset orgb_
select t.throws(format('select * from list_org_members(%L)', :'org_id'), 'صلاحية عرض أعضاء الفريق', 'org B''s owner cannot list org A''s team (has_permission correctly scopes to org B)');
select t.throws(format('select add_team_member(%L, ''nobody-yet@team.test'', %L)', :'org_id', :'sales_role'), 'صلاحية إضافة أعضاء', 'org B''s owner cannot add to org A''s team');

-- ============================================================
-- Organization settings: name is editable, module toggles are
-- permission-gated table writes that were already possible — confirming
-- they still work and are audited (§46 "Permission change" / settings).
-- ============================================================
select t.as_user('f0000000-0000-0000-0000-000000000001');
update organizations set name = 'الاسم الجديد' where id = :'org_id';
select t.eq_text((select name from organizations where id = :'org_id'), 'الاسم الجديد', 'the owner can rename the organization');
select t.eq((select count(*) from audit_logs where organization_id = :'org_id' and entity = 'organization'), 1, 'renaming the organization is audited');

insert into organization_modules (organization_id, module_key, enabled) values (:'org_id', 'expenses', true);
select t.ok((select is_module_enabled(:'org_id', 'expenses')), 'a module can be enabled after onboarding, not just during it');
update organization_modules set enabled = false where organization_id = :'org_id' and module_key = 'expenses';
select t.ok(not (select is_module_enabled(:'org_id', 'expenses')), 'and disabled again — enforcement (Phase 7) reads this live');

select t.as_user('f0000000-0000-0000-0000-000000000003');
select t.eq(t.affected(format('update organizations set name = ''تعديل غير مصرح'' where id = %L', :'org_id')), 0, 'a plain sales role''s attempt to rename the organization touches 0 rows (RLS)');
select t.throws(format('insert into organization_modules (organization_id, module_key, enabled) values (%L, ''partners'', true)', :'org_id'), 'row-level security', 'a plain sales role cannot enable a module');

select t.as_owner();

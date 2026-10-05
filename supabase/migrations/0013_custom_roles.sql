-- Kayan — Phase 10: Custom Role Builder (§14)
--
-- 0011's own comment on list_org_members flagged this explicitly: system
-- role templates were the MVP scope, and "a custom-role builder is a
-- reasonable future addition, not a silent gap." This is that addition.
--
-- The schema already had everything needed for this — roles.organization_id
-- being non-null IS a custom role, and the roles_manage RLS policy already
-- anticipated org admins managing their own roles. What was missing was
-- the write path. Every other write in this app goes through a
-- SECURITY DEFINER RPC rather than raw table grants (lets us validate,
-- audit, and keep the RLS policies honest about what's actually possible
-- through the client) — so custom roles get the same treatment rather
-- than granting insert/update/delete on `roles` directly.
--
-- Design choices:
--   1. A custom role's `key` is machine-generated (custom_<8 hex chars>)
--      rather than derived from the name, so renaming a role later never
--      touches its key, and there's no slug-collision handling to get
--      wrong. The `name` is what the UI (and role_key in list_org_members)
--      shows to people.
--   2. A custom role always starts from an explicit permission set chosen
--      in the builder — no "clone an existing role" shortcut, keeping the
--      first version simple. Editing later just replaces the whole set,
--      same as how sales-return items or role_permissions elsewhere in
--      this app are always fully replaced rather than diffed.
--   3. System roles (is_system = true, organization_id is null) can never
--      be edited or deleted through these RPCs — only permission keys can
--      be added/removed from a role that belongs to THIS organization.
--   4. A custom role can't be deleted while someone is still assigned to
--      it — same reasoning as why a sales/purchase invoice can't be
--      deleted outright elsewhere in the app: reassign first, don't leave
--      a dangling reference.

create or replace function create_custom_role(org_id uuid, p_name text, p_permission_keys text[])
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  new_role_id uuid;
  new_key text;
  perm text;
begin
  if auth.uid() is null then
    raise exception 'يجب تسجيل الدخول أولاً';
  end if;
  if not has_permission(org_id, 'manage_settings') then
    raise exception 'ليس لديك صلاحية إدارة الأدوار';
  end if;
  if p_name is null or trim(p_name) = '' then
    raise exception 'اسم الدور مطلوب';
  end if;
  if p_permission_keys is null or array_length(p_permission_keys, 1) is null then
    raise exception 'يجب اختيار صلاحية واحدة على الأقل';
  end if;

  new_key := 'custom_' || substr(md5(random()::text || clock_timestamp()::text), 1, 8);

  insert into roles (organization_id, name, key, is_system)
  values (org_id, trim(p_name), new_key, false)
  returning id into new_role_id;

  foreach perm in array p_permission_keys loop
    if not exists (select 1 from permissions where key = perm) then
      raise exception 'صلاحية غير معروفة: %', perm;
    end if;
    insert into role_permissions (role_id, permission_key) values (new_role_id, perm)
    on conflict do nothing;
  end loop;

  return new_role_id;
end;
$$;

create or replace function update_custom_role(org_id uuid, p_role_id uuid, p_name text, p_permission_keys text[])
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  perm text;
begin
  if auth.uid() is null then
    raise exception 'يجب تسجيل الدخول أولاً';
  end if;
  if not has_permission(org_id, 'manage_settings') then
    raise exception 'ليس لديك صلاحية إدارة الأدوار';
  end if;
  if not exists (select 1 from roles where id = p_role_id and organization_id = org_id and is_system = false) then
    raise exception 'هذا الدور غير قابل للتعديل';
  end if;
  if p_name is null or trim(p_name) = '' then
    raise exception 'اسم الدور مطلوب';
  end if;
  if p_permission_keys is null or array_length(p_permission_keys, 1) is null then
    raise exception 'يجب اختيار صلاحية واحدة على الأقل';
  end if;

  update roles set name = trim(p_name) where id = p_role_id;

  delete from role_permissions where role_id = p_role_id;
  foreach perm in array p_permission_keys loop
    if not exists (select 1 from permissions where key = perm) then
      raise exception 'صلاحية غير معروفة: %', perm;
    end if;
    insert into role_permissions (role_id, permission_key) values (p_role_id, perm)
    on conflict do nothing;
  end loop;
end;
$$;

create or replace function delete_custom_role(org_id uuid, p_role_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'يجب تسجيل الدخول أولاً';
  end if;
  if not has_permission(org_id, 'manage_settings') then
    raise exception 'ليس لديك صلاحية إدارة الأدوار';
  end if;
  if not exists (select 1 from roles where id = p_role_id and organization_id = org_id and is_system = false) then
    raise exception 'هذا الدور غير قابل للحذف';
  end if;
  if exists (select 1 from organization_users where role_id = p_role_id) then
    raise exception 'لا يمكن حذف دور مُسند إلى أعضاء — أعد إسناد هؤلاء الأعضاء لدور آخر أولاً';
  end if;

  delete from roles where id = p_role_id;
end;
$$;

revoke all on function create_custom_role(uuid, text, text[]) from public, anon;
revoke all on function update_custom_role(uuid, uuid, text, text[]) from public, anon;
revoke all on function delete_custom_role(uuid, uuid) from public, anon;
grant execute on function create_custom_role(uuid, text, text[]) to authenticated;
grant execute on function update_custom_role(uuid, uuid, text, text[]) to authenticated;
grant execute on function delete_custom_role(uuid, uuid) to authenticated;

-- Every role change (system role edits are impossible above, but a custom
-- role's own lifecycle should still be traceable, same as §46 requires for
-- team/permission changes generally). Split by event — audit_logs.
-- organization_id is NOT NULL, and a plain combined-event WHEN clause
-- referencing both OLD and NEW is easy to get subtly wrong, so this stays
-- explicit about which side is checked for which event.
create trigger audit_custom_roles_ins after insert on roles for each row when (NEW.organization_id is not null) execute function audit_row_change('role', '');
create trigger audit_custom_roles_upd after update on roles for each row when (NEW.organization_id is not null) execute function audit_row_change('role', '');
create trigger audit_custom_roles_del after delete on roles for each row when (OLD.organization_id is not null) execute function audit_row_change('role', '');

-- list_org_members already returns role_key/role_name generically (reads
-- straight off the roles table via a join) — a custom role's members show
-- up correctly with no change needed there.

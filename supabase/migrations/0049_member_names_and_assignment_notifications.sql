-- Kayan — Phase 49: member names + notifications for everything the owner does to a rep / storekeeper / team member
-- Depends on 0046–0048. Re-runnable.  TAKE A DATABASE BACKUP FIRST.
--
-- WHY
--   * A rep was never told when the owner assigned a customer to him: only invoices, payments, returns, dispatch
--     and shortage events produced notifications.  Nothing fired on customers.sales_rep_id, on the rep record,
--     or on the team (role changes, invitations, removal).
--   * People were identified by e-mail only.  Invitations now carry a NAME and every notification that mentions a
--     person shows "Name (email)".
--
-- WHAT THIS ADDS (no invoice / stock / accounting function is touched)
--   1. organization_users.display_name  +  add_team_member / complete_team_invite take a name  +  update_member_name
--      +  list_org_members returns it.
--   2. _ntf_actor_label now returns "Name (email)" — so EVERY existing notification ("بواسطة …") shows the name,
--      with no change to the 0047 builders.
--   3. New notification types
--        for the rep      : rep_customer_assigned / rep_customer_unassigned / rep_customer_updated (edited or deleted) / rep_invoice_assigned /
--                           rep_invoice_unassigned / rep_record_update (linked, unlinked, activated, deactivated, terms)
--        for the storekeeper: warehouse_task_cancelled (a return cancelled goods he was asked to dispatch/receive)
--        for any member   : role_changed
--        for the owner(s) : assignment_made, team_activity (invited / joined / declined / removed / role changed / rep record)
--      An owner is never notified about his own action (as before); another owner is.
--   4. Triggers on customers, sales_invoices, sales_representatives, organization_users, fulfilment_events.
--      Same reliability model as 0047: a failure is recorded in notification_failures and retried, never aborting
--      the business transaction.

-- ============================================================
-- 1. Names
-- ============================================================
alter table organization_users add column if not exists display_name text;
alter table organization_users drop constraint if exists organization_users_display_name_len;
alter table organization_users add constraint organization_users_display_name_len
  check (display_name is null or char_length(display_name) between 1 and 100);

-- the old 3-argument versions would make named-argument calls ambiguous
drop function if exists add_team_member(uuid, text, uuid);
drop function if exists complete_team_invite(uuid, uuid, uuid);

create or replace function add_team_member(org_id uuid, p_email text, p_role_id uuid, p_name text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_user_id uuid; v_name text := nullif(btrim(coalesce(p_name, '')), '');
begin
  if auth.uid() is null then raise exception 'يجب تسجيل الدخول أولاً'; end if;
  if not has_permission(org_id, 'manage_settings') then raise exception 'ليس لديك صلاحية إضافة أعضاء'; end if;
  if coalesce(trim(p_email), '') = '' then raise exception 'البريد الإلكتروني مطلوب'; end if;
  if v_name is not null and char_length(v_name) > 100 then raise exception 'الاسم طويل جدًا (الحد الأقصى ١٠٠ حرف)'; end if;
  if not exists (select 1 from roles where id = p_role_id and (organization_id is null or organization_id = org_id)) then
    raise exception 'الدور المختار غير صحيح';
  end if;
  v_user_id := find_user_id_by_email(p_email);
  -- Do NOT reveal whether the account exists: both branches look the same to the caller.
  if v_user_id is not null and not exists (select 1 from organization_users where organization_id = org_id and user_id = v_user_id) then
    insert into organization_users (organization_id, user_id, role_id, status, display_name) values (org_id, v_user_id, p_role_id, 'invited', v_name);
  end if;
  return jsonb_build_object('status', case when v_user_id is null then 'needs_invite' else 'added' end);
end $$;

create or replace function complete_team_invite(org_id uuid, p_user_id uuid, p_role_id uuid, p_name text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_name text := nullif(btrim(coalesce(p_name, '')), '');
begin
  if auth.uid() is null then raise exception 'يجب تسجيل الدخول أولاً'; end if;
  if not has_permission(org_id, 'manage_settings') then raise exception 'ليس لديك صلاحية إضافة أعضاء'; end if;
  if v_name is not null and char_length(v_name) > 100 then raise exception 'الاسم طويل جدًا (الحد الأقصى ١٠٠ حرف)'; end if;
  if not exists (select 1 from roles where id = p_role_id and (organization_id is null or organization_id = org_id)) then
    raise exception 'الدور المختار غير صحيح';
  end if;
  insert into organization_users (organization_id, user_id, role_id, status, display_name)
  values (org_id, p_user_id, p_role_id, 'invited', v_name)
  on conflict do nothing;
end $$;

revoke all on function add_team_member(uuid, text, uuid, text), complete_team_invite(uuid, uuid, uuid, text) from public, anon;
grant execute on function add_team_member(uuid, text, uuid, text), complete_team_invite(uuid, uuid, uuid, text) to authenticated;

-- Rename a member (also how existing members, added before this phase, get a name).
create or replace function update_member_name(org_id uuid, p_user_id uuid, p_name text) returns void
language plpgsql security definer set search_path = public as $$
declare v_name text := nullif(btrim(coalesce(p_name, '')), '');
begin
  if auth.uid() is null then raise exception 'يجب تسجيل الدخول أولاً'; end if;
  if not has_permission(org_id, 'manage_settings') then raise exception 'ليس لديك صلاحية تعديل أعضاء الفريق'; end if;
  if v_name is not null and char_length(v_name) > 100 then raise exception 'الاسم طويل جدًا (الحد الأقصى ١٠٠ حرف)'; end if;
  update organization_users set display_name = v_name where organization_id = org_id and user_id = p_user_id;
  if not found then raise exception 'العضو غير موجود في هذه المؤسسة'; end if;
end $$;
revoke all on function update_member_name(uuid, uuid, text) from public, anon;
grant execute on function update_member_name(uuid, uuid, text) to authenticated;

-- list_org_members gains display_name (the return type changes, so it has to be dropped first)
drop function if exists list_org_members(uuid);
create or replace function list_org_members(org_id uuid)
returns table (
  user_id uuid, email text, role_id uuid, role_key text, role_name text, status text, joined_at timestamptz, is_self boolean,
  display_name text
)
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'يجب تسجيل الدخول أولاً'; end if;
  if not has_permission(org_id, 'manage_settings') then raise exception 'ليس لديك صلاحية عرض أعضاء الفريق'; end if;
  return query
  select ou.user_id, u.email::text, ou.role_id, r.key::text, r.name::text, ou.status::text, ou.created_at, ou.user_id = auth.uid(), ou.display_name::text
  from organization_users ou
  join auth.users u on u.id = ou.user_id
  join roles r on r.id = ou.role_id
  where ou.organization_id = org_id
  order by ou.created_at;
end $$;
revoke all on function list_org_members(uuid) from public, anon;
grant execute on function list_org_members(uuid) to authenticated;

-- ============================================================
-- 2. Labels: "Name (email)"
-- ============================================================
-- p_user may be null (a rep record that is not linked to a login): then only the fallback name is used.
create or replace function _ntf_person_label(p_org uuid, p_user uuid, p_fallback_name text default null) returns text
language plpgsql stable security definer set search_path = public as $$
declare v_name text; v_email text;
begin
  if p_user is not null then
    select nullif(btrim(ou.display_name), '') into v_name from organization_users ou where ou.organization_id = p_org and ou.user_id = p_user;
    select u.email::text into v_email from auth.users u where u.id = p_user;
  end if;
  v_name := coalesce(v_name, nullif(btrim(coalesce(p_fallback_name, '')), ''));
  if v_name is not null and v_email is not null and lower(v_name) <> lower(v_email) then return v_name || ' (' || v_email || ')'; end if;
  return coalesce(v_name, v_email);
end $$;
revoke all on function _ntf_person_label(uuid, uuid, text) from public, anon, authenticated;

-- Same signature as 0046, so every builder that already calls it ("بواسطة …") now shows the name too.
create or replace function _ntf_actor_label(p_org uuid, p_user uuid) returns text
language sql stable security definer set search_path = public as $$
  select coalesce(
    _ntf_person_label(p_org, p_user, (select sr.name from sales_representatives sr where sr.organization_id = p_org and sr.user_id = p_user limit 1)),
    'النظام')
$$;
revoke all on function _ntf_actor_label(uuid, uuid) from public, anon, authenticated;

-- ============================================================
-- 3. New types, visibility, delivery rules
-- ============================================================
alter table notifications drop constraint if exists notifications_type_check;
alter table notifications add constraint notifications_type_check check (type in (
  'sales_invoice_created', 'purchase_invoice_created', 'dispatch_confirmed', 'receipt_confirmed',
  'customer_payment', 'supplier_payment', 'sales_return_created', 'purchase_return_created', 'shortage_reported',
  'assignment_made', 'team_activity',
  'warehouse_dispatch_needed', 'warehouse_receipt_needed', 'warehouse_task_cancelled',
  'rep_invoice_created', 'rep_dispatch_update', 'rep_payment', 'rep_return', 'shortage_status',
  'rep_customer_assigned', 'rep_customer_unassigned', 'rep_customer_updated', 'rep_invoice_assigned', 'rep_invoice_unassigned', 'rep_record_update',
  'role_changed'));

create or replace function _notif_type_visible(p_org uuid, p_type text) returns boolean
language sql stable security definer set search_path = public as $$
  select case
    when p_type = 'role_changed' then my_role_key(p_org) is not null
    else case my_role_key(p_org)
      when 'owner'     then true
      when 'sales'     then p_type in ('rep_invoice_created', 'rep_dispatch_update', 'rep_payment', 'rep_return', 'shortage_status',
                                       'rep_customer_assigned', 'rep_customer_unassigned', 'rep_customer_updated', 'rep_invoice_assigned', 'rep_invoice_unassigned', 'rep_record_update')
      when 'warehouse' then p_type in ('warehouse_dispatch_needed', 'warehouse_receipt_needed', 'warehouse_task_cancelled')
      else false
    end
  end
$$;
revoke all on function _notif_type_visible(uuid, text) from public, anon;
grant execute on function _notif_type_visible(uuid, text) to authenticated;

-- null = any active member
create or replace function _ntf_required_role(p_type text) returns text
language sql immutable as $$
  select case
    when p_type = 'role_changed' then null
    when p_type in ('warehouse_dispatch_needed', 'warehouse_receipt_needed', 'warehouse_task_cancelled') then 'warehouse'
    when p_type in ('rep_invoice_created', 'rep_dispatch_update', 'rep_payment', 'rep_return', 'shortage_status',
                    'rep_customer_assigned', 'rep_customer_unassigned', 'rep_customer_updated', 'rep_invoice_assigned', 'rep_invoice_unassigned', 'rep_record_update') then 'sales'
    else 'owner' end
$$;
revoke all on function _ntf_required_role(text) from public, anon, authenticated;

-- storekeeper payloads: items + quantities only (now also a `released` list for cancelled quantities)
create or replace function _ntf_warehouse_payload_ok(p jsonb) returns boolean
language plpgsql immutable as $$
declare k text; l jsonb;
begin
  if jsonb_typeof(p) <> 'object' then return false; end if;
  for k in select jsonb_object_keys(p) loop
    if k not in ('invoice_number', 'warehouse', 'kind', 'status', 'lines', 'released') then return false; end if;
  end loop;
  if p ? 'lines' then
    if jsonb_typeof(p->'lines') <> 'array' then return false; end if;
    for l in select * from jsonb_array_elements(p->'lines') loop
      for k in select jsonb_object_keys(l) loop
        if k not in ('name', 'unit', 'ordered', 'remaining') then return false; end if;
      end loop;
    end loop;
  end if;
  if p ? 'released' then
    if jsonb_typeof(p->'released') <> 'array' then return false; end if;
    for l in select * from jsonb_array_elements(p->'released') loop
      for k in select jsonb_object_keys(l) loop
        if k not in ('name', 'unit', 'qty') then return false; end if;
      end loop;
    end loop;
  end if;
  return true;
end $$;
revoke all on function _ntf_warehouse_payload_ok(jsonb) from public, anon, authenticated;

create or replace function _ntf_send(
  p_org uuid, p_user uuid, p_actor uuid, p_type text, p_title text, p_href text,
  p_entity_type text, p_entity_id uuid, p_payload jsonb, p_key text
) returns boolean
language plpgsql security definer set search_path = public as $$
declare v_role text; v_need text := _ntf_required_role(p_type); v_n int;
begin
  if p_user is null or p_user is not distinct from p_actor then return false; end if;      -- never notify someone about his own action
  v_role := _ntf_role_of(p_org, p_user);
  if v_role is null then return false; end if;                                              -- not an active member
  if v_need is not null and v_role is distinct from v_need then return false; end if;       -- wrong role for this type: dropped
  if v_need = 'warehouse' and not _ntf_warehouse_payload_ok(coalesce(p_payload, '{}'::jsonb)) then
    raise exception 'storekeeper notification payload carries a non-whitelisted field';
  end if;
  insert into notifications (organization_id, recipient_user_id, type, title, href, entity_type, entity_id, payload, dedupe_key)
  values (p_org, p_user, p_type, left(p_title, 200), p_href, p_entity_type, p_entity_id, coalesce(p_payload, '{}'::jsonb), p_key)
  on conflict (organization_id, recipient_user_id, dedupe_key) do nothing;
  get diagnostics v_n = row_count;
  return v_n > 0;
end $$;
revoke all on function _ntf_send(uuid, uuid, uuid, text, text, text, text, uuid, jsonb, text) from public, anon, authenticated;

-- failure outbox: new kinds
alter table notification_failures drop constraint if exists notification_failures_kind_check;
alter table notification_failures add constraint notification_failures_kind_check check (kind in (
  'sales_invoice', 'purchase_invoice', 'fulfilment_event', 'customer_collection', 'supplier_payment',
  'sales_return', 'purchase_return', 'shortage_insert', 'shortage_update',
  'customer_assign', 'customer_update', 'invoice_assign', 'rep_record', 'member_event', 'release_event'));

-- ============================================================
-- 4. Builders
-- ============================================================
-- 4a. A customer was assigned to / taken from a rep
create or replace function _ntf_build_customer_assign(p_customer uuid, p_old_rep uuid, p_new_rep uuid, p_actor uuid, p_stamp text) returns void
language plpgsql security definer set search_path = public as $$
declare
  c customers%rowtype; v_by text;
  v_new_name text; v_new_user uuid; v_old_name text; v_old_user uuid; v_new_label text; v_old_label text; v_found boolean;
begin
  select * into c from customers where id = p_customer;
  if not found then return; end if;
  v_by := _ntf_actor_label(c.organization_id, p_actor);
  if p_new_rep is not null then
    select sr.name, sr.user_id into v_new_name, v_new_user from sales_representatives sr where sr.id = p_new_rep and sr.organization_id = c.organization_id;
    v_new_label := _ntf_person_label(c.organization_id, v_new_user, v_new_name);
  end if;
  if p_old_rep is not null then
    select true, sr.name, sr.user_id into v_found, v_old_name, v_old_user from sales_representatives sr where sr.id = p_old_rep and sr.organization_id = c.organization_id;
    v_old_label := _ntf_person_label(c.organization_id, v_old_user, v_old_name);
  end if;
  -- the rep record was deleted (FK set null): nothing was "assigned", nobody to tell
  if p_new_rep is null and v_found is not true then return; end if;

  if p_new_rep is not null then
    perform _ntf_send(c.organization_id, v_new_user, p_actor, 'rep_customer_assigned', 'تم تعيين العميل ' || c.name || ' لك',
      '/dashboard/customers', 'customer', c.id,
      jsonb_build_object('customer', c.name, 'by', v_by, 'rep', v_new_label),
      'cust-assign:' || c.id || ':' || p_new_rep || ':' || p_stamp);
  end if;
  if p_old_rep is not null and p_old_rep is distinct from p_new_rep then
    perform _ntf_send(c.organization_id, v_old_user, p_actor, 'rep_customer_unassigned', 'تم إلغاء تعيين العميل ' || c.name || ' من عندك',
      '/dashboard/customers', 'customer', c.id,
      jsonb_build_object('customer', c.name, 'by', v_by, 'rep', v_old_label),      -- the old rep is never told who took the customer
      'cust-unassign:' || c.id || ':' || p_old_rep || ':' || p_stamp);
  end if;
  perform _ntf_to_owners(c.organization_id, p_actor, 'assignment_made',
    case when p_new_rep is not null then 'تم تعيين العميل ' || c.name || ' للمندوب ' || coalesce(v_new_name, '') else 'تم إلغاء تعيين مندوب العميل ' || c.name end,
    '/dashboard/customers', 'customer', c.id,
    jsonb_build_object('customer', c.name, 'rep', v_new_label, 'old_rep', v_old_label, 'by', v_by),
    'cust-assign-owner:' || c.id || ':' || coalesce(p_new_rep::text, 'none') || ':' || p_stamp);
end $$;

-- 4a'. The customer's own data was edited / the customer was deleted: the assigned rep is told WHAT changed
-- (field names only — never values), and who did it.  Fields: name, phone, type, price tier, credit status.
create or replace function _ntf_build_customer_update(p_customer uuid, p_fields jsonb, p_deleted boolean, p_rep uuid, p_name text, p_actor uuid, p_stamp text) returns void
language plpgsql security definer set search_path = public as $$
declare v_org uuid; v_rep_user uuid; v_by text; v_name text := p_name;
begin
  select sr.organization_id, sr.user_id into v_org, v_rep_user from sales_representatives sr where sr.id = p_rep;
  if v_org is null then return; end if;
  if not p_deleted then select c.name into v_name from customers c where c.id = p_customer; end if;
  v_by := _ntf_actor_label(v_org, p_actor);
  perform _ntf_send(v_org, v_rep_user, p_actor, 'rep_customer_updated',
    case when p_deleted then 'تم حذف العميل ' || coalesce(v_name, '') else 'تم تعديل بيانات العميل ' || coalesce(v_name, '') end,
    case when p_deleted then '/dashboard/customers' else '/dashboard/customers?q=' || coalesce(v_name, '') end, 'customer', p_customer,
    jsonb_build_object('customer', v_name, 'fields', p_fields, 'deleted', p_deleted, 'by', v_by),
    'cust-update:' || p_customer || ':' || p_stamp);
end $$;

-- 4b. An invoice moved to another rep
create or replace function _ntf_build_invoice_assign(p_invoice uuid, p_old_rep uuid, p_new_rep uuid, p_actor uuid, p_stamp text) returns void
language plpgsql security definer set search_path = public as $$
declare
  i sales_invoices%rowtype; v_no text; v_cust text; v_by text;
  v_new_name text; v_new_user uuid; v_old_name text; v_old_user uuid; v_new_label text; v_old_label text; v_found boolean;
begin
  select * into i from sales_invoices where id = p_invoice;
  if not found then return; end if;
  v_no := _ntf_invoice_no('sales', i.id);
  select c.name into v_cust from customers c where c.id = i.customer_id;
  v_by := _ntf_actor_label(i.organization_id, p_actor);
  if p_new_rep is not null then
    select sr.name, sr.user_id into v_new_name, v_new_user from sales_representatives sr where sr.id = p_new_rep and sr.organization_id = i.organization_id;
    v_new_label := _ntf_person_label(i.organization_id, v_new_user, v_new_name);
  end if;
  if p_old_rep is not null then
    select true, sr.name, sr.user_id into v_found, v_old_name, v_old_user from sales_representatives sr where sr.id = p_old_rep and sr.organization_id = i.organization_id;
    v_old_label := _ntf_person_label(i.organization_id, v_old_user, v_old_name);
  end if;
  if p_new_rep is null and v_found is not true then return; end if;

  if p_new_rep is not null then
    perform _ntf_send(i.organization_id, v_new_user, p_actor, 'rep_invoice_assigned', 'تم تعيين فاتورة البيع ' || v_no || ' لك',
      '/dashboard/sales?q=' || v_no, 'sales_invoice', i.id,
      jsonb_build_object('invoice_number', v_no, 'customer', v_cust, 'total', i.total, 'by', v_by),
      'inv-assign:' || i.id || ':' || p_new_rep || ':' || p_stamp);
  end if;
  if p_old_rep is not null and p_old_rep is distinct from p_new_rep then
    perform _ntf_send(i.organization_id, v_old_user, p_actor, 'rep_invoice_unassigned', 'تم إلغاء تعيين فاتورة البيع ' || v_no || ' من عندك',
      '/dashboard/sales', 'sales_invoice', i.id,
      jsonb_build_object('invoice_number', v_no, 'customer', v_cust, 'by', v_by),
      'inv-unassign:' || i.id || ':' || p_old_rep || ':' || p_stamp);
  end if;
  perform _ntf_to_owners(i.organization_id, p_actor, 'assignment_made',
    'تم تغيير مندوب فاتورة البيع ' || v_no,
    '/dashboard/sales?q=' || v_no, 'sales_invoice', i.id,
    jsonb_build_object('invoice_number', v_no, 'customer', v_cust, 'rep', v_new_label, 'old_rep', v_old_label, 'by', v_by),
    'inv-assign-owner:' || i.id || ':' || coalesce(p_new_rep::text, 'none') || ':' || p_stamp);
end $$;

-- 4c. The rep record itself: linked / unlinked to a login, activated / deactivated, commission or target terms changed.
-- p_user = the login to tell (for "unlinked" it is the PREVIOUS login).
create or replace function _ntf_build_rep_record(p_rep uuid, p_action text, p_user uuid, p_actor uuid, p_stamp text) returns void
language plpgsql security definer set search_path = public as $$
declare sr sales_representatives%rowtype; v_by text; v_label text; v_title text; v_owner_title text;
begin
  select * into sr from sales_representatives where id = p_rep;
  if not found then return; end if;
  v_by := _ntf_actor_label(sr.organization_id, p_actor);
  v_label := _ntf_person_label(sr.organization_id, coalesce(p_user, sr.user_id), sr.name);
  v_title := case p_action
    when 'linked'      then 'تم ربط حسابك بسجل المندوب «' || sr.name || '»'
    when 'unlinked'    then 'تم فصل حسابك عن سجل المندوب «' || sr.name || '»'
    when 'activated'   then 'تم تفعيل سجل المندوب الخاص بك'
    when 'deactivated' then 'تم إيقاف سجل المندوب الخاص بك'
    when 'terms'       then 'تم تعديل شروط عمولتك أو هدفك الشهري'
    else 'تم تعديل سجل المندوب الخاص بك' end;
  v_owner_title := case p_action
    when 'linked'      then 'تم ربط ' || coalesce(v_label, sr.name) || ' بسجل مندوب'
    when 'unlinked'    then 'تم فصل ' || coalesce(v_label, sr.name) || ' عن سجل مندوب'
    when 'activated'   then 'تم تفعيل المندوب ' || sr.name
    when 'deactivated' then 'تم إيقاف المندوب ' || sr.name
    when 'terms'       then 'تم تعديل شروط المندوب ' || sr.name
    else 'تم تعديل المندوب ' || sr.name end;
  perform _ntf_send(sr.organization_id, p_user, p_actor, 'rep_record_update', v_title, '/dashboard/customers', 'sales_rep', sr.id,
    jsonb_build_object('action', p_action, 'rep', v_label, 'by', v_by),
    'rep-record:' || p_action || ':' || sr.id || ':' || coalesce(p_user::text, 'none') || ':' || p_stamp);
  perform _ntf_to_owners(sr.organization_id, p_actor, 'team_activity', v_owner_title, '/dashboard/representatives', 'sales_rep', sr.id,
    jsonb_build_object('action', 'rep_' || p_action, 'member', v_label, 'by', v_by),
    'rep-record-owner:' || p_action || ':' || sr.id || ':' || p_stamp);
end $$;

-- 4d. Team: invited / joined / declined / removed / role changed.  p_args: {name, from_role, to_role}
create or replace function _ntf_build_member_event(p_org uuid, p_user uuid, p_action text, p_actor uuid, p_args jsonb, p_stamp text) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_label text; v_by text; v_from text; v_to text; v_title text;
begin
  v_label := coalesce(_ntf_person_label(p_org, p_user, p_args->>'name'),
                      nullif(btrim(coalesce(p_args->>'name', '')), ''), 'عضو');
  -- the membership row may already be gone (removed / declined): the name travels in p_args
  if not exists (select 1 from organization_users where organization_id = p_org and user_id = p_user) then
    select coalesce(nullif(btrim(coalesce(p_args->>'name', '')), '') || ' (' || u.email::text || ')', u.email::text, v_label)
    into v_label from auth.users u where u.id = p_user;
  end if;
  v_by := _ntf_actor_label(p_org, p_actor);
  select r.name into v_from from roles r where r.id = nullif(p_args->>'from_role', '')::uuid;
  select r.name into v_to   from roles r where r.id = nullif(p_args->>'to_role', '')::uuid;

  v_title := case p_action
    when 'invited'      then 'تمت دعوة ' || v_label || ' بدور ' || coalesce(v_to, '')
    when 'joined'       then 'انضم ' || v_label || ' بدور ' || coalesce(v_to, '')
    when 'declined'     then 'رفض ' || v_label || ' الدعوة'
    when 'removed'      then 'تمت إزالة ' || v_label || ' من الفريق'
    when 'role_changed' then 'تم تغيير دور ' || v_label || ' إلى ' || coalesce(v_to, '')
    else 'تحديث في الفريق: ' || v_label end;

  perform _ntf_to_owners(p_org, p_actor, 'team_activity', v_title, '/dashboard/settings/team', 'member', p_user,
    jsonb_build_object('action', p_action, 'member', v_label, 'role', v_to, 'from', v_from, 'to', v_to, 'by', v_by),
    'member:' || p_action || ':' || p_user || ':' || p_stamp);

  if p_action = 'role_changed' then
    perform _ntf_send(p_org, p_user, p_actor, 'role_changed', 'تم تغيير دورك إلى ' || coalesce(v_to, ''), null, 'member', p_user,
      jsonb_build_object('from', v_from, 'to', v_to, 'by', v_by),
      'member-role:' || p_user || ':' || p_stamp);
  end if;
end $$;

-- 4e. A return cancelled quantities the storekeeper was asked to dispatch / receive
create or replace function _ntf_build_release_event(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare
  e fulfilment_events%rowtype; v_first uuid; v_no text; v_wh text; v_released jsonb; v_status text; v_title text;
begin
  select * into e from fulfilment_events where id = p_id;
  if not found or e.event_type <> 'release' then return; end if;
  select x.id into v_first from fulfilment_events x where x.confirmation_id = e.confirmation_id and x.event_type = 'release' order by x.id limit 1;
  if v_first is distinct from e.id then return; end if;                       -- one notification per return, composed by its first line

  v_no := _ntf_invoice_no(e.kind, e.invoice_id);
  select coalesce(jsonb_agg(jsonb_build_object('name', p.name, 'unit', p.unit, 'qty', q.qty) order by p.name), '[]'::jsonb) into v_released
  from (select product_id, sum(quantity) qty from fulfilment_events where confirmation_id = e.confirmation_id and event_type = 'release' group by product_id) q
  join products p on p.id = q.product_id;
  if e.kind = 'sales' then
    select w.name, i.dispatch_status into v_wh, v_status from sales_invoices i left join warehouses w on w.id = i.warehouse_id where i.id = e.invoice_id;
    v_title := 'أُلغيت كميات من فاتورة البيع ' || v_no || ' بمرتجع — لا تصرفها';
  else
    select w.name, i.receipt_status into v_wh, v_status from purchase_invoices i left join warehouses w on w.id = i.warehouse_id where i.id = e.invoice_id;
    v_title := 'أُلغيت كميات من فاتورة الشراء ' || v_no || ' بمرتجع — لا تستلمها';
  end if;
  perform _ntf_to_storekeepers(e.organization_id, e.confirmed_by, 'warehouse_task_cancelled', v_title,
    '/dashboard/warehouse-orders?tab=' || e.kind || '&status=open&q=' || v_no, e.kind, e.invoice_id,
    jsonb_build_object('invoice_number', v_no, 'warehouse', v_wh, 'kind', e.kind, 'status', v_status, 'released', v_released),
    'release:' || e.confirmation_id);
end $$;

revoke all on function _ntf_build_customer_update(uuid, jsonb, boolean, uuid, text, uuid, text), _ntf_build_customer_assign(uuid, uuid, uuid, uuid, text), _ntf_build_invoice_assign(uuid, uuid, uuid, uuid, text),
  _ntf_build_rep_record(uuid, text, uuid, uuid, text), _ntf_build_member_event(uuid, uuid, text, uuid, jsonb, text),
  _ntf_build_release_event(uuid) from public, anon, authenticated;

-- retry dispatcher knows the new kinds
create or replace function _ntf_run_failure(f notification_failures) returns void
language plpgsql security definer set search_path = public as $$
begin
  case f.kind
    when 'sales_invoice'       then perform _ntf_build_sales_invoice(f.ref_id);
    when 'purchase_invoice'    then perform _ntf_build_purchase_invoice(f.ref_id);
    when 'fulfilment_event'    then perform _ntf_build_fulfilment_event(f.ref_id);
    when 'customer_collection' then perform _ntf_build_customer_collection(f.ref_id, coalesce((f.args->>'initial')::boolean, false));
    when 'supplier_payment'    then perform _ntf_build_supplier_payment(f.ref_id, coalesce((f.args->>'initial')::boolean, false));
    when 'sales_return'        then perform _ntf_build_sales_return(f.ref_id);
    when 'purchase_return'     then perform _ntf_build_purchase_return(f.ref_id);
    when 'shortage_insert'     then perform _ntf_build_shortage_insert(f.ref_id);
    when 'shortage_update'     then perform _ntf_build_shortage_update(f.ref_id);
    when 'customer_assign'     then perform _ntf_build_customer_assign(f.ref_id, nullif(f.args->>'old', '')::uuid, nullif(f.args->>'new', '')::uuid, nullif(f.args->>'actor', '')::uuid, f.args->>'stamp');
    when 'customer_update'     then perform _ntf_build_customer_update(f.ref_id, coalesce(f.args->'fields', '[]'::jsonb), coalesce((f.args->>'deleted')::boolean, false), nullif(f.args->>'rep', '')::uuid, f.args->>'name', nullif(f.args->>'actor', '')::uuid, f.args->>'stamp');
    when 'invoice_assign'      then perform _ntf_build_invoice_assign(f.ref_id, nullif(f.args->>'old', '')::uuid, nullif(f.args->>'new', '')::uuid, nullif(f.args->>'actor', '')::uuid, f.args->>'stamp');
    when 'rep_record'          then perform _ntf_build_rep_record(f.ref_id, f.args->>'action', nullif(f.args->>'user', '')::uuid, nullif(f.args->>'actor', '')::uuid, f.args->>'stamp');
    when 'member_event'        then perform _ntf_build_member_event(f.organization_id, f.ref_id, f.args->>'action', nullif(f.args->>'actor', '')::uuid, f.args, f.args->>'stamp');
    when 'release_event'       then perform _ntf_build_release_event(f.ref_id);
  end case;
end $$;
revoke all on function _ntf_run_failure(notification_failures) from public, anon, authenticated;

-- ============================================================
-- 5. Triggers (thin wrappers: build now, record on failure, never abort the business transaction)
-- ============================================================
-- A failure record is unique per (kind, ref_id) while pending; members/reps can fail more than once, so the
-- ref is the row id and a repeated failure simply keeps the first arguments.

create or replace function _ntf_on_customer_rep() returns trigger language plpgsql security definer set search_path = public as $$
declare v_old uuid; v_stamp text := extract(epoch from now())::text;
begin
  if TG_OP = 'UPDATE' then
    if OLD.sales_rep_id is not distinct from NEW.sales_rep_id then return null; end if;
    v_old := OLD.sales_rep_id;
  elsif NEW.sales_rep_id is null then
    return null;
  end if;
  begin perform _ntf_build_customer_assign(NEW.id, v_old, NEW.sales_rep_id, auth.uid(), v_stamp);
  exception when others then
    perform _ntf_record_failure(NEW.organization_id, 'customer_assign', NEW.id,
      jsonb_build_object('old', v_old, 'new', NEW.sales_rep_id, 'actor', auth.uid(), 'stamp', v_stamp), sqlerrm);
  end;
  return null;
end $$;

create or replace function _ntf_on_customer_update() returns trigger language plpgsql security definer set search_path = public as $$
declare v_stamp text := extract(epoch from now())::text; v_fields jsonb := '[]'::jsonb; v_rep uuid; v_org uuid; v_id uuid; v_name text; v_deleted boolean := (TG_OP = 'DELETE');
begin
  if v_deleted then
    v_rep := OLD.sales_rep_id; v_org := OLD.organization_id; v_id := OLD.id; v_name := OLD.name;
    if not exists (select 1 from organizations o where o.id = v_org) then return null; end if;     -- the whole organization is being deleted
  else
    v_rep := NEW.sales_rep_id; v_org := NEW.organization_id; v_id := NEW.id; v_name := NEW.name;
    if OLD.sales_rep_id is distinct from NEW.sales_rep_id then v_rep := NEW.sales_rep_id; end if;
    if OLD.name is distinct from NEW.name then v_fields := v_fields || to_jsonb('الاسم'::text); end if;
    if OLD.phone is distinct from NEW.phone then v_fields := v_fields || to_jsonb('الهاتف'::text); end if;
    if OLD.customer_type is distinct from NEW.customer_type then v_fields := v_fields || to_jsonb('نوع العميل'::text); end if;
    if OLD.price_tier is distinct from NEW.price_tier then v_fields := v_fields || to_jsonb('شريحة السعر'::text); end if;
    if OLD.credit_status is distinct from NEW.credit_status then v_fields := v_fields || to_jsonb('حالة الائتمان'::text); end if;
    if jsonb_array_length(v_fields) = 0 then return null; end if;
  end if;
  if v_rep is null then return null; end if;
  begin perform _ntf_build_customer_update(v_id, v_fields, v_deleted, v_rep, v_name, auth.uid(), v_stamp);
  exception when others then
    perform _ntf_record_failure(v_org, 'customer_update', v_id,
      jsonb_build_object('fields', v_fields, 'deleted', v_deleted, 'rep', v_rep, 'name', v_name, 'actor', auth.uid(), 'stamp', v_stamp), sqlerrm);
  end;
  return null;
end $$;

create or replace function _ntf_on_invoice_rep() returns trigger language plpgsql security definer set search_path = public as $$
declare v_stamp text := extract(epoch from now())::text;
begin
  if OLD.sales_rep_id is not distinct from NEW.sales_rep_id then return null; end if;
  if NEW.created_at = now() then return null; end if;               -- set while the invoice itself was being created
  begin perform _ntf_build_invoice_assign(NEW.id, OLD.sales_rep_id, NEW.sales_rep_id, auth.uid(), v_stamp);
  exception when others then
    perform _ntf_record_failure(NEW.organization_id, 'invoice_assign', NEW.id,
      jsonb_build_object('old', OLD.sales_rep_id, 'new', NEW.sales_rep_id, 'actor', auth.uid(), 'stamp', v_stamp), sqlerrm);
  end;
  return null;
end $$;

create or replace function _ntf_on_rep_record() returns trigger language plpgsql security definer set search_path = public as $$
declare v_stamp text := extract(epoch from now())::text; v_actor uuid := auth.uid();
begin
  begin
    if TG_OP = 'INSERT' then
      if NEW.user_id is not null then perform _ntf_build_rep_record(NEW.id, 'linked', NEW.user_id, v_actor, v_stamp); end if;
      return null;
    end if;
    if OLD.user_id is distinct from NEW.user_id then
      if OLD.user_id is not null then perform _ntf_build_rep_record(NEW.id, 'unlinked', OLD.user_id, v_actor, v_stamp); end if;
      if NEW.user_id is not null then perform _ntf_build_rep_record(NEW.id, 'linked', NEW.user_id, v_actor, v_stamp); end if;
    end if;
    if OLD.is_active is distinct from NEW.is_active and NEW.user_id is not null then
      perform _ntf_build_rep_record(NEW.id, case when NEW.is_active then 'activated' else 'deactivated' end, NEW.user_id, v_actor, v_stamp);
    end if;
    if NEW.user_id is not null and (
         OLD.commission_basis is distinct from NEW.commission_basis or OLD.commission_rate is distinct from NEW.commission_rate
      or OLD.fixed_salary is distinct from NEW.fixed_salary or OLD.transportation_allowance is distinct from NEW.transportation_allowance
      or OLD.monthly_target is distinct from NEW.monthly_target or OLD.min_target_for_commission is distinct from NEW.min_target_for_commission) then
      perform _ntf_build_rep_record(NEW.id, 'terms', NEW.user_id, v_actor, v_stamp);
    end if;
  exception when others then
    perform _ntf_record_failure(NEW.organization_id, 'rep_record', NEW.id,
      jsonb_build_object('action', case when TG_OP = 'INSERT' then 'linked' else 'terms' end, 'user', NEW.user_id, 'actor', v_actor, 'stamp', v_stamp), sqlerrm);
  end;
  return null;
end $$;

create or replace function _ntf_on_member() returns trigger language plpgsql security definer set search_path = public as $$
declare v_stamp text := extract(epoch from now())::text; v_actor uuid := auth.uid(); v_action text; v_args jsonb; v_org uuid; v_user uuid;
begin
  if TG_OP = 'DELETE' then
    v_org := OLD.organization_id; v_user := OLD.user_id;
    if not exists (select 1 from organizations o where o.id = v_org) then return null; end if;      -- the whole organization is being deleted
    v_action := case when OLD.status = 'invited' and v_actor is not distinct from OLD.user_id then 'declined' else 'removed' end;
    v_args := jsonb_build_object('action', v_action, 'actor', v_actor, 'stamp', v_stamp, 'name', OLD.display_name, 'to_role', OLD.role_id);
  elsif TG_OP = 'INSERT' then
    v_org := NEW.organization_id; v_user := NEW.user_id;
    if NEW.status <> 'invited' then return null; end if;
    v_action := 'invited';
    v_args := jsonb_build_object('action', v_action, 'actor', v_actor, 'stamp', v_stamp, 'name', NEW.display_name, 'to_role', NEW.role_id);
  else
    v_org := NEW.organization_id; v_user := NEW.user_id;
    if OLD.status = 'invited' and NEW.status = 'active' then
      v_action := 'joined';
      v_args := jsonb_build_object('action', v_action, 'actor', v_actor, 'stamp', v_stamp, 'name', NEW.display_name, 'to_role', NEW.role_id);
    elsif OLD.role_id is distinct from NEW.role_id then
      v_action := 'role_changed';
      v_args := jsonb_build_object('action', v_action, 'actor', v_actor, 'stamp', v_stamp, 'name', NEW.display_name, 'from_role', OLD.role_id, 'to_role', NEW.role_id);
    else
      return null;
    end if;
  end if;
  begin perform _ntf_build_member_event(v_org, v_user, v_action, v_actor, v_args, v_stamp);
  exception when others then
    perform _ntf_record_failure(v_org, 'member_event', v_user, v_args, sqlerrm);
  end;
  return null;
end $$;

create or replace function _ntf_on_release_event() returns trigger language plpgsql security definer set search_path = public as $$
begin
  begin perform _ntf_build_release_event(NEW.id);
  exception when others then perform _ntf_record_failure(NEW.organization_id, 'release_event', NEW.id, '{}', sqlerrm); end;
  return null;
end $$;

revoke all on function _ntf_on_customer_rep(), _ntf_on_customer_update(), _ntf_on_invoice_rep(), _ntf_on_rep_record(), _ntf_on_member(), _ntf_on_release_event() from public, anon, authenticated;

drop trigger if exists z_notify_rep on customers;
create trigger z_notify_rep after insert or update of sales_rep_id on customers for each row execute function _ntf_on_customer_rep();

drop trigger if exists z_notify_upd on customers;
create trigger z_notify_upd after update of name, phone, customer_type, price_tier, credit_status on customers for each row execute function _ntf_on_customer_update();
drop trigger if exists z_notify_del on customers;
create trigger z_notify_del after delete on customers for each row execute function _ntf_on_customer_update();

drop trigger if exists z_notify_rep on sales_invoices;
create trigger z_notify_rep after update of sales_rep_id on sales_invoices for each row execute function _ntf_on_invoice_rep();

drop trigger if exists z_notify_ins on sales_representatives;
create trigger z_notify_ins after insert on sales_representatives for each row execute function _ntf_on_rep_record();
drop trigger if exists z_notify_upd on sales_representatives;
create trigger z_notify_upd after update of user_id, is_active, commission_basis, commission_rate, fixed_salary, transportation_allowance, monthly_target, min_target_for_commission
  on sales_representatives for each row execute function _ntf_on_rep_record();

drop trigger if exists z_notify on organization_users;
create trigger z_notify after insert or delete or update of status, role_id on organization_users for each row execute function _ntf_on_member();

-- deferred like the confirm notifications: the returned lines of one return are all in by COMMIT
drop trigger if exists z_notify_release on fulfilment_events;
create constraint trigger z_notify_release after insert on fulfilment_events deferrable initially deferred for each row
  when (NEW.event_type = 'release') execute function _ntf_on_release_event();

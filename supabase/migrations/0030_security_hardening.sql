-- Kayan — Phase 30: security hardening (fixes verified against live exploits)
-- Apply AFTER 0029. Review section 5 (finance read gates) against your UI before shipping.

-- ============================================================
-- 1. CRITICAL — permission catalog was world-writable (no RLS).
--    Anyone with the public anon key / any signed-up user could INSERT/DELETE
--    role_permissions rows of the SHARED system roles => platform-wide privilege escalation.
-- ============================================================
alter table permissions      enable row level security;
alter table role_permissions enable row level security;
alter table permissions      force  row level security;
alter table role_permissions force  row level security;

drop policy if exists permissions_read      on permissions;
drop policy if exists role_permissions_read on role_permissions;
create policy permissions_read      on permissions      for select to authenticated using (true);
create policy role_permissions_read on role_permissions for select to authenticated using (true);

revoke all on permissions, role_permissions from public, anon, authenticated;
grant select on permissions, role_permissions to authenticated;

-- ============================================================
-- 2. HIGH — functions callable by anon / authenticated that must be internal.
--    `alter default privileges ... IN SCHEMA public revoke ... from public` does NOT remove
--    Postgres' global PUBLIC EXECUTE default, so every function created without an explicit
--    REVOKE (find_user_id_by_email, trigger fns, helpers) was exposed through /rpc.
-- ============================================================
revoke execute on function find_user_id_by_email(text) from public, anon, authenticated;

do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')   -- skip extension fns (pg_trgm)
  loop
    execute format('revoke execute on function %s from public, anon', r.sig);
  end loop;
end $$;

-- future functions: no implicit EXECUTE for anyone (every migration already GRANTs explicitly)
alter default privileges revoke execute on functions from public;
alter default privileges for role postgres in schema public revoke execute on functions from anon, authenticated, public;

-- ============================================================
-- 3. HIGH — NaN / Infinity poisoning. `NaN <= 0` is FALSE and `NaN > 0` is TRUE in Postgres,
--    so every `quantity > 0`, `price >= 0` check passes. One NaN makes sum() NaN for the whole tenant.
--    Enforced at the storage layer so no RPC can bypass it.
-- ============================================================
do $$
declare r record;
begin
  for r in
    select c.relname, a.attname
    from pg_attribute a
    join pg_class c on c.oid = a.attrelid
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind = 'r'
      and a.attnum > 0 and not a.attisdropped
      and a.atttypid = 'numeric'::regtype
  loop
    continue when exists (select 1 from pg_constraint where conrelid = format('public.%I', r.relname)::regclass
                          and conname = 'finite_' || substr(md5(r.relname || r.attname), 1, 12));
    execute format(
      'alter table public.%I add constraint %I check (%I is null or (%I <> ''NaN''::numeric and %I <> ''Infinity''::numeric and %I <> ''-Infinity''::numeric)) not valid',
      r.relname, 'finite_' || substr(md5(r.relname || r.attname), 1, 12), r.attname, r.attname, r.attname, r.attname);
  end loop;
end $$;

-- ============================================================
-- 4. HIGH — forced tenant enrolment. add_team_member / complete_team_invite put ANY existing user
--    (or any raw uuid) into the caller's org as ACTIVE with no consent. Combined with
--    getMembership() `.limit(1)` and `.maybeSingle()` in every action, that misdirects or locks out victims.
--    Fix: enrol as 'invited'; the user must accept. Users can always leave / decline.
-- ============================================================
create or replace function add_team_member(org_id uuid, p_email text, p_role_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_user_id uuid;
begin
  if auth.uid() is null then raise exception 'يجب تسجيل الدخول أولاً'; end if;
  if not has_permission(org_id, 'manage_settings') then raise exception 'ليس لديك صلاحية إضافة أعضاء'; end if;
  if coalesce(trim(p_email), '') = '' then raise exception 'البريد الإلكتروني مطلوب'; end if;
  if not exists (select 1 from roles where id = p_role_id and (organization_id is null or organization_id = org_id)) then
    raise exception 'الدور المختار غير صحيح';
  end if;
  v_user_id := find_user_id_by_email(p_email);
  -- Do NOT reveal whether the account exists: both branches look the same to the caller.
  if v_user_id is not null and not exists (select 1 from organization_users where organization_id = org_id and user_id = v_user_id) then
    insert into organization_users (organization_id, user_id, role_id, status) values (org_id, v_user_id, p_role_id, 'invited');
  end if;
  return jsonb_build_object('status', case when v_user_id is null then 'needs_invite' else 'added' end);
end $$;

create or replace function complete_team_invite(org_id uuid, p_user_id uuid, p_role_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'يجب تسجيل الدخول أولاً'; end if;
  if not has_permission(org_id, 'manage_settings') then raise exception 'ليس لديك صلاحية إضافة أعضاء'; end if;
  if not exists (select 1 from roles where id = p_role_id and (organization_id is null or organization_id = org_id)) then
    raise exception 'الدور المختار غير صحيح';
  end if;
  insert into organization_users (organization_id, user_id, role_id, status)
  values (org_id, p_user_id, p_role_id, 'invited')
  on conflict do nothing;
end $$;

create or replace function accept_org_invite(p_org uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'يجب تسجيل الدخول أولاً'; end if;
  update organization_users set status = 'active'
  where organization_id = p_org and user_id = auth.uid() and status = 'invited';
  if not found then raise exception 'لا توجد دعوة معلقة'; end if;
end $$;
revoke all on function accept_org_invite(uuid) from public, anon;
grant execute on function accept_org_invite(uuid) to authenticated;

-- a user can always decline an invite or leave (owners are still protected by protect_org_owners)
drop policy if exists org_users_self_leave on organization_users;
create policy org_users_self_leave on organization_users for delete using (user_id = auth.uid());

-- cap organisations one account may own (free-signup org spam)
create or replace function limit_owned_orgs() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from roles where id = NEW.role_id and key = 'owner' and organization_id is null)
     and (select count(*) from organization_users ou join roles r on r.id = ou.role_id
          where ou.user_id = NEW.user_id and r.key = 'owner' and r.organization_id is null) >= 3 then
    raise exception 'تم الوصول إلى الحد الأقصى لعدد المؤسسات لكل حساب';
  end if;
  return NEW;
end $$;
drop trigger if exists limit_owned_orgs on organization_users;
create trigger limit_owned_orgs before insert on organization_users for each row execute function limit_owned_orgs();

-- ============================================================
-- 5. HIGH — financial tables readable by every member. RESTRICTIVE gates (AND-ed with the
--    existing policies). Anyone without view_financial / treasury.manage (warehouse, plain sales,
--    custom roles) can no longer read treasury, expenses, partner draws, purchases, supplier payments.
--    !! Check your screens: roles that legitimately need these tables must hold one of these permissions.
-- ============================================================
create or replace function finance_org_ids() returns setof uuid
language sql security definer stable set search_path = public as $$
  select ou.organization_id
  from organization_users ou join role_permissions rp on rp.role_id = ou.role_id
  where ou.user_id = auth.uid() and ou.status = 'active'
    and rp.permission_key in ('view_financial', 'treasury.manage')
$$;
create or replace function purchasing_org_ids() returns setof uuid
language sql security definer stable set search_path = public as $$
  select ou.organization_id
  from organization_users ou join role_permissions rp on rp.role_id = ou.role_id
  where ou.user_id = auth.uid() and ou.status = 'active'
    and rp.permission_key in ('view_financial', 'treasury.manage', 'purchases.create', 'purchases.approve')
$$;
revoke all on function finance_org_ids(), purchasing_org_ids() from public, anon;
grant execute on function finance_org_ids(), purchasing_org_ids() to authenticated;

do $$
declare t text;
begin
  foreach t in array array['treasury_accounts','treasury_movements','expenses','partners','partner_withdrawals','other_balances']
  loop
    execute format('drop policy if exists fin_gate on %I', t);
    execute format('create policy fin_gate on %I as restrictive for select using (organization_id in (select finance_org_ids()))', t);
  end loop;
  foreach t in array array['purchase_invoices','purchase_invoice_items','purchase_returns','purchase_return_items','supplier_payments']
  loop
    execute format('drop policy if exists purch_gate on %I', t);
    execute format('create policy purch_gate on %I as restrictive for select using (organization_id in (select purchasing_org_ids()))', t);
  end loop;
end $$;

-- ============================================================
-- 6. MEDIUM — master data (customers, suppliers, prices) editable by ANY member, unaudited.
--    Writes need a real permission; changes are audited.
-- ============================================================
do $$
declare t text;
begin
  foreach t in array array['customers','suppliers']
  loop
    execute format('drop policy if exists wr_gate_upd on %I', t);
    execute format($p$create policy wr_gate_upd on %I as restrictive for update
      using (has_permission(organization_id, 'sales.edit') or has_permission(organization_id, 'purchases.create') or has_permission(organization_id, 'manage_settings') or has_permission(organization_id, 'sales.create'))$p$, t);
  end loop;
end $$;
drop policy if exists wr_gate_upd on product_prices;
create policy wr_gate_upd on product_prices as restrictive for update
  using (has_permission(organization_id, 'manage_settings') or has_permission(organization_id, 'purchases.approve') or has_permission(organization_id, 'sales.edit'));

drop trigger if exists audit_customers_upd on customers;
drop trigger if exists audit_suppliers_upd on suppliers;
drop trigger if exists audit_prices_upd    on product_prices;
create trigger audit_customers_upd after update on customers     for each row when (OLD.* is distinct from NEW.*) execute function audit_row_change('customer', '');
create trigger audit_suppliers_upd after update on suppliers     for each row when (OLD.* is distinct from NEW.*) execute function audit_row_change('supplier', '');
create trigger audit_prices_upd    after update on product_prices for each row when (OLD.* is distinct from NEW.*) execute function audit_row_change('product_price', '');

-- ============================================================
-- 7. MEDIUM — attachments bucket: no size / MIME limits.
-- ============================================================
update storage.buckets
set file_size_limit = 10485760,
    allowed_mime_types = array['image/jpeg','image/png','image/webp','application/pdf']
where id = 'attachments';

-- ============================================================
-- 8. An invited user must be able to SEE their own pending invitation (to accept/decline it).
-- ============================================================
drop policy if exists org_users_self_select on organization_users;
create policy org_users_self_select on organization_users for select using (user_id = auth.uid());

-- ============================================================
-- 9. Invitation helpers for the /invites page.
-- ============================================================
create or replace function list_my_invites()
returns table (organization_id uuid, organization_name text, role_name text)
language sql security definer stable set search_path = public as $$
  select ou.organization_id, o.name, r.name
  from organization_users ou
  join organizations o on o.id = ou.organization_id
  join roles r on r.id = ou.role_id
  where ou.user_id = auth.uid() and ou.status = 'invited'
$$;

create or replace function decline_org_invite(p_org uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'يجب تسجيل الدخول أولاً'; end if;
  delete from organization_users where organization_id = p_org and user_id = auth.uid() and status = 'invited';
end $$;

revoke all on function list_my_invites(), decline_org_invite(uuid) from public, anon;
grant execute on function list_my_invites(), decline_org_invite(uuid) to authenticated;

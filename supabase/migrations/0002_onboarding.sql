-- Kayan — Phase 1: onboarding support
-- Grants default permissions to system role templates, and provides an
-- atomic RPC so "create organization" + "make caller the owner" +
-- "enable selected modules" happen as one transaction instead of three
-- separate client requests racing RLS.

-- Owner: everything. Admin: everything except nothing withheld for now
-- (can be narrowed later once the business defines admin vs owner precisely).
insert into role_permissions (role_id, permission_key)
select r.id, p.key
from roles r, permissions p
where r.key in ('owner', 'admin') and r.organization_id is null
on conflict do nothing;

insert into role_permissions (role_id, permission_key)
select r.id, p.key
from roles r, permissions p
where r.key = 'accountant'
  and r.organization_id is null
  and p.key in ('view_dashboard','view_financial','purchases.create','purchases.approve','treasury.manage','reports.export')
on conflict do nothing;

insert into role_permissions (role_id, permission_key)
select r.id, p.key
from roles r, permissions p
where r.key = 'sales'
  and r.organization_id is null
  and p.key in ('view_dashboard','sales.create')
on conflict do nothing;

insert into role_permissions (role_id, permission_key)
select r.id, p.key
from roles r, permissions p
where r.key = 'warehouse'
  and r.organization_id is null
  and p.key in ('view_dashboard','inventory.adjust')
on conflict do nothing;

-- Atomic onboarding: create the organization, enable the chosen modules,
-- and make the calling user its owner — all in one transaction.
create or replace function create_organization(
  org_name text,
  org_business_type text,
  org_country text,
  org_currency text,
  org_language text,
  module_keys text[]
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  new_org_id uuid;
  owner_role_id uuid;
  mk text;
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;

  insert into organizations (name, business_type, country, currency, language)
  values (org_name, org_business_type, org_country, org_currency, org_language)
  returning id into new_org_id;

  select id into owner_role_id from roles where key = 'owner' and organization_id is null;

  insert into organization_users (organization_id, user_id, role_id, status)
  values (new_org_id, auth.uid(), owner_role_id, 'active');

  foreach mk in array module_keys loop
    insert into organization_modules (organization_id, module_key, enabled)
    values (new_org_id, mk, true)
    on conflict (organization_id, module_key) do nothing;
  end loop;

  return new_org_id;
end;
$$;

grant execute on function create_organization(text, text, text, text, text, text[]) to authenticated;

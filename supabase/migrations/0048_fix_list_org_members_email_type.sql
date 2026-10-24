-- Kayan — 0048: fix "structure of query does not match function result type" in list_org_members.
--
-- Cause: auth.users.email is varchar(255) in Supabase Auth, while list_org_members declares `email text`.
-- A plpgsql RETURN QUERY requires the exact declared types, so the call failed and every screen that lists
-- the team (Settings -> Team, and the representatives page) saw an empty list.
-- Fix: cast the email to text (same as 0044 / 0046 already do). Signature, permissions and logic are unchanged.
-- Safe to re-run.

create or replace function list_org_members(org_id uuid)
returns table (
  user_id uuid,
  email text,
  role_id uuid,
  role_key text,
  role_name text,
  status text,
  joined_at timestamptz,
  is_self boolean
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'يجب تسجيل الدخول أولاً';
  end if;
  if not has_permission(org_id, 'manage_settings') then
    raise exception 'ليس لديك صلاحية عرض أعضاء الفريق';
  end if;

  return query
  select ou.user_id, u.email::text, ou.role_id, r.key::text, r.name::text, ou.status::text, ou.created_at, ou.user_id = auth.uid()
  from organization_users ou
  join auth.users u on u.id = ou.user_id
  join roles r on r.id = ou.role_id
  where ou.organization_id = org_id
  order by ou.created_at;
end;
$$;
revoke all on function list_org_members(uuid) from public, anon;
grant execute on function list_org_members(uuid) to authenticated;

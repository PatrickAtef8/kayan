-- Kayan — Phase 1 fix: table & function grants
-- RLS policies only take effect once the calling role already has the base
-- SQL privilege on the table/function. We wrote policies in 0001/0002 but
-- never granted the underlying privileges to `authenticated` — this is
-- that missing piece.

grant usage on schema public to authenticated;

grant select, insert, update on organizations        to authenticated;
grant select, insert, update, delete on organization_users   to authenticated;
grant select on roles               to authenticated;
grant select on permissions         to authenticated;
grant select on role_permissions    to authenticated;
grant select, insert, update, delete on organization_modules to authenticated;
grant select, insert on audit_logs  to authenticated;

-- Functions used inside policies (is_org_member, has_permission) and the
-- onboarding RPC must also be explicitly executable by authenticated —
-- SECURITY DEFINER changes whose privileges the function body runs with,
-- it doesn't grant anyone the right to call it in the first place.
grant execute on function is_org_member(uuid) to authenticated;
grant execute on function has_permission(uuid, text) to authenticated;
grant execute on function create_organization(text, text, text, text, text, text[]) to authenticated;

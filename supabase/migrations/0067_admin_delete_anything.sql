-- 0067: the platform administrator can DELETE companies and users, whatever they own or did.
--
-- Why this needed a migration: the schema was built so that history cannot be erased (an immutable audit log, "restrict" links between
-- invoices and customers/products, ~25 "created_by → auth.users" links without a delete rule, audit/notification triggers that write rows
-- about the very rows being deleted). The administrator, deliberately, may override all of that — but only through the two functions
-- below (service role only), never from a browser session.
--
--   admin_delete_company(admin, org)  erases the company and everything inside it (members' accounts are NOT deleted, only their membership)
--   admin_delete_user(admin, user)    removes the person's memberships and clears them from every "created by / approved by" column
--                                     (their records stay, attributed to nobody); the Auth account itself is then deleted by the app
--
-- Both run in ONE transaction: if anything cannot be removed, nothing is.
-- Storage files (attachments) of a deleted company are not removed from Storage by this migration.

-- The "created by …" columns that point at auth.users with no delete rule must be able to hold NULL (the person is gone).
-- Primary-key columns are left alone.
do $$
declare r record;
begin
  for r in
    select c.conrelid::regclass as t, a.attname as col
    from pg_constraint c
    join pg_attribute a on a.attrelid = c.conrelid and a.attnum = any (c.conkey)
    where c.contype = 'f' and c.confrelid = 'auth.users'::regclass and c.connamespace = 'public'::regnamespace
      and c.confdeltype in ('a', 'r') and array_length(c.conkey, 1) = 1 and a.attnotnull
      and not exists (select 1 from pg_index i where i.indrelid = c.conrelid and i.indisprimary and a.attnum = any (i.indkey))
  loop
    execute format('alter table %s alter column %I drop not null', r.t, r.col);
  end loop;
end $$;

-- Switch the application triggers of every public table off / on (audit trail, notifications, immutability guards, plan limits…).
-- Referential-integrity triggers are system triggers and stay ON: nothing is ever left dangling.
create or replace function _admin_set_triggers(p_enable boolean) returns void
language plpgsql security definer set search_path = public as $$
declare r record;
begin
  for r in
    select distinct c.oid::regclass as t
    from pg_trigger g join pg_class c on c.oid = g.tgrelid join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and not g.tgisinternal and c.relkind in ('r', 'p')
  loop
    execute format('alter table %s %s trigger user', r.t, case when p_enable then 'enable' else 'disable' end);
  end loop;
end $$;

-- Result: deleted | not_found
create or replace function admin_delete_company(p_admin uuid, p_org uuid) returns text
language plpgsql security definer set search_path = public as $$
declare
  r record; v_name text; v_n bigint; v_pending int; v_progress boolean; v_rounds int := 0;
begin
  select name into v_name from organizations where id = p_org;
  if not found then return 'not_found'; end if;
  perform pg_advisory_xact_lock(hashtextextended('billing:' || p_org::text, 0));
  execute 'set local lock_timeout = ''20s''';

  perform _admin_set_triggers(false);

  -- Children first: a table whose rows are still referenced by another table (restrict / no action) is retried on the next round.
  loop
    v_rounds := v_rounds + 1;
    v_pending := 0; v_progress := false;
    for r in
      select c.oid::regclass as t
      from pg_class c join pg_namespace n on n.oid = c.relnamespace
      join pg_attribute a on a.attrelid = c.oid and a.attname = 'organization_id' and not a.attisdropped
      where n.nspname = 'public' and c.relkind = 'r' and c.relname <> 'organizations'
    loop
      begin
        execute format('delete from %s where organization_id = $1', r.t) using p_org;
        get diagnostics v_n = row_count;
        if v_n > 0 then v_progress := true; end if;
      exception when foreign_key_violation then
        v_pending := v_pending + 1;
      end;
    end loop;
    exit when v_pending = 0 or not v_progress or v_rounds >= 25;
  end loop;

  delete from organizations where id = p_org;   -- anything still inside cascades; a real blocker raises here and undoes everything
  set constraints all immediate;
  perform _admin_set_triggers(true);

  perform admin_audit(p_admin, 'company.delete', 'organization', p_org::text, jsonb_build_object('name', v_name));
  return 'deleted';
end $$;

-- Result: ok. Raises (and undoes everything) if a column that cannot be emptied still points at the person.
create or replace function admin_delete_user(p_admin uuid, p_user uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  r record; v_n bigint; v_left text[] := '{}'; v_orgs int;
begin
  select count(*) into v_orgs from organization_users where user_id = p_user and status <> 'invited';
  execute 'set local lock_timeout = ''20s''';
  perform _admin_set_triggers(false);

  delete from organization_users where user_id = p_user;

  for r in
    select c.conrelid::regclass as t, a.attname as col, a.attnotnull as nn
    from pg_constraint c join pg_attribute a on a.attrelid = c.conrelid and a.attnum = any (c.conkey)
    where c.contype = 'f' and c.confrelid = 'auth.users'::regclass and c.connamespace = 'public'::regnamespace
      and c.confdeltype in ('a', 'r') and array_length(c.conkey, 1) = 1
  loop
    if r.nn then
      execute format('select count(*) from %s where %I = $1', r.t, r.col) into v_n using p_user;
      if v_n > 0 then v_left := v_left || (r.t::text || '.' || r.col); end if;
    else
      execute format('update %s set %I = null where %I = $1', r.t, r.col, r.col) using p_user;
    end if;
  end loop;
  if cardinality(v_left) > 0 then
    raise exception 'admin: cannot clear the user from %', array_to_string(v_left, ', ');
  end if;

  set constraints all immediate;
  perform _admin_set_triggers(true);
  perform admin_audit(p_admin, 'user.detach', 'user', p_user::text, jsonb_build_object('companies', v_orgs));
  return jsonb_build_object('ok', true, 'companies', v_orgs);
end $$;

revoke all on function _admin_set_triggers(boolean), admin_delete_company(uuid, uuid), admin_delete_user(uuid, uuid) from public, anon, authenticated;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    grant execute on function admin_delete_company(uuid, uuid), admin_delete_user(uuid, uuid) to service_role;
  end if;
end $$;

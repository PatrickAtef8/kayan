-- 0066: the PACKAGE decides which modules a company has — not a choice made at sign-up.
--
-- Before: sign-up let the owner tick optional modules (customers, partners, …) before paying. The package then said something else,
--         and a company that had ticked a module its package does not include could not even pay for that package ("fit_failed").
-- Now:    * sign-up asks for no modules (the application passes an empty list);
--         * the moment a license is created, the modules of its package are switched on (and any gated module outside the package
--           is switched off — before a first payment there is nothing paid for yet, so the package is the only authority);
--         * when a package's modules are widened later (admin "apply to existing", complimentary refresh) the NEW modules are
--           switched on; nothing is ever switched off by a later change, and nothing is deleted;
--         * the fit report only judges modules once a license exists (an unpaid company has no entitlement to exceed).
-- Additive / replace-only. Safe to run twice.

create or replace function billing_fit_report(p_org uuid, p_entitlements jsonb) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_allowed  text[] := coalesce(array(select jsonb_array_elements_text(p_entitlements -> 'modules')), '{}');
  v_extra    text[];
  v_max_m    int := nullif(p_entitlements ->> 'max_members', '')::int;
  v_max_w    int := nullif(p_entitlements ->> 'max_warehouses', '')::int;
  v_members  int;
  v_wh       int;
  v_out      jsonb := '[]'::jsonb;
begin
  -- Modules only count against a package once the company HAS a license: before the first payment the package itself decides them.
  if exists (select 1 from organization_licenses l where l.organization_id = p_org) then
    select coalesce(array_agg(m.module_key order by m.module_key), '{}') into v_extra
    from organization_modules m
    where m.organization_id = p_org and m.enabled
      and not (m.module_key = any (billing_ungated_modules()))
      and not (m.module_key = any (v_allowed));
    if cardinality(v_extra) > 0 then
      v_out := v_out || jsonb_build_array(jsonb_build_object('kind', 'modules', 'keys', to_jsonb(v_extra)));
    end if;
  end if;

  select count(*) into v_members from organization_users where organization_id = p_org and status = 'active';
  if v_max_m is not null and v_members > v_max_m then
    v_out := v_out || jsonb_build_array(jsonb_build_object('kind', 'members', 'current', v_members, 'max', v_max_m));
  end if;

  select count(*) into v_wh from warehouses where organization_id = p_org and is_active;
  if v_max_w is not null and v_wh > v_max_w then
    v_out := v_out || jsonb_build_array(jsonb_build_object('kind', 'warehouses', 'current', v_wh, 'max', v_max_w));
  end if;

  return jsonb_build_object('ok', jsonb_array_length(v_out) = 0, 'violations', v_out);
end $$;

create or replace function sync_modules_to_license() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_new text[] := coalesce(array(select jsonb_array_elements_text(NEW.entitlements -> 'modules')), '{}');
  v_old text[];
  v_add text[];
  mk    text;
begin
  if TG_OP = 'INSERT' then
    -- First license: the package is the only authority. Gated modules outside it are switched off (kept in the table, not deleted).
    update organization_modules set enabled = false
     where organization_id = NEW.organization_id and enabled
       and not (module_key = any (billing_ungated_modules()))
       and not (module_key = any (v_new));
    v_add := v_new;
  else
    v_old := coalesce(array(select jsonb_array_elements_text(OLD.entitlements -> 'modules')), '{}');
    v_add := array(select unnest(v_new) except select unnest(v_old));
  end if;

  foreach mk in array coalesce(v_add, '{}') loop
    insert into organization_modules (organization_id, module_key, enabled)
    values (NEW.organization_id, mk, true)
    on conflict (organization_id, module_key) do update set enabled = true;
  end loop;
  return NEW;
end $$;

drop trigger if exists billing_license_sync_modules on organization_licenses;
create trigger billing_license_sync_modules
  after insert or update of entitlements on organization_licenses
  for each row
  execute function sync_modules_to_license();

revoke all on function billing_fit_report(uuid, jsonb), sync_modules_to_license() from public, anon, authenticated;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    grant execute on function billing_fit_report(uuid, jsonb) to service_role;
  end if;
end $$;

-- Companies that signed up under the old flow and have NOT paid yet: their sign-up ticks mean nothing now (the package decides).
-- Optional modules are switched off for them; paying turns on exactly the package's modules. Companies with a license are untouched.
update organization_modules m set enabled = false
 where m.enabled
   and not (m.module_key = any (billing_ungated_modules()))
   and not exists (select 1 from organization_licenses l where l.organization_id = m.organization_id);

-- 0072 — company safeguards: one company per user, creation validation, and deletion that keeps an archive.
-- Additive. No earlier migration is modified; existing data is untouched.
--
-- 1. SINGLE-COMPANY RULE. The application resolves "the user's company" as their oldest active membership in ~33 places; a second active
--    membership would be silently ignored. A company switcher would have to change all of them, so instead the database now refuses to
--    ACTIVATE a second membership (creating a company, accepting an invitation). Users who already have several active memberships are
--    grandfathered: nothing is changed for them, and the rule only fires on new activations.
-- 2. ORGANIZATION VALIDATION. create_organization() (0010) trusted its arguments; a trigger now enforces sane values for every insert path.
-- 3. DELETION ARCHIVE. admin_delete_company() erased the company's audit log and payment records with it. It now copies both into archive
--    tables first (inside the same transaction), so deleting a company never destroys its audit trail. Storage files are removed by the
--    application AFTER this transaction commits (SQL cannot delete the real files) — see src/app/admin/actions.ts.

-- ---- 1 ----
create or replace function _one_active_company() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'active' and (tg_op = 'INSERT' or old.status is distinct from 'active') then
    if exists (select 1 from organization_users o where o.user_id = new.user_id and o.status = 'active' and o.organization_id <> new.organization_id) then
      raise exception 'لا يمكن الانضمام إلى أكثر من شركة بنفس الحساب. استخدم بريدًا إلكترونيًا آخر للشركة الجديدة.' using errcode = 'P0001';
    end if;
  end if;
  return new;
end $$;
revoke all on function _one_active_company() from public, anon, authenticated;
drop trigger if exists zz_one_active_company on organization_users;
create trigger zz_one_active_company before insert or update of status on organization_users
  for each row execute function _one_active_company();

-- ---- 2 ----
create or replace function _validate_organization() returns trigger
language plpgsql set search_path = public as $$
begin
  new.name := btrim(coalesce(new.name, ''));
  if char_length(new.name) < 1 or char_length(new.name) > 120 then raise exception 'اسم الشركة يجب أن يكون بين ١ و١٢٠ حرفًا'; end if;
  if new.business_type is not null and char_length(new.business_type) > 60 then raise exception 'نوع النشاط طويل جدًا'; end if;
  if new.country is not null and new.country !~ '^[A-Za-z]{2}$' then raise exception 'رمز الدولة غير صالح'; end if;
  if new.currency is not null and new.currency !~ '^[A-Za-z]{3}$' then raise exception 'رمز العملة غير صالح'; end if;
  if new.language is not null and new.language not in ('ar', 'en') then raise exception 'اللغة غير مدعومة'; end if;
  return new;
end $$;
drop trigger if exists validate_organization on organizations;
create trigger validate_organization before insert on organizations for each row execute function _validate_organization();

-- ---- 3 ----
create table if not exists company_deletion_archive (
  id                 uuid primary key default gen_random_uuid(),
  source_org_id      uuid not null,           -- deliberately NOT a foreign key: the company is gone
  org_name           text not null,
  deleted_by         uuid,
  deleted_at         timestamptz not null default now(),
  audit_log_count    bigint not null default 0,
  billing_orders     jsonb not null default '[]'::jsonb,
  license            jsonb,
  attachment_paths   jsonb not null default '[]'::jsonb   -- Storage paths to remove after the commit
);
create table if not exists company_audit_archive (
  archive_id     uuid not null references company_deletion_archive(id),
  source_org_id  uuid not null,
  id             uuid not null,
  user_id        uuid,
  user_email     text,
  action         text not null,
  entity         text not null,
  entity_id      uuid,
  before_data    jsonb,
  after_data     jsonb,
  created_at     timestamptz not null
);
create index if not exists company_audit_archive_idx on company_audit_archive (archive_id, created_at);
alter table company_deletion_archive enable row level security;
alter table company_audit_archive enable row level security;
revoke all on company_deletion_archive, company_audit_archive from public, anon, authenticated;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    grant select, insert, update on company_deletion_archive to service_role;
    grant select, insert on company_audit_archive to service_role;
  end if;
end $$;

-- same name and signature as 0067 (the app calls it unchanged); the only addition is the archive block before the erase
create or replace function admin_delete_company(p_admin uuid, p_org uuid) returns text
language plpgsql security definer set search_path = public as $$
declare
  r record; v_name text; v_n bigint; v_pending int; v_progress boolean; v_rounds int := 0; v_arch uuid;
begin
  select name into v_name from organizations where id = p_org;
  if not found then return 'not_found'; end if;
  perform pg_advisory_xact_lock(hashtextextended('billing:' || p_org::text, 0));
  execute 'set local lock_timeout = ''20s''';

  insert into company_deletion_archive (source_org_id, org_name, deleted_by, audit_log_count, billing_orders, license, attachment_paths)
  values (
    p_org, v_name, p_admin,
    (select count(*) from audit_logs where organization_id = p_org),
    coalesce((select jsonb_agg(to_jsonb(b) - 'checkout_url') from billing_orders b where b.organization_id = p_org), '[]'::jsonb),
    (select to_jsonb(l) from organization_licenses l where l.organization_id = p_org),
    coalesce((select jsonb_agg(a.storage_path) from attachments a where a.organization_id = p_org), '[]'::jsonb)
  ) returning id into v_arch;
  insert into company_audit_archive (archive_id, source_org_id, id, user_id, user_email, action, entity, entity_id, before_data, after_data, created_at)
  select v_arch, p_org, a.id, a.user_id, a.user_email, a.action, a.entity, a.entity_id, a.before_data, a.after_data, a.created_at from audit_logs a where a.organization_id = p_org;

  perform _admin_set_triggers(false);
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

  delete from organizations where id = p_org;
  set constraints all immediate;
  perform _admin_set_triggers(true);

  perform admin_audit(p_admin, 'company.delete', 'organization', p_org::text, jsonb_build_object('name', v_name, 'archive_id', v_arch));
  return 'deleted';
end $$;

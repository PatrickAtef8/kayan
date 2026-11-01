-- 0064: legal pages (Terms, Privacy, Refund & Cancellation) editable by the Super Admin, versioned, and the audit trail of who accepted
-- which version when they started a payment.
--
--   legal_documents          one row per (document, version); Arabic AND English text together; IMMUTABLE (every edit is a new version,
--                            so what a customer accepted can always be reproduced exactly). Public read: these are public pages.
--   platform_legal_settings  the contact number / email / legal identity placeholders used in the pages and the footer, plus the
--                            "reviewed by a lawyer" flag that controls the draft notice on the public pages.
--   billing_order_acceptances  append-only: user, time, the three versions, language, and the technical evidence (IP, user agent) recorded
--                            against the payment ORDER when the customer ticks the box and continues to payment.
--
-- Nothing here touches prices, limits, modules, payment logic, the grace period or any access rule. Browsers cannot write any of it.
-- Run order: 0062, 0063, 0064, then 0065 (which seeds version 1 of the three documents).

create table legal_documents (
  doc_key     text not null check (doc_key in ('terms', 'privacy', 'refund')),
  version     integer not null check (version >= 1),
  title_ar    text not null check (length(btrim(title_ar)) > 0),
  body_ar     text not null check (length(btrim(body_ar)) > 0 and length(body_ar) <= 200000),
  title_en    text not null check (length(btrim(title_en)) > 0),
  body_en     text not null check (length(btrim(body_en)) > 0 and length(body_en) <= 200000),
  change_note text,
  created_at  timestamptz not null default now(),
  created_by  uuid,
  primary key (doc_key, version)
);

create table platform_legal_settings (
  id               integer primary key check (id = 1),
  company_name_ar  text not null default 'كيان',
  company_name_en  text not null default 'Kayan',
  contact_phone    text not null default '',
  contact_email    text not null default '',
  address_ar       text not null default '',
  address_en       text not null default '',
  commercial_register text not null default '',
  tax_registration text not null default '',
  lawyer_reviewed  boolean not null default false,
  updated_at       timestamptz not null default now(),
  updated_by       uuid
);
insert into platform_legal_settings (id) values (1) on conflict do nothing;

create table billing_order_acceptances (
  id              bigserial primary key,
  order_id        uuid not null references billing_orders(id) on delete cascade,
  organization_id uuid not null references organizations(id) on delete cascade,
  user_id         uuid not null,
  accepted_at     timestamptz not null default now(),
  terms_version   integer not null,
  privacy_version integer not null,
  refund_version  integer not null,
  locale          text not null check (locale in ('ar', 'en')),
  ip_address      text,
  user_agent      text
);
create index billing_order_acceptances_order_idx on billing_order_acceptances (order_id, accepted_at desc);

-- history cannot be rewritten: not even by the service role (deleting a whole order / company still cascades)
create or replace function legal_immutable() returns trigger language plpgsql as $$
begin
  raise exception 'legal: % rows are immutable (add a new version instead)', tg_table_name;
end $$;
create trigger legal_documents_immutable before update or delete on legal_documents for each row execute function legal_immutable();
create trigger billing_order_acceptances_immutable before update on billing_order_acceptances for each row execute function legal_immutable();

-- ---- access ---------------------------------------------------------------------------------------------------------------
alter table legal_documents enable row level security;
alter table platform_legal_settings enable row level security;
alter table billing_order_acceptances enable row level security;
create policy legal_documents_public_read on legal_documents for select to anon, authenticated using (true);
create policy legal_settings_public_read on platform_legal_settings for select to anon, authenticated using (true);
create policy acceptances_owner_read on billing_order_acceptances for select to authenticated using (my_role_key(organization_id) = 'owner');
revoke all on legal_documents, platform_legal_settings, billing_order_acceptances from public, anon, authenticated;
grant select on legal_documents, platform_legal_settings to anon, authenticated;
grant select on billing_order_acceptances to authenticated;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    grant select, insert on legal_documents, billing_order_acceptances to service_role;
    grant select, update on platform_legal_settings to service_role;
    grant usage, select on sequence billing_order_acceptances_id_seq to service_role;
  end if;
end $$;

-- the current version of every document, e.g. {"terms":2,"privacy":1,"refund":1}
create or replace function legal_current_versions() returns jsonb
language sql stable security invoker set search_path = public as $$
  select coalesce(jsonb_object_agg(doc_key, v), '{}'::jsonb) from (select doc_key, max(version) as v from legal_documents group by doc_key) x
$$;
grant execute on function legal_current_versions() to anon, authenticated;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then grant execute on function legal_current_versions() to service_role; end if;
end $$;

-- ---- back office (service role only) ---------------------------------------------------------------------------------------
create or replace function admin_save_legal_document(p_admin uuid, p_key text, p_title_ar text, p_body_ar text, p_title_en text, p_body_en text, p_note text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare cur legal_documents; v int;
begin
  if p_key is null or p_key not in ('terms', 'privacy', 'refund') then raise exception 'admin: unknown legal document'; end if;
  if coalesce(btrim(p_title_ar), '') = '' or coalesce(btrim(p_body_ar), '') = '' or coalesce(btrim(p_title_en), '') = '' or coalesce(btrim(p_body_en), '') = '' then
    raise exception 'admin: title and text are required in both languages';
  end if;
  if length(p_body_ar) > 200000 or length(p_body_en) > 200000 then raise exception 'admin: text too long'; end if;
  perform pg_advisory_xact_lock(hashtext('legal:' || p_key));
  select * into cur from legal_documents where doc_key = p_key order by version desc limit 1;
  if found and cur.title_ar = p_title_ar and cur.body_ar = p_body_ar and cur.title_en = p_title_en and cur.body_en = p_body_en then
    return jsonb_build_object('version', cur.version, 'unchanged', true);       -- nothing changed: no empty version
  end if;
  v := coalesce(cur.version, 0) + 1;
  insert into legal_documents (doc_key, version, title_ar, body_ar, title_en, body_en, change_note, created_by)
  values (p_key, v, p_title_ar, p_body_ar, p_title_en, p_body_en, nullif(left(btrim(coalesce(p_note, '')), 300), ''), p_admin);
  perform admin_audit(p_admin, 'legal.document', 'legal', p_key, jsonb_build_object('version', v));
  return jsonb_build_object('version', v, 'unchanged', false);
end $$;

create or replace function admin_save_legal_settings(
  p_admin uuid, p_name_ar text, p_name_en text, p_phone text, p_email text, p_address_ar text, p_address_en text,
  p_register text, p_tax text, p_lawyer_reviewed boolean
) returns boolean language plpgsql security definer set search_path = public as $$
begin
  if coalesce(btrim(p_name_ar), '') = '' or coalesce(btrim(p_name_en), '') = '' then raise exception 'admin: company name is required'; end if;
  if length(p_name_ar) > 200 or length(p_name_en) > 200 or length(coalesce(p_address_ar, '')) > 400 or length(coalesce(p_address_en, '')) > 400
     or length(coalesce(p_register, '')) > 60 or length(coalesce(p_tax, '')) > 60 then raise exception 'admin: value too long'; end if;
  if coalesce(p_phone, '') !~ '^[0-9+()\-\s]{0,30}$' then raise exception 'admin: invalid phone number'; end if;
  if coalesce(p_email, '') <> '' and p_email !~ '^[^\s@]+@[^\s@]+\.[^\s@]{2,}$' then raise exception 'admin: invalid email'; end if;
  update platform_legal_settings set
    company_name_ar = btrim(p_name_ar), company_name_en = btrim(p_name_en), contact_phone = btrim(coalesce(p_phone, '')),
    contact_email = btrim(coalesce(p_email, '')), address_ar = btrim(coalesce(p_address_ar, '')), address_en = btrim(coalesce(p_address_en, '')),
    commercial_register = btrim(coalesce(p_register, '')), tax_registration = btrim(coalesce(p_tax, '')),
    lawyer_reviewed = coalesce(p_lawyer_reviewed, false), updated_at = now(), updated_by = p_admin
  where id = 1;
  perform admin_audit(p_admin, 'legal.settings', 'legal', '1', jsonb_build_object('lawyer_reviewed', coalesce(p_lawyer_reviewed, false)));
  return true;
end $$;

-- Records that the OWNER accepted the CURRENT versions of the three documents when starting a payment for this order. It refuses an
-- acceptance of versions that are no longer current (the page was open while the text changed), of someone who is not an active owner
-- of the order's company, and when the documents are not available. Append-only: a resumed payment adds another row.
create or replace function billing_record_acceptance(p_order uuid, p_user uuid, p_versions jsonb, p_locale text, p_ip text, p_ua text)
returns text language plpgsql security definer set search_path = public as $$
declare o billing_orders; cur jsonb; t int; pv int; r int;
begin
  select * into o from billing_orders where id = p_order;
  if not found then return 'not_found'; end if;
  if not exists (select 1 from organization_users ou join roles ro on ro.id = ou.role_id
                 where ou.organization_id = o.organization_id and ou.user_id = p_user and ou.status = 'active' and ro.key = 'owner') then return 'not_owner'; end if;
  cur := legal_current_versions();
  if not (cur ? 'terms' and cur ? 'privacy' and cur ? 'refund') then return 'legal_unavailable'; end if;
  begin
    t := (p_versions ->> 'terms')::int; pv := (p_versions ->> 'privacy')::int; r := (p_versions ->> 'refund')::int;
  exception when others then return 'stale';
  end;
  if t is distinct from (cur ->> 'terms')::int or pv is distinct from (cur ->> 'privacy')::int or r is distinct from (cur ->> 'refund')::int then return 'stale'; end if;
  insert into billing_order_acceptances (order_id, organization_id, user_id, terms_version, privacy_version, refund_version, locale, ip_address, user_agent)
  values (o.id, o.organization_id, p_user, t, pv, r, case when p_locale = 'en' then 'en' else 'ar' end, left(p_ip, 64), left(p_ua, 300));
  return 'recorded';
end $$;

revoke all on function admin_save_legal_document(uuid, text, text, text, text, text, text),
                       admin_save_legal_settings(uuid, text, text, text, text, text, text, text, text, boolean),
                       billing_record_acceptance(uuid, uuid, jsonb, text, text, text) from public, anon, authenticated;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    grant execute on function admin_save_legal_document(uuid, text, text, text, text, text, text),
                              admin_save_legal_settings(uuid, text, text, text, text, text, text, text, text, boolean),
                              billing_record_acceptance(uuid, uuid, jsonb, text, text, text) to service_role;
  end if;
end $$;

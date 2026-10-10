-- Minimal stand-in for the parts of Supabase that the migrations depend on,
-- so the schema + RLS + RPC logic can be tested on a plain PostgreSQL 15/16
-- (local dev, CI). NEVER run this against a real Supabase project — it
-- already has all of this.
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'anon') then create role anon nologin; end if;
end $$;

create schema if not exists auth;
create table if not exists auth.users (id uuid primary key default gen_random_uuid(), email text);

create or replace function auth.uid() returns uuid language sql stable as $$
  select coalesce(
    nullif(current_setting('request.jwt.claim.sub', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')
  )::uuid
$$;

grant usage on schema auth to authenticated, anon;
grant execute on function auth.uid() to authenticated, anon;

-- Minimal stand-in for Supabase Storage (0016_attachments.sql creates a
-- bucket and RLS policies on storage.objects). Real projects already have
-- the full schema; this is only enough for the migration to apply.
create schema if not exists storage;
create table if not exists storage.buckets (id text primary key, name text not null, public boolean default false, file_size_limit bigint, allowed_mime_types text[]);
create table if not exists storage.objects (
  id uuid primary key default gen_random_uuid(),
  bucket_id text references storage.buckets(id),
  name text
);
alter table storage.objects enable row level security;
create or replace function storage.foldername(name text) returns text[] language sql immutable as $$
  select string_to_array(name, '/')
$$;

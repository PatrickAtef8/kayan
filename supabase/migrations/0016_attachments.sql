-- Kayan — Phase 13: File Attachments (§55)
--
-- Nothing in the app could attach a file to anything — no expense receipt,
-- no invoice scan, no supplier document. This adds a generic mechanism
-- rather than one bolted onto a single table, since the SRS names the
-- need in general terms without tying it to one entity.
--
-- Design:
--   1. One `attachments` table with a polymorphic (entity_type, entity_id)
--      pair rather than a nullable FK column per attachable table — the
--      same shape as how audit_logs already references (entity, entity_id)
--      generically elsewhere in this app.
--   2. The actual bytes live in Supabase Storage, not in Postgres — the
--      table only holds the path and metadata. The bucket is PRIVATE
--      (public = false): every read goes through a signed URL, scoped by
--      the same organization membership check as everything else here.
--   3. Storage path convention: <organization_id>/<entity_type>/<entity_id>/
--      <filename> — this lets the storage.objects RLS policies below
--      authorize purely from the path (via storage.foldername), with no
--      need to join back to the attachments table itself for read access.
--   4. An attachment is immutable once uploaded (delete-and-reupload to
--      replace it, no update) — simplest correct model for a receipt/scan,
--      and consistent with how this app treats every other record of a
--      completed action (sales/purchase returns, treasury movements) as
--      append-only rather than editable in place.
--   5. Deleting an attachment is logged (§46) the same as anything else
--      that removes a record from the system; uploading isn't (a file
--      appearing is visible on the entity itself, and logging every
--      upload would flood the audit log for something this routine).

insert into storage.buckets (id, name, public)
values ('attachments', 'attachments', false)
on conflict (id) do nothing;

-- Path segment 1 is organization_id, matching this app's is_org_member
-- check everywhere else — a person can read/write only inside their own
-- organization's folder.
create policy attachments_storage_select on storage.objects
  for select using (
    bucket_id = 'attachments'
    and is_org_member((storage.foldername(name))[1]::uuid)
  );
create policy attachments_storage_insert on storage.objects
  for insert with check (
    bucket_id = 'attachments'
    and is_org_member((storage.foldername(name))[1]::uuid)
  );
create policy attachments_storage_delete on storage.objects
  for delete using (
    bucket_id = 'attachments'
    and is_org_member((storage.foldername(name))[1]::uuid)
  );

create table attachments (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  entity_type     text not null check (entity_type in ('expense', 'sales_invoice', 'purchase_invoice', 'customer', 'supplier')),
  entity_id       uuid not null,
  storage_path    text not null,
  file_name       text not null,
  file_size       bigint,
  content_type    text,
  uploaded_by     uuid references auth.users(id),
  created_at      timestamptz not null default now()
);
create index attachments_entity_idx on attachments(organization_id, entity_type, entity_id);

alter table attachments enable row level security;
create policy attachments_select on attachments for select using (is_org_member(organization_id));
create policy attachments_insert on attachments for insert with check (is_org_member(organization_id));
create policy attachments_delete on attachments for delete using (is_org_member(organization_id));
-- No update policy — see design note 4 above.

grant select, insert, delete on attachments to authenticated;

create trigger audit_attachments_del after delete on attachments for each row execute function audit_row_change('attachment', '');

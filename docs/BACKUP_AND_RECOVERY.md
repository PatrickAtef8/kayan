# Backups, point-in-time recovery, and company deletion

## Why this matters
Deleting a company (/admin → company → حذف الشركة) erases its business rows permanently. Migration 0072 **archives** its audit log and payment records first
(`company_audit_archive`, `company_deletion_archive`) and the app then removes the company's files from Storage — but the **business data itself is not archived**.
Backups are the only way to bring a deleted company back.

## Required before launch (Supabase dashboard — cannot be set from code)
1. **Backups:** Supabase → Database → Backups. Paid plans take daily backups; the retention window depends on the plan — confirm yours.
2. **Point-in-Time Recovery (PITR):** an add-on on paid plans (Database → Backups → PITR). Enable it before real customer data exists; it lets you restore to a chosen minute (e.g. just before an accidental deletion).
3. **Storage is NOT covered by database backups.** Attachment files live in Supabase Storage (bucket `attachments`); database backups/PITR restore the rows, not the files. If you need file recovery, export the bucket periodically (e.g. a scheduled script using the Storage API) — not implemented here.
4. Practise one restore (into a separate project) before launch, and write down who can do it.

## Company deletion — what happens, in order
1. Typed-name check on the server (exact match with the stored name; the browser's copy is not trusted).
2. One database transaction: archive audit log + billing orders + licence snapshot + attachment paths → delete the company's rows → delete the company. If it fails, nothing is deleted and no file is touched.
3. After the commit: Storage files under `attachments/<company-id>/` are removed (listed from the bucket, plus the archived paths). If some cannot be removed, the admin sees the folder to delete by hand.
4. Both steps are written to the platform admin audit log (`company.delete`, `company.delete.files`).
5. The archive tables are readable only with the service role. There is no UI for them yet; query them in the SQL editor. **Retention of the archive is a legal decision** (see `docs/LEGAL_OPEN_ITEMS.md`): it contains audit data and payment records.

-- email_log: the unique index is what makes "send once" race-safe; failed attempts free the slot; cairo_today() is the Cairo calendar day.
\set ON_ERROR_STOP on
select t.as_owner();
insert into email_log (template, recipient_hash, recipient_masked, dedupe_key, status) values ('subscription_reminder', repeat('a', 64), 'a***@b***.com', 'renewal:x:2026-12-01:7', 'sent');
select t.throws($q$insert into email_log (template, recipient_hash, recipient_masked, dedupe_key, status) values ('subscription_reminder', repeat('a', 64), 'a***@b***.com', 'renewal:x:2026-12-01:7', 'pending')$q$, 'duplicate', 'the same template + key + recipient cannot be claimed twice');
insert into email_log (template, recipient_hash, recipient_masked, dedupe_key, status) values ('subscription_reminder', repeat('b', 64), 'b***@b***.com', 'renewal:x:2026-12-01:7', 'sent');
select t.ok(true, 'a different recipient with the same key is allowed');
insert into email_log (template, recipient_hash, recipient_masked, dedupe_key, status, error_code) values ('subscription_reminder', repeat('c', 64), 'c***@b***.com', 'k', 'failed', 'network_error'), ('subscription_reminder', repeat('c', 64), 'c***@b***.com', 'k', 'failed', 'network_error');
insert into email_log (template, recipient_hash, recipient_masked, dedupe_key, status) values ('subscription_reminder', repeat('c', 64), 'c***@b***.com', 'k', 'sent');
select t.ok(true, 'failed attempts never block a retry');
select t.throws($q$insert into email_log (template, recipient_hash, recipient_masked, status) values ('x', 'short', 'm', 'sent')$q$, 'check', 'the recipient hash must be a full sha-256');
insert into email_log (template, recipient_hash, recipient_masked, status) values ('team_invite', repeat('d', 64), 'd***@b***.com', 'sent'), ('team_invite', repeat('d', 64), 'd***@b***.com', 'sent');
select t.ok(true, 'rows without a dedupe key are plain audit lines (no uniqueness)');

-- cairo_today(): Cairo midnight boundary (checked against now() by re-deriving it)
select t.eq_text(cairo_today()::text, ((now() at time zone 'Africa/Cairo')::date)::text, 'cairo_today() is the Cairo calendar day');
select t.eq_text(((timestamptz '2026-01-10 21:59:59+00') at time zone 'Africa/Cairo')::date::text, '2026-01-10', 'winter: 23:59:59 Cairo is still the 10th');
select t.eq_text(((timestamptz '2026-01-10 22:00:00+00') at time zone 'Africa/Cairo')::date::text, '2026-01-11', 'winter: midnight Cairo is the 11th');
select t.eq_text(((timestamptz '2026-07-10 20:59:59+00') at time zone 'Africa/Cairo')::date::text, '2026-07-10', 'summer (UTC+3): 23:59:59 Cairo is still the 10th');
select t.eq_text(((timestamptz '2026-07-10 21:00:00+00') at time zone 'Africa/Cairo')::date::text, '2026-07-11', 'summer: midnight Cairo is the 11th');
-- the alert functions use it: an invoice dated "today in Cairo" is not overdue
select t.ok(pg_get_functiondef('report_overdue_collections(uuid,int)'::regprocedure) like '%cairo_today()%', 'report_overdue_collections compares against Cairo today');
select t.ok(pg_get_functiondef('report_large_expenses(uuid,int)'::regprocedure) like '%cairo_today()%', 'report_large_expenses compares against Cairo today');
select t.ok((select column_default from information_schema.columns where table_name = 'sales_invoices' and column_name = 'invoice_date') like '%cairo_today()%', 'sales_invoices.invoice_date defaults to Cairo today');

-- 0070: security hardening, round 3.
-- Covers: the search helpers are callable by the signed-in role (a customer INSERT works — the GIN index runs ar_norm as the
-- inserting user) and never by anon; the privilege model on a Supabase-style project (anon sees only the three public-read tables,
-- nobody but the owner has TRUNCATE / REFERENCES / TRIGGER, immutable ledgers refuse DML, every table has RLS, anon cannot run
-- any function except the one public one); the admin's user id is no longer public; and the database-backed rate limiter
-- (service role only, atomic, per-key, resets with the window, rejects bad arguments).

\set ON_ERROR_STOP on
select t.autoconfirm_off();

-- ============================================================
-- 1. Search helpers (0069 shipped them without grants)
-- ============================================================
select t.ok(has_function_privilege('authenticated', 'ar_norm(text)', 'execute'),      'authenticated can run ar_norm');
select t.ok(has_function_privilege('authenticated', 'like_contains(text)', 'execute'), 'authenticated can run like_contains');
select t.ok(not has_function_privilege('anon', 'ar_norm(text)', 'execute'),            'anon cannot run ar_norm');
select t.ok(not has_function_privilege('anon', 'like_contains(text)', 'execute'),      'anon cannot run like_contains');

-- ============================================================
-- 2. Privilege model (meaningful because the stub reproduces Supabase's default ACL)
-- ============================================================
-- 2a. Functions: the ONLY thing anon may execute is the public legal-version lookup.
select t.eq((select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             where n.nspname = 'public' and p.prokind = 'f'
               and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
               and has_function_privilege('anon', p.oid, 'execute') and p.proname <> 'legal_current_versions'),
            0, 'anon can execute no function except legal_current_versions');
-- 2b. Tables: anon reads only the three public pages' tables, and only SELECT.
select t.eq((select count(*) from information_schema.role_table_grants
             where grantee = 'anon' and table_schema = 'public'
               and not (privilege_type = 'SELECT' and table_name in ('legal_documents', 'platform_legal_settings', 'platform_pricing_config'))),
            0, 'anon holds no table privilege beyond SELECT on the three public-read tables');
-- 2c. Nobody but the owner may TRUNCATE (it ignores RLS), REFERENCE or add triggers.
select t.eq((select count(*) from information_schema.role_table_grants
             where grantee in ('anon', 'authenticated') and table_schema = 'public'
               and privilege_type in ('TRUNCATE', 'REFERENCES', 'TRIGGER')),
            0, 'neither anon nor authenticated can TRUNCATE / REFERENCE / add triggers on any table');
-- 2d. Row Level Security is on for every table in public.
select t.eq((select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
             where n.nspname = 'public' and c.relkind in ('r', 'p') and not c.relrowsecurity),
            0, 'every table in public has row level security enabled');
-- 2e. Immutable ledgers refuse DML from a signed-in session at the privilege layer (RLS is then a second barrier, not the only one).
select t.eq((select count(*) from information_schema.role_table_grants
             where grantee = 'authenticated' and table_schema = 'public'
               and table_name in ('audit_logs', 'treasury_movements', 'inventory_movements', 'sales_invoices', 'purchase_invoices',
                                  'billing_orders', 'organization_licenses')
               and privilege_type in ('INSERT', 'UPDATE', 'DELETE')),
            0, 'a signed-in session cannot write the audit log, the ledgers, invoices or billing rows directly');
-- 2f. A table created from now on does NOT inherit ALL for anon / authenticated (fail closed, like functions since 0030).
create table public.zz_default_acl_probe (id int);
select t.eq((select count(*) from information_schema.role_table_grants
             where table_schema = 'public' and table_name = 'zz_default_acl_probe' and grantee in ('anon', 'authenticated')),
            0, 'a new table starts with no anon / authenticated privileges');
drop table public.zz_default_acl_probe;

-- ============================================================
-- 3. platform_pricing_config: the config is public, the admin's id is not
-- ============================================================
select t.as_anon();
select t.ok((select count(*) from (select config, updated_at from platform_pricing_config) q) >= 0, 'anon can still read the config and its timestamp');
select t.throws($q$select updated_by from platform_pricing_config$q$, 'permission denied', 'anon cannot read updated_by (the admin user id)');
select t.throws($q$select * from platform_pricing_config$q$,          'permission denied', 'anon cannot select * from the pricing config either');
select t.as_user('f0000000-0000-0000-0000-000000000120');
select t.throws($q$select updated_by from platform_pricing_config$q$, 'permission denied', 'a signed-in user cannot read updated_by either');
reset role;

-- ============================================================
-- 4. Rate limiter
-- ============================================================
select t.as_user('f0000000-0000-0000-0000-000000000120');
select t.throws($q$select rate_limit_hit('k', 60, 5)$q$, 'permission denied', 'a signed-in browser session cannot touch the rate limiter');
select t.throws($q$select * from rate_limits$q$,          'permission denied', 'nor read its counters');
select t.as_anon();
select t.throws($q$select rate_limit_hit('k', 60, 5)$q$, 'permission denied', 'anon cannot call it');
reset role;

set role service_role;
select rate_limit_hit('t:a', 60, 3) ->> 'allowed' as a1 \gset
select rate_limit_hit('t:a', 60, 3) ->> 'allowed' as a2 \gset
select rate_limit_hit('t:a', 60, 3) ->> 'allowed' as a3 \gset
select rate_limit_hit('t:a', 60, 3) as j \gset
select rate_limit_hit('t:b', 60, 3) ->> 'allowed' as b1 \gset
select rate_limit_hit('t:w', 1, 1) ->> 'allowed' as w1 \gset
select rate_limit_hit('t:w', 1, 1) ->> 'allowed' as w2 \gset
select pg_sleep(1.1);
select rate_limit_hit('t:w', 1, 1) ->> 'allowed' as w3 \gset
reset role;

select t.eq_text(:'a1', 'true', 'hit 1 of 3 is allowed');
select t.eq_text(:'a2', 'true', 'hit 2 of 3 is allowed');
select t.eq_text(:'a3', 'true', 'hit 3 of 3 is allowed');
select t.ok(not (:'j'::jsonb ->> 'allowed')::boolean, 'hit 4 of 3 is refused');
select t.eq((:'j'::jsonb ->> 'hits')::numeric, 4, 'the counter keeps counting');
select t.ok((:'j'::jsonb ->> 'retry_after')::int between 1 and 60, 'it says how long to wait (1..60 s)');
select t.eq_text(:'b1', 'true', 'another key is unaffected');
select t.ok(:'w1' = 'true' and :'w2' = 'false', 'a 1-per-second key: first allowed, second refused');
select t.eq_text(:'w3', 'true', 'and allowed again once the window has passed');

-- bad arguments never create a row or a bypass (the definer function raises; run as the owner so the helper is callable)
select t.throws($q$select rate_limit_hit('', 60, 3)$q$,      'invalid rate limit arguments', 'empty key is refused');
select t.throws($q$select rate_limit_hit('x', 0, 3)$q$,      'invalid rate limit arguments', 'window of 0 is refused');
select t.throws($q$select rate_limit_hit('x', 60, 0)$q$,     'invalid rate limit arguments', 'max of 0 is refused');
select t.throws(format($q$select rate_limit_hit(%L, 60, 3)$q$, repeat('x', 201)), 'invalid rate limit arguments', 'an oversized key is refused');

select t.autoconfirm_on();

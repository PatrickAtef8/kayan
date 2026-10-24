-- :who = 1|2 (which storekeeper),  :inv = purchase invoice id,  :sleep.  Prints "RECEIVED" or "REFUSED".
\set ON_ERROR_STOP off
\set VERBOSITY terse
select t.as_user(case :who when 1 then '98000000-0000-0000-0000-000000000004' else '98000000-0000-0000-0000-000000000005' end::uuid);
begin;
select confirm_purchase_receipt((select org from t.cl_ids), :'inv'::uuid) is not null as ok \gset
\if :{?ok}
  select pg_sleep(:sleep);
  commit;
  \echo RECEIVED
\else
  rollback;
  \echo REFUSED
\endif

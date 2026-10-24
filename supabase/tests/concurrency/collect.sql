-- :who = 1 owner | 2 rep 1 | 3 rep 2,  :inv = invoice id,  :cust = customer id,  :amount,  :sleep = seconds to keep the transaction open.
-- Prints "COLLECTED" or "REFUSED: <message>".
\set ON_ERROR_STOP off
\set VERBOSITY terse
select t.as_user(case :who when 1 then '98000000-0000-0000-0000-000000000001' when 2 then '98000000-0000-0000-0000-000000000002' else '98000000-0000-0000-0000-000000000003' end::uuid);
begin;
select record_customer_collection((select org from t.cl_ids), :'cust'::uuid, :'inv'::uuid, :amount, current_date, 'نقدًا', null, null) is not null as ok \gset
\if :{?ok}
  select pg_sleep(:sleep);
  commit;
  \echo COLLECTED
\else
  rollback;
  \echo REFUSED
\endif

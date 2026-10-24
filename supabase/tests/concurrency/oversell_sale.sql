-- :who = 1|2 (which rep), :qty, :no = invoice number, :sleep = seconds to keep the transaction open.
-- Prints "SOLD" or "REFUSED: <message>" (a refused sale rolls back, so a failed statement is the expected outcome).
\set ON_ERROR_STOP off
select t.as_user(case :who when 1 then '99000000-0000-0000-0000-000000000002' else '99000000-0000-0000-0000-000000000003' end::uuid);
begin;
select create_sales_invoice((select org from t.ov_ids), (select case :who when 1 then c1 else c2 end from t.ov_ids), (select w1 from t.ov_ids), :'no', current_date,
  jsonb_build_array(jsonb_build_object('product_id', (select pa from t.ov_ids), 'quantity', :qty, 'unit_price', 100, 'discount_pct', 0)), 0, 0, 0, null, null, null, 0) is not null as sold \gset
\if :{?sold}
  select pg_sleep(:sleep);
  commit;
  \echo SOLD
\else
  rollback;
  \echo REFUSED
\endif

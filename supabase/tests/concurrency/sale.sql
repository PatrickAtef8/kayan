-- :prod = 'pa'|'pb', :qty, :no = invoice number, :sleep = seconds to keep the transaction open
select t.as_user('98000000-0000-0000-0000-000000000001');
begin;
select create_sales_invoice((select org from t.cc_ids), (select cus from t.cc_ids), (select w1 from t.cc_ids), :'no', current_date,
  jsonb_build_array(jsonb_build_object('product_id', (select case :'prod' when 'pa' then pa else pb end from t.cc_ids), 'quantity', :qty, 'unit_price', 100, 'discount_pct', 0)), 0, 0, 0, null, null, null, 0) is not null as sold;
select pg_sleep(:sleep);
commit;

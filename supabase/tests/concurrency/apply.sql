-- :st = stocktake id, :sleep = seconds to keep the transaction open after applying
select t.as_user('98000000-0000-0000-0000-000000000001');
begin;
select apply_stocktake((select org from t.cc_ids), :'st'::uuid) as applied;
select pg_sleep(:sleep);
commit;

-- Kayan — Phase 59: stop downloading whole balance/stock tables just to add them up (performance)
--
-- PROBLEM
--   * The owner dashboard fetched EVERY row of customer_balances, supplier_balances, treasury_balances and
--     inventory_stock (+ stock_costs) on each load and summed them in JavaScript. The payload grows with the size of
--     the catalogue / customer list, and PostgREST cuts a response at max_rows (1000 by default), so past 1000 rows
--     the totals were silently wrong.
--   * The customers / suppliers pages showed 20 rows per page but fetched the balances of ALL customers / suppliers
--     (the views aggregate every invoice / collection / return of the organization) on every page view.
--
-- FIX (no change of meaning — same views, same RLS, same visibility rules)
--   1. dashboard_balance_totals(org_id)  — the four sums in SQL, built from the SAME views/tables the page used,
--      as SECURITY INVOKER: a role that cannot read balances or costs gets 0, exactly as before.
--   2. customer_balances_for(p_ids) / supplier_balances_for(p_ids) — the body of customer_balances /
--      supplier_balances (0032) restricted to the requested parties, with the restriction applied INSIDE each
--      aggregate so only those parties' documents are summed instead of the whole organization's.
--   Both are SECURITY INVOKER + STABLE: RLS of the caller applies to every table they read.

create or replace function dashboard_balance_totals(org_id uuid)
returns table (customer_receivable numeric, supplier_payable numeric, inventory_value numeric, treasury_balance numeric)
language sql
stable
set search_path = public
as $$
  select
    (select coalesce(sum(b.balance), 0) from customer_balances b where b.organization_id = org_id)::numeric,
    (select coalesce(sum(b.balance), 0) from supplier_balances b where b.organization_id = org_id)::numeric,
    -- average cost is protected (0034): stock_costs is empty for roles without cost access, so the value is 0 for them
    (select coalesce(sum(s.quantity * coalesce(c.avg_cost, 0)), 0)
       from inventory_stock s left join stock_costs c on c.stock_id = s.id
      where s.organization_id = org_id)::numeric,
    (select coalesce(sum(b.balance), 0) from treasury_balances b where b.organization_id = org_id)::numeric;
$$;

revoke all on function dashboard_balance_totals(uuid) from public, anon;
grant execute on function dashboard_balance_totals(uuid) to authenticated;

create or replace function customer_balances_for(p_ids uuid[])
returns table (customer_id uuid, total_sales numeric, total_collected numeric, balance numeric)
language sql
stable
set search_path = public
as $$
  select
    c.id,
    case when c.organization_id in (select balance_org_ids('customer')) then coalesce(s.total_sales, 0) end,
    case when c.organization_id in (select balance_org_ids('customer')) then coalesce(col.total_collected, 0) end,
    case when c.organization_id in (select balance_org_ids('customer')) then
      coalesce(ob.amount, 0) + coalesce(s.total_sales, 0) - coalesce(col.total_collected, 0)
      - coalesce(r.total_returned, 0) + coalesce(r.total_refunded, 0) end
  from customers c
  left join customer_opening_balances ob on ob.customer_id = c.id
  left join (select x.customer_id, sum(x.total) as total_sales from sales_invoices x where x.customer_id = any(p_ids) group by x.customer_id) s on s.customer_id = c.id
  left join (select x.customer_id, sum(x.amount) as total_collected from customer_collections x where x.customer_id = any(p_ids) group by x.customer_id) col on col.customer_id = c.id
  left join (select x.customer_id, sum(x.total) as total_returned, sum(x.cash_refunded) as total_refunded from sales_returns x where x.customer_id = any(p_ids) group by x.customer_id) r on r.customer_id = c.id
  where c.id = any(p_ids);
$$;

revoke all on function customer_balances_for(uuid[]) from public, anon;
grant execute on function customer_balances_for(uuid[]) to authenticated;

create or replace function supplier_balances_for(p_ids uuid[])
returns table (supplier_id uuid, total_purchases numeric, total_paid numeric, balance numeric)
language sql
stable
set search_path = public
as $$
  select
    s.id,
    case when s.organization_id in (select balance_org_ids('supplier')) then coalesce(p.total_purchases, 0) end,
    case when s.organization_id in (select balance_org_ids('supplier')) then coalesce(pay.total_paid, 0) end,
    case when s.organization_id in (select balance_org_ids('supplier')) then
      coalesce(ob.amount, 0) + coalesce(p.total_purchases, 0) - coalesce(pay.total_paid, 0)
      - coalesce(r.total_returned, 0) + coalesce(r.total_refunded, 0) end
  from suppliers s
  left join supplier_opening_balances ob on ob.supplier_id = s.id
  left join (select x.supplier_id, sum(x.total) as total_purchases from purchase_invoices x where x.supplier_id = any(p_ids) group by x.supplier_id) p on p.supplier_id = s.id
  left join (select x.supplier_id, sum(x.amount) as total_paid from supplier_payments x where x.supplier_id = any(p_ids) group by x.supplier_id) pay on pay.supplier_id = s.id
  left join (select x.supplier_id, sum(x.total) as total_returned, sum(x.cash_refunded) as total_refunded from purchase_returns x where x.supplier_id = any(p_ids) group by x.supplier_id) r on r.supplier_id = s.id
  where s.id = any(p_ids);
$$;

revoke all on function supplier_balances_for(uuid[]) from public, anon;
grant execute on function supplier_balances_for(uuid[]) to authenticated;

-- Stock value of the organization (quantity x weighted-average cost) for the Inventory page, which is now paginated and
-- therefore can no longer add the value up from the rows it shows. Invoker rights: stock_costs is empty for roles
-- without cost access (0034), so they get 0, as before.
create or replace function inventory_value_total(org_id uuid)
returns numeric
language sql
stable
set search_path = public
as $$
  select coalesce(sum(s.quantity * coalesce(c.avg_cost, 0)), 0)::numeric
    from inventory_stock s left join stock_costs c on c.stock_id = s.id
   where s.organization_id = org_id;
$$;

revoke all on function inventory_value_total(uuid) from public, anon;
grant execute on function inventory_value_total(uuid) to authenticated;

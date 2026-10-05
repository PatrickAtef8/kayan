-- Kayan — Phase 15: Opening Balances (§56)
--
-- §56 names "opening balances" as its own import target, separate from
-- plain customer/supplier records — the real-world need is migrating an
-- existing business onto Kayan with its receivables/payables already in
-- place, not starting every relationship at zero.
--
-- customer_balances/supplier_balances (§28/§23) are computed views, not
-- stored ledgers — balance = purchases/sales minus payments/collections
-- minus returns. An "opening balance" has no transactions behind it, so
-- it can't be a row in sales_invoices or purchase_invoices without
-- distorting sales/purchase totals elsewhere in the reports (§43's
-- "Sales by customer" would then double-count a balance that was never a
-- sale). Instead: a single opening_balance column on customers/suppliers
-- — a starting number, set once at onboarding — that both balance views
-- and the party ledger (§28) add in as a baseline. Everyone who never had
-- one (opening_balance defaults to 0) sees no change at all.
--
-- Sign convention: positive opening_balance on a CUSTOMER means they owed
-- the business money before Kayan started tracking them (adds to
-- receivable, same direction as an unpaid sale); positive on a SUPPLIER
-- means the business owed the supplier (adds to payable, same direction
-- as an unpaid purchase) — i.e. it behaves exactly like a sale/purchase
-- that happened before day one, just without inventory or profit
-- attached to it.

alter table customers add column if not exists opening_balance numeric(14,2) not null default 0;
alter table suppliers add column if not exists opening_balance numeric(14,2) not null default 0;

create or replace view customer_balances
with (security_invoker = true) as
select
  c.id as customer_id,
  c.organization_id,
  coalesce(s.total_sales, 0) as total_sales,
  coalesce(col.total_collected, 0) as total_collected,
  c.opening_balance
    + coalesce(s.total_sales, 0) - coalesce(col.total_collected, 0) - coalesce(r.total_returned, 0) as balance,
  coalesce(r.total_returned, 0) as total_returned
from customers c
left join (
  select customer_id, sum(total) as total_sales
  from sales_invoices
  group by customer_id
) s on s.customer_id = c.id
left join (
  select customer_id, sum(amount) as total_collected
  from customer_collections
  group by customer_id
) col on col.customer_id = c.id
left join (
  select customer_id, sum(total) as total_returned
  from sales_returns
  group by customer_id
) r on r.customer_id = c.id;

create or replace view supplier_balances
with (security_invoker = true) as
select
  s.id as supplier_id,
  s.organization_id,
  coalesce(p.total_purchases, 0) as total_purchases,
  coalesce(pay.total_paid, 0) as total_paid,
  s.opening_balance
    + coalesce(p.total_purchases, 0) - coalesce(pay.total_paid, 0) - coalesce(r.total_returned, 0) as balance,
  coalesce(r.total_returned, 0) as total_returned
from suppliers s
left join (
  select supplier_id, sum(total) as total_purchases
  from purchase_invoices
  group by supplier_id
) p on p.supplier_id = s.id
left join (
  select supplier_id, sum(amount) as total_paid
  from supplier_payments
  group by supplier_id
) pay on pay.supplier_id = s.id
left join (
  select supplier_id, sum(total) as total_returned
  from purchase_returns
  group by supplier_id
) r on r.supplier_id = s.id;

-- report_party_ledger (0009, extended in 0011 and 0012) now folds the
-- opening_balance in as a base offset added to every row's running
-- balance, on top of whatever entries actually happened — the ledger
-- shouldn't start from zero for a party that didn't start at zero.
create or replace function report_party_ledger(
  org_id uuid,
  p_type text,
  p_party uuid,
  p_from date default null,
  p_to date default null
)
returns table (
  entry_date date,
  entry_type text,
  reference text,
  description text,
  increase numeric,
  decrease numeric,
  balance numeric
)
language plpgsql
stable
set search_path = public
as $$
declare
  v_opening_balance numeric(14,2) := 0;
begin
  perform assert_report_access(org_id, true);
  if p_type not in ('customer', 'supplier') then
    raise exception 'نوع الطرف غير صحيح';
  end if;

  if p_type = 'customer' then
    select opening_balance into v_opening_balance from customers where id = p_party and organization_id = org_id;
    if not found then
      raise exception 'هذا العميل لا ينتمي إلى هذه المؤسسة';
    end if;
  else
    select opening_balance into v_opening_balance from suppliers where id = p_party and organization_id = org_id;
    if not found then
      raise exception 'هذا المورد لا ينتمي إلى هذه المؤسسة';
    end if;
  end if;

  return query
  with entries as (
    select i.invoice_date as d, i.created_at as ts, i.id as eid,
           'sale'::text as t, coalesce(i.invoice_number, '') as ref, i.notes as descr,
           i.total::numeric as inc, 0::numeric as dec
    from sales_invoices i
    where p_type = 'customer' and i.organization_id = org_id and i.customer_id = p_party
    union all
    select c.collection_date, c.created_at, c.id,
           'collection', coalesce(c.reference, ''), coalesce(c.payment_method, ''),
           0::numeric, c.amount::numeric
    from customer_collections c
    where p_type = 'customer' and c.organization_id = org_id and c.customer_id = p_party
    union all
    select r.return_date, r.created_at, r.id,
           'return', coalesce((select invoice_number from sales_invoices where id = r.sales_invoice_id), ''), r.notes,
           0::numeric, r.total::numeric
    from sales_returns r
    where p_type = 'customer' and r.organization_id = org_id and r.customer_id = p_party
    union all
    select pi.invoice_date, pi.created_at, pi.id,
           'purchase', coalesce(pi.invoice_number, ''), pi.notes,
           pi.total::numeric, 0::numeric
    from purchase_invoices pi
    where p_type = 'supplier' and pi.organization_id = org_id and pi.supplier_id = p_party
    union all
    select sp.payment_date, sp.created_at, sp.id,
           'payment', coalesce(sp.reference, ''), coalesce(sp.payment_method, ''),
           0::numeric, sp.amount::numeric
    from supplier_payments sp
    where p_type = 'supplier' and sp.organization_id = org_id and sp.supplier_id = p_party
    union all
    select pr.return_date, pr.created_at, pr.id,
           'return', coalesce((select invoice_number from purchase_invoices where id = pr.purchase_invoice_id), ''), pr.notes,
           0::numeric, pr.total::numeric
    from purchase_returns pr
    where p_type = 'supplier' and pr.organization_id = org_id and pr.supplier_id = p_party
  ), running as (
    select e.*, v_opening_balance + sum(e.inc - e.dec) over (order by e.d, e.ts, (case when e.inc > 0 then 0 else 1 end), e.eid) as bal
    from entries e
  ), opening as (
    select p_from as d, 'opening'::text as t, ''::text as ref, ''::text as descr,
           0::numeric as inc, 0::numeric as dec,
           v_opening_balance + coalesce((select sum(e.inc - e.dec) from entries e where e.d < p_from), 0) as bal,
           0 as ord
    where p_from is not null
  )
  select x.d, x.t, x.ref, x.descr, x.inc, x.dec, x.bal
  from (
    select o.d, o.t, o.ref, o.descr, o.inc, o.dec, o.bal, o.ord, null::timestamptz as ts, 0 as tie, null::uuid as eid from opening o
    union all
    select r.d, r.t, r.ref, r.descr, r.inc, r.dec, r.bal, 1, r.ts, (case when r.inc > 0 then 0 else 1 end), r.eid
    from running r
    where (p_from is null or r.d >= p_from) and (p_to is null or r.d <= p_to)
  ) x
  order by x.d, x.ord, x.ts, x.tie, x.eid;
end;
$$;

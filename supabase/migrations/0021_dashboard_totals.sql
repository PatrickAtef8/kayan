-- Kayan — Phase 21: dashboard totals in SQL, and the expenses list index
--
-- 1. dashboard_sales_totals
--    The dashboard used to download EVERY sales invoice of the selected period
--    (total, profit_total, invoice_date) into the Node process just to add up
--    two columns — tens of thousands of rows on the "all time" view. The sums
--    now happen in Postgres and one row comes back. The maths is the same as
--    the JS reduce it replaces: sum(total) and sum(profit_total) over the
--    org's invoices with invoice_date >= p_from (null = all time), no returns
--    netted (that is what the KPI card always showed).
--
--    Access: any active member (same as before — RLS already let every member
--    read sales_invoices). One deliberate tightening: the profit figure is
--    only computed for members with view_financial; everyone else gets 0. The
--    UI already shows a locked card for them, but the number used to be sent
--    to their browser inside the page payload.
--
-- 2. expenses(organization_id, created_at desc)
--    The expenses list is now paginated and ordered by created_at, filtered by
--    organization. This lets Postgres read just one page in index order.

create or replace function dashboard_sales_totals(org_id uuid, p_from date default null)
returns table (total_sales numeric, total_profit numeric)
language plpgsql
stable
set search_path = public
as $$
begin
  perform assert_report_access(org_id, false);
  return query
  select
    coalesce(sum(i.total), 0)::numeric,
    case when has_permission(org_id, 'view_financial')
         then coalesce(sum(i.profit_total), 0)::numeric
         else 0::numeric end
  from sales_invoices i
  where i.organization_id = org_id
    and (p_from is null or i.invoice_date >= p_from);
end;
$$;

revoke all on function dashboard_sales_totals(uuid, date) from public, anon;
grant execute on function dashboard_sales_totals(uuid, date) to authenticated;

create index if not exists expenses_org_created_idx on expenses (organization_id, created_at desc);

-- 3. dashboard_sales_rollups
--    The dashboard called report_sales_breakdown three times for the trend chart,
--    top customers and top representatives. That function also computes item
--    quantities and returned quantities per invoice — the two most expensive
--    parts, scanning every invoice line of the period — which these three
--    widgets never display. This function returns exactly the three datasets
--    the dashboard shows, in ONE pass over the period's invoices with returns
--    pre-aggregated, and no invoice-line scan at all. (Top products still
--    comes from report_sales_breakdown: it genuinely needs line data.)
--
--    Figures and ordering are identical to report_sales_breakdown:
--      net_sales    = subtotal - discount_total - returns total
--      gross_profit = profit_total - returned profit   (NULL without view_financial)
--    trend           : per invoice_date, newest first, max 1000 days
--    customer / rep  : top 5 by net_sales desc, then label
--    (the rep list keeps the "no representative" group, group_key '', exactly
--    as the SQL did; the page filters it out afterwards, as before).
create or replace function dashboard_sales_rollups(org_id uuid, p_from date default null)
returns table (
  kind text,
  group_key text,
  group_label text,
  ref_date date,
  invoices bigint,
  net_sales numeric,
  gross_profit numeric
)
language plpgsql
stable
set search_path = public
as $$
declare
  fin boolean;
begin
  perform assert_report_access(org_id, false);
  fin := has_permission(org_id, 'view_financial');

  return query
  with f as materialized (
    select i.invoice_date, i.customer_id, i.sales_rep_id, i.subtotal, i.discount_total, i.profit_total,
           coalesce(rt.ret_total, 0) as ret_total,
           coalesce(rt.ret_profit, 0) as ret_profit
    from sales_invoices i
    left join (
      select r.sales_invoice_id, sum(r.total) as ret_total, sum(r.profit_reversed) as ret_profit
      from sales_returns r
      where r.organization_id = org_id
      group by r.sales_invoice_id
    ) rt on rt.sales_invoice_id = i.id
    where i.organization_id = org_id
      and (p_from is null or i.invoice_date >= p_from)
  ),
  trend as (
    select 'trend'::text as k, x.invoice_date::text as gk, x.invoice_date::text as gl, x.invoice_date as rd,
           count(*)::bigint as n,
           coalesce(sum(x.subtotal - x.discount_total - x.ret_total), 0)::numeric as ns,
           case when fin then coalesce(sum(x.profit_total - x.ret_profit), 0)::numeric end as gp
    from f x
    group by x.invoice_date
    order by x.invoice_date desc
    limit 1000
  ),
  cust as (
    select 'customer'::text as k, x.customer_id::text as gk, coalesce(c.name, '—') as gl, null::date as rd,
           count(*)::bigint as n,
           coalesce(sum(x.subtotal - x.discount_total - x.ret_total), 0)::numeric as ns,
           case when fin then coalesce(sum(x.profit_total - x.ret_profit), 0)::numeric end as gp
    from f x
    left join customers c on c.id = x.customer_id
    group by x.customer_id, coalesce(c.name, '—')
    order by 6 desc nulls last, 3
    limit 5
  ),
  reps as (
    select 'representative'::text as k, coalesce(x.sales_rep_id::text, '') as gk, coalesce(r.name, 'بدون مندوب') as gl, null::date as rd,
           count(*)::bigint as n,
           coalesce(sum(x.subtotal - x.discount_total - x.ret_total), 0)::numeric as ns,
           case when fin then coalesce(sum(x.profit_total - x.ret_profit), 0)::numeric end as gp
    from f x
    left join sales_representatives r on r.id = x.sales_rep_id
    group by coalesce(x.sales_rep_id::text, ''), coalesce(r.name, 'بدون مندوب')
    order by 6 desc nulls last, 3
    limit 5
  )
  select * from trend
  union all select * from cust
  union all select * from reps;
end;
$$;

revoke all on function dashboard_sales_rollups(uuid, date) from public, anon;
grant execute on function dashboard_sales_rollups(uuid, date) to authenticated;

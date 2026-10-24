-- Kayan — Phase 56: the home page can show ANY month or year, not just "this month / this year / all"
--
-- The period picker now sends a closed range (p_from .. p_to) for a past month or year, so people can open data
-- they entered for months before the system was in use. Three dashboard functions only knew "from", so each
-- gets an optional p_to (null = open-ended, exactly the old behaviour — the current month/year still send null).
--
--   dashboard_sales_totals   → report_summary already took p_to; it is simply passed through.
--   dashboard_sales_trend    → p_to bounds every source and the zero-filled axis ends at p_to's bucket
--                              (instead of today), so a past March shows 31 days, a past 2025 shows 12 months.
--   dashboard_sales_rollups  → p_to, and the return side now follows the cards too: a return is netted in the
--                              period it was MADE (return_date), on the customer / rep of its invoice — before,
--                              it was netted against the invoice's own date, which disagreed with the cards for
--                              any period that did not contain both. The unused 'trend' rows are gone (the chart
--                              reads dashboard_sales_trend).
--
-- The old (uuid, date[, text]) signatures are dropped so PostgREST never has two candidates to choose between.

drop function if exists dashboard_sales_totals(uuid, date);
drop function if exists dashboard_sales_rollups(uuid, date);
drop function if exists dashboard_sales_trend(uuid, date, text);

create or replace function dashboard_sales_totals(org_id uuid, p_from date default null, p_to date default null)
returns table (total_sales numeric, total_profit numeric)
language plpgsql
stable
set search_path = public
as $$
declare
  s jsonb;
begin
  perform assert_sales_report_access(org_id);
  s := report_summary(org_id, p_from, p_to);
  return query select
    coalesce((s->'sales'->>'net_sales')::numeric, 0),
    coalesce((s->'financial'->>'net_profit')::numeric, 0);
end;
$$;

create or replace function dashboard_sales_trend(org_id uuid, p_from date default null, p_to date default null, p_bucket text default 'day')
returns table (bucket_date date, net_sales numeric, gross_profit numeric, overhead numeric, net_profit numeric)
language plpgsql
stable
set search_path = public
as $$
declare
  fin boolean;
  v_today date := cairo_today();
  v_step interval;
begin
  perform assert_sales_report_access(org_id);
  if p_bucket not in ('day', 'month') then
    raise exception 'تجميع غير مدعوم';
  end if;
  fin := has_permission(org_id, 'view_financial');
  v_step := case when p_bucket = 'month' then interval '1 month' else interval '1 day' end;

  return query
  with inv as (
    select date_trunc(p_bucket, i.invoice_date::timestamp)::date as b,
           sum(i.subtotal - i.discount_total) as ns,
           sum(i.subtotal - i.discount_total - i.cogs_total) as gp
    from v_sales_invoices i
    where i.organization_id = org_id
      and (p_from is null or i.invoice_date >= p_from)
      and (p_to is null or i.invoice_date <= p_to)
    group by 1
  ), ret as (
    select date_trunc(p_bucket, r.return_date::timestamp)::date as b,
           sum(r.subtotal_reversed) as rs,
           sum(r.subtotal_reversed - r.cost_reversed) as rp
    from v_sales_returns r
    where r.organization_id = org_id
      and (p_from is null or r.return_date >= p_from)
      and (p_to is null or r.return_date <= p_to)
    group by 1
  ), com as (
    select date_trunc(p_bucket, ic.invoice_date::timestamp)::date as b,
           sum(ic.earned_commission) as cm
    from invoice_commissions ic
    where fin
      and ic.organization_id = org_id
      and (p_from is null or ic.invoice_date >= p_from)
      and (p_to is null or ic.invoice_date <= p_to)
    group by 1
  ), opx as (
    select date_trunc(p_bucket, x.expense_date::timestamp)::date as b,
           sum(x.amount) as ex
    from operating_expenses x
    where fin
      and x.organization_id = org_id
      and (p_from is null or x.expense_date >= p_from)
      and (p_to is null or x.expense_date <= p_to)
    group by 1
  ), keys as (
    select k1.b from inv k1 union select k2.b from ret k2 union select k3.b from com k3 union select k4.b from opx k4
  ), rng as (
    select coalesce(date_trunc(p_bucket, p_from::timestamp)::date, (select min(k.b) from keys k)) as s,
           coalesce(date_trunc(p_bucket, p_to::timestamp)::date,
                    greatest(date_trunc(p_bucket, v_today::timestamp)::date, (select max(k.b) from keys k))) as e
  )
  select g.d::date,
         (coalesce(inv.ns, 0) - coalesce(ret.rs, 0))::numeric,
         case when fin then (coalesce(inv.gp, 0) - coalesce(ret.rp, 0))::numeric end,
         case when fin then (coalesce(com.cm, 0) + coalesce(opx.ex, 0))::numeric end,
         case when fin then (coalesce(inv.gp, 0) - coalesce(ret.rp, 0) - coalesce(com.cm, 0) - coalesce(opx.ex, 0))::numeric end
  from rng
  cross join lateral generate_series(rng.s::timestamp, rng.e::timestamp, v_step) as g(d)
  left join inv on inv.b = g.d::date
  left join ret on ret.b = g.d::date
  left join com on com.b = g.d::date
  left join opx on opx.b = g.d::date
  order by 1;
end;
$$;

create or replace function dashboard_sales_rollups(org_id uuid, p_from date default null, p_to date default null)
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
  perform assert_sales_report_access(org_id);
  fin := has_permission(org_id, 'view_financial');

  return query
  with f as materialized (
    -- the sales side: one row per invoice dated inside the period
    select i.customer_id, i.sales_rep_id, 1 as n,
           (i.subtotal - i.discount_total)::numeric as ns, i.profit_total::numeric as gp
    from v_sales_invoices i
    where i.organization_id = org_id
      and (p_from is null or i.invoice_date >= p_from)
      and (p_to is null or i.invoice_date <= p_to)
    union all
    -- the return side: one row per return MADE inside the period, on its invoice's customer / rep
    select i.customer_id, i.sales_rep_id, 0,
           (-r.subtotal_reversed)::numeric, (-r.profit_reversed)::numeric
    from v_sales_returns r
    join v_sales_invoices i on i.id = r.sales_invoice_id
    where r.organization_id = org_id
      and (p_from is null or r.return_date >= p_from)
      and (p_to is null or r.return_date <= p_to)
  ),
  cust as (
    select 'customer'::text as k, x.customer_id::text as gk, coalesce(c.name, '—') as gl, null::date as rd,
           sum(x.n)::bigint as n,
           coalesce(sum(x.ns), 0)::numeric as ns,
           case when fin then coalesce(sum(x.gp), 0)::numeric end as gp
    from f x
    left join customers c on c.id = x.customer_id
    group by x.customer_id, coalesce(c.name, '—')
    order by 6 desc nulls last, 3
    limit 5
  ),
  reps as (
    select 'representative'::text as k, coalesce(x.sales_rep_id::text, '') as gk, coalesce(r.name, 'بدون مندوب') as gl, null::date as rd,
           sum(x.n)::bigint as n,
           coalesce(sum(x.ns), 0)::numeric as ns,
           case when fin then coalesce(sum(x.gp), 0)::numeric end as gp
    from f x
    left join sales_representatives r on r.id = x.sales_rep_id
    group by coalesce(x.sales_rep_id::text, ''), coalesce(r.name, 'بدون مندوب')
    order by 6 desc nulls last, 3
    limit 5
  )
  select * from cust
  union all select * from reps;
end;
$$;

revoke all on function dashboard_sales_totals(uuid, date, date) from public, anon;
grant execute on function dashboard_sales_totals(uuid, date, date) to authenticated;
revoke all on function dashboard_sales_trend(uuid, date, date, text) from public, anon;
grant execute on function dashboard_sales_trend(uuid, date, date, text) to authenticated;
revoke all on function dashboard_sales_rollups(uuid, date, date) from public, anon;
grant execute on function dashboard_sales_rollups(uuid, date, date) to authenticated;

-- Kayan — Phase 55: a home-page trend chart that adds up to the KPI cards
--
-- Why
--   The chart on الرئيسية was fed by dashboard_sales_rollups (kind = 'trend'), which does NOT use the same
--   rules as the two cards above it (صافي المبيعات / صافي الربح, from report_summary):
--     1. Returns: the chart took a return off the day of the ORIGINAL INVOICE; the cards take it off the day
--        of the RETURN. A September invoice returned in October made October's cards smaller but left
--        October's bars untouched (and quietly rewrote September's bar after the fact).
--     2. Profit: the chart's profit series was GROSS profit (no operating expenses, no earned commissions)
--        while the card called صافي الربح is net. The bars could never sum to the card.
--     3. Gaps: days/months with no activity produced no row, so the chart skipped them.
--     4. "limit 1000" on the daily rows silently dropped the oldest days of the "all time" view.
--
-- What
--   dashboard_sales_trend(org_id, p_from, p_bucket 'day' | 'month') — one row per bucket, zero-filled from the
--   period start (or the first activity, for all time) to today in Cairo, with exactly report_summary's rules:
--     net_sales    = Σ(subtotal − discount_total) by invoice_date  −  Σ subtotal_reversed by return_date
--     gross_profit = Σ(subtotal − discount_total − cogs_total) by invoice_date  −  Σ(subtotal_reversed − cost_reversed) by return_date
--     overhead     = Σ operating_expenses by expense_date  +  Σ earned_commission by invoice_date
--     net_profit   = gross_profit − overhead
--   For any period: Σ net_sales = dashboard_sales_totals.total_sales and Σ net_profit = .total_profit
--   (tests/101_dashboard_trend_test.sql). Members without view_financial get NULL in the three profit columns.

create or replace function dashboard_sales_trend(org_id uuid, p_from date default null, p_bucket text default 'day')
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
    group by 1
  ), ret as (
    select date_trunc(p_bucket, r.return_date::timestamp)::date as b,
           sum(r.subtotal_reversed) as rs,
           sum(r.subtotal_reversed - r.cost_reversed) as rp
    from v_sales_returns r
    where r.organization_id = org_id
      and (p_from is null or r.return_date >= p_from)
    group by 1
  ), com as (
    select date_trunc(p_bucket, ic.invoice_date::timestamp)::date as b,
           sum(ic.earned_commission) as cm
    from invoice_commissions ic
    where fin
      and ic.organization_id = org_id
      and (p_from is null or ic.invoice_date >= p_from)
    group by 1
  ), opx as (
    select date_trunc(p_bucket, x.expense_date::timestamp)::date as b,
           sum(x.amount) as ex
    from operating_expenses x
    where fin
      and x.organization_id = org_id
      and (p_from is null or x.expense_date >= p_from)
    group by 1
  ), keys as (
    select k1.b from inv k1 union select k2.b from ret k2 union select k3.b from com k3 union select k4.b from opx k4
  ), rng as (
    select coalesce(date_trunc(p_bucket, p_from::timestamp)::date, (select min(k.b) from keys k)) as s,
           greatest(date_trunc(p_bucket, v_today::timestamp)::date, (select max(k.b) from keys k)) as e
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

revoke all on function dashboard_sales_trend(uuid, date, text) from public, anon;
grant execute on function dashboard_sales_trend(uuid, date, text) to authenticated;

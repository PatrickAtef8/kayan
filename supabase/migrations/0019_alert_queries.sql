-- Kayan — Phase 16: Notification queries (§45)
--
-- §45 lists seven alert kinds. Three already existed as simple derived
-- checks in the dashboard layout (low stock, customer debt, supplier due).
-- This adds the two that need real logic and are better computed in SQL
-- than by pulling whole tables into the Next.js layout on every page load:
--
--   * Outstanding collections — customers who still owe money, have a sale
--     older than p_days, and have NOT paid anything in the last p_days.
--     Judged per customer rather than per invoice on purpose: a collection
--     recorded without picking an invoice (allowed by
--     record_customer_collection) never updates any invoice's
--     payment_status, so an invoice-level "unpaid > 30 days" test would
--     raise false alarms for customers who did pay.
--
--   * Large expenses — the SRS names the alert but no threshold, and a
--     fixed amount would be meaningless across businesses of different
--     sizes. So "large" is relative: an expense in the last p_days that is
--     at least 3x the organization's own average expense, and only once
--     there are at least 5 expenses to average (with fewer, everything
--     looks unusual).
--
-- Both are financial (they expose balances / spend), so both require
-- view_financial, same as the balances they are derived from.
--
-- NOT covered: "Failed transactions". A failed RPC rolls back and leaves no
-- row anywhere, so there is nothing to alert on until failures are
-- recorded — that belongs with the error-tracking work in §58, not here.

create or replace function report_overdue_collections(org_id uuid, p_days int default 30)
returns table (customer_count bigint, total_balance numeric)
language plpgsql
stable
set search_path = public
as $$
declare
  v_days int := least(greatest(coalesce(p_days, 30), 1), 365);
begin
  perform assert_report_access(org_id, true);

  return query
  select count(*), coalesce(sum(b.balance), 0)::numeric
  from customer_balances b
  where b.organization_id = org_id
    and b.balance > 0
    and exists (
      select 1 from sales_invoices i
      where i.customer_id = b.customer_id and i.invoice_date < current_date - v_days
    )
    and not exists (
      select 1 from customer_collections c
      where c.customer_id = b.customer_id and c.collection_date >= current_date - v_days
    );
end;
$$;

create or replace function report_large_expenses(org_id uuid, p_days int default 7)
returns table (expense_count bigint, largest_amount numeric, average_amount numeric)
language plpgsql
stable
set search_path = public
as $$
declare
  v_days int := least(greatest(coalesce(p_days, 7), 1), 90);
  v_total bigint;
  v_avg numeric;
begin
  perform assert_report_access(org_id, true);

  select count(*), coalesce(avg(amount), 0) into v_total, v_avg
  from expenses where organization_id = org_id;

  if v_total < 5 then
    return query select 0::bigint, 0::numeric, v_avg::numeric;
    return;
  end if;

  return query
  select count(*), coalesce(max(e.amount), 0)::numeric, v_avg::numeric
  from expenses e
  where e.organization_id = org_id
    and e.expense_date >= current_date - v_days
    and e.amount >= v_avg * 3;
end;
$$;

revoke all on function report_overdue_collections(uuid, int) from public, anon;
revoke all on function report_large_expenses(uuid, int) from public, anon;
grant execute on function report_overdue_collections(uuid, int) to authenticated;
grant execute on function report_large_expenses(uuid, int) to authenticated;

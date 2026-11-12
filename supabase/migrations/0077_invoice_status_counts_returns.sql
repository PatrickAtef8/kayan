-- 0077: an invoice that is fully settled by payments AND returns is «paid», not «partial».
--
-- The status was decided only by  amount_paid >= total  (in create_sales_invoice, record_customer_collection and, on the purchase
-- side, create_purchase_invoice / record_supplier_payment). A return was never taken into account, so an invoice of 12,484.47 with
-- 12,285.67 collected and 198.80 returned owed nothing — remaining = 0, and the collection screen refused any further payment —
-- yet it stayed «partial» for ever, because no payment could ever push amount_paid up to the total.
--
-- One rule, in one place (the same arithmetic as sales_invoice_remaining() / purchase_invoice_remaining()):
--     remaining = total − amount_paid − returns + cash refunded
--     remaining <= 0          → paid
--     else amount_paid <= 0   → unpaid
--     else                    → partial
-- A refund in cash is added back, so «paid 100, returned 100, refunded 100» is settled, while «paid 100, returned 100, nothing
-- refunded» is also settled (the customer holds a credit of 100, which is a balance, not an open invoice).
--
-- How it is applied (the four payment functions are NOT rewritten — they are long and are redefined across many migrations):
--   * BEFORE UPDATE trigger on sales_invoices / purchase_invoices: whenever total, amount_paid or payment_status is written, the
--     status is recomputed from the rule above, whatever value the caller set;
--   * AFTER INSERT/UPDATE trigger on sales_returns / purchase_returns: when a return (or its totals) is written, the invoice's
--     status is recomputed, because a return changes what is still owed without touching amount_paid.
-- Existing rows are corrected at the end of this migration. updated_at is left alone.

-- ---------------------------------------------------------------------------------------------------------------------------------
-- the rule
-- ---------------------------------------------------------------------------------------------------------------------------------
create or replace function _settlement_status(p_total numeric, p_paid numeric, p_returned numeric, p_refunded numeric)
returns text
language sql
immutable
as $$
  select case
    when coalesce(p_total, 0) - coalesce(p_paid, 0) - coalesce(p_returned, 0) + coalesce(p_refunded, 0) <= 0.004 then 'paid'
    when coalesce(p_paid, 0) <= 0 then 'unpaid'
    else 'partial'
  end;
$$;

create or replace function _sales_invoice_status(p_invoice_id uuid, p_total numeric, p_paid numeric)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select _settlement_status(p_total, p_paid,
           coalesce((select sum(r.total)         from sales_returns r where r.sales_invoice_id = p_invoice_id), 0),
           coalesce((select sum(r.cash_refunded) from sales_returns r where r.sales_invoice_id = p_invoice_id), 0));
$$;

create or replace function _purchase_invoice_status(p_invoice_id uuid, p_total numeric, p_paid numeric)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select _settlement_status(p_total, p_paid,
           coalesce((select sum(r.total)         from purchase_returns r where r.purchase_invoice_id = p_invoice_id), 0),
           coalesce((select sum(r.cash_refunded) from purchase_returns r where r.purchase_invoice_id = p_invoice_id), 0));
$$;

revoke all on function _settlement_status(numeric, numeric, numeric, numeric) from public, anon;
revoke all on function _sales_invoice_status(uuid, numeric, numeric)          from public, anon;
revoke all on function _purchase_invoice_status(uuid, numeric, numeric)       from public, anon;

-- ---------------------------------------------------------------------------------------------------------------------------------
-- sales
-- ---------------------------------------------------------------------------------------------------------------------------------
create or replace function _sales_invoice_sync_status() returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  new.payment_status := _sales_invoice_status(new.id, new.total, new.amount_paid);
  return new;
end;
$$;

create or replace function _sales_return_sync_invoice_status() returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  update sales_invoices i
     set payment_status = _sales_invoice_status(i.id, i.total, i.amount_paid)
   where i.id = new.sales_invoice_id
     and i.payment_status is distinct from _sales_invoice_status(i.id, i.total, i.amount_paid);
  return null;
end;
$$;

revoke all on function _sales_invoice_sync_status()         from public, anon;
revoke all on function _sales_return_sync_invoice_status()  from public, anon;

drop trigger if exists a_sync_status on sales_invoices;
create trigger a_sync_status before update of total, amount_paid, payment_status on sales_invoices
  for each row execute function _sales_invoice_sync_status();

drop trigger if exists z_sync_invoice_status on sales_returns;
create trigger z_sync_invoice_status after insert or update of total, cash_refunded on sales_returns
  for each row execute function _sales_return_sync_invoice_status();

-- ---------------------------------------------------------------------------------------------------------------------------------
-- purchases (same rule, same defect)
-- ---------------------------------------------------------------------------------------------------------------------------------
create or replace function _purchase_invoice_sync_status() returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  new.payment_status := _purchase_invoice_status(new.id, new.total, new.amount_paid);
  return new;
end;
$$;

create or replace function _purchase_return_sync_invoice_status() returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  update purchase_invoices i
     set payment_status = _purchase_invoice_status(i.id, i.total, i.amount_paid)
   where i.id = new.purchase_invoice_id
     and i.payment_status is distinct from _purchase_invoice_status(i.id, i.total, i.amount_paid);
  return null;
end;
$$;

revoke all on function _purchase_invoice_sync_status()         from public, anon;
revoke all on function _purchase_return_sync_invoice_status()  from public, anon;

drop trigger if exists a_sync_status on purchase_invoices;
create trigger a_sync_status before update of total, amount_paid, payment_status on purchase_invoices
  for each row execute function _purchase_invoice_sync_status();

drop trigger if exists z_sync_invoice_status on purchase_returns;
create trigger z_sync_invoice_status after insert or update of total, cash_refunded on purchase_returns
  for each row execute function _purchase_return_sync_invoice_status();

-- ---------------------------------------------------------------------------------------------------------------------------------
-- correct the invoices that already exist
-- ---------------------------------------------------------------------------------------------------------------------------------
update sales_invoices i
   set payment_status = _sales_invoice_status(i.id, i.total, i.amount_paid)
 where i.payment_status is distinct from _sales_invoice_status(i.id, i.total, i.amount_paid);

update purchase_invoices i
   set payment_status = _purchase_invoice_status(i.id, i.total, i.amount_paid)
 where i.payment_status is distinct from _purchase_invoice_status(i.id, i.total, i.amount_paid);

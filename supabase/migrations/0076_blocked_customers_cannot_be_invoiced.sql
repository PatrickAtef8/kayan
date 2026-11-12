-- 0076: a customer whose credit status is «محظور» (blocked) cannot be given a NEW sales invoice.
--
-- Until now «blocked» was only a coloured label in the customers list: the database accepted a new invoice for a blocked customer
-- from any caller (owner, rep, direct RPC), so the status protected nothing.
--
-- The rule lives in the database, on sales_invoices, so it covers every way an invoice can be created (the sales form, a rep's form,
-- the create_sales_invoice() RPC called directly) and cannot be skipped from the browser. The error is Arabic, so the sales form shows
-- it as it is (safeErrorMessage passes Arabic business messages through).
--
-- Deliberately NOT blocked: collecting money from the customer, recording his returns, reading his statement. A blocked customer
-- usually owes money, and the point of the status is to stop NEW credit, not to stop him from paying what he owes.
-- «مراقبة» (watch) is a warning only and is not affected.

create or replace function _reject_blocked_customer() returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_status text;
  v_name   text;
begin
  select c.credit_status, c.name into v_status, v_name from customers c where c.id = new.customer_id;
  if v_status = 'blocked' then
    raise exception 'العميل "%" محظور — لا يمكن إصدار فاتورة جديدة له. غيّر حالته الائتمانية أولًا.', v_name;
  end if;
  return new;
end;
$$;

revoke all on function _reject_blocked_customer() from public, anon;

drop trigger if exists a_reject_blocked_customer on sales_invoices;
-- "a_r…" sorts after the module check (a_enforce_module) and before the duplicate guard (b_…): a blocked customer is refused first.
create trigger a_reject_blocked_customer before insert on sales_invoices
  for each row execute function _reject_blocked_customer();

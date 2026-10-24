-- Kayan — Phase 47: notifications that are never silently lost + backfill of open dispatch/receiving work
-- Depends on 0046. Re-runnable.  TAKE A DATABASE BACKUP FIRST.
--
-- 1. RELIABILITY
--    0046 turned a failure while building a notification into a WARNING (the sale must not fail because of a
--    bell) — but that meant the notification was lost.  Now the failure is RECORDED in `notification_failures`
--    (what happened, to which row) and retried:
--      * the business transaction still commits (a failure never blocks an invoice, never repeats an operation);
--      * the builders are idempotent (dedupe keys), so a retry can never create a second notification;
--      * `process_notification_retries(org)` re-runs the pending ones (up to 10 attempts each).  The app calls
--        it from the bell on load / focus / reconnect — no cron or extra service needed.
--    The triggers are now thin wrappers around `_ntf_build_*(row id)` builders (same logic as 0046), so the same
--    code serves the first attempt and every retry.  NO invoice / stock / accounting function is touched.
--
-- 2. BACKFILL
--    Invoices that were already waiting for dispatch / receiving when 0046 was applied have no task card.  This
--    creates them for every storekeeper (unread, dated by the invoice), with today's remaining quantities.
--    Idempotent (same dedupe key as the trigger), items/quantities only, no stock or money is read or changed.

-- ============================================================
-- 1. Failure outbox
-- ============================================================
create table if not exists notification_failures (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  kind            text not null check (kind in ('sales_invoice', 'purchase_invoice', 'fulfilment_event', 'customer_collection',
                                               'supplier_payment', 'sales_return', 'purchase_return', 'shortage_insert', 'shortage_update')),
  ref_id          uuid not null,
  args            jsonb not null default '{}'::jsonb,
  error           text,
  attempts        integer not null default 0,
  created_at      timestamptz not null default now(),
  last_attempt_at timestamptz,
  done_at         timestamptz
);
-- one pending record per source row, however many times it fails
create unique index if not exists notification_failures_pending_idx on notification_failures (kind, ref_id) where done_at is null;
create index if not exists notification_failures_org_idx on notification_failures (organization_id) where done_at is null;
alter table notification_failures enable row level security;
alter table notification_failures force row level security;
revoke all on notification_failures from public, anon, authenticated;

create or replace function _ntf_record_failure(p_org uuid, p_kind text, p_ref uuid, p_args jsonb, p_err text) returns void
language plpgsql security definer set search_path = public as $$
begin
  begin
    insert into notification_failures (organization_id, kind, ref_id, args, error)
    values (p_org, p_kind, p_ref, coalesce(p_args, '{}'::jsonb), left(p_err, 500))
    on conflict (kind, ref_id) where done_at is null do update set error = excluded.error;
  exception when others then
    raise warning 'notifications: could not record failure of % %: % (original: %)', p_kind, p_ref, sqlerrm, p_err;   -- last resort
  end;
end $$;
revoke all on function _ntf_record_failure(uuid, text, uuid, jsonb, text) from public, anon, authenticated;

-- ============================================================
-- 2. Builders (the 0046 trigger bodies, keyed by row id so they can be re-run)
-- ============================================================
create or replace function _ntf_build_sales_invoice(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare i sales_invoices%rowtype; v_cust text; v_rep_name text; v_rep_user uuid; v_no text; v_by text; v_wh text; v_lines jsonb;
begin
  select * into i from sales_invoices where id = p_id;
  if not found then return; end if;
  v_no := _ntf_invoice_no('sales', i.id);
  select c.name into v_cust from customers c where c.id = i.customer_id;
  select sr.name, sr.user_id into v_rep_name, v_rep_user from sales_representatives sr where sr.id = i.sales_rep_id and sr.organization_id = i.organization_id;
  v_by := _ntf_actor_label(i.organization_id, i.created_by);

  perform _ntf_to_owners(i.organization_id, i.created_by, 'sales_invoice_created', 'فاتورة بيع جديدة ' || v_no,
    '/dashboard/sales?q=' || v_no, 'sales_invoice', i.id,
    jsonb_build_object('invoice_number', v_no, 'customer', v_cust, 'total', i.total, 'amount_paid', i.amount_paid, 'rep', v_rep_name, 'by', v_by),
    'sales-invoice:' || i.id);
  perform _ntf_send(i.organization_id, v_rep_user, i.created_by, 'rep_invoice_created', 'فاتورة بيع جديدة ' || v_no,
    '/dashboard/sales?q=' || v_no, 'sales_invoice', i.id,
    jsonb_build_object('invoice_number', v_no, 'customer', v_cust, 'total', i.total, 'amount_paid', i.amount_paid, 'by', v_by),
    'rep-sales-invoice:' || i.id);

  v_lines := _ntf_work_lines('sales', i.id);
  if jsonb_array_length(v_lines) > 0 then
    select w.name into v_wh from warehouses w where w.id = i.warehouse_id;
    perform _ntf_to_storekeepers(i.organization_id, i.created_by, 'warehouse_dispatch_needed', 'فاتورة بيع ' || v_no || ' بانتظار التجهيز والصرف',
      '/dashboard/warehouse-orders?tab=sales&status=open&q=' || v_no, 'sales', i.id,
      jsonb_build_object('invoice_number', v_no, 'warehouse', v_wh, 'kind', 'sales', 'status', i.dispatch_status, 'lines', v_lines),
      'work:sales:' || i.id);
  end if;
end $$;

create or replace function _ntf_build_purchase_invoice(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare i purchase_invoices%rowtype; v_sup text; v_no text; v_by text; v_wh text; v_lines jsonb;
begin
  select * into i from purchase_invoices where id = p_id;
  if not found then return; end if;
  v_no := _ntf_invoice_no('purchase', i.id);
  select s.name into v_sup from suppliers s where s.id = i.supplier_id;
  v_by := _ntf_actor_label(i.organization_id, i.created_by);

  perform _ntf_to_owners(i.organization_id, i.created_by, 'purchase_invoice_created', 'فاتورة شراء جديدة ' || v_no,
    '/dashboard/purchases?q=' || v_no, 'purchase_invoice', i.id,
    jsonb_build_object('invoice_number', v_no, 'supplier', v_sup, 'total', i.total, 'amount_paid', i.amount_paid, 'by', v_by),
    'purchase-invoice:' || i.id);

  v_lines := _ntf_work_lines('purchase', i.id);
  if jsonb_array_length(v_lines) > 0 then
    select w.name into v_wh from warehouses w where w.id = i.warehouse_id;
    perform _ntf_to_storekeepers(i.organization_id, i.created_by, 'warehouse_receipt_needed', 'فاتورة شراء ' || v_no || ' بانتظار الاستلام',
      '/dashboard/warehouse-orders?tab=purchase&status=open&q=' || v_no, 'purchase', i.id,
      jsonb_build_object('invoice_number', v_no, 'warehouse', v_wh, 'kind', 'purchase', 'status', i.receipt_status, 'lines', v_lines),
      'work:purchase:' || i.id);
  end if;
end $$;

create or replace function _ntf_build_fulfilment_event(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare
  e fulfilment_events%rowtype; v_first uuid; v_no text; v_status text; v_done jsonb; v_left jsonb;
  v_rep_user uuid; v_cust text; v_by text; v_title text;
begin
  select * into e from fulfilment_events where id = p_id;
  if not found then return; end if;
  perform _ntf_refresh_work(e.kind, e.organization_id, e.invoice_id, e.confirmed_by);

  if e.event_type = 'confirm' then
    -- one notification per confirmation: composed by its first line (a retry of a later line is a no-op by the dedupe key)
    v_no := _ntf_invoice_no(e.kind, e.invoice_id);
    v_by := _ntf_actor_label(e.organization_id, e.confirmed_by);
    select coalesce(jsonb_agg(jsonb_build_object('name', p.name, 'unit', p.unit, 'qty', q.qty) order by p.name), '[]'::jsonb) into v_done
    from (select product_id, sum(quantity) qty from fulfilment_events where confirmation_id = e.confirmation_id and event_type = 'confirm' group by product_id) q
    join products p on p.id = q.product_id;
    select coalesce(jsonb_agg(x order by x->>'name'), '[]'::jsonb) into v_left
    from jsonb_array_elements(_ntf_work_lines(e.kind, e.invoice_id)) x where (x->>'remaining')::numeric > 0;

    if e.kind = 'sales' then
      select i.dispatch_status, sr.user_id, c.name into v_status, v_rep_user, v_cust
      from sales_invoices i left join sales_representatives sr on sr.id = i.sales_rep_id left join customers c on c.id = i.customer_id where i.id = e.invoice_id;
      v_title := case when v_status = 'dispatched' then 'تم صرف فاتورة البيع ' else 'تم صرف جزء من فاتورة البيع ' end || v_no;
      perform _ntf_to_owners(e.organization_id, e.confirmed_by, 'dispatch_confirmed', v_title,
        '/dashboard/sales?q=' || v_no, 'sales_invoice', e.invoice_id,
        jsonb_build_object('invoice_number', v_no, 'customer', v_cust, 'status', v_status, 'by', v_by, 'done', v_done, 'left', v_left),
        'confirm:' || e.confirmation_id);
      perform _ntf_send(e.organization_id, v_rep_user, e.confirmed_by, 'rep_dispatch_update', v_title,
        '/dashboard/sales?q=' || v_no, 'sales_invoice', e.invoice_id,
        jsonb_build_object('invoice_number', v_no, 'customer', v_cust, 'status', v_status, 'done', v_done, 'left', v_left),
        'rep-confirm:' || e.confirmation_id);
    else
      select i.receipt_status, s.name into v_status, v_cust
      from purchase_invoices i left join suppliers s on s.id = i.supplier_id where i.id = e.invoice_id;
      v_title := case when v_status = 'received' then 'تم استلام فاتورة الشراء ' else 'تم استلام جزء من فاتورة الشراء ' end || v_no;
      perform _ntf_to_owners(e.organization_id, e.confirmed_by, 'receipt_confirmed', v_title,
        '/dashboard/purchases?q=' || v_no, 'purchase_invoice', e.invoice_id,
        jsonb_build_object('invoice_number', v_no, 'supplier', v_cust, 'status', v_status, 'by', v_by, 'done', v_done, 'left', v_left),
        'confirm:' || e.confirmation_id);
    end if;
  end if;
end $$;

-- p_initial: the payment was taken together with its invoice (already part of the invoice notification)
create or replace function _ntf_build_customer_collection(p_id uuid, p_initial boolean) returns void
language plpgsql security definer set search_path = public as $$
declare c customer_collections%rowtype; v_cust text; v_rep uuid; v_no text; v_payload jsonb;
begin
  select * into c from customer_collections where id = p_id;
  if not found or coalesce(p_initial, false) then return; end if;
  select cu.name, cu.sales_rep_id into v_cust, v_rep from customers cu where cu.id = c.customer_id;
  if c.sales_invoice_id is not null then v_no := _ntf_invoice_no('sales', c.sales_invoice_id); end if;
  v_payload := jsonb_build_object('customer', v_cust, 'amount', c.amount, 'invoice_number', v_no, 'method', c.payment_method,
                                  'by', _ntf_actor_label(c.organization_id, c.created_by));
  perform _ntf_to_owners(c.organization_id, c.created_by, 'customer_payment', 'تحصيل من العميل ' || coalesce(v_cust, ''),
    '/dashboard/reports/debts/payments', 'customer_collection', c.id, v_payload, 'collection:' || c.id);
  perform _ntf_send(c.organization_id, _ntf_rep_user(c.organization_id, v_rep), c.created_by, 'rep_payment', 'تحصيل من العميل ' || coalesce(v_cust, ''),
    '/dashboard/customers', 'customer_collection', c.id, v_payload - 'by', 'rep-collection:' || c.id);
end $$;

create or replace function _ntf_build_supplier_payment(p_id uuid, p_initial boolean) returns void
language plpgsql security definer set search_path = public as $$
declare sp supplier_payments%rowtype; v_sup text; v_no text;
begin
  select * into sp from supplier_payments where id = p_id;
  if not found or coalesce(p_initial, false) then return; end if;
  select s.name into v_sup from suppliers s where s.id = sp.supplier_id;
  if sp.purchase_invoice_id is not null then v_no := _ntf_invoice_no('purchase', sp.purchase_invoice_id); end if;
  perform _ntf_to_owners(sp.organization_id, sp.created_by, 'supplier_payment', 'دفعة للمورد ' || coalesce(v_sup, ''),
    '/dashboard/suppliers', 'supplier_payment', sp.id,
    jsonb_build_object('supplier', v_sup, 'amount', sp.amount, 'invoice_number', v_no, 'method', sp.payment_method, 'by', _ntf_actor_label(sp.organization_id, sp.created_by)),
    'supplier-payment:' || sp.id);
end $$;

create or replace function _ntf_build_sales_return(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare r sales_returns%rowtype; v_no text; v_cust text; v_rep uuid; v_payload jsonb;
begin
  select * into r from sales_returns where id = p_id;
  if not found then return; end if;
  v_no := _ntf_invoice_no('sales', r.sales_invoice_id);
  select c.name into v_cust from customers c where c.id = r.customer_id;
  select i.sales_rep_id into v_rep from sales_invoices i where i.id = r.sales_invoice_id;
  v_payload := jsonb_build_object('invoice_number', v_no, 'customer', v_cust, 'total', r.total, 'by', _ntf_actor_label(r.organization_id, r.created_by));
  perform _ntf_to_owners(r.organization_id, r.created_by, 'sales_return_created', 'مرتجع على فاتورة البيع ' || v_no,
    '/dashboard/sales/returns', 'sales_return', r.id, v_payload, 'sales-return:' || r.id);
  perform _ntf_send(r.organization_id, _ntf_rep_user(r.organization_id, v_rep), r.created_by, 'rep_return', 'مرتجع على فاتورة البيع ' || v_no,
    '/dashboard/sales/returns', 'sales_return', r.id, v_payload - 'by', 'rep-sales-return:' || r.id);
end $$;

create or replace function _ntf_build_purchase_return(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare r purchase_returns%rowtype; v_no text; v_sup text;
begin
  select * into r from purchase_returns where id = p_id;
  if not found then return; end if;
  v_no := _ntf_invoice_no('purchase', r.purchase_invoice_id);
  select s.name into v_sup from suppliers s where s.id = r.supplier_id;
  perform _ntf_to_owners(r.organization_id, r.created_by, 'purchase_return_created', 'مرتجع على فاتورة الشراء ' || v_no,
    '/dashboard/purchases/returns', 'purchase_return', r.id,
    jsonb_build_object('invoice_number', v_no, 'supplier', v_sup, 'total', r.total, 'by', _ntf_actor_label(r.organization_id, r.created_by)),
    'purchase-return:' || r.id);
end $$;

create or replace function _ntf_build_shortage_insert(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare s stock_shortage_reports%rowtype; v_prod text; v_unit text; v_wh text;
begin
  select * into s from stock_shortage_reports where id = p_id;
  if not found then return; end if;
  select p.name, p.unit into v_prod, v_unit from products p where p.id = s.product_id;
  select w.name into v_wh from warehouses w where w.id = s.warehouse_id;
  perform _ntf_to_owners(s.organization_id, s.reported_by, 'shortage_reported', 'بلاغ نقص: ' || coalesce(v_prod, ''),
    '/dashboard/shortages?status=new', 'shortage_report', s.id,
    jsonb_build_object('product', v_prod, 'unit', v_unit, 'warehouse', v_wh, 'needed', s.needed_qty, 'available', s.available_qty, 'rep', s.rep_name, 'note', s.note),
    'shortage:' || s.id);
  -- the report may already have been replaced / resolved by the time a retry runs: keep the card in step
  if s.superseded_by is not null or s.status = 'resolved' then
    update notifications set resolved_at = coalesce(resolved_at, now()), updated_at = now()
    where organization_id = s.organization_id and type = 'shortage_reported' and entity_id = s.id;
  end if;
end $$;

create or replace function _ntf_build_shortage_update(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare s stock_shortage_reports%rowtype; v_prod text; v_unit text;
begin
  select * into s from stock_shortage_reports where id = p_id;
  if not found then return; end if;
  -- owner's card: a task — done once provided or replaced, open otherwise
  update notifications set resolved_at = case when s.status = 'resolved' or s.superseded_by is not null then coalesce(resolved_at, now()) else null end, updated_at = now()
  where organization_id = s.organization_id and type = 'shortage_reported' and entity_id = s.id;

  if s.status in ('in_progress', 'resolved') and s.superseded_by is null then
    select p.name, p.unit into v_prod, v_unit from products p where p.id = s.product_id;
    perform _ntf_send(s.organization_id, s.reported_by, s.status_changed_by, 'shortage_status',
      case when s.status = 'resolved' then 'تم توفير الصنف الذي أبلغت عن نقصه: ' else 'جاري تجهيز الصنف الذي أبلغت عن نقصه: ' end || coalesce(v_prod, ''),
      '/dashboard/shortages?status=' || case when s.status = 'resolved' then 'resolved' else 'in_progress' end, 'shortage_report', s.id,
      jsonb_build_object('product', v_prod, 'unit', v_unit, 'status', s.status, 'needed', s.needed_qty, 'owner_note', s.owner_note),
      'shortage-status:' || s.id || ':' || s.status || ':' || extract(epoch from coalesce(s.status_changed_at, now()))::text);
  end if;
end $$;

revoke all on function _ntf_build_sales_invoice(uuid), _ntf_build_purchase_invoice(uuid), _ntf_build_fulfilment_event(uuid),
  _ntf_build_customer_collection(uuid, boolean), _ntf_build_supplier_payment(uuid, boolean), _ntf_build_sales_return(uuid),
  _ntf_build_purchase_return(uuid), _ntf_build_shortage_insert(uuid), _ntf_build_shortage_update(uuid) from public, anon, authenticated;

-- ============================================================
-- 3. Triggers: build now; if that fails, record it for retry (never abort the business transaction)
-- ============================================================
create or replace function _ntf_on_sales_invoice() returns trigger language plpgsql security definer set search_path = public as $$
begin
  begin perform _ntf_build_sales_invoice(NEW.id);
  exception when others then perform _ntf_record_failure(NEW.organization_id, 'sales_invoice', NEW.id, '{}', sqlerrm); end;
  return null;
end $$;
create or replace function _ntf_on_purchase_invoice() returns trigger language plpgsql security definer set search_path = public as $$
begin
  begin perform _ntf_build_purchase_invoice(NEW.id);
  exception when others then perform _ntf_record_failure(NEW.organization_id, 'purchase_invoice', NEW.id, '{}', sqlerrm); end;
  return null;
end $$;
create or replace function _ntf_on_fulfilment_event() returns trigger language plpgsql security definer set search_path = public as $$
begin
  begin perform _ntf_build_fulfilment_event(NEW.id);
  exception when others then perform _ntf_record_failure(NEW.organization_id, 'fulfilment_event', NEW.id, '{}', sqlerrm); end;
  return null;
end $$;
create or replace function _ntf_on_customer_collection() returns trigger language plpgsql security definer set search_path = public as $$
declare v_initial boolean := false;
begin
  begin
    v_initial := NEW.sales_invoice_id is not null and exists (select 1 from sales_invoices i where i.id = NEW.sales_invoice_id and i.created_at = now());
    perform _ntf_build_customer_collection(NEW.id, v_initial);
  exception when others then perform _ntf_record_failure(NEW.organization_id, 'customer_collection', NEW.id, jsonb_build_object('initial', v_initial), sqlerrm); end;
  return null;
end $$;
create or replace function _ntf_on_supplier_payment() returns trigger language plpgsql security definer set search_path = public as $$
declare v_initial boolean := false;
begin
  begin
    v_initial := NEW.purchase_invoice_id is not null and exists (select 1 from purchase_invoices i where i.id = NEW.purchase_invoice_id and i.created_at = now());
    perform _ntf_build_supplier_payment(NEW.id, v_initial);
  exception when others then perform _ntf_record_failure(NEW.organization_id, 'supplier_payment', NEW.id, jsonb_build_object('initial', v_initial), sqlerrm); end;
  return null;
end $$;
create or replace function _ntf_on_sales_return() returns trigger language plpgsql security definer set search_path = public as $$
begin
  begin perform _ntf_build_sales_return(NEW.id);
  exception when others then perform _ntf_record_failure(NEW.organization_id, 'sales_return', NEW.id, '{}', sqlerrm); end;
  return null;
end $$;
create or replace function _ntf_on_purchase_return() returns trigger language plpgsql security definer set search_path = public as $$
begin
  begin perform _ntf_build_purchase_return(NEW.id);
  exception when others then perform _ntf_record_failure(NEW.organization_id, 'purchase_return', NEW.id, '{}', sqlerrm); end;
  return null;
end $$;
create or replace function _ntf_on_shortage_insert() returns trigger language plpgsql security definer set search_path = public as $$
begin
  begin perform _ntf_build_shortage_insert(NEW.id);
  exception when others then perform _ntf_record_failure(NEW.organization_id, 'shortage_insert', NEW.id, '{}', sqlerrm); end;
  return null;
end $$;
create or replace function _ntf_on_shortage_update() returns trigger language plpgsql security definer set search_path = public as $$
begin
  begin perform _ntf_build_shortage_update(NEW.id);
  exception when others then perform _ntf_record_failure(NEW.organization_id, 'shortage_update', NEW.id, '{}', sqlerrm); end;
  return null;
end $$;

revoke all on function _ntf_on_sales_invoice(), _ntf_on_purchase_invoice(), _ntf_on_fulfilment_event(), _ntf_on_customer_collection(),
  _ntf_on_supplier_payment(), _ntf_on_sales_return(), _ntf_on_purchase_return(), _ntf_on_shortage_insert(), _ntf_on_shortage_update()
  from public, anon, authenticated;

-- ============================================================
-- 4. Retry (callable by any member of the organization; processes only that organization's pending failures)
-- ============================================================
create or replace function _ntf_run_failure(f notification_failures) returns void
language plpgsql security definer set search_path = public as $$
begin
  case f.kind
    when 'sales_invoice'       then perform _ntf_build_sales_invoice(f.ref_id);
    when 'purchase_invoice'    then perform _ntf_build_purchase_invoice(f.ref_id);
    when 'fulfilment_event'    then perform _ntf_build_fulfilment_event(f.ref_id);
    when 'customer_collection' then perform _ntf_build_customer_collection(f.ref_id, coalesce((f.args->>'initial')::boolean, false));
    when 'supplier_payment'    then perform _ntf_build_supplier_payment(f.ref_id, coalesce((f.args->>'initial')::boolean, false));
    when 'sales_return'        then perform _ntf_build_sales_return(f.ref_id);
    when 'purchase_return'     then perform _ntf_build_purchase_return(f.ref_id);
    when 'shortage_insert'     then perform _ntf_build_shortage_insert(f.ref_id);
    when 'shortage_update'     then perform _ntf_build_shortage_update(f.ref_id);
  end case;
end $$;
revoke all on function _ntf_run_failure(notification_failures) from public, anon, authenticated;

-- Returns how many failures are STILL pending for the organization after this run.
create or replace function process_notification_retries(org_id uuid) returns integer
language plpgsql security definer set search_path = public as $$
declare f notification_failures%rowtype;
begin
  perform _ntf_guard(org_id);
  for f in select * from notification_failures
           where organization_id = org_id and done_at is null and attempts < 10
           order by created_at limit 25 for update skip locked      -- two tabs retrying at once never double-process
  loop
    begin
      perform _ntf_run_failure(f);
      update notification_failures set done_at = now(), last_attempt_at = now(), attempts = attempts + 1 where id = f.id;
    exception when others then
      update notification_failures set attempts = attempts + 1, last_attempt_at = now(), error = left(sqlerrm, 500) where id = f.id;
    end;
  end loop;
  return (select count(*)::int from notification_failures where organization_id = org_id and done_at is null and attempts < 10);
end $$;
revoke all on function process_notification_retries(uuid) from public, anon;
grant execute on function process_notification_retries(uuid) to authenticated;

-- ============================================================
-- 5. Backfill: dispatch / receiving work that was already open before 0046
--    (items + quantities only; reads invoice_stock_lines, writes only notifications)
-- ============================================================
create or replace function _ntf_backfill_open_work() returns integer
language plpgsql security definer set search_path = public as $$
declare i record; u record; v_lines jsonb; v_no text; v_wh text; v_n integer := 0; v_inserted integer;
begin
  for i in
    select 'sales'::text as kind, s.id, s.organization_id, s.warehouse_id, s.dispatch_status as status, s.created_at
    from sales_invoices s where s.dispatch_status in ('pending', 'partial')
    union all
    select 'purchase', p.id, p.organization_id, p.warehouse_id, p.receipt_status, p.created_at
    from purchase_invoices p where p.receipt_status in ('pending', 'partial')
  loop
    v_lines := _ntf_work_lines(i.kind, i.id);
    continue when jsonb_array_length(v_lines) = 0;
    v_no := _ntf_invoice_no(i.kind, i.id);
    select w.name into v_wh from warehouses w where w.id = i.warehouse_id;
    for u in select ou.user_id from organization_users ou join roles r on r.id = ou.role_id
             where ou.organization_id = i.organization_id and ou.status = 'active' and r.key = 'warehouse'
    loop
      insert into notifications (organization_id, recipient_user_id, type, title, href, entity_type, entity_id, payload, dedupe_key, created_at, updated_at)
      values (i.organization_id, u.user_id,
              case when i.kind = 'sales' then 'warehouse_dispatch_needed' else 'warehouse_receipt_needed' end,
              case when i.kind = 'sales' then 'فاتورة بيع ' || v_no || ' بانتظار التجهيز والصرف' else 'فاتورة شراء ' || v_no || ' بانتظار الاستلام' end,
              '/dashboard/warehouse-orders?tab=' || i.kind || '&status=open&q=' || v_no,
              i.kind, i.id,
              jsonb_build_object('invoice_number', v_no, 'warehouse', v_wh, 'kind', i.kind, 'status', i.status, 'lines', v_lines),
              'work:' || i.kind || ':' || i.id, i.created_at, now())
      on conflict (organization_id, recipient_user_id, dedupe_key) do nothing;     -- same key as the trigger: never a duplicate
      get diagnostics v_inserted = row_count;
      v_n := v_n + v_inserted;
    end loop;
  end loop;
  return v_n;
end $$;
revoke all on function _ntf_backfill_open_work() from public, anon, authenticated;

select _ntf_backfill_open_work();

-- Kayan — Phase 46: stored, role-scoped, realtime notifications
-- Depends on 0043–0045. Re-runnable.  TAKE A DATABASE BACKUP FIRST.
--
-- WHY
--   The old bell was computed on every page render from live data and had no state at all: there was
--   nothing that could be "read", so the red dot was shown for as long as ANY alert existed.
--
-- WHAT THIS ADDS (and nothing else)
--   * `notifications`: one row per recipient (fan-out), so "read" is simply that user's own read_at.
--     `resolved_at` is a SEPARATE flag: reading a notification never means the task itself is done,
--     and finishing a task never silently marks it read.
--   * Triggers on the existing tables (invoices, fulfilment events, payments, returns, shortage
--     reports) create the notifications.  NO existing function is replaced, so invoice, stock, cost,
--     commission and balance logic is byte-for-byte what it was — nothing can be double-deducted.
--   * A deduplication key per (organization, recipient) makes every event produce at most one row,
--     however many times its trigger fires.
--   * Visibility is enforced by RLS + the RPCs below (recipient only, and only the types that belong
--     to the recipient's CURRENT role), so a user whose role changed never reads old rows that were
--     meant for the previous role.  The storekeeper's payload is whitelisted: no price/total/party.
--   * The table is added to the supabase_realtime publication; Realtime applies the same RLS.
--
-- A failure while building a notification is turned into a WARNING and never aborts the business
-- transaction (an invoice must not fail because of a bell).

-- ============================================================
-- 1. Table
-- ============================================================
create table if not exists notifications (
  id                uuid primary key default gen_random_uuid(),
  organization_id   uuid not null references organizations(id) on delete cascade,
  recipient_user_id uuid not null references auth.users(id) on delete cascade,
  type              text not null check (type in (
    -- owner
    'sales_invoice_created', 'purchase_invoice_created', 'dispatch_confirmed', 'receipt_confirmed',
    'customer_payment', 'supplier_payment', 'sales_return_created', 'purchase_return_created', 'shortage_reported',
    -- storekeeper (quantities only)
    'warehouse_dispatch_needed', 'warehouse_receipt_needed',
    -- sales rep (own invoices / own customers only)
    'rep_invoice_created', 'rep_dispatch_update', 'rep_payment', 'rep_return', 'shortage_status')),
  title             text not null check (char_length(title) between 1 and 200),
  href              text check (href is null or href ~ '^/dashboard(/|\?|$)'),
  entity_type       text,
  entity_id         uuid,
  payload           jsonb not null default '{}'::jsonb,
  dedupe_key        text not null check (char_length(dedupe_key) between 1 and 200),
  read_at           timestamptz,
  resolved_at       timestamptz,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

create unique index if not exists notifications_dedupe_idx on notifications (organization_id, recipient_user_id, dedupe_key);
create index if not exists notifications_inbox_idx on notifications (recipient_user_id, organization_id, created_at desc, id);
create index if not exists notifications_unread_idx on notifications (recipient_user_id, organization_id) where read_at is null;
create index if not exists notifications_entity_idx on notifications (organization_id, entity_type, entity_id);

alter table notifications enable row level security;
alter table notifications force row level security;
revoke all on notifications from public, anon, authenticated;
grant select on notifications to authenticated;     -- rows are filtered by the policy below; every write goes through definer functions

-- ============================================================
-- 2. Who may see which type (follows the CURRENT role, not the role at creation time)
-- ============================================================
create or replace function _notif_type_visible(p_org uuid, p_type text) returns boolean
language sql stable security definer set search_path = public as $$
  select case my_role_key(p_org)
    when 'owner'     then true
    when 'sales'     then p_type in ('rep_invoice_created', 'rep_dispatch_update', 'rep_payment', 'rep_return', 'shortage_status')
    when 'warehouse' then p_type in ('warehouse_dispatch_needed', 'warehouse_receipt_needed')
    else false
  end
$$;
revoke all on function _notif_type_visible(uuid, text) from public, anon;
grant execute on function _notif_type_visible(uuid, text) to authenticated;

drop policy if exists notifications_recipient_select on notifications;
create policy notifications_recipient_select on notifications for select to authenticated
  using (recipient_user_id = auth.uid() and _notif_type_visible(organization_id, type));

-- ============================================================
-- 3. Internal helpers (never callable from the API)
-- ============================================================
create or replace function _ntf_role_of(p_org uuid, p_user uuid) returns text
language sql stable security definer set search_path = public as $$
  select r.key from organization_users ou join roles r on r.id = ou.role_id
  where ou.organization_id = p_org and ou.user_id = p_user and ou.status = 'active' limit 1
$$;

create or replace function _ntf_actor_label(p_org uuid, p_user uuid) returns text
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select sr.name from sales_representatives sr where sr.organization_id = p_org and sr.user_id = p_user limit 1),
    (select u.email::text from auth.users u where u.id = p_user),
    'النظام')
$$;

create or replace function _ntf_rep_user(p_org uuid, p_rep uuid) returns uuid
language sql stable security definer set search_path = public as $$
  select sr.user_id from sales_representatives sr where sr.id = p_rep and sr.organization_id = p_org
$$;

create or replace function _ntf_invoice_no(p_kind text, p_id uuid) returns text
language sql stable security definer set search_path = public as $$
  select coalesce(
    case when p_kind = 'sales' then (select nullif(btrim(i.invoice_number), '') from sales_invoices i where i.id = p_id)
         else (select nullif(btrim(i.invoice_number), '') from purchase_invoices i where i.id = p_id) end,
    left(p_id::text, 8))
$$;

-- The type decides which role may receive it; a mismatch is dropped, never delivered.
create or replace function _ntf_required_role(p_type text) returns text
language sql immutable as $$
  select case
    when p_type in ('warehouse_dispatch_needed', 'warehouse_receipt_needed') then 'warehouse'
    when p_type in ('rep_invoice_created', 'rep_dispatch_update', 'rep_payment', 'rep_return', 'shortage_status') then 'sales'
    else 'owner' end
$$;

-- Storekeeper payloads may carry only these keys: items and quantities, never money or parties.
create or replace function _ntf_warehouse_payload_ok(p jsonb) returns boolean
language plpgsql immutable as $$
declare k text; l jsonb;
begin
  if jsonb_typeof(p) <> 'object' then return false; end if;
  for k in select jsonb_object_keys(p) loop
    if k not in ('invoice_number', 'warehouse', 'kind', 'status', 'lines') then return false; end if;
  end loop;
  if p ? 'lines' then
    if jsonb_typeof(p->'lines') <> 'array' then return false; end if;
    for l in select * from jsonb_array_elements(p->'lines') loop
      for k in select jsonb_object_keys(l) loop
        if k not in ('name', 'unit', 'ordered', 'remaining') then return false; end if;
      end loop;
    end loop;
  end if;
  return true;
end $$;

-- One insert path.  Idempotent per (organization, recipient, dedupe key).
create or replace function _ntf_send(
  p_org uuid, p_user uuid, p_actor uuid, p_type text, p_title text, p_href text,
  p_entity_type text, p_entity_id uuid, p_payload jsonb, p_key text
) returns boolean
language plpgsql security definer set search_path = public as $$
declare v_role text; v_need text := _ntf_required_role(p_type); v_n int;
begin
  if p_user is null or p_user is not distinct from p_actor then return false; end if;      -- never notify someone about his own action
  v_role := _ntf_role_of(p_org, p_user);
  if v_role is distinct from v_need then return false; end if;                               -- wrong role for this type: dropped
  if v_need = 'warehouse' and not _ntf_warehouse_payload_ok(coalesce(p_payload, '{}'::jsonb)) then
    raise exception 'storekeeper notification payload carries a non-whitelisted field';
  end if;
  insert into notifications (organization_id, recipient_user_id, type, title, href, entity_type, entity_id, payload, dedupe_key)
  values (p_org, p_user, p_type, left(p_title, 200), p_href, p_entity_type, p_entity_id, coalesce(p_payload, '{}'::jsonb), p_key)
  on conflict (organization_id, recipient_user_id, dedupe_key) do nothing;
  get diagnostics v_n = row_count;
  return v_n > 0;
end $$;

-- Owners hear about what reps, storekeepers and the OTHER owners do (never about their own actions).
create or replace function _ntf_to_owners(
  p_org uuid, p_actor uuid, p_type text, p_title text, p_href text, p_entity_type text, p_entity_id uuid, p_payload jsonb, p_key text
) returns void
language plpgsql security definer set search_path = public as $$
declare u uuid;
begin
  -- the actor is skipped inside _ntf_send; a second owner still hears about what the first one did
  for u in select ou.user_id from organization_users ou join roles r on r.id = ou.role_id
           where ou.organization_id = p_org and ou.status = 'active' and r.key = 'owner'
  loop
    perform _ntf_send(p_org, u, p_actor, p_type, p_title, p_href, p_entity_type, p_entity_id, p_payload, p_key);
  end loop;
end $$;

create or replace function _ntf_to_storekeepers(
  p_org uuid, p_actor uuid, p_type text, p_title text, p_href text, p_entity_type text, p_entity_id uuid, p_payload jsonb, p_key text
) returns void
language plpgsql security definer set search_path = public as $$
declare u uuid;
begin
  for u in select ou.user_id from organization_users ou join roles r on r.id = ou.role_id
           where ou.organization_id = p_org and ou.status = 'active' and r.key = 'warehouse'
  loop
    perform _ntf_send(p_org, u, p_actor, p_type, p_title, p_href, p_entity_type, p_entity_id, p_payload, p_key);
  end loop;
end $$;

-- items + quantities of one invoice's work lines (open quantity = what is still to dispatch/receive)
create or replace function _ntf_work_lines(p_kind text, p_invoice uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'name', p.name, 'unit', p.unit, 'ordered', l.ordered_units,
           'remaining', greatest(l.ordered_units - l.fulfilled_units - l.cancelled_units, 0)) order by l.seq), '[]'::jsonb)
  from invoice_stock_lines l join products p on p.id = l.product_id
  where l.kind = p_kind and l.invoice_id = p_invoice
$$;

revoke all on function _ntf_role_of(uuid, uuid), _ntf_actor_label(uuid, uuid), _ntf_rep_user(uuid, uuid), _ntf_invoice_no(text, uuid),
  _ntf_required_role(text), _ntf_warehouse_payload_ok(jsonb),
  _ntf_send(uuid, uuid, uuid, text, text, text, text, uuid, jsonb, text),
  _ntf_to_owners(uuid, uuid, text, text, text, text, uuid, jsonb, text),
  _ntf_to_storekeepers(uuid, uuid, text, text, text, text, uuid, jsonb, text),
  _ntf_work_lines(text, uuid) from public, anon, authenticated;

-- keeps the storekeeper's task card in step with the invoice: remaining quantities, done/open, and
-- marks it read for the person who just acted on it (he has obviously seen it)
create or replace function _ntf_refresh_work(p_kind text, p_org uuid, p_invoice uuid, p_actor uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_lines jsonb := _ntf_work_lines(p_kind, p_invoice); v_open int; v_status text;
begin
  select count(*) into v_open from invoice_stock_lines
  where kind = p_kind and invoice_id = p_invoice and ordered_units > fulfilled_units + cancelled_units;
  if p_kind = 'sales' then select dispatch_status into v_status from sales_invoices where id = p_invoice;
  else select receipt_status into v_status from purchase_invoices where id = p_invoice; end if;

  update notifications n
  set payload     = n.payload || jsonb_build_object('lines', v_lines, 'status', v_status),
      resolved_at = case when v_open = 0 then coalesce(n.resolved_at, now()) else null end,
      read_at     = case when n.recipient_user_id is not distinct from p_actor then coalesce(n.read_at, now()) else n.read_at end,
      updated_at  = now()
  where n.organization_id = p_org
    and n.type = case when p_kind = 'sales' then 'warehouse_dispatch_needed' else 'warehouse_receipt_needed' end
    and n.entity_id = p_invoice;
end $$;
revoke all on function _ntf_refresh_work(text, uuid, uuid, uuid) from public, anon, authenticated;

-- ============================================================
-- 4. Triggers.  Constraint triggers are DEFERRED to COMMIT: by then the invoice lines, totals and the
--    collected amount of the same transaction are final (an AFTER INSERT row trigger would see the
--    half-built header).  They never raise: a notification problem must not roll back a sale.
-- ============================================================
create or replace function _ntf_on_sales_invoice() returns trigger
language plpgsql security definer set search_path = public as $$
declare i sales_invoices%rowtype; v_cust text; v_rep_name text; v_rep_user uuid; v_no text; v_by text; v_wh text; v_lines jsonb;
begin
  begin
    select * into i from sales_invoices where id = NEW.id;
    if not found then return null; end if;
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
  exception when others then
    raise warning 'notifications: sales invoice % skipped: %', NEW.id, sqlerrm;
  end;
  return null;
end $$;

create or replace function _ntf_on_purchase_invoice() returns trigger
language plpgsql security definer set search_path = public as $$
declare i purchase_invoices%rowtype; v_sup text; v_no text; v_by text; v_wh text; v_lines jsonb;
begin
  begin
    select * into i from purchase_invoices where id = NEW.id;
    if not found then return null; end if;
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
  exception when others then
    raise warning 'notifications: purchase invoice % skipped: %', NEW.id, sqlerrm;
  end;
  return null;
end $$;

-- Dispatch / receiving confirmations and releases (a return that cancels the still-open quantity)
create or replace function _ntf_on_fulfilment_event() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_first uuid; v_no text; v_status text; v_done jsonb; v_left jsonb; v_rep_user uuid; v_rep_name text; v_by text; v_cust text; v_title text;
begin
  begin
    perform _ntf_refresh_work(NEW.kind, NEW.organization_id, NEW.invoice_id, NEW.confirmed_by);

    if NEW.event_type = 'confirm' then
      -- one notification per confirmation, not per line: only the first line's trigger composes it
      select e.id into v_first from fulfilment_events e where e.confirmation_id = NEW.confirmation_id order by e.id limit 1;
      if v_first is distinct from NEW.id then return null; end if;

      v_no := _ntf_invoice_no(NEW.kind, NEW.invoice_id);
      v_by := _ntf_actor_label(NEW.organization_id, NEW.confirmed_by);
      select coalesce(jsonb_agg(jsonb_build_object('name', p.name, 'unit', p.unit, 'qty', q.qty) order by p.name), '[]'::jsonb) into v_done
      from (select product_id, sum(quantity) qty from fulfilment_events where confirmation_id = NEW.confirmation_id and event_type = 'confirm' group by product_id) q
      join products p on p.id = q.product_id;
      select coalesce(jsonb_agg(x order by x->>'name'), '[]'::jsonb) into v_left
      from jsonb_array_elements(_ntf_work_lines(NEW.kind, NEW.invoice_id)) x where (x->>'remaining')::numeric > 0;

      if NEW.kind = 'sales' then
        select i.dispatch_status, i.sales_rep_id into v_status, v_rep_user from sales_invoices i where i.id = NEW.invoice_id;
        select sr.user_id, sr.name into v_rep_user, v_rep_name from sales_representatives sr where sr.id = v_rep_user;
        select c.name into v_cust from sales_invoices i join customers c on c.id = i.customer_id where i.id = NEW.invoice_id;
        v_title := case when v_status = 'dispatched' then 'تم صرف فاتورة البيع ' else 'تم صرف جزء من فاتورة البيع ' end || v_no;
        perform _ntf_to_owners(NEW.organization_id, NEW.confirmed_by, 'dispatch_confirmed', v_title,
          '/dashboard/sales?q=' || v_no, 'sales_invoice', NEW.invoice_id,
          jsonb_build_object('invoice_number', v_no, 'customer', v_cust, 'status', v_status, 'by', v_by, 'done', v_done, 'left', v_left),
          'confirm:' || NEW.confirmation_id);
        perform _ntf_send(NEW.organization_id, v_rep_user, NEW.confirmed_by, 'rep_dispatch_update', v_title,
          '/dashboard/sales?q=' || v_no, 'sales_invoice', NEW.invoice_id,
          jsonb_build_object('invoice_number', v_no, 'customer', v_cust, 'status', v_status, 'done', v_done, 'left', v_left),
          'rep-confirm:' || NEW.confirmation_id);
      else
        select i.receipt_status into v_status from purchase_invoices i where i.id = NEW.invoice_id;
        select s.name into v_cust from purchase_invoices i join suppliers s on s.id = i.supplier_id where i.id = NEW.invoice_id;
        v_title := case when v_status = 'received' then 'تم استلام فاتورة الشراء ' else 'تم استلام جزء من فاتورة الشراء ' end || v_no;
        perform _ntf_to_owners(NEW.organization_id, NEW.confirmed_by, 'receipt_confirmed', v_title,
          '/dashboard/purchases?q=' || v_no, 'purchase_invoice', NEW.invoice_id,
          jsonb_build_object('invoice_number', v_no, 'supplier', v_cust, 'status', v_status, 'by', v_by, 'done', v_done, 'left', v_left),
          'confirm:' || NEW.confirmation_id);
      end if;
    end if;
  exception when others then
    raise warning 'notifications: fulfilment event % skipped: %', NEW.id, sqlerrm;
  end;
  return null;
end $$;

-- Payments.  The payment taken while the invoice itself is created is already in the invoice notification.
create or replace function _ntf_on_customer_collection() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_cust text; v_rep uuid; v_no text; v_by text; v_payload jsonb;
begin
  begin
    if NEW.sales_invoice_id is not null and exists (select 1 from sales_invoices i where i.id = NEW.sales_invoice_id and i.created_at = now()) then return null; end if;
    select c.name, c.sales_rep_id into v_cust, v_rep from customers c where c.id = NEW.customer_id;
    if NEW.sales_invoice_id is not null then v_no := _ntf_invoice_no('sales', NEW.sales_invoice_id); end if;
    v_by := _ntf_actor_label(NEW.organization_id, NEW.created_by);
    v_payload := jsonb_build_object('customer', v_cust, 'amount', NEW.amount, 'invoice_number', v_no, 'method', NEW.payment_method, 'by', v_by);
    perform _ntf_to_owners(NEW.organization_id, NEW.created_by, 'customer_payment', 'تحصيل من العميل ' || coalesce(v_cust, ''),
      '/dashboard/reports/debts/payments', 'customer_collection', NEW.id, v_payload, 'collection:' || NEW.id);
    perform _ntf_send(NEW.organization_id, _ntf_rep_user(NEW.organization_id, v_rep), NEW.created_by, 'rep_payment', 'تحصيل من العميل ' || coalesce(v_cust, ''),
      '/dashboard/customers', 'customer_collection', NEW.id, v_payload - 'by', 'rep-collection:' || NEW.id);
  exception when others then
    raise warning 'notifications: collection % skipped: %', NEW.id, sqlerrm;
  end;
  return null;
end $$;

create or replace function _ntf_on_supplier_payment() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_sup text; v_no text;
begin
  begin
    if NEW.purchase_invoice_id is not null and exists (select 1 from purchase_invoices i where i.id = NEW.purchase_invoice_id and i.created_at = now()) then return null; end if;
    select s.name into v_sup from suppliers s where s.id = NEW.supplier_id;
    if NEW.purchase_invoice_id is not null then v_no := _ntf_invoice_no('purchase', NEW.purchase_invoice_id); end if;
    perform _ntf_to_owners(NEW.organization_id, NEW.created_by, 'supplier_payment', 'دفعة للمورد ' || coalesce(v_sup, ''),
      '/dashboard/suppliers', 'supplier_payment', NEW.id,
      jsonb_build_object('supplier', v_sup, 'amount', NEW.amount, 'invoice_number', v_no, 'method', NEW.payment_method, 'by', _ntf_actor_label(NEW.organization_id, NEW.created_by)),
      'supplier-payment:' || NEW.id);
  exception when others then
    raise warning 'notifications: supplier payment % skipped: %', NEW.id, sqlerrm;
  end;
  return null;
end $$;

-- Returns (deferred: the total is written after the header row)
create or replace function _ntf_on_sales_return() returns trigger
language plpgsql security definer set search_path = public as $$
declare r sales_returns%rowtype; v_no text; v_cust text; v_rep uuid; v_payload jsonb;
begin
  begin
    select * into r from sales_returns where id = NEW.id;
    if not found then return null; end if;
    v_no := _ntf_invoice_no('sales', r.sales_invoice_id);
    select c.name into v_cust from customers c where c.id = r.customer_id;
    select i.sales_rep_id into v_rep from sales_invoices i where i.id = r.sales_invoice_id;
    v_payload := jsonb_build_object('invoice_number', v_no, 'customer', v_cust, 'total', r.total, 'by', _ntf_actor_label(r.organization_id, r.created_by));
    perform _ntf_to_owners(r.organization_id, r.created_by, 'sales_return_created', 'مرتجع على فاتورة البيع ' || v_no,
      '/dashboard/sales/returns', 'sales_return', r.id, v_payload, 'sales-return:' || r.id);
    perform _ntf_send(r.organization_id, _ntf_rep_user(r.organization_id, v_rep), r.created_by, 'rep_return', 'مرتجع على فاتورة البيع ' || v_no,
      '/dashboard/sales/returns', 'sales_return', r.id, v_payload - 'by', 'rep-sales-return:' || r.id);
  exception when others then
    raise warning 'notifications: sales return % skipped: %', NEW.id, sqlerrm;
  end;
  return null;
end $$;

create or replace function _ntf_on_purchase_return() returns trigger
language plpgsql security definer set search_path = public as $$
declare r purchase_returns%rowtype; v_no text; v_sup text;
begin
  begin
    select * into r from purchase_returns where id = NEW.id;
    if not found then return null; end if;
    v_no := _ntf_invoice_no('purchase', r.purchase_invoice_id);
    select s.name into v_sup from suppliers s where s.id = r.supplier_id;
    perform _ntf_to_owners(r.organization_id, r.created_by, 'purchase_return_created', 'مرتجع على فاتورة الشراء ' || v_no,
      '/dashboard/purchases/returns', 'purchase_return', r.id,
      jsonb_build_object('invoice_number', v_no, 'supplier', v_sup, 'total', r.total, 'by', _ntf_actor_label(r.organization_id, r.created_by)),
      'purchase-return:' || r.id);
  exception when others then
    raise warning 'notifications: purchase return % skipped: %', NEW.id, sqlerrm;
  end;
  return null;
end $$;

-- Stock-shortage reports (0045)
create or replace function _ntf_on_shortage_insert() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_prod text; v_unit text; v_wh text;
begin
  begin
    select p.name, p.unit into v_prod, v_unit from products p where p.id = NEW.product_id;
    select w.name into v_wh from warehouses w where w.id = NEW.warehouse_id;
    perform _ntf_to_owners(NEW.organization_id, NEW.reported_by, 'shortage_reported', 'بلاغ نقص: ' || coalesce(v_prod, ''),
      '/dashboard/shortages?status=new', 'shortage_report', NEW.id,
      jsonb_build_object('product', v_prod, 'unit', v_unit, 'warehouse', v_wh, 'needed', NEW.needed_qty, 'available', NEW.available_qty, 'rep', NEW.rep_name, 'note', NEW.note),
      'shortage:' || NEW.id);
  exception when others then
    raise warning 'notifications: shortage report % skipped: %', NEW.id, sqlerrm;
  end;
  return null;
end $$;

create or replace function _ntf_on_shortage_update() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_prod text; v_unit text;
begin
  begin
    -- a newer report replaced this one: the owner's card for the old report is no longer a task
    if NEW.superseded_by is not null and OLD.superseded_by is null then
      update notifications set resolved_at = coalesce(resolved_at, now()), updated_at = now()
      where organization_id = NEW.organization_id and type = 'shortage_reported' and entity_id = NEW.id;
    end if;

    if NEW.status is distinct from OLD.status then
      -- the owner's card is a task: done once the item is provided, open again if reopened
      update notifications set resolved_at = case when NEW.status = 'resolved' then coalesce(resolved_at, now()) else null end, updated_at = now()
      where organization_id = NEW.organization_id and type = 'shortage_reported' and entity_id = NEW.id and NEW.superseded_by is null;

      if NEW.status in ('in_progress', 'resolved') and NEW.superseded_by is null then
        select p.name, p.unit into v_prod, v_unit from products p where p.id = NEW.product_id;
        perform _ntf_send(NEW.organization_id, NEW.reported_by, NEW.status_changed_by, 'shortage_status',
          case when NEW.status = 'resolved' then 'تم توفير الصنف الذي أبلغت عن نقصه: ' else 'جاري تجهيز الصنف الذي أبلغت عن نقصه: ' end || coalesce(v_prod, ''),
          '/dashboard/shortages?status=' || case when NEW.status = 'resolved' then 'resolved' else 'in_progress' end, 'shortage_report', NEW.id,
          jsonb_build_object('product', v_prod, 'unit', v_unit, 'status', NEW.status, 'needed', NEW.needed_qty, 'owner_note', NEW.owner_note),
          'shortage-status:' || NEW.id || ':' || NEW.status || ':' || extract(epoch from coalesce(NEW.status_changed_at, now()))::text);
      end if;
    end if;
  exception when others then
    raise warning 'notifications: shortage update % skipped: %', NEW.id, sqlerrm;
  end;
  return null;
end $$;

revoke all on function _ntf_on_sales_invoice(), _ntf_on_purchase_invoice(), _ntf_on_fulfilment_event(), _ntf_on_customer_collection(),
  _ntf_on_supplier_payment(), _ntf_on_sales_return(), _ntf_on_purchase_return(), _ntf_on_shortage_insert(), _ntf_on_shortage_update()
  from public, anon, authenticated;

-- Trigger names sort AFTER z_fulfil_init (which settles auto-dispatched invoices) and BEFORE zz_autoconfirm.
drop trigger if exists z_notify on sales_invoices;
create constraint trigger z_notify after insert on sales_invoices deferrable initially deferred for each row execute function _ntf_on_sales_invoice();
drop trigger if exists z_notify on purchase_invoices;
create constraint trigger z_notify after insert on purchase_invoices deferrable initially deferred for each row execute function _ntf_on_purchase_invoice();
drop trigger if exists z_notify on fulfilment_events;
create constraint trigger z_notify after insert on fulfilment_events deferrable initially deferred for each row execute function _ntf_on_fulfilment_event();
drop trigger if exists z_notify on sales_returns;
create constraint trigger z_notify after insert on sales_returns deferrable initially deferred for each row execute function _ntf_on_sales_return();
drop trigger if exists z_notify on purchase_returns;
create constraint trigger z_notify after insert on purchase_returns deferrable initially deferred for each row execute function _ntf_on_purchase_return();
drop trigger if exists z_notify on customer_collections;
create trigger z_notify after insert on customer_collections for each row execute function _ntf_on_customer_collection();
drop trigger if exists z_notify on supplier_payments;
create trigger z_notify after insert on supplier_payments for each row execute function _ntf_on_supplier_payment();
drop trigger if exists z_notify on stock_shortage_reports;
create trigger z_notify after insert on stock_shortage_reports for each row execute function _ntf_on_shortage_insert();
drop trigger if exists z_notify_upd on stock_shortage_reports;
create trigger z_notify_upd after update of status, superseded_by on stock_shortage_reports for each row execute function _ntf_on_shortage_update();

-- ============================================================
-- 5. API for the app (the only way to read lists / change read state)
-- ============================================================
create or replace function _ntf_guard(org_id uuid) returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'يجب تسجيل الدخول أولاً'; end if;
  if not is_org_member(org_id) then raise exception 'أنت لست عضوًا في هذه المؤسسة'; end if;
end $$;
revoke all on function _ntf_guard(uuid) from public, anon, authenticated;

-- p_filter: all | unread.   Keyset paging: pass the created_at of the last row as p_before.
create or replace function list_my_notifications(org_id uuid, p_filter text default 'all', p_limit integer default 30, p_before timestamptz default null)
returns table (id uuid, type text, title text, href text, payload jsonb, created_at timestamptz, read_at timestamptz, resolved_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  perform _ntf_guard(org_id);
  if p_filter not in ('all', 'unread') then raise exception 'فلتر غير صحيح'; end if;
  return query
  select n.id, n.type, n.title, n.href, n.payload, n.created_at, n.read_at, n.resolved_at
  from notifications n
  where n.organization_id = org_id and n.recipient_user_id = auth.uid()
    and _notif_type_visible(org_id, n.type)
    and (p_filter = 'all' or n.read_at is null)
    and (p_before is null or n.created_at < p_before)
  order by n.created_at desc, n.id
  limit least(greatest(coalesce(p_limit, 30), 1), 100);
end $$;

create or replace function my_unread_notification_count(org_id uuid) returns integer
language plpgsql stable security definer set search_path = public as $$
begin
  perform _ntf_guard(org_id);
  return (select count(*)::int from notifications n
          where n.organization_id = org_id and n.recipient_user_id = auth.uid() and n.read_at is null and _notif_type_visible(org_id, n.type));
end $$;

-- Idempotent: marking an already-read notification changes nothing.  Returns the new unread count.
create or replace function mark_notification_read(org_id uuid, p_id uuid) returns integer
language plpgsql security definer set search_path = public as $$
begin
  perform _ntf_guard(org_id);
  update notifications n set read_at = now(), updated_at = now()
  where n.id = p_id and n.organization_id = org_id and n.recipient_user_id = auth.uid() and n.read_at is null and _notif_type_visible(org_id, n.type);
  return my_unread_notification_count(org_id);
end $$;

create or replace function mark_all_notifications_read(org_id uuid) returns integer
language plpgsql security definer set search_path = public as $$
begin
  perform _ntf_guard(org_id);
  update notifications n set read_at = now(), updated_at = now()
  where n.organization_id = org_id and n.recipient_user_id = auth.uid() and n.read_at is null and _notif_type_visible(org_id, n.type);
  return my_unread_notification_count(org_id);
end $$;

revoke all on function list_my_notifications(uuid, text, integer, timestamptz), my_unread_notification_count(uuid),
  mark_notification_read(uuid, uuid), mark_all_notifications_read(uuid) from public, anon;
grant execute on function list_my_notifications(uuid, text, integer, timestamptz), my_unread_notification_count(uuid),
  mark_notification_read(uuid, uuid), mark_all_notifications_read(uuid) to authenticated;

-- ============================================================
-- 6. Realtime: Postgres Changes on this table (RLS is applied per subscriber)
-- ============================================================
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'notifications') then
    alter publication supabase_realtime add table public.notifications;
  end if;
end $$;

-- Kayan — 0053: every invoice has a real, stable number; notifications and search open the RIGHT invoice.
--
-- ROOT CAUSE (reproduced before this fix, see supabase/tests/109_document_numbers_test.sql):
--   1. sales_invoices.invoice_number / purchase_invoices.invoice_number were OPTIONAL free text typed by the user.
--      Nothing in the system issued a number, so every invoice saved with the box left empty had NULL.
--   2. _ntf_invoice_no() (0046) fell back to left(<uuid>, 8) for such invoices.  Those 8 hex characters are the
--      "random numbers of unknown origin" the owner saw in notifications and the storekeeper saw on the warehouse page.
--   3. Every invoice notification linked to  …?q=<number>  and the list pages answered with
--      `invoice_number ILIKE '%<q>%'`.  For a NULL number that matches nothing (empty page); for a short number it
--      matches OTHER invoices ("12" also finds "123"); for a number containing & # % or a space the unencoded link broke.
--
-- THE FIX (at the source, not in the UI):
--   A. Every invoice gets a number AT INSERT, in the database, whatever path created it (RPC, service role, import):
--      a blank number becomes  S-000001 / P-000001  (per organization, per document kind, gap-free, race-safe).
--      A typed number is kept as typed, but may not duplicate another one (sales: per organization;
--      purchases: per supplier — suppliers number their own invoices).
--   B. The number can no longer be edited once issued (API users); the column is NOT NULL and never blank.
--   C. Existing invoices WITHOUT a number are numbered in creation order, NOTHING else is touched: ids, amounts, stock,
--      payments, returns, batches and every foreign key stay exactly as they were.  Every number issued this way is
--      logged in invoice_number_backfill (the log is also the undo list: those rows were NULL before).
--   D. Notifications link by invoice ID (…?inv=<uuid>), never by a text search; stored notifications are repaired the same
--      way and their random-looking numbers are replaced by the real ones.
--   E. _ntf_invoice_no() never returns a fragment of an id again, and global_search() never shows an id as a title and
--      treats % and _ in what you type literally.

-- ============================================================
-- 1. Counters + audit log of what the backfill numbered
-- ============================================================
create table if not exists document_counters (
  organization_id uuid not null references organizations(id) on delete cascade,
  kind            text not null check (kind in ('sales_invoice', 'purchase_invoice')),
  last_value      bigint not null default 0 check (last_value >= 0),
  primary key (organization_id, kind)
);
alter table document_counters enable row level security;
alter table document_counters force row level security;
revoke all on document_counters from public, anon, authenticated;

create table if not exists invoice_number_backfill (
  id              bigserial primary key,
  kind            text not null check (kind in ('sales_invoice', 'purchase_invoice')),
  invoice_id      uuid not null,
  organization_id uuid not null,
  assigned_number text not null,
  assigned_at     timestamptz not null default now(),
  unique (kind, invoice_id)
);
alter table invoice_number_backfill enable row level security;
alter table invoice_number_backfill force row level security;
revoke all on invoice_number_backfill from public, anon, authenticated;

-- remembers that the system (not a person) issued the number; the double-submit guard below needs to know
alter table sales_invoices    add column if not exists number_is_auto boolean not null default false;
alter table purchase_invoices add column if not exists number_is_auto boolean not null default false;

-- lookups by (organization, normalized number): used by the issuer, the duplicate check and the search
create index if not exists sales_invoices_org_number_idx    on sales_invoices    (organization_id, lower(btrim(invoice_number)));
create index if not exists purchase_invoices_org_number_idx on purchase_invoices (organization_id, lower(btrim(invoice_number)));

-- ============================================================
-- 2. The issuer.  The prefix is the only "design" choice: change the two literals to change the look of new numbers.
--    The counter row is locked by the upsert until the invoice's transaction ends, so two requests can never get the
--    same number and a rolled-back invoice never burns one.
-- ============================================================
create or replace function _next_document_number(p_org uuid, p_kind text) returns text
language plpgsql security definer set search_path = public as $$
declare
  v_prefix text := case p_kind when 'sales_invoice' then 'S-' when 'purchase_invoice' then 'P-' end;
  v_n bigint;
  v_no text;
  v_taken boolean;
begin
  if v_prefix is null then raise exception 'نوع مستند غير معروف: %', p_kind; end if;
  loop
    insert into document_counters (organization_id, kind, last_value) values (p_org, p_kind, 1)
    on conflict (organization_id, kind) do update set last_value = document_counters.last_value + 1
    returning last_value into v_n;
    v_no := v_prefix || lpad(v_n::text, 6, '0');
    -- a hand-typed number may already look like a generated one: skip it instead of duplicating it
    if p_kind = 'sales_invoice' then
      select exists (select 1 from sales_invoices where organization_id = p_org and lower(btrim(invoice_number)) = lower(v_no)) into v_taken;
    else
      select exists (select 1 from purchase_invoices where organization_id = p_org and lower(btrim(invoice_number)) = lower(v_no)) into v_taken;
    end if;
    exit when not v_taken;
  end loop;
  return v_no;
end $$;
revoke all on function _next_document_number(uuid, text) from public, anon, authenticated;

-- ============================================================
-- 3. NUMBERING OLD INVOICES — only rows with a missing/blank number, oldest first, per organization.
--    Rows that already have a number are never touched (duplicates among them are kept as they are: they are real data;
--    every link and notification now uses the invoice id, so a duplicate can no longer open the wrong invoice).
-- ============================================================
do $$
declare r record; v_no text;
begin
  for r in select id, organization_id from sales_invoices where nullif(btrim(invoice_number), '') is null order by organization_id, created_at, id loop
    v_no := _next_document_number(r.organization_id, 'sales_invoice');
    update sales_invoices set invoice_number = v_no, number_is_auto = true where id = r.id;
    insert into invoice_number_backfill (kind, invoice_id, organization_id, assigned_number) values ('sales_invoice', r.id, r.organization_id, v_no);
  end loop;
  for r in select id, organization_id from purchase_invoices where nullif(btrim(invoice_number), '') is null order by organization_id, created_at, id loop
    v_no := _next_document_number(r.organization_id, 'purchase_invoice');
    update purchase_invoices set invoice_number = v_no, number_is_auto = true where id = r.id;
    insert into invoice_number_backfill (kind, invoice_id, organization_id, assigned_number) values ('purchase_invoice', r.id, r.organization_id, v_no);
  end loop;
end $$;

-- now it is safe to forbid "no number"
alter table sales_invoices    alter column invoice_number set not null;
alter table purchase_invoices alter column invoice_number set not null;
alter table sales_invoices    drop constraint if exists sales_invoices_number_not_blank;
alter table sales_invoices    add  constraint sales_invoices_number_not_blank    check (btrim(invoice_number) <> '');
alter table purchase_invoices drop constraint if exists purchase_invoices_number_not_blank;
alter table purchase_invoices add  constraint purchase_invoices_number_not_blank check (btrim(invoice_number) <> '');

-- ============================================================
-- 4. Triggers: issue on insert, freeze after
--    (named c_*: they fire AFTER b_duplicate_guard, which must still see a blank number so that a double-clicked
--     "save" is caught — if it saw two different generated numbers it would let both through.)
-- ============================================================
create or replace function _assign_sales_invoice_number() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  NEW.invoice_number := nullif(btrim(NEW.invoice_number), '');
  if NEW.invoice_number is null then
    -- 0010's double-submit guard compared blank with blank; now the first save already holds a generated number, so the
    -- same protection is applied here to "recent identical invoice with a system-issued number"
    if exists (select 1 from sales_invoices x where x.organization_id = NEW.organization_id and x.created_by is not distinct from NEW.created_by
               and x.number_is_auto and x.customer_id = NEW.customer_id and x.warehouse_id = NEW.warehouse_id
               and x.invoice_date = NEW.invoice_date and x.created_at > now() - interval '5 seconds') then
      raise exception 'تم تسجيل عملية مطابقة منذ لحظات. راجع السجل قبل إعادة المحاولة.';
    end if;
    NEW.invoice_number := _next_document_number(NEW.organization_id, 'sales_invoice');
    NEW.number_is_auto := true;
    return NEW;
  end if;
  NEW.number_is_auto := false;
  perform pg_advisory_xact_lock(hashtextextended('sales_invoices:' || NEW.organization_id::text || ':' || lower(NEW.invoice_number), 53));
  if exists (select 1 from sales_invoices x where x.organization_id = NEW.organization_id and lower(btrim(x.invoice_number)) = lower(NEW.invoice_number)) then
    raise exception 'رقم الفاتورة % مستخدم من قبل. غيّر الرقم أو اترك الخانة فارغة ليولّد النظام رقمًا تلقائيًا.', NEW.invoice_number;
  end if;
  return NEW;
end $$;

create or replace function _assign_purchase_invoice_number() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  NEW.invoice_number := nullif(btrim(NEW.invoice_number), '');
  if NEW.invoice_number is null then
    if exists (select 1 from purchase_invoices x where x.organization_id = NEW.organization_id and x.created_by is not distinct from NEW.created_by
               and x.number_is_auto and x.supplier_id = NEW.supplier_id and x.warehouse_id = NEW.warehouse_id
               and x.invoice_date = NEW.invoice_date and x.created_at > now() - interval '5 seconds') then
      raise exception 'تم تسجيل عملية مطابقة منذ لحظات. راجع السجل قبل إعادة المحاولة.';
    end if;
    NEW.invoice_number := _next_document_number(NEW.organization_id, 'purchase_invoice');
    NEW.number_is_auto := true;
    return NEW;
  end if;
  NEW.number_is_auto := false;
  -- suppliers number their own invoices: the same number from two different suppliers is legitimate
  perform pg_advisory_xact_lock(hashtextextended('purchase_invoices:' || NEW.organization_id::text || ':' || NEW.supplier_id::text || ':' || lower(NEW.invoice_number), 53));
  if exists (select 1 from purchase_invoices x where x.organization_id = NEW.organization_id and x.supplier_id = NEW.supplier_id
             and lower(btrim(x.invoice_number)) = lower(NEW.invoice_number)) then
    raise exception 'رقم الفاتورة % مستخدم من قبل لنفس المورد. غيّر الرقم أو اترك الخانة فارغة ليولّد النظام رقمًا تلقائيًا.', NEW.invoice_number;
  end if;
  return NEW;
end $$;

create or replace function _protect_invoice_number() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if NEW.invoice_number is distinct from OLD.invoice_number
     and nullif(btrim(OLD.invoice_number), '') is not null
     and auth.uid() is not null then
    raise exception 'رقم الفاتورة لا يمكن تعديله بعد إصدارها';
  end if;
  return NEW;
end $$;

drop trigger if exists c_assign_number on sales_invoices;
create trigger c_assign_number before insert on sales_invoices    for each row execute function _assign_sales_invoice_number();
drop trigger if exists c_assign_number on purchase_invoices;
create trigger c_assign_number before insert on purchase_invoices for each row execute function _assign_purchase_invoice_number();
drop trigger if exists c_protect_number on sales_invoices;
create trigger c_protect_number before update of invoice_number on sales_invoices    for each row execute function _protect_invoice_number();
drop trigger if exists c_protect_number on purchase_invoices;
create trigger c_protect_number before update of invoice_number on purchase_invoices for each row execute function _protect_invoice_number();

-- ============================================================
-- 5. Notifications: the number is the stored one, the link is the invoice's id.
-- ============================================================
create or replace function _ntf_invoice_no(p_kind text, p_id uuid) returns text
language sql stable security definer set search_path = public as $$
  select coalesce(
    case when p_kind = 'sales' then (select nullif(btrim(i.invoice_number), '') from sales_invoices i where i.id = p_id)
         else (select nullif(btrim(i.invoice_number), '') from purchase_invoices i where i.id = p_id) end,
    'بدون رقم')   -- unreachable since 0053 (NOT NULL); never a fragment of an id again
$$;

-- one place decides where an invoice notification leads.  status=all on the storekeeper link: the order must open even
-- if it was completed or cancelled after the notification was sent.
create or replace function _ntf_invoice_href(p_entity_type text, p_id uuid) returns text
language sql immutable as $$
  select case p_entity_type
    when 'sales_invoice'    then '/dashboard/sales?inv=' || p_id::text
    when 'purchase_invoice' then '/dashboard/purchases?inv=' || p_id::text
    when 'sales'            then '/dashboard/warehouse-orders?tab=sales&status=all&inv=' || p_id::text
    when 'purchase'         then '/dashboard/warehouse-orders?tab=purchase&status=all&inv=' || p_id::text
  end
$$;

-- Every insert path (builders, retries, backfill) goes through this, so no builder can bring the text-search link back.
-- A deliberate bare list link (e.g. "invoice taken off you" → /dashboard/sales) has no q= and is left alone.
create or replace function _ntf_normalize_invoice_href() returns trigger
language plpgsql set search_path = public as $$
begin
  if NEW.entity_type in ('sales_invoice', 'purchase_invoice', 'sales', 'purchase')
     and NEW.entity_id is not null and NEW.href ~ '[?&]q=' then
    NEW.href := _ntf_invoice_href(NEW.entity_type, NEW.entity_id);
  end if;
  return NEW;
end $$;
drop trigger if exists a_invoice_href on notifications;
create trigger a_invoice_href before insert on notifications for each row execute function _ntf_normalize_invoice_href();

-- repair what is already stored ------------------------------------------------------------------------------
update notifications n set href = _ntf_invoice_href(n.entity_type, n.entity_id)
where n.entity_type in ('sales_invoice', 'purchase_invoice', 'sales', 'purchase') and n.entity_id is not null and n.href ~ '[?&]q=';

-- random-looking numbers (an 8-character slice of the id) → the invoice's real number, in the payload and in the title
with inv as (
  select 'sales'::text as kind, i.id, i.invoice_number as no from sales_invoices i
  union all select 'purchase', i.id, i.invoice_number from purchase_invoices i
)
update notifications n
set payload = jsonb_set(n.payload, '{invoice_number}', to_jsonb(inv.no)),
    title   = left(replace(n.title, left(n.entity_id::text, 8), inv.no), 200)
from inv
where inv.id = n.entity_id
  and inv.kind = case when n.entity_type in ('sales_invoice', 'sales') then 'sales' when n.entity_type in ('purchase_invoice', 'purchase') then 'purchase' end
  and n.payload->>'invoice_number' = left(n.entity_id::text, 8);

-- payment notifications carry the invoice number of the invoice they settled
update notifications n
set payload = jsonb_set(n.payload, '{invoice_number}', to_jsonb(si.invoice_number))
from customer_collections c join sales_invoices si on si.id = c.sales_invoice_id
where n.entity_type = 'customer_collection' and c.id = n.entity_id and n.payload->>'invoice_number' = left(c.sales_invoice_id::text, 8);
update notifications n
set payload = jsonb_set(n.payload, '{invoice_number}', to_jsonb(pi.invoice_number))
from supplier_payments p join purchase_invoices pi on pi.id = p.purchase_invoice_id
where n.entity_type = 'supplier_payment' and p.id = n.entity_id and n.payload->>'invoice_number' = left(p.purchase_invoice_id::text, 8);

-- ============================================================
-- 6. Global search: never an id as a title; what you type is matched literally (a "_" or "%" is not a wildcard).
--    Same visibility rules as before (still SECURITY INVOKER: row-level security decides what each role may find).
-- ============================================================
create or replace function global_search(org_id uuid, p_query text, p_limit int default 6)
returns table (entity_type text, entity_id uuid, title text, subtitle text)
language plpgsql stable set search_path = public as $$
declare
  v_limit int := least(greatest(coalesce(p_limit, 6), 1), 20);
  v_query text := trim(coalesce(p_query, ''));
  v_pat text;
begin
  if auth.uid() is null then raise exception 'يجب تسجيل الدخول أولاً'; end if;
  if not is_org_member(org_id) then raise exception 'أنت لست عضوًا في هذه المؤسسة'; end if;
  if length(v_query) < 2 then return; end if;
  v_pat := '%' || replace(replace(replace(v_query, '\', '\\'), '%', '\%'), '_', '\_') || '%';

  return query
  (
    select 'customer'::text, c.id, c.name, coalesce(c.phone, '')
    from customers c
    where c.organization_id = org_id and (c.name ilike v_pat or c.phone ilike v_pat)
    order by c.name limit v_limit
  )
  union all
  (
    select 'supplier'::text, s.id, s.name, coalesce(s.phone, '')
    from suppliers s
    where s.organization_id = org_id and (s.name ilike v_pat or s.phone ilike v_pat)
    order by s.name limit v_limit
  )
  union all
  (
    select 'product'::text, p.id, p.name, coalesce(p.sku, '')
    from products p
    where p.organization_id = org_id and (p.name ilike v_pat or p.sku ilike v_pat)
    order by p.name limit v_limit
  )
  union all
  (
    select 'sales_invoice'::text, i.id, i.invoice_number, coalesce(c.name, '') || ' — ' || i.invoice_date::text
    from sales_invoices i left join customers c on c.id = i.customer_id
    where i.organization_id = org_id and i.invoice_number ilike v_pat
    order by i.invoice_date desc, i.created_at desc limit v_limit
  )
  union all
  (
    select 'purchase_invoice'::text, pi.id, pi.invoice_number, coalesce(s.name, '') || ' — ' || pi.invoice_date::text
    from purchase_invoices pi left join suppliers s on s.id = pi.supplier_id
    where pi.organization_id = org_id and pi.invoice_number ilike v_pat
    order by pi.invoice_date desc, pi.created_at desc limit v_limit
  );
end;
$$;
revoke all on function global_search(uuid, text, int) from public, anon;
grant execute on function global_search(uuid, text, int) to authenticated;

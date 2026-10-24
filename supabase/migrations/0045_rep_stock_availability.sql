-- Kayan — Phase 45: reps see what is SELLABLE while invoicing, and can report a shortage to the Owner
-- Depends on 0044. Re-runnable.  Takes no data away and moves no stock: it only ADDS a read function,
-- a reports table and a database-level oversell guard.
--
-- WHAT THIS ADDS
--   1. get_sellable_stock()      what a rep may sell right now: on hand − reserved by invoices not yet dispatched
--                                − expired.  ONE number per product.  No cost, no price, no on-hand / reserved split
--                                (the reserved part is other reps' pending invoices — not his business).
--   2. stock_shortage_reports    "I need 40 of X, only 12 are sellable" — rep → Owner, with a status the Owner moves
--                                (new → in preparation → provided) and the rep can follow.
--        report_stock_shortage()          rep/owner sends a report (the server measures the available quantity itself)
--        list_stock_shortage_reports()    Owner: every report.  Rep: only his own.  Nobody else.
--        set_stock_shortage_status()      Owner only
--        stock_shortage_counts()          numbers for the sidebar badge / bell
--      No spam: one open report per (reporter, product, warehouse).  Sending it again with the same shortage
--      does nothing; if the need grew or the available quantity changed, a NEW report replaces the old one.
--   3. The shortage error of the stock engine now says what was asked and what is available (and no longer
--      reveals how much is reserved by others).
--   4. A deferred constraint trigger re-checks, at COMMIT, that open sales reservations never exceed what is on
--      hand — a last line of defence behind the row lock in _consume_stock.
--
-- WHAT DOES NOT CHANGE
--   Reservation (0044) is the single source of truth: available = on hand − reserved.  Confirming a dispatch lowers
--   on hand and reserved by the same amount, so availability does not move and nothing is deducted twice.

-- ============================================================
-- 1. Sellable quantity (same rule _consume_stock enforces)
-- ============================================================
create or replace function _sellable_qty(p_org uuid, p_product uuid, p_wh uuid) returns numeric
language sql security definer stable set search_path = public as $$
  select greatest(
    coalesce((select s.quantity from inventory_stock s where s.organization_id = p_org and s.product_id = p_product and s.warehouse_id = p_wh), 0)
    - _stock_reserved(p_org, p_product, p_wh)
    - coalesce((select sum(b.quantity) from stock_batches b
                where b.organization_id = p_org and b.product_id = p_product and b.warehouse_id = p_wh and b.expiry_date < cairo_today()), 0),
    0)
$$;

create or replace function _sales_stock_guard(org_id uuid) returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'يجب تسجيل الدخول أولاً'; end if;
  if not is_org_member(org_id) then raise exception 'أنت لست عضوًا في هذه المؤسسة'; end if;
  if not has_permission(org_id, 'sales.create') then raise exception 'ليس لديك صلاحية عرض الكميات المتاحة للبيع'; end if;
end $$;

revoke all on function _sellable_qty(uuid, uuid, uuid), _sales_stock_guard(uuid) from public, anon, authenticated;

-- p_product_ids = null -> every product of the company.  available is NULL for products that do not track stock.
create or replace function get_sellable_stock(org_id uuid, p_warehouse_id uuid, p_product_ids uuid[] default null)
returns table (product_id uuid, tracked boolean, available numeric)
language plpgsql stable security definer set search_path = public as $$
begin
  perform _sales_stock_guard(org_id);
  if not exists (select 1 from warehouses w where w.id = p_warehouse_id and w.organization_id = org_id) then
    raise exception 'المخزن غير موجود';
  end if;
  return query
  select p.id, p.track_inventory,
         case when p.track_inventory
              then greatest(coalesce(s.quantity, 0) - coalesce(r.units, 0) - coalesce(x.units, 0), 0)::numeric
              else null end
  from products p
  left join inventory_stock s on s.organization_id = org_id and s.product_id = p.id and s.warehouse_id = p_warehouse_id
  left join (select l.product_id as pid, sum(l.ordered_units - l.fulfilled_units - l.cancelled_units) as units
             from invoice_stock_lines l
             where l.organization_id = org_id and l.kind = 'sales' and l.warehouse_id = p_warehouse_id
               and l.ordered_units > l.fulfilled_units + l.cancelled_units
             group by l.product_id) r on r.pid = p.id
  left join (select b.product_id as pid, sum(b.quantity) as units
             from stock_batches b
             where b.organization_id = org_id and b.warehouse_id = p_warehouse_id and b.expiry_date < cairo_today()
             group by b.product_id) x on x.pid = p.id
  where p.organization_id = org_id
    and (p_product_ids is null or p.id = any (p_product_ids));
end $$;

-- ============================================================
-- 2. Shortage reports
-- ============================================================
create table if not exists stock_shortage_reports (
  id                uuid primary key default gen_random_uuid(),
  organization_id   uuid not null references organizations(id) on delete cascade,
  product_id        uuid not null references products(id),
  warehouse_id      uuid not null references warehouses(id),
  reported_by       uuid not null references auth.users(id),
  rep_name          text not null,                                  -- snapshot: who reported
  available_qty     numeric(14,3) not null check (available_qty >= 0 and available_qty <> 'NaN'::numeric),   -- measured by the SERVER at report time
  needed_qty        numeric(14,3) not null check (needed_qty > 0 and needed_qty < 1000000000 and needed_qty <> 'NaN'::numeric),
  note              text check (note is null or char_length(note) <= 500),
  status            text not null default 'new' check (status in ('new', 'in_progress', 'resolved')),
  owner_note        text check (owner_note is null or char_length(owner_note) <= 500),
  status_changed_at timestamptz,
  status_changed_by uuid references auth.users(id),
  superseded_by     uuid references stock_shortage_reports(id) deferrable initially deferred,   -- a newer report replaced this one
  created_at        timestamptz not null default now()
);
create index if not exists stock_shortage_org_idx on stock_shortage_reports (organization_id, created_at desc);
create index if not exists stock_shortage_reporter_idx on stock_shortage_reports (organization_id, reported_by, created_at desc);
-- the hard guarantee behind "no duplicate open report for the same problem"
create unique index if not exists stock_shortage_one_open_idx
  on stock_shortage_reports (organization_id, reported_by, product_id, warehouse_id)
  where status in ('new', 'in_progress') and superseded_by is null;

-- Nobody reads or writes this table directly: every access goes through the definer functions below,
-- which decide who sees what (the Owner everything, a rep only his own reports, the storekeeper nothing).
alter table stock_shortage_reports enable row level security;
alter table stock_shortage_reports force row level security;
revoke all on stock_shortage_reports from public, anon, authenticated;

create or replace function report_stock_shortage(org_id uuid, p_product_id uuid, p_warehouse_id uuid, p_needed_qty numeric, p_note text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_track boolean; v_name text; v_avail numeric; v_needed numeric; v_old stock_shortage_reports%rowtype;
  v_rep_name text; v_new uuid := gen_random_uuid(); v_note text;
begin
  perform _sales_stock_guard(org_id);

  if p_needed_qty is null or p_needed_qty = 'NaN'::numeric or p_needed_qty <= 0 then raise exception 'أدخل الكمية المطلوبة'; end if;
  if p_needed_qty >= 1000000000 then raise exception 'الكمية المطلوبة غير منطقية'; end if;
  if p_needed_qty <> round(p_needed_qty, 3) then raise exception 'الكمية تقبل 3 خانات عشرية كحد أقصى'; end if;
  v_needed := p_needed_qty;
  v_note := nullif(btrim(coalesce(p_note, '')), '');
  if v_note is not null and char_length(v_note) > 500 then raise exception 'الملاحظة طويلة (الحد الأقصى 500 حرف)'; end if;

  select pr.track_inventory, pr.name into v_track, v_name from products pr where pr.id = p_product_id and pr.organization_id = org_id;
  if not found then raise exception 'الصنف غير موجود'; end if;
  if not v_track then raise exception 'هذا الصنف غير مرتبط بالمخزون — لا يوجد نقص يُبلَّغ عنه'; end if;
  if not exists (select 1 from warehouses w where w.id = p_warehouse_id and w.organization_id = org_id) then raise exception 'المخزن غير موجود'; end if;

  -- two clicks at the same moment must not create two reports
  perform pg_advisory_xact_lock(hashtextextended(org_id::text || auth.uid()::text || p_product_id::text || p_warehouse_id::text, 45));

  -- the available quantity is measured here, never taken from the browser
  v_avail := _sellable_qty(org_id, p_product_id, p_warehouse_id);
  if v_needed <= v_avail then
    raise exception 'الكمية المطلوبة متاحة حاليًا (المتاح: %) — لا حاجة لبلاغ نقص', trim_scale(v_avail);
  end if;

  select * into v_old from stock_shortage_reports r
  where r.organization_id = org_id and r.reported_by = auth.uid() and r.product_id = p_product_id and r.warehouse_id = p_warehouse_id
    and r.status in ('new', 'in_progress') and r.superseded_by is null
  for update;

  if found then
    -- same problem, nothing new: do not notify again
    if v_needed <= v_old.needed_qty and v_avail = v_old.available_qty then
      return jsonb_build_object('created', false, 'duplicate', true, 'report_id', v_old.id, 'status', v_old.status);
    end if;
    update stock_shortage_reports set superseded_by = v_new where id = v_old.id;   -- the situation changed: a fresh report replaces it
  end if;

  select coalesce((select sr.name from sales_representatives sr where sr.id = own_rep_id(org_id)),
                  (select u.email from auth.users u where u.id = auth.uid()),
                  'مستخدم') into v_rep_name;

  insert into stock_shortage_reports (id, organization_id, product_id, warehouse_id, reported_by, rep_name, available_qty, needed_qty, note)
  values (v_new, org_id, p_product_id, p_warehouse_id, auth.uid(), v_rep_name, v_avail, v_needed, v_note);

  insert into audit_logs (organization_id, user_id, action, entity, entity_id, after_data)
  values (org_id, auth.uid(), 'stock_shortage.reported', 'stock_shortage_report', v_new,
          jsonb_build_object('product', v_name, 'available', v_avail, 'needed', v_needed, 'replaced', v_old.id));

  return jsonb_build_object('created', true, 'duplicate', false, 'report_id', v_new, 'status', 'new', 'replaced_previous', v_old.id is not null);
end $$;

-- Owner: every report.  Sales rep: only his own.  Anyone else: nothing.
-- p_status: new | in_progress | resolved | open (= new + in_progress) | null (all, including replaced ones)
create or replace function list_stock_shortage_reports(org_id uuid, p_status text default null, p_limit integer default 100, p_offset integer default 0)
returns table (
  id uuid, product_id uuid, product_name text, unit text, warehouse_id uuid, warehouse_name text,
  rep_name text, available_qty numeric, needed_qty numeric, note text, status text, owner_note text,
  created_at timestamptz, status_changed_at timestamptz, superseded boolean, mine boolean
)
language plpgsql stable security definer set search_path = public as $$
declare v_owner boolean; v_rep boolean;
begin
  if auth.uid() is null then raise exception 'يجب تسجيل الدخول أولاً'; end if;
  if not is_org_member(org_id) then raise exception 'أنت لست عضوًا في هذه المؤسسة'; end if;
  v_owner := is_org_owner(org_id);
  v_rep := is_restricted_rep(org_id);
  if not v_owner and not v_rep then raise exception 'ليس لديك صلاحية عرض بلاغات النقص'; end if;
  if p_status is not null and p_status not in ('new', 'in_progress', 'resolved', 'open') then raise exception 'حالة غير صحيحة'; end if;

  return query
  select r.id, r.product_id, pr.name, pr.unit, r.warehouse_id, w.name,
         r.rep_name, r.available_qty::numeric, r.needed_qty::numeric, r.note, r.status, r.owner_note,
         r.created_at, r.status_changed_at, (r.superseded_by is not null), (r.reported_by = auth.uid())
  from stock_shortage_reports r
  join products pr on pr.id = r.product_id
  join warehouses w on w.id = r.warehouse_id
  where r.organization_id = org_id
    and (v_owner or r.reported_by = auth.uid())
    and (p_status is null
         or (p_status = 'open' and r.status in ('new', 'in_progress') and r.superseded_by is null)
         or (p_status in ('new', 'in_progress', 'resolved') and r.status = p_status and r.superseded_by is null))
  order by r.created_at desc, r.id
  limit least(greatest(coalesce(p_limit, 100), 1), 500) offset greatest(coalesce(p_offset, 0), 0);
end $$;

-- Owner only: new → in preparation → provided (any move is allowed, each one is logged)
create or replace function set_stock_shortage_status(org_id uuid, p_report_id uuid, p_status text, p_owner_note text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_old stock_shortage_reports%rowtype; v_note text;
begin
  if auth.uid() is null then raise exception 'يجب تسجيل الدخول أولاً'; end if;
  if not is_org_member(org_id) then raise exception 'أنت لست عضوًا في هذه المؤسسة'; end if;
  if not is_org_owner(org_id) then raise exception 'تغيير حالة بلاغ النقص للمالك فقط'; end if;
  if p_status is null or p_status not in ('new', 'in_progress', 'resolved') then raise exception 'حالة غير صحيحة'; end if;
  v_note := nullif(btrim(coalesce(p_owner_note, '')), '');
  if v_note is not null and char_length(v_note) > 500 then raise exception 'الملاحظة طويلة (الحد الأقصى 500 حرف)'; end if;

  select * into v_old from stock_shortage_reports r where r.id = p_report_id and r.organization_id = org_id for update;
  if not found then raise exception 'البلاغ غير موجود'; end if;
  if v_old.superseded_by is not null then raise exception 'تم استبدال هذا البلاغ ببلاغ أحدث من نفس المندوب'; end if;
  if v_old.status = p_status and (v_note is null or v_note is not distinct from v_old.owner_note) then raise exception 'البلاغ بهذه الحالة بالفعل'; end if;

  update stock_shortage_reports
  set status = p_status, owner_note = coalesce(v_note, owner_note),
      status_changed_at = now(), status_changed_by = auth.uid()
  where id = p_report_id;

  insert into audit_logs (organization_id, user_id, action, entity, entity_id, before_data, after_data)
  values (org_id, auth.uid(), 'stock_shortage.status_changed', 'stock_shortage_report', p_report_id,
          jsonb_build_object('status', v_old.status), jsonb_build_object('status', p_status, 'note', v_note));
  return jsonb_build_object('report_id', p_report_id, 'status', p_status);
end $$;

-- Numbers for the sidebar badge and the bell. Never raises (the dashboard layout calls it for every role).
--   Owner: open reports waiting.   Rep: his own open reports, and his own reports provided in the last 3 days.
create or replace function stock_shortage_counts(org_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null or not is_org_member(org_id) then return jsonb_build_object('new', 0, 'in_progress', 0, 'ready', 0); end if;
  if is_org_owner(org_id) then
    return jsonb_build_object(
      'new', (select count(*) from stock_shortage_reports r where r.organization_id = org_id and r.status = 'new' and r.superseded_by is null),
      'in_progress', (select count(*) from stock_shortage_reports r where r.organization_id = org_id and r.status = 'in_progress' and r.superseded_by is null),
      'ready', 0);
  end if;
  if is_restricted_rep(org_id) then
    return jsonb_build_object(
      'new', (select count(*) from stock_shortage_reports r where r.organization_id = org_id and r.reported_by = auth.uid() and r.status = 'new' and r.superseded_by is null),
      'in_progress', (select count(*) from stock_shortage_reports r where r.organization_id = org_id and r.reported_by = auth.uid() and r.status = 'in_progress' and r.superseded_by is null),
      'ready', (select count(*) from stock_shortage_reports r where r.organization_id = org_id and r.reported_by = auth.uid() and r.status = 'resolved'
                  and r.superseded_by is null and r.status_changed_at > now() - interval '3 days'));
  end if;
  return jsonb_build_object('new', 0, 'in_progress', 0, 'ready', 0);
end $$;

revoke all on function get_sellable_stock(uuid, uuid, uuid[]), report_stock_shortage(uuid, uuid, uuid, numeric, text),
                       list_stock_shortage_reports(uuid, text, integer, integer), set_stock_shortage_status(uuid, uuid, text, text),
                       stock_shortage_counts(uuid) from public, anon;
grant execute on function get_sellable_stock(uuid, uuid, uuid[]), report_stock_shortage(uuid, uuid, uuid, numeric, text),
                          list_stock_shortage_reports(uuid, text, integer, integer), set_stock_shortage_status(uuid, uuid, text, text),
                          stock_shortage_counts(uuid) to authenticated;

-- ============================================================
-- 3. The stock engine's shortage message: what was asked, what is available.
--    (Body = 0044's _consume_stock; ONLY the message of the shortage check changed. It no longer prints how much
--    is reserved — that is other people's pending invoices.)
-- ============================================================
create or replace function _consume_stock(org_id uuid, p_product uuid, p_wh uuid, p_qty numeric, p_ref uuid)
returns numeric language plpgsql security definer set search_path = public as $$
declare v_track boolean; v_name text; v_old_qty numeric(14,3); v_old_avg numeric(14,6); v_cost numeric(14,6); v_expired numeric(14,3); v_reserved numeric(14,3); v_free numeric;
begin
  select track_inventory, name into v_track, v_name from products where id = p_product and organization_id = org_id;
  if not found then raise exception 'أحد المنتجات المختارة لا ينتمي إلى هذه المؤسسة'; end if;
  if v_track then
    select s.quantity, coalesce(sc.avg_cost, 0) into v_old_qty, v_old_avg
    from inventory_stock s left join stock_costs sc on sc.stock_id = s.id
    where s.product_id = p_product and s.warehouse_id = p_wh for update of s;     -- serialises every sale of this product/warehouse
    if not found then
      v_old_qty := 0; v_old_avg := 0;
      insert into inventory_stock (organization_id, product_id, warehouse_id, quantity) values (org_id, p_product, p_wh, 0);
    end if;
    v_reserved := _stock_reserved(org_id, p_product, p_wh);      -- read AFTER the lock: this is the re-check against concurrent sales
    if v_old_qty - v_reserved < p_qty then
      v_free := greatest(v_old_qty - v_reserved, 0);
      raise exception '%الكمية المتاحة بالمخزون أقل من الكمية المطلوبة (الصنف: %، المطلوب: %، المتاح حاليًا: %)',
        case when v_free <= 0 then 'الصنف غير متوفر حاليًا — ' else '' end, v_name, trim_scale(p_qty), trim_scale(v_free);
    end if;
    select coalesce(sum(quantity), 0) into v_expired from stock_batches
    where organization_id = org_id and product_id = p_product and warehouse_id = p_wh and expiry_date < cairo_today();
    if v_old_qty - v_reserved - v_expired < p_qty then
      raise exception 'لا يمكن بيع بضاعة منتهية الصلاحية — المتاح للبيع (غير المنتهي): %، المنتهي الصلاحية في المخزن: %', greatest(v_old_qty - v_reserved - v_expired, 0), v_expired;
    end if;
    v_cost := v_old_avg;
    insert into invoice_stock_lines (organization_id, kind, invoice_id, product_id, warehouse_id, ordered_units)
    values (org_id, 'sales', p_ref, p_product, p_wh, p_qty);
  else
    select coalesce(pc.cost, 0) into v_cost from product_costs pc where pc.product_id = p_product limit 1;
    v_cost := coalesce(v_cost, 0);
  end if;
  return v_cost;
end $$;
revoke all on function _consume_stock(uuid, uuid, uuid, numeric, uuid) from public, anon, authenticated;

-- ============================================================
-- 4. Last line of defence, inside the database: at COMMIT the open sales reservations of a product/warehouse can
--    never exceed what is physically on hand.  _consume_stock already refuses before this point; this catches any
--    other path that tries to write a reservation.  (It fires on a NEW reservation only — dispatching, returns and
--    stock adjustments never trigger it, so they cannot be blocked by it.)
-- ============================================================
create or replace function _guard_oversell() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_qty numeric; v_res numeric;
begin
  if NEW.kind <> 'sales' then return NEW; end if;
  select s.quantity into v_qty from inventory_stock s where s.organization_id = NEW.organization_id and s.product_id = NEW.product_id and s.warehouse_id = NEW.warehouse_id;
  v_res := _stock_reserved(NEW.organization_id, NEW.product_id, NEW.warehouse_id);
  if coalesce(v_qty, 0) < v_res then
    raise exception 'لا يمكن حجز كمية أكبر من المتاح بالمخزون (الموجود: %، المحجوز بعد هذه الفاتورة: %)', trim_scale(coalesce(v_qty, 0)), trim_scale(v_res);
  end if;
  return NEW;
end $$;
revoke all on function _guard_oversell() from public, anon, authenticated;
drop trigger if exists z_oversell_guard on invoice_stock_lines;
create constraint trigger z_oversell_guard after insert on invoice_stock_lines
  deferrable initially deferred for each row execute function _guard_oversell();

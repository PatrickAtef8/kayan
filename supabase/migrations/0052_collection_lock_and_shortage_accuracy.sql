-- Kayan — 0052: close the gaps found while verifying collections and stock-shortage reports.
-- Depends on 0050/0051. Re-runnable. Touches only: record_customer_collection, the shortage functions and one trigger.
-- No invoice, stock, treasury, commission or notification logic changes except where stated below.
--
-- A. Collections (found by a real two-session test: two simultaneous collections of the full 1 000 on a 1 000 invoice
--    BOTH committed -> 2 000 recorded, 2 000 of cash in the treasury, amount_paid = 2 000).
--    Cause: the "not more than remains" check ran BEFORE the invoice row was locked.
--    Fix: lock the invoice first, then read what remains. The amount is also rounded once and used everywhere.
--
-- B. Shortage reports
--    1. Duplicate purchases: before saving a purchase from a report the owner is told if purchases already on their way
--       cover the shortage; an additional purchase then needs an explicit confirmation. When they do NOT cover it
--       (partly received, or the need is bigger) a further purchase is allowed without any friction.
--    2. Cancelled / partly received purchase: the report follows the invoice (status + an accurate note) instead of
--       staying "جاري التجهيز" forever. A report with no live purchase left returns to "جديد".
--    3. "Remaining shortage" is now computed live: needed − sellable now − still coming on live linked purchases.
--    4. Closing by hand ("تم توفيره من مصدر آخر") is refused unless the sellable stock really covers the need.

-- ============================================================
-- A. record_customer_collection (lock first, then check)
-- ============================================================
create or replace function public.record_customer_collection(org_id uuid, p_customer_id uuid, p_sales_invoice_id uuid, p_amount numeric, p_collection_date date, p_payment_method text, p_reference text, p_notes text)
 returns uuid
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  new_collection_id uuid;
  account_id uuid;
  v_total numeric(14,2);
  v_amount_paid numeric(14,2);
  v_amount numeric(14,2);
  v_remaining numeric(14,2);
begin
  if auth.uid() is null then
    raise exception 'يجب تسجيل الدخول أولاً';
  end if;
  if not is_org_member(org_id) then
    raise exception 'أنت لست عضوًا في هذه المؤسسة';
  end if;

  -- Who may collect:
  --   * a sales rep: needs collections.record AND the customer must be assigned to his own rep record
  --   * everybody else: treasury.manage (the Owner) — no customer restriction
  if is_restricted_rep(org_id) then
    if not has_permission(org_id, 'collections.record') then
      raise exception 'ليس لديك صلاحية تسجيل التحصيلات';
    end if;
    if own_rep_id(org_id) is null then
      raise exception 'حسابك غير مربوط بسجل مندوب — اطلب من المالك ربطه أولاً';
    end if;
    if not exists (select 1 from customers c
                   where c.id = p_customer_id and c.organization_id = org_id
                     and c.sales_rep_id in (select my_rep_ids())) then
      raise exception 'يمكنك تسجيل التحصيل من عملائك المعيّنين لك فقط';
    end if;
  elsif not has_permission(org_id, 'treasury.manage') then
    raise exception 'ليس لديك صلاحية تسجيل التحصيلات';
  end if;

  if not exists (select 1 from customers where id = p_customer_id and organization_id = org_id) then
    raise exception 'هذا العميل لا ينتمي إلى هذه المؤسسة';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'يجب أن يكون المبلغ أكبر من صفر';
  end if;
  if p_amount > 999999999999 then
    raise exception 'المبلغ كبير جدًا';
  end if;
  v_amount := round(p_amount, 2);
  if v_amount <= 0 then
    raise exception 'يجب أن يكون المبلغ أكبر من صفر';
  end if;
  if p_sales_invoice_id is not null
     and not exists (select 1 from sales_invoices where id = p_sales_invoice_id and organization_id = org_id and customer_id = p_customer_id) then
    raise exception 'هذه الفاتورة لا تخص هذا العميل';
  end if;

  -- One collection at a time per invoice. The row is locked BEFORE the remaining balance is read, so a collection that
  -- commits while this one waits is already counted when the check runs (previously the check ran first and two
  -- simultaneous collections could both pass it, recording more cash than the invoice was worth).
  if p_sales_invoice_id is not null then
    select total, amount_paid into v_total, v_amount_paid
    from sales_invoices where id = p_sales_invoice_id and organization_id = org_id for update;
    v_remaining := sales_invoice_remaining(p_sales_invoice_id);
    if v_amount > v_remaining then
      raise exception 'المبلغ أكبر من المتبقي على الفاتورة (المتبقي: %)', v_remaining;
    end if;
  end if;

  account_id := ensure_default_treasury_account(org_id);

  insert into customer_collections (organization_id, customer_id, sales_invoice_id, amount, collection_date, payment_method, reference, notes, created_by)
  values (org_id, p_customer_id, p_sales_invoice_id, v_amount, coalesce(p_collection_date, current_date), nullif(p_payment_method, ''), nullif(p_reference, ''), nullif(p_notes, ''), auth.uid())
  returning id into new_collection_id;

  insert into treasury_movements (organization_id, treasury_account_id, direction, amount, category, movement_date, source_type, source_id, description, created_by)
  values (org_id, account_id, 'in', v_amount, 'customer_collection', coalesce(p_collection_date, current_date), 'customer_collection', new_collection_id, nullif(p_notes, ''), auth.uid());

  if p_sales_invoice_id is not null then
    v_amount_paid := v_amount_paid + v_amount;
    update sales_invoices
    set amount_paid = v_amount_paid,
        payment_status = case when v_amount_paid >= v_total then 'paid' when v_amount_paid <= 0 then 'unpaid' else 'partial' end,
        updated_at = now()
    where id = p_sales_invoice_id;

    perform recompute_sales_commission(p_sales_invoice_id);
  end if;

  return new_collection_id;
end;
$function$;

revoke all on function record_customer_collection(uuid, uuid, uuid, numeric, date, text, text, text) from public, anon;
grant execute on function record_customer_collection(uuid, uuid, uuid, numeric, date, text, text, text) to authenticated;

-- ============================================================
-- B1. Live numbers for a report
-- ============================================================
-- Units still to arrive on LIVE (pending / partly received) purchase invoices linked to the report, for the report's
-- product in the report's warehouse. p_exclude lets the link step ignore the invoice that is being linked right now.
create or replace function _shortage_incoming(p_report_id uuid, p_exclude uuid default null) returns numeric
language sql stable security definer set search_path = public as $$
  select coalesce(sum(greatest(l.ordered_units - l.fulfilled_units - l.cancelled_units, 0)), 0)
  from stock_shortage_reports r
  join stock_shortage_purchase_links k on k.report_id = r.id
  join purchase_invoices i on i.id = k.purchase_invoice_id and i.receipt_status in ('pending', 'partial') and i.id is distinct from p_exclude
  join invoice_stock_lines l on l.kind = 'purchase' and l.invoice_id = i.id and l.product_id = r.product_id and l.warehouse_id = r.warehouse_id
  where r.id = p_report_id
$$;
revoke all on function _shortage_incoming(uuid, uuid) from public, anon, authenticated;

-- ============================================================
-- B2. Keep a report in step with its purchase invoices
--     resolved  only when the SELLABLE stock covers the need
--     new       when every linked invoice was cancelled (nothing is on its way any more)
--     in_progress otherwise, with a note that states available / coming / still missing
-- ============================================================
create or replace function _shortage_refresh(p_report_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare r stock_shortage_reports%rowtype; v_avail numeric; v_in numeric; v_rem numeric; v_live int; v_any int; v_status text; v_note text;
begin
  select * into r from stock_shortage_reports where id = p_report_id for update;
  if not found or r.superseded_by is not null or r.status not in ('new', 'in_progress') then return; end if;

  v_avail := _sellable_qty(r.organization_id, r.product_id, r.warehouse_id);
  v_in    := _shortage_incoming(r.id);
  v_rem   := greatest(r.needed_qty - v_avail - v_in, 0);
  select count(*) filter (where i.receipt_status in ('pending', 'partial')), count(*) filter (where i.receipt_status <> 'cancelled')
  into v_live, v_any
  from stock_shortage_purchase_links k join purchase_invoices i on i.id = k.purchase_invoice_id where k.report_id = r.id;

  if v_avail >= r.needed_qty then
    v_status := 'resolved';
    v_note := 'تم استلام فاتورة الشراء وإضافة الكمية للمخزون';
  elsif v_any = 0 then
    v_status := 'new';
    v_note := 'أُلغيت فاتورة الشراء المرتبطة — البلاغ مفتوح من جديد: المتاح للبيع (' || trim_scale(v_avail)::text || ') أقل من المطلوب (' || trim_scale(r.needed_qty)::text || ')';
  elsif v_live > 0 then
    v_status := 'in_progress';
    v_note := 'المتاح للبيع (' || trim_scale(v_avail)::text || ') من المطلوب (' || trim_scale(r.needed_qty)::text || ') — في الطريق (' || trim_scale(v_in)::text || ') بفواتير شراء بانتظار الاستلام'
              || case when v_rem > 0 then ' — ما زال ينقص ' || trim_scale(v_rem)::text || ' يلزم توريدها' else '' end;
  else
    v_status := 'in_progress';
    v_note := 'تم استلام فاتورة الشراء لكن المتاح (' || trim_scale(v_avail)::text || ') ما زال أقل من المطلوب (' || trim_scale(r.needed_qty)::text || ') — العجز المتبقي ' || trim_scale(v_rem)::text;
  end if;

  if v_status is distinct from r.status or v_note is distinct from r.owner_note then
    update stock_shortage_reports
    set status = v_status, owner_note = v_note,
        status_changed_at = case when v_status is distinct from status then now() else status_changed_at end,
        status_changed_by = case when v_status is distinct from status then coalesce(auth.uid(), status_changed_by) else status_changed_by end
    where id = r.id;
    if v_status = 'resolved' then
      insert into audit_logs (organization_id, user_id, action, entity, entity_id, after_data)
      values (r.organization_id, auth.uid(), 'stock_shortage.resolved_by_purchase', 'stock_shortage_report', r.id,
              jsonb_build_object('available', v_avail, 'needed', r.needed_qty));
    end if;
  end if;
end $$;
revoke all on function _shortage_refresh(uuid) from public, anon, authenticated;

-- fires for every change of a linked purchase invoice's receiving state: partly received, fully received, cancelled
create or replace function _shortage_on_purchase_status() returns trigger
language plpgsql security definer set search_path = public as $$
declare l record;
begin
  begin
    for l in select k.report_id from stock_shortage_purchase_links k where k.purchase_invoice_id = NEW.id loop
      perform _shortage_refresh(l.report_id);
    end loop;
  exception when others then
    raise warning 'shortage refresh skipped for purchase invoice %: %', NEW.id, sqlerrm;   -- never blocks the storekeeper
  end;
  return NEW;
end $$;
revoke all on function _shortage_on_purchase_status() from public, anon, authenticated;

drop trigger if exists z_shortage_resolve on purchase_invoices;
create trigger z_shortage_resolve after update of receipt_status on purchase_invoices
  for each row when (OLD.receipt_status is distinct from NEW.receipt_status)
  execute function _shortage_on_purchase_status();
drop function if exists _shortage_on_purchase_received();

-- ============================================================
-- B3. Before saving a purchase for a report: what is already on its way? (owner only)
-- ============================================================
create or replace function shortage_purchase_precheck(org_id uuid, p_report_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare r stock_shortage_reports%rowtype; v_avail numeric; v_in numeric; v_pending jsonb;
begin
  if auth.uid() is null then raise exception 'يجب تسجيل الدخول أولاً'; end if;
  if not is_org_member(org_id) then raise exception 'أنت لست عضوًا في هذه المؤسسة'; end if;
  if not is_org_owner(org_id) then raise exception 'ليس لديك صلاحية'; end if;
  select * into r from stock_shortage_reports x where x.id = p_report_id and x.organization_id = org_id;
  if not found then raise exception 'البلاغ غير موجود'; end if;
  v_avail := _sellable_qty(org_id, r.product_id, r.warehouse_id);
  v_in := _shortage_incoming(r.id);
  select coalesce(jsonb_agg(jsonb_build_object('purchase_invoice_id', i.id, 'invoice_number', i.invoice_number,
           'open_units', (select coalesce(sum(greatest(l.ordered_units - l.fulfilled_units - l.cancelled_units, 0)), 0)
                          from invoice_stock_lines l where l.kind = 'purchase' and l.invoice_id = i.id and l.product_id = r.product_id and l.warehouse_id = r.warehouse_id))
         order by i.created_at), '[]'::jsonb)
  into v_pending
  from stock_shortage_purchase_links k join purchase_invoices i on i.id = k.purchase_invoice_id
  where k.report_id = r.id and i.receipt_status in ('pending', 'partial');
  return jsonb_build_object('needed', r.needed_qty, 'available', v_avail, 'incoming', v_in,
                            'remaining', greatest(r.needed_qty - v_avail - v_in, 0),
                            'covered', (v_in > 0 and v_avail + v_in >= r.needed_qty),
                            'pending', v_pending);
end $$;
revoke all on function shortage_purchase_precheck(uuid, uuid) from public, anon;
grant execute on function shortage_purchase_precheck(uuid, uuid) to authenticated;

-- ============================================================
-- B4. Linking a purchase to a report (duplicate guard; the guard is bypassed only by an explicit p_additional)
--     The old 3-argument version is dropped so the name cannot become ambiguous.
-- ============================================================
drop function if exists link_shortage_to_purchase(uuid, uuid, uuid);
create or replace function link_shortage_to_purchase(org_id uuid, p_report_id uuid, p_purchase_invoice_id uuid, p_additional boolean default false)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_r stock_shortage_reports%rowtype; v_inv record; v_other numeric; v_avail numeric; v_already boolean;
begin
  if auth.uid() is null then raise exception 'يجب تسجيل الدخول أولاً'; end if;
  if not is_org_member(org_id) then raise exception 'أنت لست عضوًا في هذه المؤسسة'; end if;
  if not is_org_owner(org_id) then raise exception 'ربط بلاغ النقص بفاتورة شراء للمالك فقط'; end if;

  select * into v_r from stock_shortage_reports r where r.id = p_report_id and r.organization_id = org_id for update;
  if not found then raise exception 'البلاغ غير موجود'; end if;
  if v_r.superseded_by is not null then raise exception 'تم استبدال هذا البلاغ ببلاغ أحدث من نفس المندوب'; end if;
  if v_r.status = 'resolved' then raise exception 'تم توفير هذا الصنف بالفعل — أعد فتح البلاغ أولًا إن كنت تحتاج توريدًا جديدًا'; end if;

  select i.id, i.invoice_number, i.receipt_status into v_inv from purchase_invoices i where i.id = p_purchase_invoice_id and i.organization_id = org_id;
  if not found then raise exception 'فاتورة الشراء غير موجودة'; end if;
  if v_inv.receipt_status = 'cancelled' then raise exception 'فاتورة الشراء ملغاة'; end if;
  if not exists (select 1 from purchase_invoice_items it
                 where it.purchase_invoice_id = p_purchase_invoice_id and it.organization_id = org_id and it.product_id = v_r.product_id) then
    raise exception 'فاتورة الشراء لا تحتوي على الصنف المطلوب في البلاغ';
  end if;

  v_already := exists (select 1 from stock_shortage_purchase_links where report_id = p_report_id and purchase_invoice_id = p_purchase_invoice_id);
  if not v_already and not coalesce(p_additional, false) then
    v_other := _shortage_incoming(p_report_id, p_purchase_invoice_id);
    v_avail := _sellable_qty(org_id, v_r.product_id, v_r.warehouse_id);
    if v_other > 0 and v_avail + v_other >= v_r.needed_qty then
      raise exception 'يوجد بالفعل فاتورة شراء قائمة لهذا البلاغ (الكمية في الطريق: %) تغطي العجز — المتاح % + في الطريق % من المطلوب %. لو تحتاج فاتورة إضافية فعلًا أكّد ذلك صراحةً.',
        trim_scale(v_other), trim_scale(v_avail), trim_scale(v_other), trim_scale(v_r.needed_qty);
    end if;
  end if;

  insert into stock_shortage_purchase_links (organization_id, report_id, purchase_invoice_id, created_by)
  values (org_id, p_report_id, p_purchase_invoice_id, auth.uid())
  on conflict do nothing;

  update stock_shortage_reports
  set status = 'in_progress',
      status_changed_at = case when status = 'in_progress' then status_changed_at else now() end,
      status_changed_by = case when status = 'in_progress' then status_changed_by else auth.uid() end
  where id = p_report_id;
  perform _shortage_refresh(p_report_id);     -- accurate note (available / coming / still missing); closes it only if stock already covers the need

  insert into audit_logs (organization_id, user_id, action, entity, entity_id, after_data)
  values (org_id, auth.uid(), 'stock_shortage.purchase_linked', 'stock_shortage_report', p_report_id,
          jsonb_build_object('purchase_invoice_id', p_purchase_invoice_id, 'invoice_number', v_inv.invoice_number, 'additional', coalesce(p_additional, false)));

  return jsonb_build_object('report_id', p_report_id, 'purchase_invoice_id', p_purchase_invoice_id,
                            'status', (select status from stock_shortage_reports where id = p_report_id));
end $$;
revoke all on function link_shortage_to_purchase(uuid, uuid, uuid, boolean) from public, anon;
grant execute on function link_shortage_to_purchase(uuid, uuid, uuid, boolean) to authenticated;

-- ============================================================
-- B5. The list now carries the LIVE figures. The owner sees available / coming / remaining; a rep only sees what is
--     available now (he never sees purchases). Null for resolved and replaced reports.
-- ============================================================
drop function if exists list_stock_shortage_reports(uuid, text, integer, integer);
create or replace function list_stock_shortage_reports(org_id uuid, p_status text default null, p_limit integer default 100, p_offset integer default 0)
returns table (
  id uuid, product_id uuid, product_name text, unit text, warehouse_id uuid, warehouse_name text,
  rep_name text, available_qty numeric, needed_qty numeric, note text, status text, owner_note text,
  created_at timestamptz, status_changed_at timestamptz, superseded boolean, mine boolean,
  current_available numeric, incoming_qty numeric, remaining_qty numeric
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
         r.created_at, r.status_changed_at, (r.superseded_by is not null), (r.reported_by = auth.uid()),
         case when r.status <> 'resolved' and r.superseded_by is null then _sellable_qty(org_id, r.product_id, r.warehouse_id) end,
         case when v_owner and r.status <> 'resolved' and r.superseded_by is null then _shortage_incoming(r.id) end,
         case when v_owner and r.status <> 'resolved' and r.superseded_by is null
              then greatest(r.needed_qty - _sellable_qty(org_id, r.product_id, r.warehouse_id) - _shortage_incoming(r.id), 0) end
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
revoke all on function list_stock_shortage_reports(uuid, text, integer, integer) from public, anon;
grant execute on function list_stock_shortage_reports(uuid, text, integer, integer) to authenticated;

-- ============================================================
-- B6. "Provided from another source": the report may be closed by hand ONLY when the sellable stock covers the need.
--     (Sellable = on hand − promised to open sales − expired batches.) Other transitions are unchanged.
-- ============================================================
create or replace function set_stock_shortage_status(org_id uuid, p_report_id uuid, p_status text, p_owner_note text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_old stock_shortage_reports%rowtype; v_note text; v_avail numeric;
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

  if p_status = 'resolved' then
    v_avail := _sellable_qty(org_id, v_old.product_id, v_old.warehouse_id);
    if v_avail < v_old.needed_qty then
      raise exception 'لا يمكن إغلاق البلاغ: المتاح للبيع الآن (%) أقل من المطلوب (%). أضف الكمية للمخزن أولًا (فاتورة مشتريات يستلمها أمين المخزن، أو تحويل من مخزن آخر) ثم أغلق البلاغ.',
        trim_scale(v_avail), trim_scale(v_old.needed_qty);
    end if;
    -- a note the owner typed is kept; a note written by the system while the report was open ("في الطريق…", "ما زال ينقص…")
    -- would be stale on a closed report, so only those are replaced
    if v_note is null and (v_old.owner_note is null
        or v_old.owner_note ~ '^(المتاح للبيع \(|تم استلام فاتورة الشراء|أُلغيت فاتورة الشراء|تم إنشاء فاتورة شراء)') then
      v_note := 'تم التوفير — المتاح للبيع عند الإغلاق (' || trim_scale(v_avail) || ') يغطي المطلوب (' || trim_scale(v_old.needed_qty) || ')';
    end if;
  end if;

  update stock_shortage_reports
  set status = p_status, owner_note = coalesce(v_note, owner_note),
      status_changed_at = now(), status_changed_by = auth.uid()
  where id = p_report_id;

  insert into audit_logs (organization_id, user_id, action, entity, entity_id, before_data, after_data)
  values (org_id, auth.uid(), 'stock_shortage.status_changed', 'stock_shortage_report', p_report_id,
          jsonb_build_object('status', v_old.status),
          jsonb_build_object('status', p_status, 'note', v_note) || case when p_status = 'resolved' then jsonb_build_object('available', v_avail, 'needed', v_old.needed_qty) else '{}'::jsonb end);
  return jsonb_build_object('report_id', p_report_id, 'status', p_status);
end $$;
revoke all on function set_stock_shortage_status(uuid, uuid, text, text) from public, anon;
grant execute on function set_stock_shortage_status(uuid, uuid, text, text) to authenticated;

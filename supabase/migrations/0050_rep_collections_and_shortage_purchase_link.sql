-- Kayan — Phase 50: (1) the sales rep is also a COLLECTION rep, (2) shortage reports are closed through a purchase invoice
-- Depends on 0049. Re-runnable. Does not touch existing stock, balances, invoices or collections.
--
-- (1) Rep collections
--     Before: record_customer_collection() demanded `treasury.manage`, which only the Owner holds, so a rep could
--     create the invoice but not register the money he collected from his own customer.
--     Now: a rep (role `sales`) holding the new permission `collections.record` may register a collection
--     (against one invoice, or a standalone payment) ONLY for customers assigned to his own rep record.
--     Everything else is unchanged: amount can never exceed what is still owed, one treasury movement per payment,
--     commission is recomputed, audit + notifications fire as before. The Owner is unaffected.
--
-- (2) Shortage reports -> purchase invoice
--     The Owner no longer "just marks the item provided". From a shortage report he creates a purchase invoice for
--     the item (product pre-selected in the form), enters the quantity and saves it. The invoice is linked to the
--     report (report becomes «جاري التجهيز»). Stock is added by the normal receiving cycle (0044) when the
--     storekeeper confirms receiving, and at that moment the linked report is closed automatically — but only if the
--     sellable quantity now really covers the quantity the rep asked for.

-- ============================================================
-- 1. Permission: collections.record  (rep + owner)
-- ============================================================
insert into permissions (key, description, category) values
  ('collections.record', 'Record payments collected from the customers assigned to the user (sales rep) — Owner: any customer', 'treasury')
on conflict (key) do nothing;

insert into role_permissions (role_id, permission_key)
select r.id, 'collections.record' from roles r
where r.organization_id is null and r.key in ('owner', 'sales')
on conflict do nothing;

-- ============================================================
-- 2. record_customer_collection — rep scope
--    (body = 0028 version; only the permission block changed, and the two identical UPDATE branches were merged)
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
  if p_sales_invoice_id is not null
     and not exists (select 1 from sales_invoices where id = p_sales_invoice_id and organization_id = org_id and customer_id = p_customer_id) then
    raise exception 'هذه الفاتورة لا تخص هذا العميل';
  end if;

  if p_sales_invoice_id is not null and round(p_amount, 2) > sales_invoice_remaining(p_sales_invoice_id) then
    raise exception 'المبلغ أكبر من المتبقي على الفاتورة (المتبقي: %)', sales_invoice_remaining(p_sales_invoice_id);
  end if;

  account_id := ensure_default_treasury_account(org_id);

  insert into customer_collections (organization_id, customer_id, sales_invoice_id, amount, collection_date, payment_method, reference, notes, created_by)
  values (org_id, p_customer_id, p_sales_invoice_id, p_amount, coalesce(p_collection_date, current_date), nullif(p_payment_method, ''), nullif(p_reference, ''), nullif(p_notes, ''), auth.uid())
  returning id into new_collection_id;

  insert into treasury_movements (organization_id, treasury_account_id, direction, amount, category, movement_date, source_type, source_id, description, created_by)
  values (org_id, account_id, 'in', p_amount, 'customer_collection', coalesce(p_collection_date, current_date), 'customer_collection', new_collection_id, nullif(p_notes, ''), auth.uid());

  if p_sales_invoice_id is not null then
    select total, amount_paid
    into v_total, v_amount_paid
    from sales_invoices
    where id = p_sales_invoice_id and organization_id = org_id
    for update;

    if found then
      v_amount_paid := v_amount_paid + p_amount;
      update sales_invoices
      set amount_paid = v_amount_paid,
          payment_status = case when v_amount_paid >= v_total then 'paid' when v_amount_paid <= 0 then 'unpaid' else 'partial' end,
          updated_at = now()
      where id = p_sales_invoice_id;
    end if;

    perform recompute_sales_commission(p_sales_invoice_id);
  end if;

  return new_collection_id;
end;
$function$;

revoke all on function record_customer_collection(uuid, uuid, uuid, numeric, date, text, text, text) from public, anon;
grant execute on function record_customer_collection(uuid, uuid, uuid, numeric, date, text, text, text) to authenticated;

-- ============================================================
-- 3. Shortage report <-> purchase invoice link
--    Same access model as stock_shortage_reports (0045): nobody touches the table directly.
-- ============================================================
create table if not exists stock_shortage_purchase_links (
  organization_id     uuid not null references organizations(id) on delete cascade,
  report_id           uuid not null references stock_shortage_reports(id) on delete cascade,
  purchase_invoice_id uuid not null references purchase_invoices(id) on delete cascade,
  created_by          uuid references auth.users(id),
  created_at          timestamptz not null default now(),
  primary key (report_id, purchase_invoice_id)
);
create index if not exists stock_shortage_links_invoice_idx on stock_shortage_purchase_links (purchase_invoice_id);

alter table stock_shortage_purchase_links enable row level security;
alter table stock_shortage_purchase_links force row level security;
revoke all on stock_shortage_purchase_links from public, anon, authenticated;

-- Owner only. Called right after the purchase invoice is saved from the shortage report.
-- The report moves to «جاري التجهيز»; it is NOT resolved here — stock has not arrived yet.
create or replace function link_shortage_to_purchase(org_id uuid, p_report_id uuid, p_purchase_invoice_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_r stock_shortage_reports%rowtype;
  v_inv record;
  v_no text;
  v_note text;
begin
  if auth.uid() is null then raise exception 'يجب تسجيل الدخول أولاً'; end if;
  if not is_org_member(org_id) then raise exception 'أنت لست عضوًا في هذه المؤسسة'; end if;
  if not is_org_owner(org_id) then raise exception 'ربط بلاغ النقص بفاتورة شراء للمالك فقط'; end if;

  select * into v_r from stock_shortage_reports r where r.id = p_report_id and r.organization_id = org_id for update;
  if not found then raise exception 'البلاغ غير موجود'; end if;
  if v_r.superseded_by is not null then raise exception 'تم استبدال هذا البلاغ ببلاغ أحدث من نفس المندوب'; end if;
  if v_r.status = 'resolved' then raise exception 'تم توفير هذا الصنف بالفعل — أعد فتح البلاغ أولًا إن كنت تحتاج توريدًا جديدًا'; end if;

  select i.id, i.invoice_number, i.receipt_status into v_inv
  from purchase_invoices i where i.id = p_purchase_invoice_id and i.organization_id = org_id;
  if not found then raise exception 'فاتورة الشراء غير موجودة'; end if;
  if v_inv.receipt_status = 'cancelled' then raise exception 'فاتورة الشراء ملغاة'; end if;
  if not exists (select 1 from purchase_invoice_items it
                 where it.purchase_invoice_id = p_purchase_invoice_id and it.organization_id = org_id and it.product_id = v_r.product_id) then
    raise exception 'فاتورة الشراء لا تحتوي على الصنف المطلوب في البلاغ';
  end if;

  insert into stock_shortage_purchase_links (organization_id, report_id, purchase_invoice_id, created_by)
  values (org_id, p_report_id, p_purchase_invoice_id, auth.uid())
  on conflict do nothing;

  v_no := coalesce(nullif(btrim(coalesce(v_inv.invoice_number, '')), ''), 'بدون رقم');
  v_note := 'تم إنشاء فاتورة شراء (' || v_no || ') — بانتظار استلام أمين المخزن';

  update stock_shortage_reports
  set status = 'in_progress',
      owner_note = coalesce(owner_note, v_note),
      status_changed_at = case when status = 'in_progress' then status_changed_at else now() end,
      status_changed_by = case when status = 'in_progress' then status_changed_by else auth.uid() end
  where id = p_report_id;

  insert into audit_logs (organization_id, user_id, action, entity, entity_id, after_data)
  values (org_id, auth.uid(), 'stock_shortage.purchase_linked', 'stock_shortage_report', p_report_id,
          jsonb_build_object('purchase_invoice_id', p_purchase_invoice_id, 'invoice_number', v_inv.invoice_number));

  return jsonb_build_object('report_id', p_report_id, 'purchase_invoice_id', p_purchase_invoice_id, 'status', 'in_progress');
end $$;

-- Owner only: the purchase invoices linked to a set of reports (the page shows them under each report)
create or replace function list_shortage_report_links(org_id uuid, p_report_ids uuid[])
returns table (report_id uuid, purchase_invoice_id uuid, invoice_number text, invoice_date date, receipt_status text)
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'يجب تسجيل الدخول أولاً'; end if;
  if not is_org_member(org_id) then raise exception 'أنت لست عضوًا في هذه المؤسسة'; end if;
  if not is_org_owner(org_id) then raise exception 'ليس لديك صلاحية'; end if;
  return query
  select l.report_id, l.purchase_invoice_id, i.invoice_number, i.invoice_date, i.receipt_status
  from stock_shortage_purchase_links l
  join purchase_invoices i on i.id = l.purchase_invoice_id
  where l.organization_id = org_id and l.report_id = any (coalesce(p_report_ids, '{}'::uuid[]))
  order by l.created_at;
end $$;

revoke all on function link_shortage_to_purchase(uuid, uuid, uuid), list_shortage_report_links(uuid, uuid[]) from public, anon;
grant execute on function link_shortage_to_purchase(uuid, uuid, uuid), list_shortage_report_links(uuid, uuid[]) to authenticated;

-- ============================================================
-- 4. When the storekeeper has fully received a linked purchase invoice, close the linked reports —
--    only if the sellable quantity now covers what the rep needed. Never blocks the receiving itself.
--    (stock is added inside _confirm_fulfilment BEFORE it refreshes receipt_status, so the number read here is final)
-- ============================================================
create or replace function _shortage_on_purchase_received() returns trigger
language plpgsql security definer set search_path = public as $$
declare l record; v_avail numeric;
begin
  begin
    for l in
      select r.id, r.organization_id, r.product_id, r.warehouse_id, r.needed_qty, k.created_by
      from stock_shortage_purchase_links k
      join stock_shortage_reports r on r.id = k.report_id
      where k.purchase_invoice_id = NEW.id and r.status in ('new', 'in_progress') and r.superseded_by is null
      for update of r
    loop
      v_avail := _sellable_qty(l.organization_id, l.product_id, l.warehouse_id);
      if v_avail >= l.needed_qty then
        update stock_shortage_reports
        set status = 'resolved', status_changed_at = now(), status_changed_by = coalesce(l.created_by, status_changed_by),
            owner_note = 'تم استلام فاتورة الشراء وإضافة الكمية للمخزون'
        where id = l.id;
        insert into audit_logs (organization_id, user_id, action, entity, entity_id, after_data)
        values (l.organization_id, auth.uid(), 'stock_shortage.resolved_by_purchase', 'stock_shortage_report', l.id,
                jsonb_build_object('purchase_invoice_id', NEW.id, 'available', v_avail, 'needed', l.needed_qty));
      else
        update stock_shortage_reports
        set owner_note = 'تم استلام فاتورة الشراء لكن المتاح (' || trim_scale(v_avail)::text || ') ما زال أقل من المطلوب (' || trim_scale(l.needed_qty)::text || ')'
        where id = l.id;
      end if;
    end loop;
  exception when others then
    raise warning 'shortage auto-resolve skipped for purchase invoice %: %', NEW.id, sqlerrm;
  end;
  return NEW;
end $$;
revoke all on function _shortage_on_purchase_received() from public, anon, authenticated;

drop trigger if exists z_shortage_resolve on purchase_invoices;
create trigger z_shortage_resolve after update of receipt_status on purchase_invoices
  for each row when (NEW.receipt_status = 'received' and OLD.receipt_status is distinct from NEW.receipt_status)
  execute function _shortage_on_purchase_received();

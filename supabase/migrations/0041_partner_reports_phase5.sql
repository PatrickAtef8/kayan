-- Kayan — Reports package, Phase 5: supplier & customer account reports
--
--   A. Sales channel is a SNAPSHOT (follow-up to 0040)
--   B. Supplier payment due dates
--   C. Open-items engine + reports:
--        report_party_open_items   invoice-level statement (paid / returned / remaining / overdue)
--        report_supplier_dues      supplier balances split into overdue / not yet due / undated
--        report_receivables_summary customer outstanding per rep and for the whole company
--        report_party_payments     payment register (supplier payments / customer collections)
--        report_supplier_items     what was bought from each supplier (purchased / free / returned / net received)
--
-- Nothing here changes how invoices, payments, returns, stock or balances are calculated. The
-- single source of truth for a balance stays customer_balances / supplier_balances:
--     balance = opening + Σ invoices − Σ payments − Σ returns + Σ cash refunded
-- and every new report is tested to add up to exactly that figure.

-- ============================================================
-- A. Sales channel snapshot — explicit migration plan
-- ============================================================
-- New invoices (0040) already store their channel at creation (a BEFORE INSERT trigger fills it from
-- the customer's price tier when the sales form does not choose one) and nothing can edit it later,
-- so a later change of the customer's tier cannot move them.
--
-- Invoices created BEFORE 0040 have sales_channel = NULL and 0040 reported them under the customer's
-- CURRENT tier — which would silently re-classify history whenever a tier changes. This migration
-- freezes that classification once, as of now, WITHOUT touching a single sales_invoices row:
--   * the frozen value goes into a side table (no UPDATE on invoices → no audit noise, no triggers,
--     no change to existing data);
--   * report_sales_by reads  invoice.sales_channel → frozen snapshot → (tier, only as a last resort);
--   * source = 'tier_at_migration' marks these as INFERRED, not chosen by a user.
--
-- Dry run (before applying; shows what will be frozen):
--   select c.price_tier, count(*) from sales_invoices i join customers c on c.id = i.customer_id
--   where i.sales_channel is null group by 1;   -- retail → retail, wholesale/distributor → wholesale
-- Rollback (the report falls back to the live tier, exactly as in 0040):
--   delete from sales_invoice_channel_snapshot;
create table if not exists sales_invoice_channel_snapshot (
  sales_invoice_id uuid primary key references sales_invoices(id) on delete cascade,
  organization_id  uuid not null references organizations(id) on delete cascade,
  sales_channel    text not null check (sales_channel in ('wholesale', 'retail', 'social')),
  source           text not null default 'tier_at_migration',
  created_at       timestamptz not null default now()
);
create index if not exists sales_invoice_channel_snapshot_org on sales_invoice_channel_snapshot (organization_id);
alter table sales_invoice_channel_snapshot enable row level security;
drop policy if exists sales_invoice_channel_snapshot_select on sales_invoice_channel_snapshot;
-- visible exactly when the invoice itself is visible (keeps the existing rep scoping)
create policy sales_invoice_channel_snapshot_select on sales_invoice_channel_snapshot for select
  using (exists (select 1 from sales_invoices i where i.id = sales_invoice_id));
revoke all on sales_invoice_channel_snapshot from public, anon, authenticated;
grant select on sales_invoice_channel_snapshot to authenticated;

insert into sales_invoice_channel_snapshot (sales_invoice_id, organization_id, sales_channel)
select i.id, i.organization_id, case c.price_tier when 'retail' then 'retail' else 'wholesale' end
from sales_invoices i join customers c on c.id = i.customer_id
where i.sales_channel is null
on conflict (sales_invoice_id) do nothing;

-- report_sales_by: the 0040 definition with ONE change — the channel comes from the invoice, then the
-- frozen snapshot, and only then (never expected for real data) the live tier.
create or replace function report_sales_by(
  org_id uuid, p_group text,
  p_from date default null, p_to date default null,
  p_warehouse uuid default null, p_rep uuid default null, p_channel text default null,
  p_limit int default 200, p_offset int default 0
)
returns table (
  group_id text, group_label text,
  invoices bigint, customers bigint, products bigint,
  billed_qty numeric, bonus_qty numeric, returned_qty numeric, net_qty numeric,
  units_per_carton numeric, whole_cartons numeric, remainder_units numeric,   -- product rows only
  cartons numeric, loose_units numeric,
  gross_sales numeric, discounts numeric, returns_value numeric, net_revenue numeric,
  total_count bigint
)
language plpgsql stable set search_path = public as $$
declare
  v_limit int := least(greatest(coalesce(p_limit, 200), 1), 1000);
  v_off   int := greatest(coalesce(p_offset, 0), 0);
  v_chan  text := nullif(btrim(coalesce(p_channel, '')), '');
begin
  perform assert_report_access(org_id, false);
  if p_group is null or p_group not in ('rep', 'channel', 'product', 'customer') then raise exception 'نوع التقرير غير صحيح'; end if;
  if v_chan is not null and v_chan not in ('wholesale', 'retail', 'social') then raise exception 'قناة البيع غير صحيحة'; end if;

  return query
  with ret as (   -- returns summed PER INVOICE ITEM, so they join 1:1 and can never multiply a line
    select r.sales_invoice_item_id as item_id, sum(r.quantity) as qty, sum(r.revenue_reversed) as rev
    from sales_return_items r
    where r.organization_id = org_id
    group by r.sales_invoice_item_id
  ),
  ln as (
    select inv.id as inv_id, inv.customer_id as cust_id, inv.sales_rep_id as rep_id, i.product_id as prod_id,
           coalesce(inv.sales_channel, snap.sales_channel, case c.price_tier when 'retail' then 'retail' else 'wholesale' end) as chan,
           sr.name as rep_name, c.name as cust_name, p.name as prod_name, p.units_per_carton as per,
           (case when i.is_bonus then 0 else i.quantity end)::numeric as billed,
           (i.bonus_quantity + case when i.is_bonus then i.quantity else 0 end)::numeric as bonus,
           coalesce(ret.qty, 0)::numeric as returned,
           (i.quantity * i.unit_price)::numeric as gross,
           (i.discount + i.allocated_discount)::numeric as disc,
           coalesce(ret.rev, 0)::numeric as ret_rev,
           (i.line_total - i.allocated_discount)::numeric as net_pre
    from sales_invoice_items i
    join sales_invoices inv on inv.id = i.sales_invoice_id
    join customers c on c.id = inv.customer_id
    join products p on p.id = i.product_id
    left join sales_representatives sr on sr.id = inv.sales_rep_id
    left join sales_invoice_channel_snapshot snap on snap.sales_invoice_id = inv.id
    left join ret on ret.item_id = i.id
    where i.organization_id = org_id and inv.organization_id = org_id
      and (p_from is null or inv.invoice_date >= p_from)
      and (p_to is null or inv.invoice_date <= p_to)
      and (p_warehouse is null or inv.warehouse_id = p_warehouse)
      and (p_rep is null or inv.sales_rep_id = p_rep)
  ),
  filtered as (select * from ln where v_chan is null or ln.chan = v_chan),
  agg as (
    select (case p_group when 'rep' then coalesce(f.rep_id::text, 'none') when 'channel' then f.chan
                         when 'product' then f.prod_id::text else f.cust_id::text end) as k,
           max(case p_group when 'rep' then coalesce(f.rep_name, 'بدون مندوب')
                            when 'channel' then (case f.chan when 'wholesale' then 'جملة' when 'retail' then 'تجزئة' else 'سوشيال ميديا' end)
                            when 'product' then f.prod_name else f.cust_name end) as lbl,
           count(distinct f.inv_id) as invs, count(distinct f.cust_id) as custs, count(distinct f.prod_id) as prods,
           sum(f.billed) as billed, sum(f.bonus) as bonus, sum(f.returned) as returned,
           sum(f.billed + f.bonus - f.returned) as net_units,
           (case when p_group = 'product' then max(f.per) end) as per_out,
           coalesce(sum((f.billed + f.bonus - f.returned) / f.per) filter (where f.per is not null), 0) as ctn,
           coalesce(sum(f.billed + f.bonus - f.returned) filter (where f.per is null), 0) as loose,
           sum(f.gross) as gross, sum(f.disc) as disc, sum(f.ret_rev) as retv, sum(f.net_pre - f.ret_rev) as net
    from filtered f
    group by 1
  ),
  allrows as (
    select a.* from agg a
    union all   -- the channel report always lists all three channels, even with no sales
    select v.k, v.l, 0, 0, 0, 0::numeric, 0::numeric, 0::numeric, 0::numeric, null::numeric, 0::numeric, 0::numeric, 0::numeric, 0::numeric, 0::numeric, 0::numeric
    from (values ('wholesale', 'جملة'), ('retail', 'تجزئة'), ('social', 'سوشيال ميديا')) v(k, l)
    where p_group = 'channel' and (v_chan is null or v_chan = v.k) and not exists (select 1 from agg a where a.k = v.k)
  )
  select r.k, r.lbl, r.invs, r.custs, r.prods, r.billed, r.bonus, r.returned, r.net_units,
         r.per_out,
         (case when r.per_out is not null then floor(r.net_units / r.per_out) end),
         (case when r.per_out is not null then r.net_units - floor(r.net_units / r.per_out) * r.per_out end),
         r.ctn, r.loose, r.gross, r.disc, r.retv, r.net, count(*) over ()
  from allrows r
  order by r.net desc, r.lbl
  limit v_limit offset v_off;
end $$;

grant execute on function report_sales_by(uuid, text, date, date, uuid, uuid, text, int, int) to authenticated;


-- ============================================================
-- B. Supplier payment due dates
-- ============================================================
-- purchase_invoices.due_date  — optional; chosen on the purchase form, otherwise filled when the invoice is
--                               created from the supplier's default terms (invoice date + terms days).
--                               It is a snapshot: changing the supplier's terms later never moves old invoices.
-- suppliers.payment_terms_days — optional default (0-365).
-- Existing invoices are NOT given a due date (no backfill, no reclassification): their open balance is
-- reported as "بدون موعد سداد" and is never counted as overdue.
alter table suppliers add column if not exists payment_terms_days int;
alter table suppliers drop constraint if exists suppliers_payment_terms_chk;
alter table suppliers add constraint suppliers_payment_terms_chk check (payment_terms_days is null or payment_terms_days between 0 and 365);
grant select (payment_terms_days) on suppliers to authenticated;
grant insert (payment_terms_days) on suppliers to authenticated;
grant update (payment_terms_days) on suppliers to authenticated;

alter table purchase_invoices add column if not exists due_date date;
alter table purchase_invoices drop constraint if exists purchase_invoices_due_date_chk;
alter table purchase_invoices add constraint purchase_invoices_due_date_chk
  check (due_date is null or due_date between date '2000-01-01' and date '2100-12-31');
grant select (due_date) on purchase_invoices to authenticated;
create index if not exists purchase_invoices_due_idx on purchase_invoices (organization_id, due_date) where due_date is not null;

create or replace function _default_purchase_due_date() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.due_date is null then
    select new.invoice_date + s.payment_terms_days into new.due_date
    from suppliers s where s.id = new.supplier_id and s.payment_terms_days is not null;
  end if;
  return new;
end $$;
drop trigger if exists c_default_due_date on purchase_invoices;
create trigger c_default_due_date before insert on purchase_invoices
  for each row execute function _default_purchase_due_date();

-- create_purchase_invoice: optional p_due_date (last parameter, default NULL) — the previous definition
-- (0037 expiry dates included) with only the marked lines added.
drop function if exists create_purchase_invoice(uuid, uuid, uuid, text, date, jsonb, numeric, numeric, numeric, text, text, numeric, jsonb);
CREATE OR REPLACE FUNCTION public.create_purchase_invoice(org_id uuid, p_supplier_id uuid, p_warehouse_id uuid, p_invoice_number text, p_invoice_date date, items jsonb, p_discount_pct numeric, p_tax_total numeric, p_amount_paid numeric, p_payment_method text, p_notes text, p_cash_discount_pct numeric DEFAULT 0, p_bonus_items jsonb DEFAULT '[]'::jsonb, p_due_date date DEFAULT NULL::date)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  new_invoice_id uuid; account_id uuid;
  e jsonb; b record; v_pr jsonb; v_bonus jsonb;
  v_product_id uuid; v_q numeric(14,3); v_cost numeric(14,2); v_ldisc numeric(14,2); v_pct numeric;
  v_same numeric(14,3); v_done uuid[] := '{}'; v_idx int := 0; v_n int;
  v_base_line numeric(14,2); v_base_sum numeric(14,2); v_level numeric(14,2);
  v_alloc numeric(14,2); v_alloc_used numeric(14,2) := 0; v_units numeric(14,3); v_net_line numeric(14,2);
  v_gross numeric(14,2); v_disc_total numeric(14,2); v_total numeric(14,2);
  v_bonus_units numeric(14,3) := 0; v_paid numeric(14,2); v_status text; v_expiry date;
begin
  if auth.uid() is null then raise exception 'يجب تسجيل الدخول أولاً'; end if;
  if not is_org_member(org_id) then raise exception 'أنت لست عضوًا في هذه المؤسسة'; end if;
  if not has_permission(org_id, 'purchases.create') then raise exception 'ليس لديك صلاحية إنشاء فواتير الشراء'; end if;
  if not exists (select 1 from suppliers where id = p_supplier_id and organization_id = org_id) then
    raise exception 'هذا المورد لا ينتمي إلى هذه المؤسسة';
  end if;
  if not exists (select 1 from warehouses where id = p_warehouse_id and organization_id = org_id) then
    raise exception 'هذا المخزن لا ينتمي إلى هذه المؤسسة';
  end if;
  if items is null or jsonb_array_length(items) = 0 then
    raise exception 'يجب إضافة صنف واحد على الأقل لفاتورة الشراء';
  end if;

  v_pr := _pricing(org_id, 'purchases', items, p_discount_pct, p_cash_discount_pct, p_amount_paid, p_tax_total, p_bonus_items);
  v_bonus := v_pr->'bonus';
  v_gross := (v_pr->>'gross')::numeric; v_base_sum := (v_pr->>'base')::numeric;
  v_level := (v_pr->>'invoice_level_discount')::numeric; v_disc_total := (v_pr->>'discount_total')::numeric;
  v_total := (v_pr->>'total')::numeric; v_n := jsonb_array_length(items);

  -- [due date] optional; NULL lets the database take it from the supplier's default terms
  if p_due_date is not null then
    if p_due_date < coalesce(p_invoice_date, current_date) then raise exception 'تاريخ الاستحقاق لا يمكن أن يسبق تاريخ الفاتورة'; end if;
    if p_due_date > date '2100-12-31' then raise exception 'تاريخ الاستحقاق غير صحيح'; end if;
  end if;

  insert into purchase_invoices (organization_id, supplier_id, warehouse_id, invoice_number, invoice_date, notes, created_by, payment_method, due_date)
  values (org_id, p_supplier_id, p_warehouse_id, nullif(p_invoice_number, ''), coalesce(p_invoice_date, current_date), nullif(p_notes, ''), auth.uid(), nullif(p_payment_method, ''), p_due_date)
  returning id into new_invoice_id;

  for e in select * from jsonb_array_elements(items) loop
    v_idx := v_idx + 1;
    v_product_id := (e->>'product_id')::uuid;
    v_q := (e->>'quantity')::numeric;
    v_cost := (e->>'unit_cost')::numeric;
    v_pct := coalesce((e->>'discount_pct')::numeric, 0);
    v_ldisc := _line_discount(v_q, v_cost, v_pct);
    -- [batches] optional expiry date for this line's batch
    begin
      v_expiry := nullif(btrim(coalesce(e->>'expiry_date', '')), '')::date;
    exception when others then
      raise exception 'تاريخ الصلاحية غير صحيح';
    end;
    if v_expiry is not null and (v_expiry < date '2000-01-01' or v_expiry > date '2100-12-31') then
      raise exception 'تاريخ الصلاحية غير صحيح';
    end if;
    if not exists (select 1 from products where id = v_product_id and organization_id = org_id) then
      raise exception 'أحد المنتجات المختارة لا ينتمي إلى هذه المؤسسة';
    end if;

    v_same := 0;
    if not (v_product_id = any (v_done)) then
      select coalesce(sum((x->>'qty')::numeric), 0) into v_same
      from jsonb_array_elements(v_bonus) x
      where (x->>'trigger')::uuid = v_product_id and (x->>'product')::uuid = v_product_id;
      v_done := v_done || v_product_id;
    end if;

    v_base_line := round(v_q * v_cost, 2) - v_ldisc;
    v_alloc := case when v_idx = v_n then v_level - v_alloc_used
                    when v_base_sum > 0 then round(v_level * v_base_line / v_base_sum, 2) else 0 end;
    v_alloc_used := v_alloc_used + v_alloc;
    v_units := v_q + v_same;
    v_net_line := v_base_line - v_alloc;

    insert into purchase_invoice_items (organization_id, purchase_invoice_id, product_id, quantity, unit_cost, discount, discount_pct, line_total,
                                        bonus_quantity, allocated_discount, net_total, effective_unit_cost)
    values (org_id, new_invoice_id, v_product_id, v_q, v_cost, v_ldisc, v_pct, v_base_line, v_same, v_alloc, v_net_line, v_net_line / v_units);

    perform set_config('kayan.batch_expiry', coalesce(v_expiry::text, ''), true);   -- [batches]
    perform _receive_stock(org_id, v_product_id, p_warehouse_id, v_units, v_net_line / v_units, new_invoice_id);
    v_bonus_units := v_bonus_units + v_same;
  end loop;

  for b in
    select (x->>'product')::uuid as pid, sum((x->>'qty')::numeric) as q
    from jsonb_array_elements(v_bonus) x where (x->>'trigger') <> (x->>'product') group by 1
  loop
    if not exists (select 1 from products where id = b.pid and organization_id = org_id) then
      raise exception 'أحد المنتجات المختارة لا ينتمي إلى هذه المؤسسة';
    end if;
    insert into purchase_invoice_items (organization_id, purchase_invoice_id, product_id, quantity, unit_cost, discount, line_total, is_bonus, net_total, effective_unit_cost)
    values (org_id, new_invoice_id, b.pid, b.q, 0, 0, 0, true, 0, 0);
    perform _receive_stock(org_id, b.pid, p_warehouse_id, b.q, 0, new_invoice_id);
    v_bonus_units := v_bonus_units + b.q;
  end loop;

  if coalesce(p_amount_paid, 0) > v_total then
    raise exception 'المبلغ المدفوع أكبر من إجمالي الفاتورة';
  end if;
  v_paid := coalesce(p_amount_paid, 0);
  v_status := case when v_paid <= 0 then 'unpaid' when v_paid >= v_total then 'paid' else 'partial' end;

  perform allocate_invoice_tax('purchases', new_invoice_id, coalesce(p_tax_total, 0));

  update purchase_invoices
  set subtotal = v_gross, discount_total = v_disc_total,
      line_discount_total = (v_pr->>'line_discount')::numeric, invoice_discount = (v_pr->>'invoice_discount')::numeric,
      cash_discount = (v_pr->>'cash_discount')::numeric, tier_discount = (v_pr->>'tier_discount')::numeric,
      invoice_discount_pct = (v_pr->>'invoice_discount_pct')::numeric, cash_discount_pct = (v_pr->>'cash_discount_pct')::numeric, tier_discount_pct = (v_pr->>'tier_discount_pct')::numeric,
      bonus_units = v_bonus_units, tax_total = coalesce(p_tax_total, 0), total = v_total,
      amount_paid = v_paid, payment_status = v_status, updated_at = now()
  where id = new_invoice_id;

  if v_paid > 0 then
    account_id := ensure_default_treasury_account(org_id);
    insert into supplier_payments (organization_id, supplier_id, purchase_invoice_id, amount, payment_date, payment_method, created_by)
    values (org_id, p_supplier_id, new_invoice_id, v_paid, coalesce(p_invoice_date, current_date), nullif(p_payment_method, ''), auth.uid());
    insert into treasury_movements (organization_id, treasury_account_id, direction, amount, category, movement_date, source_type, source_id, description, created_by)
    values (org_id, account_id, 'out', v_paid, 'supplier_payment', coalesce(p_invoice_date, current_date), 'purchase_invoice', new_invoice_id, nullif(p_notes, ''), auth.uid());
  end if;

  return new_invoice_id;
end $function$;
revoke all on function create_purchase_invoice(uuid, uuid, uuid, text, date, jsonb, numeric, numeric, numeric, text, text, numeric, jsonb, date) from public, anon;
grant execute on function create_purchase_invoice(uuid, uuid, uuid, text, date, jsonb, numeric, numeric, numeric, text, text, numeric, jsonb, date) to authenticated;

-- ============================================================
-- C. Open-items engine
-- ============================================================
-- For every customer / supplier: what is still open, invoice by invoice.
--   remaining(invoice) = total − payments linked to that invoice − (returns on it − cash refunded)
--   "on account" credit = payments NOT linked to an invoice (+ any over-credit and negative opening balance)
--   The on-account credit settles the OLDEST debits first (opening balance, then invoices by date).
-- Because the credit pool is exactly "all payments − linked payments", the rows always add up to the party's
-- balance:   Σ open_amount (the 'credit' row is negative) = opening + Σ invoices − Σ payments − Σ returns + Σ refunds
-- = customer_balances.balance / supplier_balances.balance. report tests assert this for every party.
create or replace function _open_items(org_id uuid, p_type text, p_party uuid default null)
returns table (
  party_id uuid, kind text, doc_id uuid, doc_number text, doc_date date, due_date date,
  doc_total numeric, linked_paid numeric, returns_net numeric, remaining numeric,
  on_account_applied numeric, open_amount numeric
)
language plpgsql stable set search_path = public as $$
begin
  if p_type is null or p_type not in ('customer', 'supplier') then raise exception 'نوع الطرف غير صحيح'; end if;
  -- the engine is callable directly, so it carries the gate itself (a restricted rep has no balance permission)
  perform _assert_balance_access(org_id, p_type);
  return query
  with docs as (
    -- opening balance (positive = a debit to settle; negative = credit)
    select ob.customer_id as pid, 'opening'::text as k, null::uuid as did, null::text as dnum, null::date as dd, null::date as due,
           ob.amount::numeric as tot, 0::numeric as lp, 0::numeric as rn, null::timestamptz as ts
    from customer_opening_balances ob
    where p_type = 'customer' and ob.organization_id = org_id and (p_party is null or ob.customer_id = p_party)
    union all
    select i.customer_id, 'invoice', i.id, i.invoice_number, i.invoice_date, null::date,
           i.total::numeric, coalesce(lp.s, 0)::numeric, coalesce(rr.s, 0)::numeric, i.created_at
    from sales_invoices i
    left join (select c.sales_invoice_id as iid, sum(c.amount) as s from customer_collections c where c.organization_id = org_id and c.sales_invoice_id is not null group by 1) lp on lp.iid = i.id
    left join (select r.sales_invoice_id as iid, sum(r.total - r.cash_refunded) as s from sales_returns r where r.organization_id = org_id group by 1) rr on rr.iid = i.id
    where p_type = 'customer' and i.organization_id = org_id and (p_party is null or i.customer_id = p_party)
    union all
    select ob.supplier_id, 'opening', null::uuid, null::text, null::date, null::date, ob.amount::numeric, 0::numeric, 0::numeric, null::timestamptz
    from supplier_opening_balances ob
    where p_type = 'supplier' and ob.organization_id = org_id and (p_party is null or ob.supplier_id = p_party)
    union all
    select i.supplier_id, 'invoice', i.id, i.invoice_number, i.invoice_date, i.due_date,
           i.total::numeric, coalesce(lp.s, 0)::numeric, coalesce(rr.s, 0)::numeric, i.created_at
    from purchase_invoices i
    left join (select p.purchase_invoice_id as iid, sum(p.amount) as s from supplier_payments p where p.organization_id = org_id and p.purchase_invoice_id is not null group by 1) lp on lp.iid = i.id
    left join (select r.purchase_invoice_id as iid, sum(r.total - r.cash_refunded) as s from purchase_returns r where r.organization_id = org_id group by 1) rr on rr.iid = i.id
    where p_type = 'supplier' and i.organization_id = org_id and (p_party is null or i.supplier_id = p_party)
  ),
  unlinked as (   -- payments that were not tied to an invoice: "on account"
    select c.customer_id as pid, sum(c.amount) as s from customer_collections c
    where p_type = 'customer' and c.organization_id = org_id and c.sales_invoice_id is null and (p_party is null or c.customer_id = p_party) group by 1
    union all
    select p.supplier_id, sum(p.amount) from supplier_payments p
    where p_type = 'supplier' and p.organization_id = org_id and p.purchase_invoice_id is null and (p_party is null or p.supplier_id = p_party) group by 1
  ),
  d as (
    select docs.pid, docs.k, docs.did, docs.dnum, docs.dd, docs.due, docs.tot, docs.lp, docs.rn, docs.ts,
           (docs.tot - docs.lp - docs.rn) as rem,
           greatest(docs.tot - docs.lp - docs.rn, 0) as debit,
           greatest(-(docs.tot - docs.lp - docs.rn), 0) as over_credit
    from docs
  ),
  pool as (   -- total on-account credit per party
    select x.pid, sum(x.v) as credit from (
      select d.pid, d.over_credit as v from d
      union all select u.pid, u.s from unlinked u
    ) x group by x.pid
  ),
  fifo as (
    select d.*, coalesce(pool.credit, 0) as credit,
           coalesce(sum(d.debit) over (partition by d.pid order by (d.k = 'opening') desc, d.dd nulls first, d.ts nulls first, d.did
                                       rows between unbounded preceding and 1 preceding), 0) as before_debit
    from d left join pool on pool.pid = d.pid
  ),
  applied as (
    select f.pid, f.k, f.did, f.dnum, f.dd, f.due, f.tot, f.lp, f.rn, f.rem, f.credit,
           least(f.debit, greatest(f.credit - f.before_debit, 0)) as app, f.debit
    from fifo f
  ),
  totals as (   -- per party: all debits, credit pool
    select pid, sum(debit) as debit_total from d group by pid
  ),
  advance as (  -- credit left over after every debit is settled
    select pool.pid, greatest(pool.credit - coalesce(t.debit_total, 0), 0) as adv
    from pool left join totals t on t.pid = pool.pid
  )
  select a.pid, a.k, a.did, a.dnum, a.dd, a.due, a.tot::numeric, a.lp::numeric, a.rn::numeric, a.rem::numeric,
         a.app::numeric, (a.debit - a.app)::numeric
  from applied a
  union all
  select adv.pid, 'credit'::text, null::uuid, null::text, null::date, null::date, 0::numeric, 0::numeric, 0::numeric, 0::numeric, 0::numeric, (-adv.adv)::numeric
  from advance adv where adv.adv > 0;
end $$;
revoke all on function _open_items(uuid, text, uuid) from public, anon;
grant execute on function _open_items(uuid, text, uuid) to authenticated;

-- shared gate: the same checks the existing party reports use, plus the balance permission the
-- customer_balances / supplier_balances views already enforce (restricted reps do not have it)
create or replace function _assert_balance_access(org_id uuid, p_type text)
returns void language plpgsql stable set search_path = public as $$
begin
  perform assert_party_report_access(org_id);
  if p_type = 'customer' and org_id not in (select balance_org_ids('customer')) then raise exception 'ليس لديك صلاحية عرض أرصدة العملاء'; end if;
  if p_type = 'supplier' and org_id not in (select balance_org_ids('supplier')) then raise exception 'ليس لديك صلاحية عرض أرصدة الموردين'; end if;
end $$;
grant execute on function _assert_balance_access(uuid, text) to authenticated;

-- ============================================================
-- Invoice-level statement of ONE customer / supplier
-- ============================================================
create or replace function report_party_open_items(org_id uuid, p_type text, p_party uuid, p_as_of date default null)
returns table (
  kind text, doc_id uuid, doc_number text, doc_date date, due_date date,
  doc_total numeric, linked_paid numeric, returns_net numeric, on_account_applied numeric, remaining numeric,
  days_overdue integer, status text
)
language plpgsql stable set search_path = public as $$
declare v_as_of date := coalesce(p_as_of, cairo_today());
begin
  perform _assert_balance_access(org_id, p_type);
  if p_type = 'customer' and not exists (select 1 from customers where id = p_party and organization_id = org_id) then raise exception 'العميل غير موجود'; end if;
  if p_type = 'supplier' and not exists (select 1 from suppliers where id = p_party and organization_id = org_id) then raise exception 'المورد غير موجود'; end if;
  return query
  select o.kind, o.doc_id, o.doc_number, o.doc_date, o.due_date, o.doc_total, o.linked_paid, o.returns_net, o.on_account_applied, o.open_amount,
         (case when o.kind = 'invoice' and o.open_amount > 0 and o.due_date is not null and o.due_date < v_as_of then v_as_of - o.due_date end)::integer,
         (case when o.kind = 'opening' then 'opening'
               when o.kind = 'credit' then 'credit'
               when o.open_amount <= 0 then 'settled'
               when o.due_date is not null and o.due_date < v_as_of then 'overdue'
               else 'open' end)::text
  from _open_items(org_id, p_type, p_party) o
  order by (o.kind = 'opening') desc, o.doc_date nulls first, o.doc_number, o.doc_id;
end $$;
grant execute on function report_party_open_items(uuid, text, uuid, date) to authenticated;

-- ============================================================
-- Supplier dues: overdue / not yet due / undated, per supplier
-- ============================================================
-- balance = overdue + not_due + undated − advance, and balance = supplier_balances.balance.
-- "Overdue" = open amount of an invoice whose due_date is before p_as_of (default: today, Cairo).
-- Opening balances and invoices without a due date are "undated" and are never counted as overdue.
create or replace function report_supplier_dues(org_id uuid, p_as_of date default null, p_supplier uuid default null, p_all boolean default false)
returns table (
  supplier_id uuid, supplier_name text, phone text, payment_terms_days integer,
  balance numeric, overdue numeric, not_due numeric, undated numeric, advance numeric,
  overdue_invoices bigint, oldest_overdue_date date, max_days_overdue integer, next_due_date date,
  last_payment_date date, last_payment_amount numeric
)
language plpgsql stable set search_path = public as $$
declare v_as_of date := coalesce(p_as_of, cairo_today());
begin
  perform _assert_balance_access(org_id, 'supplier');
  return query
  with o as (select * from _open_items(org_id, 'supplier', p_supplier)),
  agg as (
    select x.party_id as sid,
           sum(x.open_amount) as bal,
           coalesce(sum(x.open_amount) filter (where x.kind = 'invoice' and x.open_amount > 0 and x.due_date < v_as_of), 0) as ov,
           coalesce(sum(x.open_amount) filter (where x.kind = 'invoice' and x.open_amount > 0 and x.due_date >= v_as_of), 0) as nd,
           coalesce(sum(x.open_amount) filter (where x.kind in ('invoice', 'opening') and x.open_amount > 0 and x.due_date is null), 0) as und,
           coalesce(-sum(x.open_amount) filter (where x.kind = 'credit'), 0) as adv,
           count(*) filter (where x.kind = 'invoice' and x.open_amount > 0 and x.due_date < v_as_of) as ov_n,
           min(x.due_date) filter (where x.kind = 'invoice' and x.open_amount > 0 and x.due_date < v_as_of) as ov_oldest,
           max(v_as_of - x.due_date) filter (where x.kind = 'invoice' and x.open_amount > 0 and x.due_date < v_as_of) as ov_days,
           min(x.due_date) filter (where x.kind = 'invoice' and x.open_amount > 0 and x.due_date >= v_as_of) as nxt
    from o x group by x.party_id
  )
  select s.id, s.name, s.phone, s.payment_terms_days,
         a.bal::numeric, a.ov::numeric, a.nd::numeric, a.und::numeric, a.adv::numeric,
         a.ov_n, a.ov_oldest, a.ov_days::integer, a.nxt,
         lp.payment_date, lp.amount::numeric
  from suppliers s
  join agg a on a.sid = s.id
  left join lateral (
    select sp.payment_date, sp.amount from supplier_payments sp
    where sp.supplier_id = s.id order by sp.payment_date desc, sp.created_at desc limit 1
  ) lp on true
  where s.organization_id = org_id and (p_all or a.bal <> 0 or a.ov <> 0)
  order by a.ov desc, a.bal desc, s.name;
end $$;
grant execute on function report_supplier_dues(uuid, date, uuid, boolean) to authenticated;

-- ============================================================
-- Customer outstanding per sales rep and for the whole company
-- ============================================================
-- Built on customer_balances (the same figure the debts page shows). net_balance = opening + sales − collected − returns,
-- receivable = Σ positive balances (what customers owe), advances = Σ negative balances (customers in credit).
-- Customers are attributed to the rep assigned on the customer record — the same attribution the debts page uses.
create or replace function report_receivables_summary(org_id uuid, p_rep uuid default null)
returns table (
  group_id text, group_label text, is_total boolean,
  customers bigint, customers_with_debt bigint,
  opening numeric, sales numeric, collected numeric, returns_net numeric,
  receivable numeric, advances numeric, net_balance numeric
)
language plpgsql stable set search_path = public as $$
begin
  perform _assert_balance_access(org_id, 'customer');
  return query
  with base as (
    select coalesce(c.sales_rep_id::text, 'none') as gid, coalesce(r.name, 'بدون مندوب') as glabel,
           coalesce(ob.amount, 0)::numeric as opening, b.total_sales::numeric as sales, b.total_collected::numeric as collected,
           (b.total_returned - b.total_refunded)::numeric as ret, b.balance::numeric as bal
    from customers c
    join customer_balances b on b.customer_id = c.id
    left join customer_opening_balances ob on ob.customer_id = c.id
    left join sales_representatives r on r.id = c.sales_rep_id
    where c.organization_id = org_id and b.organization_id = org_id and (p_rep is null or c.sales_rep_id = p_rep)
  ),
  per as (
    select b.gid, max(b.glabel) as glabel, count(*) as n, count(*) filter (where b.bal > 0) as n_debt,
           sum(b.opening) as op, sum(b.sales) as sl, sum(b.collected) as col, sum(b.ret) as rt,
           coalesce(sum(b.bal) filter (where b.bal > 0), 0) as recv, coalesce(-sum(b.bal) filter (where b.bal < 0), 0) as adv, sum(b.bal) as net
    from base b group by b.gid
  )
  select p.gid, p.glabel, false, p.n, p.n_debt, p.op, p.sl, p.col, p.rt, p.recv, p.adv, p.net from per p
  union all
  select 'total', 'إجمالي الشركة', true, coalesce(sum(p.n), 0)::bigint, coalesce(sum(p.n_debt), 0)::bigint,
         coalesce(sum(p.op), 0), coalesce(sum(p.sl), 0), coalesce(sum(p.col), 0), coalesce(sum(p.rt), 0),
         coalesce(sum(p.recv), 0), coalesce(sum(p.adv), 0), coalesce(sum(p.net), 0)
  from per p
  order by 3, 10 desc, 2;   -- reps by receivable (largest first), the company total last
end $$;
grant execute on function report_receivables_summary(uuid, uuid) to authenticated;

-- ============================================================
-- Payment register: supplier payments / customer collections, with dates
-- ============================================================
create or replace function report_party_payments(
  org_id uuid, p_type text, p_from date default null, p_to date default null, p_party uuid default null, p_rep uuid default null,
  p_limit int default 200, p_offset int default 0
)
returns table (
  payment_id uuid, payment_date date, party_id uuid, party_name text, rep_name text,
  amount numeric, payment_method text, reference text, doc_number text, notes text,
  total_count bigint, total_amount numeric
)
language plpgsql stable set search_path = public as $$
declare
  v_limit int := least(greatest(coalesce(p_limit, 200), 1), 1000);
  v_off   int := greatest(coalesce(p_offset, 0), 0);
begin
  perform _assert_balance_access(org_id, p_type);
  if p_type = 'customer' then
    return query
    select c.id, c.collection_date, c.customer_id, cu.name, r.name,
           c.amount::numeric, c.payment_method, c.reference, i.invoice_number, c.notes,
           count(*) over (), (sum(c.amount) over ())::numeric
    from customer_collections c
    join customers cu on cu.id = c.customer_id
    left join sales_representatives r on r.id = cu.sales_rep_id
    left join sales_invoices i on i.id = c.sales_invoice_id
    where c.organization_id = org_id
      and (p_from is null or c.collection_date >= p_from) and (p_to is null or c.collection_date <= p_to)
      and (p_party is null or c.customer_id = p_party) and (p_rep is null or cu.sales_rep_id = p_rep)
    order by c.collection_date desc, c.created_at desc, c.id
    limit v_limit offset v_off;
  elsif p_type = 'supplier' then
    return query
    select sp.id, sp.payment_date, sp.supplier_id, s.name, null::text,
           sp.amount::numeric, sp.payment_method, sp.reference, i.invoice_number, sp.notes,
           count(*) over (), (sum(sp.amount) over ())::numeric
    from supplier_payments sp
    join suppliers s on s.id = sp.supplier_id
    left join purchase_invoices i on i.id = sp.purchase_invoice_id
    where sp.organization_id = org_id
      and (p_from is null or sp.payment_date >= p_from) and (p_to is null or sp.payment_date <= p_to)
      and (p_party is null or sp.supplier_id = p_party)
    order by sp.payment_date desc, sp.created_at desc, sp.id
    limit v_limit offset v_off;
  else
    raise exception 'نوع الطرف غير صحيح';
  end if;
end $$;
grant execute on function report_party_payments(uuid, text, date, date, uuid, uuid, int, int) to authenticated;

-- ============================================================
-- Items bought from suppliers (purchased / free / returned / net received)
-- ============================================================
-- Purchases receive stock when the invoice is saved (there is no separate goods-receipt step), so
-- net received = purchased + free − returned. Period = invoice date; returns follow their original invoice.
create or replace function report_supplier_items(org_id uuid, p_from date default null, p_to date default null, p_supplier uuid default null,
                                                 p_limit int default 500, p_offset int default 0)
returns table (
  supplier_id uuid, supplier_name text, product_id uuid, product_name text, unit text,
  invoices bigint, purchased_qty numeric, free_qty numeric, returned_qty numeric, received_qty numeric,
  purchased_value numeric, returned_value numeric, net_value numeric, last_purchase_date date,
  total_count bigint
)
language plpgsql stable set search_path = public as $$
declare
  v_limit int := least(greatest(coalesce(p_limit, 500), 1), 2000);
  v_off   int := greatest(coalesce(p_offset, 0), 0);
begin
  perform assert_report_access(org_id, true);
  return query
  with ret as (
    select r.purchase_invoice_item_id as iid, sum(r.quantity) as q, sum(r.line_total) as v
    from purchase_return_items r where r.organization_id = org_id group by r.purchase_invoice_item_id
  ),
  ln as (
    select inv.supplier_id as sid, i.product_id as pid, inv.id as inv_id, inv.invoice_date as d,
           (case when i.is_bonus then 0 else i.quantity end)::numeric as bought,
           (i.bonus_quantity + case when i.is_bonus then i.quantity else 0 end)::numeric as free,
           coalesce(ret.q, 0)::numeric as rq, coalesce(ret.v, 0)::numeric as rv, i.net_total::numeric as nv
    from purchase_invoice_items i
    join purchase_invoices inv on inv.id = i.purchase_invoice_id
    left join ret on ret.iid = i.id
    where i.organization_id = org_id and inv.organization_id = org_id
      and (p_from is null or inv.invoice_date >= p_from) and (p_to is null or inv.invoice_date <= p_to)
      and (p_supplier is null or inv.supplier_id = p_supplier)
  )
  select s.id, s.name, p.id, p.name, p.unit,
         count(distinct l.inv_id), sum(l.bought), sum(l.free), sum(l.rq), sum(l.bought + l.free - l.rq),
         sum(l.nv), sum(l.rv), sum(l.nv - l.rv), max(l.d), count(*) over ()
  from ln l
  join suppliers s on s.id = l.sid
  join products p on p.id = l.pid
  group by s.id, s.name, p.id, p.name, p.unit
  order by s.name, sum(l.nv - l.rv) desc, p.name
  limit v_limit offset v_off;
end $$;
grant execute on function report_supplier_items(uuid, date, date, uuid, int, int) to authenticated;

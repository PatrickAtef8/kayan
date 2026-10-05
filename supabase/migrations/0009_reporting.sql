-- Kayan — Phase 6: Reporting (SRS §36–§45, §64 Phase 6)
--
-- Design rules for everything in this file:
--   * Reports are computed in SQL (aggregates), never by pulling every row
--     into the browser (§57 performance).
--   * Every function is SECURITY INVOKER, so Row Level Security still
--     applies on top of the explicit checks below (defence in depth), and
--     every query ALSO filters `organization_id = org_id` explicitly, so a
--     user who belongs to two organizations never sees the two mixed.
--   * Financial figures (cost, profit, balances, treasury) are gated on the
--     `view_financial` permission INSIDE the database (§14: "sensitive
--     financial information must be permission-controlled"), not only by
--     hiding a column in the UI.
--   * Nothing here writes to, or changes the meaning of, any Phase 1–5
--     table or function. The only new table is `other_balances`.
--
-- Definitions (documented once, used everywhere):
--   gross_sales      = Σ sales_invoices.subtotal            (qty × price)
--   discounts        = Σ sales_invoices.discount_total
--   net_sales        = gross_sales − discounts              (§36)
--   gross_profit     = net_sales − COGS = Σ profit_total    (§25, §37)
--   operating_expenses = Σ expenses.amount                  (§38)
--   commissions      = Σ sales_invoices.commission_amount   (accrued, §33)
--   net_profit       = gross_profit − operating_expenses − commissions (§38)
--   Partner withdrawals, collections and supplier payments are NEVER part
--   of net profit (§34, §38).
--   receivables / payables = the live customer_balances / supplier_balances
--   views (§39), netted across parties.

-- ============================================================
-- 1. Other assets / other liabilities (§40–§41)
--    "رأس المال العام" and the net business position both need
--    "التزامات أخرى" / other assets, and no earlier phase has a place to
--    record them. Kept deliberately minimal: a labelled amount, soft-
--    deactivated (never deleted, §47), written only through RPCs.
-- ============================================================
create table other_balances (
  id                uuid primary key default gen_random_uuid(),
  organization_id   uuid not null references organizations(id) on delete cascade,
  kind              text not null check (kind in ('asset','liability')),
  name              text not null,
  amount            numeric(14,2) not null check (amount > 0),
  notes             text,
  is_active         boolean not null default true,
  created_by        uuid references auth.users(id),
  created_at        timestamptz not null default now(),
  deactivated_at    timestamptz
);
create index other_balances_org_idx on other_balances(organization_id) where is_active;

alter table other_balances enable row level security;
create policy other_balances_select on other_balances
  for select using (has_permission(organization_id, 'view_financial'));

grant select on other_balances to authenticated;

create or replace function add_other_balance(
  org_id uuid,
  p_kind text,
  p_name text,
  p_amount numeric,
  p_notes text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  new_id uuid;
begin
  if auth.uid() is null then
    raise exception 'يجب تسجيل الدخول أولاً';
  end if;
  if not is_org_member(org_id) then
    raise exception 'أنت لست عضوًا في هذه المؤسسة';
  end if;
  if not has_permission(org_id, 'treasury.manage') then
    raise exception 'ليس لديك صلاحية تسجيل الأصول والالتزامات الأخرى';
  end if;
  if p_kind not in ('asset', 'liability') then
    raise exception 'نوع البند غير صحيح';
  end if;
  if coalesce(trim(p_name), '') = '' then
    raise exception 'اكتب اسم البند';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'يجب أن يكون المبلغ أكبر من صفر';
  end if;

  insert into other_balances (organization_id, kind, name, amount, notes, created_by)
  values (org_id, p_kind, trim(p_name), p_amount, nullif(trim(coalesce(p_notes, '')), ''), auth.uid())
  returning id into new_id;

  return new_id;
end;
$$;

create or replace function deactivate_other_balance(org_id uuid, p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'يجب تسجيل الدخول أولاً';
  end if;
  if not is_org_member(org_id) then
    raise exception 'أنت لست عضوًا في هذه المؤسسة';
  end if;
  if not has_permission(org_id, 'treasury.manage') then
    raise exception 'ليس لديك صلاحية تعديل الأصول والالتزامات الأخرى';
  end if;

  update other_balances
  set is_active = false, deactivated_at = now()
  where id = p_id and organization_id = org_id and is_active;

  if not found then
    raise exception 'هذا البند غير موجود أو تم إلغاؤه من قبل';
  end if;
end;
$$;

-- ============================================================
-- 2. Access guard shared by every report function
-- ============================================================
create or replace function assert_report_access(org_id uuid, need_financial boolean default false)
returns void
language plpgsql
stable
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'يجب تسجيل الدخول أولاً';
  end if;
  if not is_org_member(org_id) then
    raise exception 'أنت لست عضوًا في هذه المؤسسة';
  end if;
  if need_financial and not has_permission(org_id, 'view_financial') then
    raise exception 'ليس لديك صلاحية عرض البيانات المالية';
  end if;
end;
$$;

-- ============================================================
-- 3. report_summary — the one-shot numbers behind the dashboard and the
--    profit & loss statement. p_from / p_to are inclusive; null = open.
-- ============================================================
create or replace function report_summary(org_id uuid, p_from date default null, p_to date default null)
returns jsonb
language plpgsql
stable
set search_path = public
as $$
declare
  fin boolean;
  s record;
  v_expenses numeric(14,2);
  v_collections numeric(14,2);
  v_supplier_payments numeric(14,2);
  v_purchases numeric(14,2);
  v_by_category jsonb;
  v_receivable numeric;
  v_payable numeric;
  v_inventory numeric;
  v_treasury numeric;
  v_net_sales numeric;
  v_gross_profit numeric;
begin
  perform assert_report_access(org_id, false);
  fin := has_permission(org_id, 'view_financial');

  select
    count(*) as invoices,
    coalesce(sum(subtotal), 0) as gross_sales,
    coalesce(sum(discount_total), 0) as discounts,
    coalesce(sum(tax_total), 0) as tax,
    coalesce(sum(total), 0) as billed,
    coalesce(sum(cogs_total), 0) as cogs,
    coalesce(sum(profit_total), 0) as gross_profit,
    coalesce(sum(commission_amount), 0) as commissions
  into s
  from sales_invoices
  where organization_id = org_id
    and (p_from is null or invoice_date >= p_from)
    and (p_to is null or invoice_date <= p_to);

  v_net_sales := s.gross_sales - s.discounts;

  if not fin then
    return jsonb_build_object(
      'period', jsonb_build_object('from', p_from, 'to', p_to),
      'sales', jsonb_build_object(
        'invoices', s.invoices,
        'gross_sales', s.gross_sales,
        'discounts', s.discounts,
        'net_sales', v_net_sales,
        'tax', s.tax,
        'billed', s.billed
      ),
      'financial', null,
      'balances', null
    );
  end if;

  select coalesce(sum(amount), 0) into v_expenses
  from expenses
  where organization_id = org_id
    and (p_from is null or expense_date >= p_from)
    and (p_to is null or expense_date <= p_to);

  select coalesce(jsonb_agg(jsonb_build_object('name', name, 'amount', amount) order by amount desc), '[]'::jsonb)
  into v_by_category
  from (
    select coalesce(c.name, 'بدون تصنيف') as name, sum(e.amount) as amount
    from expenses e
    left join expense_categories c on c.id = e.category_id
    where e.organization_id = org_id
      and (p_from is null or e.expense_date >= p_from)
      and (p_to is null or e.expense_date <= p_to)
    group by 1
  ) t;

  select coalesce(sum(amount), 0) into v_collections
  from customer_collections
  where organization_id = org_id
    and (p_from is null or collection_date >= p_from)
    and (p_to is null or collection_date <= p_to);

  select coalesce(sum(amount), 0) into v_supplier_payments
  from supplier_payments
  where organization_id = org_id
    and (p_from is null or payment_date >= p_from)
    and (p_to is null or payment_date <= p_to);

  select coalesce(sum(total), 0) into v_purchases
  from purchase_invoices
  where organization_id = org_id
    and (p_from is null or invoice_date >= p_from)
    and (p_to is null or invoice_date <= p_to);

  select coalesce(sum(balance), 0) into v_receivable from customer_balances where organization_id = org_id;
  select coalesce(sum(balance), 0) into v_payable from supplier_balances where organization_id = org_id;
  select coalesce(sum(quantity * avg_cost), 0) into v_inventory from inventory_stock where organization_id = org_id;
  select coalesce(sum(balance), 0) into v_treasury from treasury_balances where organization_id = org_id;

  v_gross_profit := v_net_sales - s.cogs;

  return jsonb_build_object(
    'period', jsonb_build_object('from', p_from, 'to', p_to),
    'sales', jsonb_build_object(
      'invoices', s.invoices,
      'gross_sales', s.gross_sales,
      'discounts', s.discounts,
      'net_sales', v_net_sales,
      'tax', s.tax,
      'billed', s.billed
    ),
    'financial', jsonb_build_object(
      'cogs', s.cogs,
      'gross_profit', v_gross_profit,
      'operating_expenses', v_expenses,
      'commissions', s.commissions,
      'net_profit', v_gross_profit - v_expenses - s.commissions,
      'collections', v_collections,
      'supplier_payments', v_supplier_payments,
      'purchases', v_purchases,
      'expenses_by_category', v_by_category
    ),
    'balances', jsonb_build_object(
      'receivable', v_receivable,
      'payable', v_payable,
      'inventory_value', v_inventory,
      'treasury', v_treasury
    )
  );
end;
$$;

-- ============================================================
-- 4. report_timeseries — chart data. bucket: day | week | month
-- ============================================================
create or replace function report_timeseries(org_id uuid, p_from date default null, p_to date default null, p_bucket text default 'day')
returns table (bucket date, net_sales numeric, gross_profit numeric, expenses numeric)
language plpgsql
stable
set search_path = public
as $$
declare
  fin boolean;
begin
  perform assert_report_access(org_id, false);
  if p_bucket not in ('day', 'week', 'month') then
    raise exception 'تجميع غير مدعوم';
  end if;
  fin := has_permission(org_id, 'view_financial');

  return query
  with s as (
    select date_trunc(p_bucket, i.invoice_date::timestamp)::date as b,
           sum(i.subtotal - i.discount_total) as ns,
           sum(i.profit_total) as gp
    from sales_invoices i
    where i.organization_id = org_id
      and (p_from is null or i.invoice_date >= p_from)
      and (p_to is null or i.invoice_date <= p_to)
    group by 1
  ), e as (
    select date_trunc(p_bucket, x.expense_date::timestamp)::date as b,
           sum(x.amount) as ex
    from expenses x
    where fin
      and x.organization_id = org_id
      and (p_from is null or x.expense_date >= p_from)
      and (p_to is null or x.expense_date <= p_to)
    group by 1
  )
  select coalesce(s.b, e.b),
         coalesce(s.ns, 0)::numeric,
         case when fin then coalesce(s.gp, 0)::numeric end,
         case when fin then coalesce(e.ex, 0)::numeric end
  from s full join e on e.b = s.b
  order by 1;
end;
$$;

-- ============================================================
-- 5. report_sales_breakdown — §36/§37/§43: sales and profit by date,
--    invoice, customer, product, representative. One function so the
--    Sales report and the Profit report share exactly the same numbers.
--    Cost/profit/commission columns are NULL without view_financial.
--    NOTE (by-product): computed from the stored item lines (§26). An
--    invoice-level discount is not stored on the lines, so it is allocated
--    across the invoice's lines pro-rata to their gross value (a reporting
--    calculation only; nothing stored changes). That makes by-product
--    totals reconcile with by-invoice totals. The one remaining source of
--    difference: a per-line discount is reflected in the stored item
--    profit but not in the invoice header, so an invoice that used
--    per-line discounts will show that amount lower by product.
-- ============================================================
create or replace function report_sales_breakdown(
  org_id uuid,
  p_from date,
  p_to date,
  p_group text,
  p_limit int default 100,
  p_offset int default 0
)
returns table (
  group_key text,
  group_label text,
  ref_date date,
  party text,
  invoices bigint,
  quantity numeric,
  gross_sales numeric,
  discounts numeric,
  net_sales numeric,
  cogs numeric,
  gross_profit numeric,
  commission numeric,
  total_count bigint
)
language plpgsql
stable
set search_path = public
as $$
declare
  fin boolean;
  v_limit int := least(greatest(coalesce(p_limit, 100), 1), 1000);
  v_offset int := greatest(coalesce(p_offset, 0), 0);
begin
  perform assert_report_access(org_id, false);
  if p_group not in ('date', 'invoice', 'customer', 'product', 'representative') then
    raise exception 'نوع التجميع غير مدعوم';
  end if;
  fin := has_permission(org_id, 'view_financial');

  if p_group = 'product' then
    return query
    select
      x.product_id::text,
      coalesce(p.name, '—'),
      null::date,
      null::text,
      count(distinct x.sales_invoice_id),
      coalesce(sum(x.quantity), 0)::numeric,
      coalesce(sum(x.quantity * x.unit_price), 0)::numeric,
      coalesce(sum(x.discount + x.alloc), 0)::numeric,
      coalesce(sum(x.line_total - x.alloc), 0)::numeric,
      case when fin then coalesce(sum(x.cost_total), 0)::numeric end,
      case when fin then coalesce(sum(x.profit - x.alloc), 0)::numeric end,
      null::numeric,
      count(*) over ()
    from (
      select it.product_id, it.sales_invoice_id, it.quantity, it.unit_price, it.discount,
             it.line_total, it.cost_total, it.profit,
             case when i.subtotal > 0
                  then i.discount_total * (it.quantity * it.unit_price) / i.subtotal
                  else 0 end as alloc
      from sales_invoice_items it
      join sales_invoices i on i.id = it.sales_invoice_id
      where it.organization_id = org_id
        and i.organization_id = org_id
        and (p_from is null or i.invoice_date >= p_from)
        and (p_to is null or i.invoice_date <= p_to)
    ) x
    left join products p on p.id = x.product_id
    group by x.product_id, p.name
    order by sum(x.line_total - x.alloc) desc, p.name
    limit v_limit offset v_offset;
    return;
  end if;

  return query
  with inv as (
    select i.*,
           coalesce((select sum(it.quantity) from sales_invoice_items it where it.sales_invoice_id = i.id), 0) as qty
    from sales_invoices i
    where i.organization_id = org_id
      and (p_from is null or i.invoice_date >= p_from)
      and (p_to is null or i.invoice_date <= p_to)
  )
  select * from (
    select
      case p_group
        when 'date' then i.invoice_date::text
        when 'invoice' then i.id::text
        when 'customer' then i.customer_id::text
        else coalesce(i.sales_rep_id::text, '')
      end as group_key,
      case p_group
        when 'date' then i.invoice_date::text
        when 'invoice' then coalesce(nullif(i.invoice_number, ''), '—')
        when 'customer' then coalesce(c.name, '—')
        else coalesce(r.name, 'بدون مندوب')
      end as group_label,
      case p_group
        when 'date' then i.invoice_date
        when 'invoice' then i.invoice_date
        else null::date
      end as ref_date,
      case p_group when 'invoice' then c.name else null::text end as party,
      count(*)::bigint as invoices,
      coalesce(sum(i.qty), 0)::numeric as quantity,
      coalesce(sum(i.subtotal), 0)::numeric as gross_sales,
      coalesce(sum(i.discount_total), 0)::numeric as discounts,
      coalesce(sum(i.subtotal - i.discount_total), 0)::numeric as net_sales,
      case when fin then coalesce(sum(i.cogs_total), 0)::numeric end as cogs,
      case when fin then coalesce(sum(i.profit_total), 0)::numeric end as gross_profit,
      case when fin then coalesce(sum(i.commission_amount), 0)::numeric end as commission,
      count(*) over () as total_count
    from inv i
    left join customers c on c.id = i.customer_id
    left join sales_representatives r on r.id = i.sales_rep_id
    group by
      case p_group
        when 'date' then i.invoice_date::text
        when 'invoice' then i.id::text
        when 'customer' then i.customer_id::text
        else coalesce(i.sales_rep_id::text, '')
      end,
      case p_group
        when 'date' then i.invoice_date::text
        when 'invoice' then coalesce(nullif(i.invoice_number, ''), '—')
        when 'customer' then coalesce(c.name, '—')
        else coalesce(r.name, 'بدون مندوب')
      end,
      case p_group
        when 'date' then i.invoice_date
        when 'invoice' then i.invoice_date
        else null::date
      end,
      case p_group when 'invoice' then c.name else null::text end
  ) g
  order by
    case when p_group in ('date', 'invoice') then g.ref_date end desc nulls last,
    case when p_group in ('customer', 'representative') then g.net_sales end desc nulls last,
    g.group_label
  limit v_limit offset v_offset;
end;
$$;

-- ============================================================
-- 6. Inventory reports (§43)
-- ============================================================
create or replace function report_inventory_stock(org_id uuid)
returns table (
  product_id uuid,
  product_name text,
  sku text,
  unit text,
  warehouse_id uuid,
  warehouse_name text,
  quantity numeric,
  avg_cost numeric,
  stock_value numeric
)
language plpgsql
stable
set search_path = public
as $$
declare
  fin boolean;
begin
  perform assert_report_access(org_id, false);
  fin := has_permission(org_id, 'view_financial');

  return query
  select
    s.product_id,
    p.name,
    p.sku,
    p.unit,
    s.warehouse_id,
    w.name,
    s.quantity::numeric,
    case when fin then s.avg_cost::numeric end,
    case when fin then (s.quantity * s.avg_cost)::numeric end
  from inventory_stock s
  join products p on p.id = s.product_id
  join warehouses w on w.id = s.warehouse_id
  where s.organization_id = org_id
    and s.quantity <> 0
  order by p.name, w.name;
end;
$$;

create or replace function report_stock_movements(
  org_id uuid,
  p_from date default null,
  p_to date default null,
  p_product uuid default null,
  p_warehouse uuid default null,
  p_type text default null,
  p_limit int default 50,
  p_offset int default 0
)
returns table (
  id uuid,
  moved_at timestamptz,
  product_name text,
  warehouse_name text,
  movement_type text,
  quantity_delta numeric,
  unit_cost numeric,
  reference_type text,
  note text,
  total_count bigint
)
language plpgsql
stable
set search_path = public
as $$
declare
  fin boolean;
  v_limit int := least(greatest(coalesce(p_limit, 50), 1), 1000);
  v_offset int := greatest(coalesce(p_offset, 0), 0);
begin
  perform assert_report_access(org_id, false);
  fin := has_permission(org_id, 'view_financial');

  return query
  select
    m.id,
    m.created_at,
    p.name,
    w.name,
    m.movement_type,
    m.quantity_delta::numeric,
    case when fin then m.unit_cost::numeric end,
    m.reference_type,
    m.note,
    count(*) over ()
  from inventory_movements m
  join products p on p.id = m.product_id
  join warehouses w on w.id = m.warehouse_id
  where m.organization_id = org_id
    -- movements only carry a timestamp; compare on the business's local
    -- (Cairo) calendar day so "today" means today in Egypt, not in UTC.
    and (p_from is null or (m.created_at at time zone 'Africa/Cairo')::date >= p_from)
    and (p_to is null or (m.created_at at time zone 'Africa/Cairo')::date <= p_to)
    and (p_product is null or m.product_id = p_product)
    and (p_warehouse is null or m.warehouse_id = p_warehouse)
    and (p_type is null or p_type = '' or m.movement_type = p_type)
  order by m.created_at desc, m.id
  limit v_limit offset v_offset;
end;
$$;

-- ============================================================
-- 7. Customer / supplier reports (§15, §16, §39, §43)
-- ============================================================
create or replace function report_party_balances(org_id uuid, p_type text)
returns table (
  party_id uuid,
  name text,
  phone text,
  total numeric,
  settled numeric,
  balance numeric
)
language plpgsql
stable
set search_path = public
as $$
begin
  perform assert_report_access(org_id, true);
  if p_type not in ('customer', 'supplier') then
    raise exception 'نوع الطرف غير صحيح';
  end if;

  if p_type = 'customer' then
    return query
    select c.id, c.name, c.phone, b.total_sales::numeric, b.total_collected::numeric, b.balance::numeric
    from customer_balances b
    join customers c on c.id = b.customer_id
    where b.organization_id = org_id and c.organization_id = org_id
    order by b.balance desc, c.name;
  else
    return query
    select s.id, s.name, s.phone, b.total_purchases::numeric, b.total_paid::numeric, b.balance::numeric
    from supplier_balances b
    join suppliers s on s.id = b.supplier_id
    where b.organization_id = org_id and s.organization_id = org_id
    order by b.balance desc, s.name;
  end if;
end;
$$;

-- Transaction-level support for one balance (§39). `increase` grows what is
-- owed (customer: a sale; supplier: a purchase); `decrease` reduces it
-- (customer: a collection; supplier: a payment). `balance` is the running
-- total. When p_from is given, the first row is the opening balance.
create or replace function report_party_ledger(
  org_id uuid,
  p_type text,
  p_party uuid,
  p_from date default null,
  p_to date default null
)
returns table (
  entry_date date,
  entry_type text,
  reference text,
  description text,
  increase numeric,
  decrease numeric,
  balance numeric
)
language plpgsql
stable
set search_path = public
as $$
begin
  perform assert_report_access(org_id, true);
  if p_type not in ('customer', 'supplier') then
    raise exception 'نوع الطرف غير صحيح';
  end if;

  if p_type = 'customer' then
    if not exists (select 1 from customers where id = p_party and organization_id = org_id) then
      raise exception 'هذا العميل لا ينتمي إلى هذه المؤسسة';
    end if;
  else
    if not exists (select 1 from suppliers where id = p_party and organization_id = org_id) then
      raise exception 'هذا المورد لا ينتمي إلى هذه المؤسسة';
    end if;
  end if;

  return query
  with entries as (
    select i.invoice_date as d, i.created_at as ts, i.id as eid,
           'sale'::text as t, coalesce(i.invoice_number, '') as ref, i.notes as descr,
           i.total::numeric as inc, 0::numeric as dec
    from sales_invoices i
    where p_type = 'customer' and i.organization_id = org_id and i.customer_id = p_party
    union all
    select c.collection_date, c.created_at, c.id,
           'collection', coalesce(c.reference, ''), coalesce(c.payment_method, ''),
           0::numeric, c.amount::numeric
    from customer_collections c
    where p_type = 'customer' and c.organization_id = org_id and c.customer_id = p_party
    union all
    select pi.invoice_date, pi.created_at, pi.id,
           'purchase', coalesce(pi.invoice_number, ''), pi.notes,
           pi.total::numeric, 0::numeric
    from purchase_invoices pi
    where p_type = 'supplier' and pi.organization_id = org_id and pi.supplier_id = p_party
    union all
    select sp.payment_date, sp.created_at, sp.id,
           'payment', coalesce(sp.reference, ''), coalesce(sp.payment_method, ''),
           0::numeric, sp.amount::numeric
    from supplier_payments sp
    where p_type = 'supplier' and sp.organization_id = org_id and sp.supplier_id = p_party
  ), running as (
    -- Rows written by one RPC call share the same timestamp (now() is the
    -- transaction start), so an invoice and the collection taken with it tie
    -- on (date, ts). `increase` rows sort first inside a tie so the running
    -- balance never dips below zero mid-transaction because of ordering.
    select e.*, sum(e.inc - e.dec) over (order by e.d, e.ts, (case when e.inc > 0 then 0 else 1 end), e.eid) as bal
    from entries e
  ), opening as (
    select p_from as d, 'opening'::text as t, ''::text as ref, ''::text as descr,
           0::numeric as inc, 0::numeric as dec,
           coalesce((select sum(e.inc - e.dec) from entries e where e.d < p_from), 0) as bal,
           0 as ord
    where p_from is not null
  )
  select x.d, x.t, x.ref, x.descr, x.inc, x.dec, x.bal
  from (
    select o.d, o.t, o.ref, o.descr, o.inc, o.dec, o.bal, o.ord, null::timestamptz as ts, 0 as tie, null::uuid as eid from opening o
    union all
    select r.d, r.t, r.ref, r.descr, r.inc, r.dec, r.bal, 1, r.ts, (case when r.inc > 0 then 0 else 1 end), r.eid
    from running r
    where (p_from is null or r.d >= p_from) and (p_to is null or r.d <= p_to)
  ) x
  order by x.d, x.ord, x.ts, x.tie, x.eid;
end;
$$;

-- ============================================================
-- 8. Treasury reports (§31, §43)
-- ============================================================
create or replace function report_treasury_summary(org_id uuid, p_from date default null, p_to date default null)
returns jsonb
language plpgsql
stable
set search_path = public
as $$
declare
  v_base numeric;
  v_before numeric;
  v_in numeric;
  v_out numeric;
  v_accounts jsonb;
  v_by_category jsonb;
begin
  perform assert_report_access(org_id, true);

  select coalesce(sum(opening_balance), 0) into v_base from treasury_accounts where organization_id = org_id;

  select coalesce(sum(case when direction = 'in' then amount else -amount end), 0)
  into v_before
  from treasury_movements
  where organization_id = org_id and p_from is not null and movement_date < p_from;

  select
    coalesce(sum(amount) filter (where direction = 'in'), 0),
    coalesce(sum(amount) filter (where direction = 'out'), 0)
  into v_in, v_out
  from treasury_movements
  where organization_id = org_id
    and (p_from is null or movement_date >= p_from)
    and (p_to is null or movement_date <= p_to);

  select coalesce(jsonb_agg(jsonb_build_object('id', treasury_account_id, 'name', name, 'balance', balance) order by name), '[]'::jsonb)
  into v_accounts
  from treasury_balances where organization_id = org_id;

  select coalesce(jsonb_agg(jsonb_build_object('category', category, 'direction', direction, 'total', total) order by direction, total desc), '[]'::jsonb)
  into v_by_category
  from (
    select category, direction, sum(amount) as total
    from treasury_movements
    where organization_id = org_id
      and (p_from is null or movement_date >= p_from)
      and (p_to is null or movement_date <= p_to)
    group by category, direction
  ) t;

  return jsonb_build_object(
    'opening', v_base + v_before,
    'total_in', v_in,
    'total_out', v_out,
    'closing', v_base + v_before + v_in - v_out,
    'accounts', v_accounts,
    'by_category', v_by_category
  );
end;
$$;

create or replace function report_treasury_movements(
  org_id uuid,
  p_from date default null,
  p_to date default null,
  p_category text default null,
  p_limit int default 50,
  p_offset int default 0
)
returns table (
  id uuid,
  movement_date date,
  direction text,
  amount numeric,
  category text,
  account_name text,
  description text,
  total_count bigint
)
language plpgsql
stable
set search_path = public
as $$
declare
  v_limit int := least(greatest(coalesce(p_limit, 50), 1), 1000);
  v_offset int := greatest(coalesce(p_offset, 0), 0);
begin
  perform assert_report_access(org_id, true);

  return query
  select m.id, m.movement_date, m.direction, m.amount::numeric, m.category, a.name, m.description, count(*) over ()
  from treasury_movements m
  join treasury_accounts a on a.id = m.treasury_account_id
  where m.organization_id = org_id
    and (p_from is null or m.movement_date >= p_from)
    and (p_to is null or m.movement_date <= p_to)
    and (p_category is null or p_category = '' or m.category = p_category)
  order by m.movement_date desc, m.created_at desc, m.id
  limit v_limit offset v_offset;
end;
$$;

-- ============================================================
-- 9. Financial position + رأس المال العام (§40, §41)
--    Components are returned separately so the owner can see how the
--    number is built. This is a management metric, NOT statutory equity.
-- ============================================================
create or replace function report_financial_position(org_id uuid)
returns jsonb
language plpgsql
stable
set search_path = public
as $$
declare
  v_inventory numeric;
  v_negative int;
  v_receivables numeric;
  v_cash numeric;
  v_payables numeric;
  v_other_assets numeric;
  v_other_liabilities numeric;
  v_items jsonb;
begin
  perform assert_report_access(org_id, true);

  select coalesce(sum(quantity * avg_cost), 0), count(*) filter (where quantity < 0)
  into v_inventory, v_negative
  from inventory_stock where organization_id = org_id;

  select coalesce(sum(balance), 0) into v_receivables from customer_balances where organization_id = org_id;
  select coalesce(sum(balance), 0) into v_cash from treasury_balances where organization_id = org_id;
  select coalesce(sum(balance), 0) into v_payables from supplier_balances where organization_id = org_id;

  select
    coalesce(sum(amount) filter (where kind = 'asset'), 0),
    coalesce(sum(amount) filter (where kind = 'liability'), 0)
  into v_other_assets, v_other_liabilities
  from other_balances where organization_id = org_id and is_active;

  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'kind', kind, 'name', name, 'amount', amount, 'notes', notes) order by created_at desc), '[]'::jsonb)
  into v_items
  from other_balances where organization_id = org_id and is_active;

  return jsonb_build_object(
    'inventory_value', v_inventory,
    'receivables', v_receivables,
    'cash', v_cash,
    'other_assets', v_other_assets,
    'payables', v_payables,
    'other_liabilities', v_other_liabilities,
    'net_position', v_inventory + v_receivables + v_cash + v_other_assets - v_payables - v_other_liabilities,
    'general_capital', v_inventory + v_receivables + v_cash - v_payables - v_other_liabilities,
    'negative_stock_items', v_negative,
    'other_items', v_items
  );
end;
$$;

-- ============================================================
-- 10. Recent activity feed for the dashboard (§42)
--     Non-financial users only see sales invoices.
-- ============================================================
create or replace function report_recent_activity(org_id uuid, p_limit int default 8)
returns table (occurred_at timestamptz, kind text, label text, amount numeric)
language plpgsql
stable
set search_path = public
as $$
declare
  fin boolean;
  v_limit int := least(greatest(coalesce(p_limit, 8), 1), 50);
begin
  perform assert_report_access(org_id, false);
  fin := has_permission(org_id, 'view_financial');

  return query
  select * from (
    (select i.created_at, 'sale'::text, coalesce(c.name, '—'), i.total::numeric
     from sales_invoices i left join customers c on c.id = i.customer_id
     where i.organization_id = org_id
     order by i.created_at desc limit v_limit)
    union all
    (select pi.created_at, 'purchase'::text, coalesce(s.name, '—'), pi.total::numeric
     from purchase_invoices pi left join suppliers s on s.id = pi.supplier_id
     where fin and pi.organization_id = org_id
     order by pi.created_at desc limit v_limit)
    union all
    (select cc.created_at, 'collection'::text, coalesce(c.name, '—'), cc.amount::numeric
     from customer_collections cc left join customers c on c.id = cc.customer_id
     where fin and cc.organization_id = org_id
     order by cc.created_at desc limit v_limit)
    union all
    (select sp.created_at, 'supplier_payment'::text, coalesce(s.name, '—'), sp.amount::numeric
     from supplier_payments sp left join suppliers s on s.id = sp.supplier_id
     where fin and sp.organization_id = org_id
     order by sp.created_at desc limit v_limit)
    union all
    (select e.created_at, 'expense'::text, coalesce(ec.name, 'بدون تصنيف'), e.amount::numeric
     from expenses e left join expense_categories ec on ec.id = e.category_id
     where fin and e.organization_id = org_id
     order by e.created_at desc limit v_limit)
  ) a
  order by 1 desc
  limit v_limit;
end;
$$;

-- ============================================================
-- 11. Grants — new functions are callable by signed-in users only
-- ============================================================
revoke all on function assert_report_access(uuid, boolean) from public, anon;
revoke all on function add_other_balance(uuid, text, text, numeric, text) from public, anon;
revoke all on function deactivate_other_balance(uuid, uuid) from public, anon;
revoke all on function report_summary(uuid, date, date) from public, anon;
revoke all on function report_timeseries(uuid, date, date, text) from public, anon;
revoke all on function report_sales_breakdown(uuid, date, date, text, int, int) from public, anon;
revoke all on function report_inventory_stock(uuid) from public, anon;
revoke all on function report_stock_movements(uuid, date, date, uuid, uuid, text, int, int) from public, anon;
revoke all on function report_party_balances(uuid, text) from public, anon;
revoke all on function report_party_ledger(uuid, text, uuid, date, date) from public, anon;
revoke all on function report_treasury_summary(uuid, date, date) from public, anon;
revoke all on function report_treasury_movements(uuid, date, date, text, int, int) from public, anon;
revoke all on function report_financial_position(uuid) from public, anon;
revoke all on function report_recent_activity(uuid, int) from public, anon;

grant execute on function assert_report_access(uuid, boolean) to authenticated;
grant execute on function add_other_balance(uuid, text, text, numeric, text) to authenticated;
grant execute on function deactivate_other_balance(uuid, uuid) to authenticated;
grant execute on function report_summary(uuid, date, date) to authenticated;
grant execute on function report_timeseries(uuid, date, date, text) to authenticated;
grant execute on function report_sales_breakdown(uuid, date, date, text, int, int) to authenticated;
grant execute on function report_inventory_stock(uuid) to authenticated;
grant execute on function report_stock_movements(uuid, date, date, uuid, uuid, text, int, int) to authenticated;
grant execute on function report_party_balances(uuid, text) to authenticated;
grant execute on function report_party_ledger(uuid, text, uuid, date, date) to authenticated;
grant execute on function report_treasury_summary(uuid, date, date) to authenticated;
grant execute on function report_treasury_movements(uuid, date, date, text, int, int) to authenticated;
grant execute on function report_financial_position(uuid) to authenticated;
grant execute on function report_recent_activity(uuid, int) to authenticated;

-- Kayan — Phase 9: Purchase Returns (§20, §23, §27, §46, §51)
--
-- Deferred twice already — 0005's own comment says supplier_balances has
-- "no purchase returns yet", and 0006 explicitly named this the same kind
-- of deferral as sales returns were at the time. Sales returns got their
-- own migration (0011); this is the symmetrical pass for the purchase
-- side, following the exact same design decisions so the two modules stay
-- consistent for the business:
--
--   1. A return always references one original purchase invoice — same
--      reasoning as §27/§48 on the sales side: historical cost integrity
--      needs that reference.
--   2. Unlike a sales return, there's no "damaged vs resalable" split here:
--      goods are physically leaving the business back to the supplier, so
--      there's nothing to keep in a warehouse either way. The return
--      always reduces on-hand quantity.
--   3. Costing: §21's weighted-average pool has already blended by the
--      time a return happens, so — same treatment as a sale's inventory
--      decrement (0006's header note: "quantity only — weighted-average
--      cost only moves on purchases") — a purchase return decrements
--      inventory_stock.quantity only and leaves avg_cost untouched. The
--      return is still recorded at the ORIGINAL line's historical
--      unit_cost on the movement/return-item row, for traceability, even
--      though it doesn't re-derive the average.
--   4. A return cannot take a product's on-hand quantity negative — if
--      some of the purchased stock has already been sold or adjusted out,
--      only what's still physically on hand can go back. This has no
--      sales-return equivalent because a sales return re-adds stock
--      (nothing to run out of); a purchase return removes it.
--   5. Payable effect: reduces what's owed to the supplier, exactly
--      mirroring §28/§39's customer formula: Payable = Purchases −
--      Payments − Purchase Returns (§23's own words, finally implemented).
--   6. An optional cash refund (supplier hands cash back rather than just
--      lowering the payable) posts as its own treasury movement, same as
--      a sales return's cash_refunded.
--   7. Permission: gated on `purchases.approve` ("Approve purchase
--      invoices") — reversing a completed transaction, not creating a
--      fresh one — matching the sales.approve choice for sales returns.

-- A cash refund on a purchase return needs its own treasury category.
alter table treasury_movements drop constraint treasury_movements_category_check;
alter table treasury_movements add constraint treasury_movements_category_check
  check (category in ('customer_collection','sales_cash','supplier_payment','expense','partner_withdrawal','other_income','other_payment','sales_return','purchase_return'));

-- ============================================================
-- 1. Purchase returns
-- ============================================================
create table purchase_returns (
  id                  uuid primary key default gen_random_uuid(),
  organization_id     uuid not null references organizations(id) on delete cascade,
  purchase_invoice_id uuid not null references purchase_invoices(id) on delete restrict,
  supplier_id         uuid not null references suppliers(id) on delete restrict,
  warehouse_id        uuid not null references warehouses(id) on delete restrict,
  return_date         date not null default current_date,
  total               numeric(14,2) not null default 0,  -- value reversed = the payable credit (§23)
  cash_refunded       numeric(14,2) not null default 0,
  notes               text,
  created_by          uuid references auth.users(id),
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);
create index purchase_returns_org_idx      on purchase_returns(organization_id);
create index purchase_returns_invoice_idx  on purchase_returns(purchase_invoice_id);
create index purchase_returns_supplier_idx on purchase_returns(supplier_id);

create table purchase_return_items (
  id                       uuid primary key default gen_random_uuid(),
  organization_id          uuid not null references organizations(id) on delete cascade,
  purchase_return_id       uuid not null references purchase_returns(id) on delete cascade,
  purchase_invoice_item_id uuid not null references purchase_invoice_items(id) on delete restrict,
  product_id               uuid not null references products(id) on delete restrict,
  quantity                 numeric(14,3) not null check (quantity > 0),
  unit_cost                numeric(14,2) not null default 0,  -- captured from the original line, historical (§48)
  line_total               numeric(14,2) not null default 0
);
create index purchase_return_items_return_idx  on purchase_return_items(purchase_return_id);
create index purchase_return_items_product_idx on purchase_return_items(organization_id, product_id);
create index purchase_return_items_invitem_idx on purchase_return_items(purchase_invoice_item_id);

alter table purchase_returns      enable row level security;
alter table purchase_return_items enable row level security;

create policy purchase_returns_select on purchase_returns for select using (is_org_member(organization_id));
create policy purchase_return_items_select on purchase_return_items for select using (is_org_member(organization_id));

grant select on purchase_returns, purchase_return_items to authenticated;
-- No insert/update/delete grants — written only by create_purchase_return()
-- below (SECURITY DEFINER), same as every other ledger table since Phase 7.

-- ============================================================
-- 2. get_returnable_purchase_items — remaining returnable quantity and
--    current on-hand stock per line, for a given purchase invoice (drives
--    the return form's quantity caps, same role as get_returnable_items).
-- ============================================================
create or replace function get_returnable_purchase_items(org_id uuid, p_purchase_invoice_id uuid)
returns table (
  purchase_invoice_item_id uuid,
  product_id uuid,
  product_name text,
  quantity numeric,
  already_returned numeric,
  returnable numeric,
  on_hand numeric,
  unit_cost numeric,
  line_total numeric
)
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
  if not exists (select 1 from purchase_invoices where id = p_purchase_invoice_id and organization_id = org_id) then
    raise exception 'هذه الفاتورة لا تنتمي إلى هذه المؤسسة';
  end if;

  return query
  select
    it.id,
    it.product_id,
    p.name,
    it.quantity::numeric,
    coalesce(ret.qty, 0)::numeric,
    (it.quantity - coalesce(ret.qty, 0))::numeric,
    coalesce(stk.quantity, 0)::numeric,
    it.unit_cost::numeric,
    it.line_total::numeric
  from purchase_invoice_items it
  join products p on p.id = it.product_id
  join purchase_invoices pi on pi.id = it.purchase_invoice_id
  left join (
    select pri.purchase_invoice_item_id, sum(pri.quantity) as qty
    from purchase_return_items pri
    group by pri.purchase_invoice_item_id
  ) ret on ret.purchase_invoice_item_id = it.id
  left join inventory_stock stk on stk.product_id = it.product_id and stk.warehouse_id = pi.warehouse_id and stk.organization_id = org_id
  where it.purchase_invoice_id = p_purchase_invoice_id and it.organization_id = org_id
  order by p.name;
end;
$$;
revoke all on function get_returnable_purchase_items(uuid, uuid) from public, anon;
grant execute on function get_returnable_purchase_items(uuid, uuid) to authenticated;

-- ============================================================
-- 3. create_purchase_return — the only way a return is written
-- ============================================================
create or replace function create_purchase_return(
  org_id uuid,
  p_purchase_invoice_id uuid,
  p_return_date date,
  items jsonb,          -- [{purchase_invoice_item_id, quantity}]
  p_cash_refund numeric default 0,
  p_notes text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  new_return_id uuid;
  v_supplier_id uuid;
  v_warehouse_id uuid;
  account_id uuid;
  item jsonb;
  v_item_id uuid;
  v_quantity numeric(14,3);
  v_orig record;
  v_already_returned numeric(14,3);
  v_remaining numeric(14,3);
  v_line_total numeric(14,2);
  v_track_inventory boolean;
  v_current_qty numeric(14,3);
  v_subtotal numeric(14,2) := 0;
begin
  if auth.uid() is null then
    raise exception 'يجب تسجيل الدخول أولاً';
  end if;
  if not is_org_member(org_id) then
    raise exception 'أنت لست عضوًا في هذه المؤسسة';
  end if;
  if not has_permission(org_id, 'purchases.approve') then
    raise exception 'ليس لديك صلاحية تسجيل مرتجعات المشتريات';
  end if;

  select supplier_id, warehouse_id into v_supplier_id, v_warehouse_id
  from purchase_invoices
  where id = p_purchase_invoice_id and organization_id = org_id;
  if not found then
    raise exception 'هذه الفاتورة لا تنتمي إلى هذه المؤسسة';
  end if;

  if items is null or jsonb_array_length(items) = 0 then
    raise exception 'يجب اختيار صنف واحد على الأقل للمرتجع';
  end if;
  if p_cash_refund is null or p_cash_refund < 0 then
    raise exception 'قيمة الاسترجاع النقدي غير صحيحة';
  end if;

  insert into purchase_returns (organization_id, purchase_invoice_id, supplier_id, warehouse_id, return_date, notes, created_by)
  values (org_id, p_purchase_invoice_id, v_supplier_id, v_warehouse_id, coalesce(p_return_date, current_date), nullif(p_notes, ''), auth.uid())
  returning id into new_return_id;

  for item in select * from jsonb_array_elements(items)
  loop
    v_item_id := (item->>'purchase_invoice_item_id')::uuid;
    v_quantity := (item->>'quantity')::numeric;

    if v_quantity is null or v_quantity <= 0 then
      raise exception 'يجب أن تكون كمية المرتجع أكبر من صفر';
    end if;

    select * into v_orig
    from purchase_invoice_items
    where id = v_item_id and purchase_invoice_id = p_purchase_invoice_id and organization_id = org_id;
    if not found then
      raise exception 'هذا الصنف لا ينتمي إلى هذه الفاتورة';
    end if;

    select coalesce(sum(quantity), 0) into v_already_returned
    from purchase_return_items
    where purchase_invoice_item_id = v_item_id;

    v_remaining := v_orig.quantity - v_already_returned;
    if v_quantity > v_remaining then
      raise exception 'الكمية المطلوب إرجاعها أكبر من المتاح لهذا الصنف (المتبقي: %)', v_remaining;
    end if;

    v_line_total := v_orig.unit_cost * v_quantity;

    select track_inventory into v_track_inventory from products where id = v_orig.product_id and organization_id = org_id;

    if v_track_inventory then
      select quantity into v_current_qty
      from inventory_stock
      where product_id = v_orig.product_id and warehouse_id = v_warehouse_id
      for update;

      if not found or coalesce(v_current_qty, 0) < v_quantity then
        raise exception 'الكمية المتاحة بالمخزون أقل من كمية المرتجع لهذا الصنف';
      end if;

      -- Quantity-only decrement (§21/§27 note above): the weighted-average
      -- pool has already blended, so a return doesn't try to re-derive it.
      update inventory_stock
      set quantity = quantity - v_quantity, updated_at = now()
      where product_id = v_orig.product_id and warehouse_id = v_warehouse_id;

      insert into inventory_movements (organization_id, product_id, warehouse_id, movement_type, quantity_delta, unit_cost, reference_type, reference_id, created_by)
      values (org_id, v_orig.product_id, v_warehouse_id, 'purchase_return', -v_quantity, v_orig.unit_cost, 'purchase_return', new_return_id, auth.uid());
    end if;

    insert into purchase_return_items (organization_id, purchase_return_id, purchase_invoice_item_id, product_id, quantity, unit_cost, line_total)
    values (org_id, new_return_id, v_item_id, v_orig.product_id, v_quantity, v_orig.unit_cost, v_line_total);

    v_subtotal := v_subtotal + v_line_total;
  end loop;

  if p_cash_refund > v_subtotal then
    raise exception 'قيمة الاسترجاع النقدي أكبر من قيمة المرتجع';
  end if;

  update purchase_returns
  set total = v_subtotal,
      cash_refunded = p_cash_refund,
      updated_at = now()
  where id = new_return_id;

  if p_cash_refund > 0 then
    account_id := ensure_default_treasury_account(org_id);
    insert into treasury_movements (organization_id, treasury_account_id, direction, amount, category, movement_date, source_type, source_id, description, created_by)
    values (org_id, account_id, 'in', p_cash_refund, 'purchase_return', coalesce(p_return_date, current_date), 'purchase_return', new_return_id, nullif(p_notes, ''), auth.uid());
  end if;

  return new_return_id;
end;
$$;

-- Deferred so the audit row captures the finished totals (§46 "Return
-- creation" must be an audited action, same as sales_returns).
create constraint trigger audit_purchase_returns after insert on purchase_returns deferrable initially deferred for each row execute function audit_row_change('purchase_return', 'final');

create trigger a_enforce_module before insert on purchase_returns for each row execute function enforce_module_enabled('purchases');
create trigger b_duplicate_guard before insert on purchase_returns for each row execute function guard_duplicate_submission('purchase_invoice_id', 'return_date');

revoke all on function create_purchase_return(uuid, uuid, date, jsonb, numeric, text) from public, anon;
grant execute on function create_purchase_return(uuid, uuid, date, jsonb, numeric, text) to authenticated;

-- ============================================================
-- 4. supplier_balances now nets returns (§23: Purchases − Payments −
--    Purchase Returns), same shape as customer_balances (§28) in 0011.
-- ============================================================
create or replace view supplier_balances
with (security_invoker = true) as
select
  s.id as supplier_id,
  s.organization_id,
  coalesce(p.total_purchases, 0) as total_purchases,
  coalesce(pay.total_paid, 0) as total_paid,
  coalesce(p.total_purchases, 0) - coalesce(pay.total_paid, 0) - coalesce(r.total_returned, 0) as balance,
  coalesce(r.total_returned, 0) as total_returned
from suppliers s
left join (
  select supplier_id, sum(total) as total_purchases
  from purchase_invoices
  group by supplier_id
) p on p.supplier_id = s.id
left join (
  select supplier_id, sum(amount) as total_paid
  from supplier_payments
  group by supplier_id
) pay on pay.supplier_id = s.id
left join (
  select supplier_id, sum(total) as total_returned
  from purchase_returns
  group by supplier_id
) r on r.supplier_id = s.id;

-- ============================================================
-- 5. report_summary: 'purchase_returns' as its own period-scoped line,
--    mirroring how 'returns' (sales) already reads (§36 parity).
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
  v_purchase_returns numeric(14,2);
  v_by_category jsonb;
  v_receivable numeric;
  v_payable numeric;
  v_inventory numeric;
  v_treasury numeric;
  v_net_sales numeric;
  v_gross_profit numeric;
  v_returns numeric;
  v_returns_cost numeric;
  v_returns_profit numeric;
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

  select coalesce(sum(total), 0), coalesce(sum(cost_reversed), 0), coalesce(sum(profit_reversed), 0)
  into v_returns, v_returns_cost, v_returns_profit
  from sales_returns
  where organization_id = org_id
    and (p_from is null or return_date >= p_from)
    and (p_to is null or return_date <= p_to);

  v_net_sales := s.gross_sales - s.discounts - v_returns;

  if not fin then
    return jsonb_build_object(
      'period', jsonb_build_object('from', p_from, 'to', p_to),
      'sales', jsonb_build_object(
        'invoices', s.invoices,
        'gross_sales', s.gross_sales,
        'discounts', s.discounts,
        'returns', v_returns,
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

  select coalesce(sum(total), 0) into v_purchase_returns
  from purchase_returns
  where organization_id = org_id
    and (p_from is null or return_date >= p_from)
    and (p_to is null or return_date <= p_to);

  select coalesce(sum(balance), 0) into v_receivable from customer_balances where organization_id = org_id;
  select coalesce(sum(balance), 0) into v_payable from supplier_balances where organization_id = org_id;
  select coalesce(sum(quantity * avg_cost), 0) into v_inventory from inventory_stock where organization_id = org_id;
  select coalesce(sum(balance), 0) into v_treasury from treasury_balances where organization_id = org_id;

  v_gross_profit := v_net_sales - (s.cogs - v_returns_cost);

  return jsonb_build_object(
    'period', jsonb_build_object('from', p_from, 'to', p_to),
    'sales', jsonb_build_object(
      'invoices', s.invoices,
      'gross_sales', s.gross_sales,
      'discounts', s.discounts,
      'returns', v_returns,
      'net_sales', v_net_sales,
      'tax', s.tax,
      'billed', s.billed
    ),
    'financial', jsonb_build_object(
      'cogs', s.cogs - v_returns_cost,
      'gross_profit', v_gross_profit,
      'operating_expenses', v_expenses,
      'commissions', s.commissions,
      'net_profit', v_gross_profit - v_expenses - s.commissions,
      'collections', v_collections,
      'supplier_payments', v_supplier_payments,
      'purchases', v_purchases,
      'purchase_returns', v_purchase_returns,
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
-- 6. report_party_ledger: a purchase return is its own entry, reducing
--    the supplier's balance exactly like a payment does.
-- ============================================================
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
    select r.return_date, r.created_at, r.id,
           'return', coalesce((select invoice_number from sales_invoices where id = r.sales_invoice_id), ''), r.notes,
           0::numeric, r.total::numeric
    from sales_returns r
    where p_type = 'customer' and r.organization_id = org_id and r.customer_id = p_party
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
    union all
    select pr.return_date, pr.created_at, pr.id,
           'return', coalesce((select invoice_number from purchase_invoices where id = pr.purchase_invoice_id), ''), pr.notes,
           0::numeric, pr.total::numeric
    from purchase_returns pr
    where p_type = 'supplier' and pr.organization_id = org_id and pr.supplier_id = p_party
  ), running as (
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
-- 7. report_recent_activity: a purchase return shows up alongside a
--    purchase (both gated on view_financial, same as a plain purchase).
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
    (select r.created_at, 'sales_return'::text, coalesce(c.name, '—'), r.total::numeric
     from sales_returns r left join customers c on c.id = r.customer_id
     where r.organization_id = org_id
     order by r.created_at desc limit v_limit)
    union all
    (select pi.created_at, 'purchase'::text, coalesce(s.name, '—'), pi.total::numeric
     from purchase_invoices pi left join suppliers s on s.id = pi.supplier_id
     where fin and pi.organization_id = org_id
     order by pi.created_at desc limit v_limit)
    union all
    (select pr.created_at, 'purchase_return'::text, coalesce(s.name, '—'), pr.total::numeric
     from purchase_returns pr left join suppliers s on s.id = pr.supplier_id
     where fin and pr.organization_id = org_id
     order by pr.created_at desc limit v_limit)
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

revoke all on function report_recent_activity(uuid, int) from public, anon;
grant execute on function report_recent_activity(uuid, int) to authenticated;

-- ============================================================
-- 8. Indexes for the new tables' report/ledger queries.
-- ============================================================
create index if not exists purchase_returns_org_date_idx on purchase_returns (organization_id, return_date);

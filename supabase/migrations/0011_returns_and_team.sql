-- Kayan — Phase 8: Sales Returns (§27) & Settings/Team management (§14, §54)
--
-- Written after a full SRS re-audit against the running app (see the chat
-- summary handed to the business): these were the two confirmed MVP gaps
-- worth their own migration. Everything else flagged in that audit (search/
-- pagination, password reset) is out of scope here — this migration only
-- covers Returns and Settings/Team.
--
-- ============================================================
-- PART A — Sales Returns (§27, §36, §46, §51, §54, §59, §68)
-- ============================================================
--
-- Design decisions made here that the SRS itself leaves open (§65 #3) —
-- flagged the same way §21's costing method and §41's رأس المال العام
-- were: a documented default, not a silent guess.
--
--   1. A return always references one original sales invoice. There is no
--      "unlinked" return — §27 says "must reference the original sale
--      where possible," and historical cost/profit reversal is only
--      possible with that reference (§48).
--   2. Each return line can be marked 'resalable' or 'damaged':
--        resalable — stock goes back into the SAME warehouse the sale
--                    shipped from, blended into its weighted-average cost
--                    exactly like a purchase would (§21's own formula,
--                    reused rather than reinvented); COGS/profit reverse
--                    proportionally.
--        damaged   — stock does NOT go back (it's a write-off); revenue
--                    still reverses (the customer doesn't owe for it) but
--                    COGS does not, so the full returned amount hits
--                    profit as a loss. This is the standard treatment for
--                    unsellable returns, but the business should confirm
--                    it matches their accounting policy.
--   3. A return's revenue/cost/profit reversal is computed from the
--      original item's own historical price and cost (line_total /
--      quantity, unit_cost) — NOT prorated against the invoice-level
--      lump discount or tax. That's the simplest, most transparent
--      default; a business that wants invoice-level discount/tax prorated
--      into returns should say so and it can be adjusted.
--   4. Returns do NOT automatically adjust the original invoice's
--      commission_amount — §33 doesn't address the interaction, and
--      changing history contradicts §48. Flagged as an open item, not
--      silently decided either way.
--   5. A return does not automatically move cash. §27's own worked
--      example only reduces the customer's balance. An optional cash
--      refund can be recorded as its own treasury movement when the
--      business actually hands money back.
--   6. Permission: gated on `sales.approve` ("Approve/cancel sales
--      invoices") rather than `sales.create` — a return reverses a
--      completed transaction, which is closer to that permission's
--      existing intent than to creating a fresh invoice.
--
-- Reports formula split (documented once, so it isn't a silent
-- inconsistency between the two report functions that use it):
--   report_summary's 'returns' figure is PERIOD-SCOPED — a return is
--   recognized in the period it happens (return_date), matching §36's
--   own chain of gross → discounts → returns → net for a given period.
--   report_sales_breakdown nets a return against the ORIGINAL invoice it
--   belongs to, regardless of when the return happened — because that
--   function answers "what did this invoice/customer/product net out
--   to," a lifetime-adjusted question, not a period P&L question.

-- A cash refund on a return needs its own treasury category (previously
-- only customer_collection/sales_cash/supplier_payment/expense/
-- partner_withdrawal/other_income/other_payment existed).
alter table treasury_movements drop constraint treasury_movements_category_check;
alter table treasury_movements add constraint treasury_movements_category_check
  check (category in ('customer_collection','sales_cash','supplier_payment','expense','partner_withdrawal','other_income','other_payment','sales_return'));

create table sales_returns (
  id                uuid primary key default gen_random_uuid(),
  organization_id   uuid not null references organizations(id) on delete cascade,
  sales_invoice_id  uuid not null references sales_invoices(id) on delete restrict,
  customer_id       uuid not null references customers(id) on delete restrict,
  warehouse_id      uuid not null references warehouses(id) on delete restrict,
  return_date       date not null default current_date,
  subtotal_reversed numeric(14,2) not null default 0,  -- revenue reversed (§27 "reduce recognized sales")
  cost_reversed     numeric(14,2) not null default 0,   -- 0 for damaged-condition lines
  profit_reversed   numeric(14,2) not null default 0,
  total             numeric(14,2) not null default 0,   -- = subtotal_reversed; the receivable credit (§28)
  cash_refunded     numeric(14,2) not null default 0,
  notes             text,
  created_by        uuid references auth.users(id),
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);
create index sales_returns_org_idx     on sales_returns(organization_id);
create index sales_returns_invoice_idx on sales_returns(sales_invoice_id);
create index sales_returns_customer_idx on sales_returns(customer_id);

create table sales_return_items (
  id                    uuid primary key default gen_random_uuid(),
  organization_id       uuid not null references organizations(id) on delete cascade,
  sales_return_id       uuid not null references sales_returns(id) on delete cascade,
  sales_invoice_item_id uuid not null references sales_invoice_items(id) on delete restrict,
  product_id            uuid not null references products(id) on delete restrict,
  quantity              numeric(14,3) not null check (quantity > 0),
  condition             text not null check (condition in ('resalable', 'damaged')),
  unit_price            numeric(14,2) not null default 0,  -- captured from the original line, historical (§48)
  unit_cost             numeric(14,2) not null default 0,
  revenue_reversed      numeric(14,2) not null default 0,
  cost_reversed         numeric(14,2) not null default 0,
  profit_reversed       numeric(14,2) not null default 0
);
create index sales_return_items_return_idx  on sales_return_items(sales_return_id);
create index sales_return_items_product_idx on sales_return_items(organization_id, product_id);
create index sales_return_items_invitem_idx on sales_return_items(sales_invoice_item_id);

alter table sales_returns      enable row level security;
alter table sales_return_items enable row level security;

create policy sales_returns_select on sales_returns for select using (is_org_member(organization_id));
create policy sales_return_items_select on sales_return_items for select using (is_org_member(organization_id));

grant select on sales_returns, sales_return_items to authenticated;
-- No insert/update/delete grants: written only by create_sales_return()
-- below (SECURITY DEFINER), matching every other ledger table since
-- Phase 7 — direct writes would bypass stock/cost/profit recalculation.

-- ============================================================
-- A.1 — create_sales_return: the only way a return is written
-- ============================================================
create or replace function create_sales_return(
  org_id uuid,
  p_sales_invoice_id uuid,
  p_return_date date,
  items jsonb,          -- [{sales_invoice_item_id, quantity, condition}]
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
  v_customer_id uuid;
  v_warehouse_id uuid;
  account_id uuid;
  item jsonb;
  v_item_id uuid;
  v_quantity numeric(14,3);
  v_condition text;
  v_orig record;
  v_already_returned numeric(14,3);
  v_remaining numeric(14,3);
  v_unit_price numeric(14,2);
  v_unit_cost numeric(14,2);
  v_revenue numeric(14,2);
  v_cost numeric(14,2);
  v_profit numeric(14,2);
  v_old_qty numeric(14,3);
  v_old_avg numeric(14,2);
  v_track_inventory boolean;
  v_subtotal numeric(14,2) := 0;
  v_cost_total numeric(14,2) := 0;
  v_profit_total numeric(14,2) := 0;
begin
  if auth.uid() is null then
    raise exception 'يجب تسجيل الدخول أولاً';
  end if;
  if not is_org_member(org_id) then
    raise exception 'أنت لست عضوًا في هذه المؤسسة';
  end if;
  if not has_permission(org_id, 'sales.approve') then
    raise exception 'ليس لديك صلاحية تسجيل مرتجعات المبيعات';
  end if;

  select customer_id, warehouse_id into v_customer_id, v_warehouse_id
  from sales_invoices
  where id = p_sales_invoice_id and organization_id = org_id;
  if not found then
    raise exception 'هذه الفاتورة لا تنتمي إلى هذه المؤسسة';
  end if;

  if items is null or jsonb_array_length(items) = 0 then
    raise exception 'يجب اختيار صنف واحد على الأقل للمرتجع';
  end if;
  if p_cash_refund is null or p_cash_refund < 0 then
    raise exception 'قيمة الاسترجاع النقدي غير صحيحة';
  end if;

  insert into sales_returns (organization_id, sales_invoice_id, customer_id, warehouse_id, return_date, notes, created_by)
  values (org_id, p_sales_invoice_id, v_customer_id, v_warehouse_id, coalesce(p_return_date, current_date), nullif(p_notes, ''), auth.uid())
  returning id into new_return_id;

  for item in select * from jsonb_array_elements(items)
  loop
    v_item_id := (item->>'sales_invoice_item_id')::uuid;
    v_quantity := (item->>'quantity')::numeric;
    v_condition := item->>'condition';

    if v_condition not in ('resalable', 'damaged') then
      raise exception 'حالة الصنف المرتجع غير صحيحة';
    end if;
    if v_quantity is null or v_quantity <= 0 then
      raise exception 'يجب أن تكون كمية المرتجع أكبر من صفر';
    end if;

    select * into v_orig
    from sales_invoice_items
    where id = v_item_id and sales_invoice_id = p_sales_invoice_id and organization_id = org_id;
    if not found then
      raise exception 'هذا الصنف لا ينتمي إلى هذه الفاتورة';
    end if;

    select coalesce(sum(quantity), 0) into v_already_returned
    from sales_return_items
    where sales_invoice_item_id = v_item_id;

    v_remaining := v_orig.quantity - v_already_returned;
    if v_quantity > v_remaining then
      raise exception 'الكمية المطلوب إرجاعها أكبر من المتاح لهذا الصنف (المتبقي: %)', v_remaining;
    end if;

    v_unit_price := v_orig.line_total / v_orig.quantity;
    v_unit_cost := v_orig.unit_cost;
    v_revenue := v_unit_price * v_quantity;
    v_cost := case when v_condition = 'resalable' then v_unit_cost * v_quantity else 0 end;
    v_profit := v_revenue - v_cost;

    if v_condition = 'resalable' then
      select track_inventory into v_track_inventory from products where id = v_orig.product_id and organization_id = org_id;

      if v_track_inventory then
        select quantity, avg_cost into v_old_qty, v_old_avg
        from inventory_stock
        where product_id = v_orig.product_id and warehouse_id = v_warehouse_id
        for update;

        if not found then
          v_old_qty := 0;
          v_old_avg := 0;
          insert into inventory_stock (organization_id, product_id, warehouse_id, quantity, avg_cost)
          values (org_id, v_orig.product_id, v_warehouse_id, 0, 0);
        end if;

        -- Same weighted-average blend as a purchase (§21) — a resalable
        -- return re-enters stock like a mini purchase at its own
        -- historical cost.
        update inventory_stock
        set quantity = v_old_qty + v_quantity,
            avg_cost = case when (v_old_qty + v_quantity) > 0
                            then ((v_old_qty * v_old_avg) + (v_quantity * v_unit_cost)) / (v_old_qty + v_quantity)
                            else v_old_avg end,
            updated_at = now()
        where product_id = v_orig.product_id and warehouse_id = v_warehouse_id;

        insert into inventory_movements (organization_id, product_id, warehouse_id, movement_type, quantity_delta, unit_cost, reference_type, reference_id, created_by)
        values (org_id, v_orig.product_id, v_warehouse_id, 'sale_return', v_quantity, v_unit_cost, 'sales_return', new_return_id, auth.uid());
      end if;
    end if;

    insert into sales_return_items (organization_id, sales_return_id, sales_invoice_item_id, product_id, quantity, condition, unit_price, unit_cost, revenue_reversed, cost_reversed, profit_reversed)
    values (org_id, new_return_id, v_item_id, v_orig.product_id, v_quantity, v_condition, v_unit_price, v_unit_cost, v_revenue, v_cost, v_profit);

    v_subtotal := v_subtotal + v_revenue;
    v_cost_total := v_cost_total + v_cost;
    v_profit_total := v_profit_total + v_profit;
  end loop;

  if p_cash_refund > v_subtotal then
    raise exception 'قيمة الاسترجاع النقدي أكبر من قيمة المرتجع';
  end if;

  update sales_returns
  set subtotal_reversed = v_subtotal,
      cost_reversed = v_cost_total,
      profit_reversed = v_profit_total,
      total = v_subtotal,
      cash_refunded = p_cash_refund,
      updated_at = now()
  where id = new_return_id;

  if p_cash_refund > 0 then
    account_id := ensure_default_treasury_account(org_id);
    insert into treasury_movements (organization_id, treasury_account_id, direction, amount, category, movement_date, source_type, source_id, description, created_by)
    values (org_id, account_id, 'out', p_cash_refund, 'sales_return', coalesce(p_return_date, current_date), 'sales_return', new_return_id, nullif(p_notes, ''), auth.uid());
  end if;

  return new_return_id;
end;
$$;

-- Deferred so the audit row captures the finished totals, exactly like
-- sales_invoices (§46 requires "Return creation" to be an audited action).
create constraint trigger audit_sales_returns after insert on sales_returns deferrable initially deferred for each row execute function audit_row_change('sales_return', 'final');

create trigger a_enforce_module before insert on sales_returns for each row execute function enforce_module_enabled('sales');
create trigger b_duplicate_guard before insert on sales_returns for each row execute function guard_duplicate_submission('sales_invoice_id', 'return_date');

revoke all on function create_sales_return(uuid, uuid, date, jsonb, numeric, text) from public, anon;
grant execute on function create_sales_return(uuid, uuid, date, jsonb, numeric, text) to authenticated;

-- ============================================================
-- A.2 — customer_balances now nets returns (§28: Sales − Collections − Returns)
-- ============================================================
create or replace view customer_balances
with (security_invoker = true) as
select
  c.id as customer_id,
  c.organization_id,
  coalesce(s.total_sales, 0) as total_sales,
  coalesce(col.total_collected, 0) as total_collected,
  coalesce(s.total_sales, 0) - coalesce(col.total_collected, 0) - coalesce(r.total_returned, 0) as balance,
  coalesce(r.total_returned, 0) as total_returned
from customers c
left join (
  select customer_id, sum(total) as total_sales
  from sales_invoices
  group by customer_id
) s on s.customer_id = c.id
left join (
  select customer_id, sum(amount) as total_collected
  from customer_collections
  group by customer_id
) col on col.customer_id = c.id
left join (
  select customer_id, sum(total) as total_returned
  from sales_returns
  group by customer_id
) r on r.customer_id = c.id;

-- ============================================================
-- A.3 — report_summary: 'returns' is its own period-scoped line (§36)
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

  -- Period-scoped by the RETURN's own date, not the original sale's date
  -- (see the design note at the top of this migration).
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

  select coalesce(sum(balance), 0) into v_receivable from customer_balances where organization_id = org_id;
  select coalesce(sum(balance), 0) into v_payable from supplier_balances where organization_id = org_id;
  select coalesce(sum(quantity * avg_cost), 0) into v_inventory from inventory_stock where organization_id = org_id;
  select coalesce(sum(balance), 0) into v_treasury from treasury_balances where organization_id = org_id;

  -- COGS for the period is reduced by returns' cost reversal (resalable
  -- stock that came back), so gross profit reflects the net position.
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
-- A.4 — report_sales_breakdown: nets returns against the invoice they
-- belong to, in every grouping (see design note above for why this
-- differs from report_summary's period-scoping). Adds a `returns` column,
-- so the function is dropped first (return type is changing).
-- ============================================================
drop function if exists report_sales_breakdown(uuid, date, date, text, int, int);

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
  returns numeric,
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
      coalesce(sum(x.quantity), 0)::numeric - coalesce(sum(x.ret_qty), 0)::numeric,
      coalesce(sum(x.quantity * x.unit_price), 0)::numeric,
      coalesce(sum(x.discount + x.alloc), 0)::numeric,
      coalesce(sum(x.ret_revenue), 0)::numeric,
      coalesce(sum(x.line_total - x.alloc - x.ret_revenue), 0)::numeric,
      case when fin then coalesce(sum(x.cost_total - x.ret_cost), 0)::numeric end,
      case when fin then coalesce(sum(x.profit - x.alloc - x.ret_profit), 0)::numeric end,
      null::numeric,
      count(*) over ()
    from (
      select it.id, it.product_id, it.sales_invoice_id, it.quantity, it.unit_price, it.discount,
             it.line_total, it.cost_total, it.profit,
             case when i.subtotal > 0
                  then i.discount_total * (it.quantity * it.unit_price) / i.subtotal
                  else 0 end as alloc,
             coalesce(ra.ret_qty, 0) as ret_qty,
             coalesce(ra.ret_revenue, 0) as ret_revenue,
             coalesce(ra.ret_cost, 0) as ret_cost,
             coalesce(ra.ret_profit, 0) as ret_profit
      from sales_invoice_items it
      join sales_invoices i on i.id = it.sales_invoice_id
      left join (
        select sri.sales_invoice_item_id, sum(sri.quantity) as ret_qty, sum(sri.revenue_reversed) as ret_revenue,
               sum(sri.cost_reversed) as ret_cost, sum(sri.profit_reversed) as ret_profit
        from sales_return_items sri
        where sri.organization_id = org_id
        group by sri.sales_invoice_item_id
      ) ra on ra.sales_invoice_item_id = it.id
      where it.organization_id = org_id
        and i.organization_id = org_id
        and (p_from is null or i.invoice_date >= p_from)
        and (p_to is null or i.invoice_date <= p_to)
    ) x
    left join products p on p.id = x.product_id
    group by x.product_id, p.name
    order by sum(x.line_total - x.alloc - x.ret_revenue) desc, p.name
    limit v_limit offset v_offset;
    return;
  end if;

  return query
  with inv as (
    select i.*,
           coalesce((select sum(it.quantity) from sales_invoice_items it where it.sales_invoice_id = i.id), 0) as qty,
           coalesce((select sum(sri.quantity) from sales_return_items sri join sales_returns r on r.id = sri.sales_return_id where r.sales_invoice_id = i.id), 0) as ret_qty,
           coalesce((select sum(r.total) from sales_returns r where r.sales_invoice_id = i.id), 0) as ret_total,
           coalesce((select sum(r.cost_reversed) from sales_returns r where r.sales_invoice_id = i.id), 0) as ret_cost,
           coalesce((select sum(r.profit_reversed) from sales_returns r where r.sales_invoice_id = i.id), 0) as ret_profit
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
      coalesce(sum(i.qty - i.ret_qty), 0)::numeric as quantity,
      coalesce(sum(i.subtotal), 0)::numeric as gross_sales,
      coalesce(sum(i.discount_total), 0)::numeric as discounts,
      coalesce(sum(i.ret_total), 0)::numeric as returns,
      coalesce(sum(i.subtotal - i.discount_total - i.ret_total), 0)::numeric as net_sales,
      case when fin then coalesce(sum(i.cogs_total - i.ret_cost), 0)::numeric end as cogs,
      case when fin then coalesce(sum(i.profit_total - i.ret_profit), 0)::numeric end as gross_profit,
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

revoke all on function report_sales_breakdown(uuid, date, date, text, int, int) from public, anon;
grant execute on function report_sales_breakdown(uuid, date, date, text, int, int) to authenticated;

-- ============================================================
-- A.5 — report_party_ledger: a return is its own entry, reducing the
-- customer's balance exactly like a collection does.
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
-- A.6 — report_recent_activity: a return shows up like a sale does
-- (visible without view_financial — it shows the reversed amount only,
-- never cost or profit, same as a plain sale already does).
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
-- A.7 — a small helper the UI needs: how much of each line is still
-- returnable, for a given invoice (drives the return form's quantity caps).
-- ============================================================
create or replace function get_returnable_items(org_id uuid, p_sales_invoice_id uuid)
returns table (
  sales_invoice_item_id uuid,
  product_id uuid,
  product_name text,
  quantity numeric,
  already_returned numeric,
  returnable numeric,
  unit_price numeric,
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
  if not exists (select 1 from sales_invoices where id = p_sales_invoice_id and organization_id = org_id) then
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
    (it.line_total / it.quantity)::numeric,
    it.line_total::numeric
  from sales_invoice_items it
  join products p on p.id = it.product_id
  left join (
    select sri.sales_invoice_item_id, sum(sri.quantity) as qty
    from sales_return_items sri
    group by sri.sales_invoice_item_id
  ) ret on ret.sales_invoice_item_id = it.id
  where it.sales_invoice_id = p_sales_invoice_id and it.organization_id = org_id
  order by p.name;
end;
$$;
revoke all on function get_returnable_items(uuid, uuid) from public, anon;
grant execute on function get_returnable_items(uuid, uuid) to authenticated;

-- ============================================================
-- PART B — Settings & Team management (§14, §54)
-- ============================================================
--
-- Adding, viewing, changing the role of, and removing a team member all
-- already work as plain permission-gated table writes on organization_users
-- (RLS from §1, protect_org_owners from Phase 7) — no new RPC needed for
-- those. What's genuinely missing is:
--   B.1  listing members WITH their email (auth.users isn't otherwise
--        queryable through the API)
--   B.2  adding an EXISTING Supabase user by email (no service-role key
--        needed — a Postgres function can read auth.users directly)
--   B.3  finishing the add after a BRAND NEW person has been invited via
--        Supabase Auth's admin API (which the server action calls with a
--        service-role client — see src/lib/supabase/admin.ts)
--
-- Custom per-organization roles (the "Custom role" example in §14) are
-- NOT built here — this phase covers the 5 system role templates
-- (owner/admin/accountant/sales/warehouse) only, which is what §68's MVP
-- scope requires. A custom-role builder is a reasonable future addition,
-- not a silent gap: it was never in the MVP list.

create or replace function list_org_members(org_id uuid)
returns table (
  user_id uuid,
  email text,
  role_id uuid,
  role_key text,
  role_name text,
  status text,
  joined_at timestamptz,
  is_self boolean
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'يجب تسجيل الدخول أولاً';
  end if;
  if not has_permission(org_id, 'manage_settings') then
    raise exception 'ليس لديك صلاحية عرض أعضاء الفريق';
  end if;

  return query
  select ou.user_id, u.email, ou.role_id, r.key, r.name, ou.status, ou.created_at, ou.user_id = auth.uid()
  from organization_users ou
  join auth.users u on u.id = ou.user_id
  join roles r on r.id = ou.role_id
  where ou.organization_id = org_id
  order by ou.created_at;
end;
$$;
revoke all on function list_org_members(uuid) from public, anon;
grant execute on function list_org_members(uuid) to authenticated;

-- Private helper — intentionally never granted to authenticated/anon.
-- Callable only from other SECURITY DEFINER functions owned by the same
-- role, which is exactly how add_team_member uses it below.
create or replace function find_user_id_by_email(p_email text)
returns uuid
language sql
security definer
stable
set search_path = public
as $$
  select id from auth.users where lower(email) = lower(trim(p_email)) limit 1;
$$;

create or replace function add_team_member(org_id uuid, p_email text, p_role_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid;
begin
  if auth.uid() is null then
    raise exception 'يجب تسجيل الدخول أولاً';
  end if;
  if not has_permission(org_id, 'manage_settings') then
    raise exception 'ليس لديك صلاحية إضافة أعضاء';
  end if;
  if coalesce(trim(p_email), '') = '' then
    raise exception 'البريد الإلكتروني مطلوب';
  end if;
  if not exists (select 1 from roles where id = p_role_id and (organization_id is null or organization_id = org_id)) then
    raise exception 'الدور المختار غير صحيح';
  end if;

  v_user_id := find_user_id_by_email(p_email);

  if v_user_id is null then
    -- No existing account with this email — the caller (server action)
    -- falls back to Supabase Auth's admin invite, then calls
    -- complete_team_invite() with the id it gets back.
    return jsonb_build_object('status', 'needs_invite');
  end if;

  if exists (select 1 from organization_users where organization_id = org_id and user_id = v_user_id) then
    raise exception 'هذا الشخص عضو بالفعل في هذه المؤسسة';
  end if;

  insert into organization_users (organization_id, user_id, role_id, status)
  values (org_id, v_user_id, p_role_id, 'active');

  return jsonb_build_object('status', 'added');
end;
$$;
revoke all on function add_team_member(uuid, text, uuid) from public, anon;
grant execute on function add_team_member(uuid, text, uuid) to authenticated;

create or replace function complete_team_invite(org_id uuid, p_user_id uuid, p_role_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'يجب تسجيل الدخول أولاً';
  end if;
  if not has_permission(org_id, 'manage_settings') then
    raise exception 'ليس لديك صلاحية إضافة أعضاء';
  end if;
  if not exists (select 1 from roles where id = p_role_id and (organization_id is null or organization_id = org_id)) then
    raise exception 'الدور المختار غير صحيح';
  end if;
  if exists (select 1 from organization_users where organization_id = org_id and user_id = p_user_id) then
    raise exception 'هذا الشخص عضو بالفعل في هذه المؤسسة';
  end if;

  insert into organization_users (organization_id, user_id, role_id, status)
  values (org_id, p_user_id, p_role_id, 'active');
end;
$$;
revoke all on function complete_team_invite(uuid, uuid, uuid) from public, anon;
grant execute on function complete_team_invite(uuid, uuid, uuid) to authenticated;

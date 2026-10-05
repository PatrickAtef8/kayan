-- Kayan — Phase 25: analysis & debt reports (customers, suppliers, reps)
--
-- Every figure comes from the same tables / views the rest of the system posts
-- to (customer_balances, supplier_balances, rep_monthly_performance,
-- rep_commission_balances, sales/purchase items & returns) — no report derives
-- a number its own way. The functions run as the caller (security invoker), so
-- a rep linked to a representative record gets exactly their own slice through
-- the Phase 24 policies, with no second permission model to keep in sync.
--
-- Access: view_financial, OR a rep restricted to their own data (they need
-- their customers' debts, by the brief). Cost/profit figures are never part of
-- these reports.

create or replace function assert_party_report_access(org_id uuid)
returns void language plpgsql stable set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'يجب تسجيل الدخول أولاً'; end if;
  if not is_org_member(org_id) then raise exception 'أنت لست عضوًا في هذه المؤسسة'; end if;
  if not has_permission(org_id, 'view_financial') and not is_restricted_rep(org_id) then
    raise exception 'ليس لديك صلاحية عرض البيانات المالية';
  end if;
end $$;

-- ============================================================
-- 1. Customer debts: one row per customer + grand total of the filtered set
-- ============================================================
create or replace function report_customer_debts(
  org_id uuid, p_search text default null, p_rep_id uuid default null,
  p_only_debt boolean default true, p_limit int default 100, p_offset int default 0
)
returns table (
  customer_id uuid, customer_name text, phone text, rep_id uuid, rep_name text,
  opening_balance numeric, total_sales numeric, total_paid numeric, total_returned numeric,
  outstanding numeric, last_payment_date date, last_payment_amount numeric,
  grand_total numeric, total_count bigint
)
language plpgsql stable set search_path = public as $$
declare
  v_limit int := least(greatest(coalesce(p_limit, 100), 1), 1000);
  v_offset int := greatest(coalesce(p_offset, 0), 0);
  v_q text := nullif(btrim(coalesce(p_search, '')), '');
begin
  perform assert_party_report_access(org_id);
  return query
  select * from (
    select c.id as k_id, c.name as k_name, c.phone as k_phone, c.sales_rep_id as k_rep, r.name as k_rep_name,
           c.opening_balance::numeric as k_open, b.total_sales::numeric as k_sales, b.total_collected::numeric as k_paid,
           b.total_returned::numeric as k_ret, b.balance::numeric as k_bal,
           lp.collection_date as k_lp_date, lp.amount::numeric as k_lp_amt,
           (sum(b.balance) over ())::numeric as k_total,
           (count(*) over ())::bigint as k_count
    from customers c
    join customer_balances b on b.customer_id = c.id
    left join sales_representatives r on r.id = c.sales_rep_id
    left join lateral (
      select cc.collection_date, cc.amount from customer_collections cc
      where cc.customer_id = c.id order by cc.collection_date desc, cc.created_at desc limit 1
    ) lp on true
    where c.organization_id = org_id and b.organization_id = org_id
      and (v_q is null or c.name ilike '%' || v_q || '%' or c.phone ilike '%' || v_q || '%')
      and (p_rep_id is null or c.sales_rep_id = p_rep_id)
      and (not coalesce(p_only_debt, true) or b.balance > 0)
  ) x
  order by x.k_bal desc, x.k_name
  limit v_limit offset v_offset;
end $$;

create or replace function report_supplier_debts(
  org_id uuid, p_search text default null, p_only_debt boolean default true,
  p_limit int default 100, p_offset int default 0
)
returns table (
  supplier_id uuid, supplier_name text, phone text,
  opening_balance numeric, total_purchases numeric, total_paid numeric, total_returned numeric,
  outstanding numeric, last_payment_date date, last_payment_amount numeric,
  grand_total numeric, total_count bigint
)
language plpgsql stable set search_path = public as $$
declare
  v_limit int := least(greatest(coalesce(p_limit, 100), 1), 1000);
  v_offset int := greatest(coalesce(p_offset, 0), 0);
  v_q text := nullif(btrim(coalesce(p_search, '')), '');
begin
  perform assert_party_report_access(org_id);
  return query
  select * from (
    select s.id as k_id, s.name as k_name, s.phone as k_phone,
           s.opening_balance::numeric as k_open, b.total_purchases::numeric as k_sales, b.total_paid::numeric as k_paid,
           b.total_returned::numeric as k_ret, b.balance::numeric as k_bal,
           lp.payment_date as k_lp_date, lp.amount::numeric as k_lp_amt,
           (sum(b.balance) over ())::numeric as k_total,
           (count(*) over ())::bigint as k_count
    from suppliers s
    join supplier_balances b on b.supplier_id = s.id
    left join lateral (
      select sp.payment_date, sp.amount from supplier_payments sp
      where sp.supplier_id = s.id order by sp.payment_date desc, sp.created_at desc limit 1
    ) lp on true
    where s.organization_id = org_id and b.organization_id = org_id
      and (v_q is null or s.name ilike '%' || v_q || '%' or s.phone ilike '%' || v_q || '%')
      and (not coalesce(p_only_debt, true) or b.balance > 0)
  ) x
  order by x.k_bal desc, x.k_name
  limit v_limit offset v_offset;
end $$;

-- ============================================================
-- 2. Detailed customer analysis
-- ============================================================
create or replace function report_customer_analysis(org_id uuid, p_customer_id uuid)
returns jsonb language plpgsql stable set search_path = public as $$
declare
  c record; b record; v_rep_name text;
  v_totals jsonb; v_invoices jsonb; v_payments jsonb; v_returns jsonb; v_notes jsonb;
begin
  perform assert_party_report_access(org_id);
  select * into c from customers where id = p_customer_id and organization_id = org_id;
  if not found then raise exception 'العميل غير موجود'; end if;
  select * into b from customer_balances where customer_id = p_customer_id;
  select name into v_rep_name from sales_representatives where id = c.sales_rep_id;

  select jsonb_build_object(
    'invoices', count(*),
    'gross_sales', coalesce(sum(subtotal), 0),
    'line_discounts', coalesce(sum(line_discount_total), 0),
    'invoice_discounts', coalesce(sum(invoice_discount), 0),
    'cash_discounts', coalesce(sum(cash_discount), 0),
    'tier_discounts', coalesce(sum(tier_discount), 0),
    'discounts', coalesce(sum(discount_total), 0),
    'net_sales', coalesce(sum(subtotal - discount_total), 0),
    'tax', coalesce(sum(tax_total), 0),
    'billed', coalesce(sum(total), 0),
    'bonus_units', coalesce(sum(bonus_units), 0)
  ) into v_totals
  from sales_invoices where customer_id = p_customer_id and organization_id = org_id;

  select coalesce(jsonb_agg(jsonb_build_object(
      'id', i.id, 'invoice_number', i.invoice_number, 'invoice_date', i.invoice_date,
      'payment_method', i.payment_method, 'payment_status', i.payment_status,
      'subtotal', i.subtotal, 'line_discount', i.line_discount_total, 'invoice_discount', i.invoice_discount,
      'cash_discount', i.cash_discount, 'tier_discount', i.tier_discount, 'discount_total', i.discount_total,
      'tax', i.tax_total, 'total', i.total, 'amount_paid', i.amount_paid, 'bonus_units', i.bonus_units,
      'notes', i.notes,
      'items', (select coalesce(jsonb_agg(jsonb_build_object(
                  'product', p.name, 'quantity', it.quantity, 'bonus_quantity', it.bonus_quantity, 'is_bonus', it.is_bonus,
                  'unit_price', it.unit_price, 'discount', it.discount, 'allocated_discount', it.allocated_discount,
                  'net_total', it.net_total, 'effective_unit_price', it.effective_unit_price
                ) order by it.is_bonus, p.name), '[]'::jsonb)
                from sales_invoice_items it join products p on p.id = it.product_id where it.sales_invoice_id = i.id)
    ) order by i.invoice_date desc, i.created_at desc), '[]'::jsonb)
  into v_invoices
  from sales_invoices i where i.customer_id = p_customer_id and i.organization_id = org_id;

  select coalesce(jsonb_agg(jsonb_build_object(
      'id', cc.id, 'date', cc.collection_date, 'amount', cc.amount, 'payment_method', cc.payment_method,
      'reference', cc.reference, 'invoice_number', si.invoice_number, 'notes', cc.notes
    ) order by cc.collection_date desc, cc.created_at desc), '[]'::jsonb)
  into v_payments
  from customer_collections cc left join sales_invoices si on si.id = cc.sales_invoice_id
  where cc.customer_id = p_customer_id and cc.organization_id = org_id;

  select coalesce(jsonb_agg(jsonb_build_object(
      'id', r.id, 'date', r.return_date, 'total', r.total, 'cash_refunded', r.cash_refunded, 'invoice_number', si.invoice_number,
      'notes', r.notes,
      'items', (select coalesce(jsonb_agg(jsonb_build_object('product', p.name, 'quantity', ri.quantity, 'condition', ri.condition,
                  'unit_price', ri.unit_price, 'amount', ri.revenue_reversed) order by p.name), '[]'::jsonb)
                from sales_return_items ri join products p on p.id = ri.product_id where ri.sales_return_id = r.id)
    ) order by r.return_date desc, r.created_at desc), '[]'::jsonb)
  into v_returns
  from sales_returns r join sales_invoices si on si.id = r.sales_invoice_id
  where r.customer_id = p_customer_id and r.organization_id = org_id;

  select coalesce(jsonb_agg(jsonb_build_object('id', n.id, 'note', n.note, 'created_at', n.created_at, 'invoice_id', n.sales_invoice_id)
                            order by n.created_at desc), '[]'::jsonb)
  into v_notes from party_notes n where n.customer_id = p_customer_id and n.organization_id = org_id;

  return jsonb_build_object(
    'customer', jsonb_build_object('id', c.id, 'name', c.name, 'phone', c.phone, 'address', c.address,
                                   'rep_id', c.sales_rep_id, 'rep_name', v_rep_name, 'opening_balance', c.opening_balance,
                                   'credit_status', c.credit_status),
    'totals', v_totals || jsonb_build_object('payments', coalesce(b.total_collected, 0), 'returns', coalesce(b.total_returned, 0),
                                             'debt', coalesce(b.balance, 0)),
    'invoices', v_invoices, 'payments', v_payments, 'returns', v_returns, 'notes', v_notes
  );
end $$;

-- ============================================================
-- 3. Detailed supplier analysis
-- ============================================================
create or replace function report_supplier_analysis(org_id uuid, p_supplier_id uuid)
returns jsonb language plpgsql stable set search_path = public as $$
declare
  s record; b record; v_totals jsonb; v_invoices jsonb; v_payments jsonb; v_returns jsonb; v_notes jsonb;
begin
  perform assert_party_report_access(org_id);
  select * into s from suppliers where id = p_supplier_id and organization_id = org_id;
  if not found then raise exception 'المورد غير موجود'; end if;
  select * into b from supplier_balances where supplier_id = p_supplier_id;

  select jsonb_build_object(
    'invoices', count(*),
    'gross_purchases', coalesce(sum(subtotal), 0),
    'line_discounts', coalesce(sum(line_discount_total), 0),
    'invoice_discounts', coalesce(sum(invoice_discount), 0),
    'cash_discounts', coalesce(sum(cash_discount), 0),
    'tier_discounts', coalesce(sum(tier_discount), 0),
    'discounts', coalesce(sum(discount_total), 0),
    'net_purchases', coalesce(sum(subtotal - discount_total), 0),
    'tax', coalesce(sum(tax_total), 0),
    'billed', coalesce(sum(total), 0),
    'bonus_units', coalesce(sum(bonus_units), 0)
  ) into v_totals
  from purchase_invoices where supplier_id = p_supplier_id and organization_id = org_id;

  select coalesce(jsonb_agg(jsonb_build_object(
      'id', i.id, 'invoice_number', i.invoice_number, 'invoice_date', i.invoice_date,
      'payment_method', i.payment_method, 'payment_status', i.payment_status,
      'subtotal', i.subtotal, 'line_discount', i.line_discount_total, 'invoice_discount', i.invoice_discount,
      'cash_discount', i.cash_discount, 'tier_discount', i.tier_discount, 'discount_total', i.discount_total,
      'tax', i.tax_total, 'total', i.total, 'amount_paid', i.amount_paid, 'bonus_units', i.bonus_units, 'notes', i.notes,
      'items', (select coalesce(jsonb_agg(jsonb_build_object(
                  'product', p.name, 'quantity', it.quantity, 'bonus_quantity', it.bonus_quantity, 'is_bonus', it.is_bonus,
                  'unit_cost', it.unit_cost, 'discount', it.discount, 'allocated_discount', it.allocated_discount,
                  'net_total', it.net_total, 'effective_unit_cost', it.effective_unit_cost
                ) order by it.is_bonus, p.name), '[]'::jsonb)
                from purchase_invoice_items it join products p on p.id = it.product_id where it.purchase_invoice_id = i.id)
    ) order by i.invoice_date desc, i.created_at desc), '[]'::jsonb)
  into v_invoices
  from purchase_invoices i where i.supplier_id = p_supplier_id and i.organization_id = org_id;

  select coalesce(jsonb_agg(jsonb_build_object(
      'id', sp.id, 'date', sp.payment_date, 'amount', sp.amount, 'payment_method', sp.payment_method,
      'reference', sp.reference, 'invoice_number', pi.invoice_number, 'notes', sp.notes
    ) order by sp.payment_date desc, sp.created_at desc), '[]'::jsonb)
  into v_payments
  from supplier_payments sp left join purchase_invoices pi on pi.id = sp.purchase_invoice_id
  where sp.supplier_id = p_supplier_id and sp.organization_id = org_id;

  select coalesce(jsonb_agg(jsonb_build_object(
      'id', r.id, 'date', r.return_date, 'total', r.total, 'cash_refunded', r.cash_refunded, 'invoice_number', pi.invoice_number,
      'notes', r.notes,
      'items', (select coalesce(jsonb_agg(jsonb_build_object('product', p.name, 'quantity', ri.quantity, 'unit_cost', ri.unit_cost, 'amount', ri.line_total) order by p.name), '[]'::jsonb)
                from purchase_return_items ri join products p on p.id = ri.product_id where ri.purchase_return_id = r.id)
    ) order by r.return_date desc, r.created_at desc), '[]'::jsonb)
  into v_returns
  from purchase_returns r join purchase_invoices pi on pi.id = r.purchase_invoice_id
  where r.supplier_id = p_supplier_id and r.organization_id = org_id;

  select coalesce(jsonb_agg(jsonb_build_object('id', n.id, 'note', n.note, 'created_at', n.created_at) order by n.created_at desc), '[]'::jsonb)
  into v_notes from party_notes n where n.supplier_id = p_supplier_id and n.organization_id = org_id;

  return jsonb_build_object(
    'supplier', jsonb_build_object('id', s.id, 'name', s.name, 'phone', s.phone, 'address', s.address, 'opening_balance', s.opening_balance),
    'totals', v_totals || jsonb_build_object('payments', coalesce(b.total_paid, 0), 'returns', coalesce(b.total_returned, 0), 'debt', coalesce(b.balance, 0)),
    'invoices', v_invoices, 'payments', v_payments, 'returns', v_returns, 'notes', v_notes
  );
end $$;

-- ============================================================
-- 4. Rep overview (one row per rep for a month) and detailed rep analysis
-- ============================================================
create or replace function report_rep_overview(org_id uuid, p_month date default null)
returns table (
  rep_id uuid, rep_name text, is_active boolean,
  invoices bigint, gross_sales numeric, discounts numeric, returns numeric, net_sales numeric, collected numeric,
  customers_count bigint, customers_debt numeric,
  monthly_target numeric, target_pct numeric, min_target numeric, min_target_met boolean,
  potential_commission numeric, earned_commission numeric, commission_paid numeric, commission_payable numeric
)
language plpgsql stable set search_path = public as $$
declare v_month date := date_trunc('month', coalesce(p_month, current_date))::date;
begin
  perform assert_party_report_access(org_id);
  return query
  select sr.id, sr.name, sr.is_active,
         coalesce(p.invoices, 0)::bigint, coalesce(p.gross_sales, 0)::numeric, coalesce(p.discounts, 0)::numeric,
         coalesce(p.returns, 0)::numeric, coalesce(p.net_sales, 0)::numeric, coalesce(p.collected, 0)::numeric,
         coalesce(cu.cnt, 0)::bigint, coalesce(cu.debt, 0)::numeric,
         sr.monthly_target::numeric,
         case when sr.monthly_target > 0 then round(coalesce(p.net_sales, 0) / sr.monthly_target * 100, 1) end::numeric,
         sr.min_target_for_commission::numeric,
         (sr.min_target_for_commission <= 0 or coalesce(p.net_sales, 0) >= sr.min_target_for_commission),
         coalesce(p.potential_commission, 0)::numeric, coalesce(p.earned_commission, 0)::numeric,
         coalesce(cb.paid, 0)::numeric, coalesce(cb.payable, 0)::numeric
  from sales_representatives sr
  left join rep_monthly_performance p on p.rep_id = sr.id and p.month = v_month
  left join rep_commission_balances cb on cb.rep_id = sr.id
  left join (
    select c.sales_rep_id, count(*) as cnt, sum(greatest(b.balance, 0)) as debt
    from customers c join customer_balances b on b.customer_id = c.id
    where c.organization_id = org_id and c.sales_rep_id is not null group by 1
  ) cu on cu.sales_rep_id = sr.id
  where sr.organization_id = org_id
  order by coalesce(p.net_sales, 0) desc, sr.name;
end $$;

create or replace function report_rep_analysis(org_id uuid, p_rep_id uuid, p_month date default null)
returns jsonb language plpgsql stable set search_path = public as $$
declare
  v_month date := date_trunc('month', coalesce(p_month, current_date))::date;
  sr record; p record; cb record; v_customers jsonb; v_months jsonb; v_invoices jsonb; v_expenses jsonb;
begin
  perform assert_party_report_access(org_id);
  select * into sr from sales_representatives where id = p_rep_id and organization_id = org_id;
  if not found then raise exception 'المندوب غير موجود'; end if;
  select * into p from rep_monthly_performance where rep_id = p_rep_id and month = v_month;
  select * into cb from rep_commission_balances where rep_id = p_rep_id;

  select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name, 'phone', c.phone, 'total_sales', b.total_sales,
            'paid', b.total_collected, 'returned', b.total_returned, 'debt', b.balance) order by b.balance desc, c.name), '[]'::jsonb)
  into v_customers
  from customers c join customer_balances b on b.customer_id = c.id
  where c.organization_id = org_id and c.sales_rep_id = p_rep_id;

  select coalesce(jsonb_agg(jsonb_build_object('month', m.month, 'invoices', m.invoices, 'net_sales', m.net_sales, 'returns', m.returns,
            'collected', m.collected, 'target', m.monthly_target, 'eligible', m.commission_eligible,
            'potential_commission', m.potential_commission, 'earned_commission', m.earned_commission) order by m.month desc), '[]'::jsonb)
  into v_months from (select * from rep_monthly_performance where rep_id = p_rep_id order by month desc limit 12) m;

  select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'invoice_number', i.invoice_number, 'invoice_date', i.invoice_date,
            'customer', c.name, 'total', i.total, 'amount_paid', i.amount_paid, 'payment_status', i.payment_status,
            'discount_total', i.discount_total, 'bonus_units', i.bonus_units) order by i.invoice_date desc, i.created_at desc), '[]'::jsonb)
  into v_invoices
  from sales_invoices i join customers c on c.id = i.customer_id
  where i.organization_id = org_id and i.sales_rep_id = p_rep_id and date_trunc('month', i.invoice_date)::date = v_month;

  select coalesce(jsonb_agg(jsonb_build_object('date', e.expense_date, 'type', e.expense_type, 'amount', e.amount, 'description', e.description)
                            order by e.expense_date desc), '[]'::jsonb)
  into v_expenses from expenses e where e.organization_id = org_id and e.sales_rep_id = p_rep_id;

  return jsonb_build_object(
    'rep', jsonb_build_object('id', sr.id, 'name', sr.name, 'phone', sr.phone, 'is_active', sr.is_active,
                              'monthly_target', sr.monthly_target, 'min_target', sr.min_target_for_commission,
                              'commission_basis', sr.commission_basis, 'commission_rate', sr.commission_rate),
    'month', v_month,
    'performance', jsonb_build_object(
      'invoices', coalesce(p.invoices, 0), 'gross_sales', coalesce(p.gross_sales, 0), 'discounts', coalesce(p.discounts, 0),
      'returns', coalesce(p.returns, 0), 'net_sales', coalesce(p.net_sales, 0), 'collected', coalesce(p.collected, 0),
      'target', sr.monthly_target,
      'target_pct', case when sr.monthly_target > 0 then round(coalesce(p.net_sales, 0) / sr.monthly_target * 100, 1) end,
      'min_target', sr.min_target_for_commission,
      'min_target_met', (sr.min_target_for_commission <= 0 or coalesce(p.net_sales, 0) >= sr.min_target_for_commission),
      'potential_commission', coalesce(p.potential_commission, 0), 'earned_commission', coalesce(p.earned_commission, 0)),
    'commission', jsonb_build_object('earned', coalesce(cb.earned, 0), 'paid', coalesce(cb.paid, 0), 'payable', coalesce(cb.payable, 0)),
    'customers', v_customers,
    'customers_debt', (select coalesce(sum(greatest((x->>'debt')::numeric, 0)), 0) from jsonb_array_elements(v_customers) x),
    'months', v_months, 'invoices', v_invoices, 'expenses', v_expenses
  );
end $$;

do $$
declare f text;
begin
  foreach f in array array[
    'assert_party_report_access(uuid)',
    'report_customer_debts(uuid, text, uuid, boolean, int, int)',
    'report_supplier_debts(uuid, text, boolean, int, int)',
    'report_customer_analysis(uuid, uuid)',
    'report_supplier_analysis(uuid, uuid)',
    'report_rep_overview(uuid, date)',
    'report_rep_analysis(uuid, uuid, date)']
  loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;

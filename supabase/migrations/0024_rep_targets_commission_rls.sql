-- Kayan — Phase 24: rep targets & commission gate, expense types, rep data isolation, notes
--
-- COMMISSION GATE (ASSUMPTION: calendar month, measured on NET sales)
--   A rep earns the commission of a month's invoices only when that month's net
--   sales (invoices − all discounts − returns booked in the month) reach the
--   rep's "minimum target for commission". Below it → 0 earned. A minimum of 0
--   means "always eligible". `invoice_commissions.earned_commission` is the one
--   number every report, the P&L and the rep screens use; the per-invoice
--   `commission_amount` stays what it always was (the potential, before the gate).
--
-- EXPENSE TYPES
--   operating / rep_expense / salary reduce profit AND treasury.
--   commission_payout reduces treasury only (the commission was already
--   deducted from profit when earned) — it settles the commission payable.

alter table sales_representatives
  add column if not exists monthly_target numeric(14,2) not null default 0 check (monthly_target >= 0),
  add column if not exists min_target_for_commission numeric(14,2) not null default 0 check (min_target_for_commission >= 0);

create or replace function check_rep_user_is_member() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if NEW.user_id is not null and not exists (
    select 1 from organization_users where organization_id = NEW.organization_id and user_id = NEW.user_id
  ) then
    raise exception 'هذا المستخدم ليس عضوًا في المؤسسة';
  end if;
  return NEW;
end $$;
create trigger rep_user_is_member before insert or update of user_id on sales_representatives
  for each row execute function check_rep_user_is_member();

-- 1. Set-based helpers for the policies (same reason as Phase 20)
create or replace function restricted_rep_org_ids() returns setof uuid
language sql security definer stable set search_path = public as $$
  select ou.organization_id
  from organization_users ou
  join roles r on r.id = ou.role_id
  where ou.user_id = auth.uid() and ou.status = 'active' and r.key = 'sales'
    and exists (select 1 from sales_representatives sr where sr.organization_id = ou.organization_id and sr.user_id = ou.user_id and sr.is_active)
$$;
create or replace function my_rep_ids() returns setof uuid
language sql security definer stable set search_path = public as $$
  select id from sales_representatives where user_id = auth.uid() and is_active
$$;
revoke all on function restricted_rep_org_ids(), my_rep_ids() from public, anon;
grant execute on function restricted_rep_org_ids(), my_rep_ids() to authenticated;

-- 2. Rep performance views (the single source for targets & commission)
create or replace view rep_monthly_performance with (security_invoker = true) as
with inv as (
  select organization_id, sales_rep_id as rep_id, date_trunc('month', invoice_date)::date as m,
         count(*) as invoices, sum(subtotal) as gross_sales, sum(discount_total) as discounts,
         sum(commission_amount) as potential_commission
  from sales_invoices where sales_rep_id is not null group by 1, 2, 3
), ret as (
  select r.organization_id, i.sales_rep_id as rep_id, date_trunc('month', r.return_date)::date as m, sum(r.total) as returns
  from sales_returns r join sales_invoices i on i.id = r.sales_invoice_id
  where i.sales_rep_id is not null group by 1, 2, 3
), col as (
  select c.organization_id, coalesce(i.sales_rep_id, cu.sales_rep_id) as rep_id,
         date_trunc('month', c.collection_date)::date as m, sum(c.amount) as collected
  from customer_collections c
  left join sales_invoices i on i.id = c.sales_invoice_id
  join customers cu on cu.id = c.customer_id
  where coalesce(i.sales_rep_id, cu.sales_rep_id) is not null group by 1, 2, 3
), keys as (
  select organization_id, rep_id, m from inv union select organization_id, rep_id, m from ret union select organization_id, rep_id, m from col
)
select k.organization_id, k.rep_id, k.m as month,
       coalesce(inv.invoices, 0) as invoices,
       coalesce(inv.gross_sales, 0) as gross_sales,
       coalesce(inv.discounts, 0) as discounts,
       coalesce(ret.returns, 0) as returns,
       coalesce(inv.gross_sales, 0) - coalesce(inv.discounts, 0) - coalesce(ret.returns, 0) as net_sales,
       coalesce(col.collected, 0) as collected,
       sr.monthly_target, sr.min_target_for_commission,
       (sr.min_target_for_commission <= 0
         or coalesce(inv.gross_sales, 0) - coalesce(inv.discounts, 0) - coalesce(ret.returns, 0) >= sr.min_target_for_commission) as commission_eligible,
       coalesce(inv.potential_commission, 0) as potential_commission,
       case when sr.min_target_for_commission <= 0
              or coalesce(inv.gross_sales, 0) - coalesce(inv.discounts, 0) - coalesce(ret.returns, 0) >= sr.min_target_for_commission
            then coalesce(inv.potential_commission, 0) else 0 end as earned_commission
from keys k
join sales_representatives sr on sr.id = k.rep_id
left join inv on inv.organization_id = k.organization_id and inv.rep_id = k.rep_id and inv.m = k.m
left join ret on ret.organization_id = k.organization_id and ret.rep_id = k.rep_id and ret.m = k.m
left join col on col.organization_id = k.organization_id and col.rep_id = k.rep_id and col.m = k.m;

create or replace view invoice_commissions with (security_invoker = true) as
select i.id as sales_invoice_id, i.organization_id, i.sales_rep_id, i.invoice_date,
       i.commission_amount as potential_commission,
       case when p.commission_eligible then i.commission_amount else 0 end as earned_commission
from sales_invoices i
left join rep_monthly_performance p
  on p.organization_id = i.organization_id and p.rep_id = i.sales_rep_id and p.month = date_trunc('month', i.invoice_date)::date
where i.sales_rep_id is not null;
grant select on rep_monthly_performance, invoice_commissions to authenticated;

-- 3. Expenses: types + optional rep link; commission payouts
alter table expenses
  add column if not exists expense_type text not null default 'operating'
    check (expense_type in ('operating', 'rep_expense', 'salary', 'commission_payout')),
  add column if not exists sales_rep_id uuid references sales_representatives(id) on delete set null;
create index if not exists expenses_rep_idx on expenses(sales_rep_id) where sales_rep_id is not null;

create or replace view operating_expenses with (security_invoker = true) as
select * from expenses where expense_type <> 'commission_payout';
grant select on operating_expenses to authenticated;

create or replace view rep_commission_balances with (security_invoker = true) as
select sr.organization_id, sr.id as rep_id,
       coalesce(e.earned, 0) as earned, coalesce(p.paid, 0) as paid,
       coalesce(e.earned, 0) - coalesce(p.paid, 0) as payable
from sales_representatives sr
left join (select organization_id, rep_id, sum(earned_commission) as earned from rep_monthly_performance group by 1, 2) e
  on e.organization_id = sr.organization_id and e.rep_id = sr.id
left join (select organization_id, sales_rep_id, sum(amount) as paid from expenses where expense_type = 'commission_payout' group by 1, 2) p
  on p.organization_id = sr.organization_id and p.sales_rep_id = sr.id;
grant select on rep_commission_balances to authenticated;

drop function if exists create_expense(uuid, uuid, uuid, numeric, date, text, text, uuid);
create or replace function create_expense(
  org_id uuid, p_category_id uuid, p_treasury_account_id uuid, p_amount numeric, p_expense_date date,
  p_payment_method text, p_description text, p_responsible_user uuid,
  p_expense_type text default 'operating', p_sales_rep_id uuid default null
)
returns uuid
language plpgsql security definer set search_path = public
as $$
declare new_expense_id uuid; account_id uuid; v_payable numeric;
begin
  if auth.uid() is null then raise exception 'يجب تسجيل الدخول أولاً'; end if;
  if not is_org_member(org_id) then raise exception 'أنت لست عضوًا في هذه المؤسسة'; end if;
  if not has_permission(org_id, 'treasury.manage') then raise exception 'ليس لديك صلاحية تسجيل المصروفات'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'يجب أن يكون المبلغ أكبر من صفر'; end if;
  if p_amount > 999999999999 then raise exception 'المبلغ كبير جدًا'; end if;
  if p_expense_type not in ('operating', 'rep_expense', 'salary', 'commission_payout') then raise exception 'نوع المصروف غير صحيح'; end if;
  if p_category_id is not null and not exists (select 1 from expense_categories where id = p_category_id and organization_id = org_id) then
    raise exception 'تصنيف المصروف لا ينتمي إلى هذه المؤسسة';
  end if;
  if p_sales_rep_id is not null and not exists (select 1 from sales_representatives where id = p_sales_rep_id and organization_id = org_id) then
    raise exception 'هذا المندوب لا ينتمي إلى هذه المؤسسة';
  end if;
  if p_expense_type in ('rep_expense', 'salary', 'commission_payout') and p_sales_rep_id is null then
    raise exception 'يجب اختيار المندوب لهذا النوع من المصروفات';
  end if;
  if p_expense_type = 'commission_payout' then
    select payable into v_payable from rep_commission_balances where rep_id = p_sales_rep_id;
    if p_amount > coalesce(v_payable, 0) then
      raise exception 'المبلغ أكبر من العمولة المستحقة للمندوب (المستحق: %)', coalesce(v_payable, 0);
    end if;
  end if;

  account_id := coalesce(p_treasury_account_id, ensure_default_treasury_account(org_id));
  if not exists (select 1 from treasury_accounts where id = account_id and organization_id = org_id) then
    raise exception 'حساب الخزنة لا ينتمي إلى هذه المؤسسة';
  end if;

  insert into expenses (organization_id, category_id, treasury_account_id, amount, expense_date, payment_method, description, responsible_user, created_by, expense_type, sales_rep_id)
  values (org_id, p_category_id, account_id, p_amount, coalesce(p_expense_date, current_date), nullif(p_payment_method, ''), nullif(p_description, ''), p_responsible_user, auth.uid(), p_expense_type, p_sales_rep_id)
  returning id into new_expense_id;

  insert into treasury_movements (organization_id, treasury_account_id, direction, amount, category, movement_date, source_type, source_id, description, created_by)
  values (org_id, account_id, 'out', p_amount, 'expense', coalesce(p_expense_date, current_date), 'expense', new_expense_id, nullif(p_description, ''), auth.uid());
  return new_expense_id;
end $$;
revoke all on function create_expense(uuid, uuid, uuid, numeric, date, text, text, uuid, text, uuid) from public, anon;
grant execute on function create_expense(uuid, uuid, uuid, numeric, date, text, text, uuid, text, uuid) to authenticated;

-- 4. Notes on customers / suppliers (never part of any calculation)
create table party_notes (
  id               uuid primary key default gen_random_uuid(),
  organization_id  uuid not null references organizations(id) on delete cascade,
  party_type       text not null check (party_type in ('customer', 'supplier')),
  customer_id      uuid references customers(id) on delete cascade,
  supplier_id      uuid references suppliers(id) on delete cascade,
  sales_invoice_id uuid references sales_invoices(id) on delete set null,
  note             text not null check (length(btrim(note)) > 0),
  created_by       uuid references auth.users(id) default auth.uid(),
  created_at       timestamptz not null default now(),
  check ((party_type = 'customer' and customer_id is not null and supplier_id is null)
      or (party_type = 'supplier' and supplier_id is not null and customer_id is null))
);
create index party_notes_customer_idx on party_notes(customer_id) where customer_id is not null;
create index party_notes_supplier_idx on party_notes(supplier_id) where supplier_id is not null;
alter table party_notes enable row level security;
create policy party_notes_select on party_notes for select using (organization_id in (select user_org_ids()));
create policy party_notes_insert on party_notes for insert with check (
  organization_id in (select user_org_ids()) and created_by = auth.uid() and (
    (party_type = 'customer' and has_permission(organization_id, 'sales.create')
       and customer_id in (select id from customers where organization_id = party_notes.organization_id))
    or (party_type = 'supplier' and has_permission(organization_id, 'purchases.create')
       and supplier_id in (select id from suppliers where organization_id = party_notes.organization_id))
  ));
grant select, insert on party_notes to authenticated;

-- 5. Reps see only their own data. RESTRICTIVE policies are AND-ed with the
--    existing ones, so nothing that already worked for other roles changes.
--    Applies to a member holding the Sales Representative role who is linked
--    to a representative record.
do $$
declare t text;
begin
  foreach t in array array['purchase_invoices','purchase_invoice_items','purchase_returns','purchase_return_items','supplier_payments',
                           'suppliers','treasury_accounts','treasury_movements','expenses','expense_categories','partners',
                           'partner_withdrawals','other_balances','audit_logs','discount_tiers','bonus_rules']
  loop
    execute format('create policy rep_scope on %I as restrictive for select using (organization_id not in (select restricted_rep_org_ids()))', t);
  end loop;
end $$;

create policy rep_scope on sales_representatives as restrictive for select
  using (organization_id not in (select restricted_rep_org_ids()) or id in (select my_rep_ids()));
create policy rep_scope on customers as restrictive for select
  using (organization_id not in (select restricted_rep_org_ids()) or sales_rep_id in (select my_rep_ids()));
create policy rep_scope on sales_invoices as restrictive for select
  using (organization_id not in (select restricted_rep_org_ids()) or sales_rep_id in (select my_rep_ids()));
create policy rep_scope on sales_invoice_items as restrictive for select
  using (organization_id not in (select restricted_rep_org_ids())
         or sales_invoice_id in (select id from sales_invoices where sales_rep_id in (select my_rep_ids())));
create policy rep_scope on customer_collections as restrictive for select
  using (organization_id not in (select restricted_rep_org_ids())
         or customer_id in (select id from customers where sales_rep_id in (select my_rep_ids())));
create policy rep_scope on sales_returns as restrictive for select
  using (organization_id not in (select restricted_rep_org_ids())
         or customer_id in (select id from customers where sales_rep_id in (select my_rep_ids())));
create policy rep_scope on sales_return_items as restrictive for select
  using (organization_id not in (select restricted_rep_org_ids())
         or sales_return_id in (select id from sales_returns where customer_id in (select id from customers where sales_rep_id in (select my_rep_ids()))));
create policy rep_scope on party_notes as restrictive for select
  using (organization_id not in (select restricted_rep_org_ids())
         or (party_type = 'customer' and customer_id in (select id from customers where sales_rep_id in (select my_rep_ids()))));

-- A rep's new customers are theirs, and they cannot hand them to someone else.
create or replace function customers_rep_guard() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if is_restricted_rep(NEW.organization_id) then
    if TG_OP = 'INSERT' then NEW.sales_rep_id := current_rep_id(NEW.organization_id);
    else NEW.sales_rep_id := OLD.sales_rep_id; end if;
  end if;
  if NEW.sales_rep_id is not null and not exists (select 1 from sales_representatives where id = NEW.sales_rep_id and organization_id = NEW.organization_id) then
    raise exception 'هذا المندوب لا ينتمي إلى هذه المؤسسة';
  end if;
  return NEW;
end $$;
create trigger customers_rep_guard before insert or update on customers for each row execute function customers_rep_guard();

-- 6. Reports read the gated commission and exclude payouts from operating expenses

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
    (select coalesce(sum(ic.earned_commission), 0) from invoice_commissions ic
     where ic.organization_id = org_id
       and (p_from is null or ic.invoice_date >= p_from)
       and (p_to is null or ic.invoice_date <= p_to)) as commissions
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
  from operating_expenses
  where organization_id = org_id
    and (p_from is null or expense_date >= p_from)
    and (p_to is null or expense_date <= p_to);

  select coalesce(jsonb_agg(jsonb_build_object('name', name, 'amount', amount) order by amount desc), '[]'::jsonb)
  into v_by_category
  from (
    select coalesce(c.name, 'بدون تصنيف') as name, sum(e.amount) as amount
    from operating_expenses e
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
      'commissions_paid', (select coalesce(sum(x.amount), 0) from expenses x
                           where x.organization_id = org_id and x.expense_type = 'commission_payout'
                             and (p_from is null or x.expense_date >= p_from) and (p_to is null or x.expense_date <= p_to)),
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
    from operating_expenses x
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
      case when fin then coalesce(sum(x.profit - x.ret_profit), 0)::numeric end,
      null::numeric,
      count(*) over ()
    from (
      select it.id, it.product_id, it.sales_invoice_id, it.quantity, it.unit_price, it.discount,
             it.line_total, it.cost_total, it.profit,
             it.allocated_discount as alloc,
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
    select i.*, coalesce(ic.earned_commission, 0) as earned_commission,
           coalesce((select sum(it.quantity) from sales_invoice_items it where it.sales_invoice_id = i.id), 0) as qty,
           coalesce((select sum(sri.quantity) from sales_return_items sri join sales_returns r on r.id = sri.sales_return_id where r.sales_invoice_id = i.id), 0) as ret_qty,
           coalesce((select sum(r.total) from sales_returns r where r.sales_invoice_id = i.id), 0) as ret_total,
           coalesce((select sum(r.cost_reversed) from sales_returns r where r.sales_invoice_id = i.id), 0) as ret_cost,
           coalesce((select sum(r.profit_reversed) from sales_returns r where r.sales_invoice_id = i.id), 0) as ret_profit
    from sales_invoices i
    left join invoice_commissions ic on ic.sales_invoice_id = i.id
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
      case when fin then coalesce(sum(i.earned_commission), 0)::numeric end as commission,
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

revoke all on function report_summary(uuid, date, date) from public, anon;
grant execute on function report_summary(uuid, date, date) to authenticated;
revoke all on function report_timeseries(uuid, date, date, text) from public, anon;
grant execute on function report_timeseries(uuid, date, date, text) to authenticated;
revoke all on function report_sales_breakdown(uuid, date, date, text, int, int) from public, anon;
grant execute on function report_sales_breakdown(uuid, date, date, text, int, int) to authenticated;

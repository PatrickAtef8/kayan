-- Kayan — Phase 5: Financial Operations
-- Treasury, Expenses, Partner Withdrawals, Sales Representatives (§29-34).
-- This also retrofits the Phase 3/4 RPCs (purchase payments, supplier
-- payments, sales collections, customer collections) to post real
-- treasury movements — §31: "every treasury movement must reference its
-- source transaction" — which is what finally makes the dashboard's
-- رصيد الخزنة card real instead of "بانتظار التفعيل".

-- ============================================================
-- 1. Treasury accounts + ledger
-- ============================================================
create table treasury_accounts (
  id                uuid primary key default gen_random_uuid(),
  organization_id   uuid not null references organizations(id) on delete cascade,
  name              text not null,
  opening_balance   numeric(14,2) not null default 0,
  is_default        boolean not null default false,
  created_at        timestamptz not null default now()
);
create index treasury_accounts_org_idx on treasury_accounts(organization_id);
-- One default account per org.
create unique index treasury_accounts_one_default on treasury_accounts(organization_id) where is_default;

create table treasury_movements (
  id                  uuid primary key default gen_random_uuid(),
  organization_id     uuid not null references organizations(id) on delete cascade,
  treasury_account_id uuid not null references treasury_accounts(id) on delete restrict,
  direction           text not null check (direction in ('in','out')),
  amount              numeric(14,2) not null check (amount > 0),
  category            text not null check (category in ('customer_collection','sales_cash','supplier_payment','expense','partner_withdrawal','other_income','other_payment')),
  movement_date       date not null default current_date,
  source_type         text,
  source_id           uuid,
  description         text,
  created_by          uuid references auth.users(id),
  created_at          timestamptz not null default now()
);
create index treasury_movements_org_idx     on treasury_movements(organization_id);
create index treasury_movements_account_idx on treasury_movements(treasury_account_id);

-- Running balance per account (opening balance + in − out), respecting RLS.
create view treasury_balances
with (security_invoker = true) as
select
  a.id as treasury_account_id,
  a.organization_id,
  a.name,
  a.opening_balance,
  a.opening_balance
    + coalesce((select sum(amount) from treasury_movements m where m.treasury_account_id = a.id and m.direction = 'in'), 0)
    - coalesce((select sum(amount) from treasury_movements m where m.treasury_account_id = a.id and m.direction = 'out'), 0)
    as balance
from treasury_accounts a;

alter table treasury_accounts  enable row level security;
alter table treasury_movements enable row level security;

create policy treasury_accounts_select on treasury_accounts for select using (is_org_member(organization_id));
create policy treasury_accounts_write  on treasury_accounts for insert with check (has_permission(organization_id, 'treasury.manage'));
create policy treasury_movements_select on treasury_movements for select using (is_org_member(organization_id));
create policy treasury_movements_write  on treasury_movements for insert with check (has_permission(organization_id, 'treasury.manage'));

grant select, insert on treasury_accounts   to authenticated;
grant select, insert on treasury_movements  to authenticated;
grant select on treasury_balances to authenticated;

-- Lazily creates "الخزنة الرئيسية" the first time an org needs one, so
-- existing organizations (created before this migration) don't need a
-- backfill step. Internal helper — SECURITY DEFINER, no permission check
-- of its own; every caller already checked treasury.manage/sales.create/
-- purchases.create before reaching here.
create or replace function ensure_default_treasury_account(org_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  account_id uuid;
begin
  select id into account_id from treasury_accounts where organization_id = org_id and is_default limit 1;
  if account_id is not null then
    return account_id;
  end if;

  insert into treasury_accounts (organization_id, name, is_default)
  values (org_id, 'الخزنة الرئيسية', true)
  returning id into account_id;

  return account_id;
end;
$$;

-- ============================================================
-- 2. Expense categories + expenses
-- ============================================================
create table expense_categories (
  id                uuid primary key default gen_random_uuid(),
  organization_id   uuid not null references organizations(id) on delete cascade,
  name              text not null,
  created_at        timestamptz not null default now(),
  unique (organization_id, name)
);
create index expense_categories_org_idx on expense_categories(organization_id);

create table expenses (
  id                    uuid primary key default gen_random_uuid(),
  organization_id       uuid not null references organizations(id) on delete cascade,
  category_id           uuid references expense_categories(id) on delete set null,
  treasury_account_id   uuid not null references treasury_accounts(id) on delete restrict,
  amount                numeric(14,2) not null check (amount > 0),
  expense_date          date not null default current_date,
  payment_method        text,
  description           text,
  responsible_user      uuid references auth.users(id),
  created_by            uuid references auth.users(id),
  created_at            timestamptz not null default now()
);
create index expenses_org_idx on expenses(organization_id);

alter table expense_categories enable row level security;
alter table expenses           enable row level security;

create policy expense_categories_select on expense_categories for select using (is_org_member(organization_id));
create policy expense_categories_write  on expense_categories for insert with check (has_permission(organization_id, 'treasury.manage'));
create policy expenses_select on expenses for select using (is_org_member(organization_id));
create policy expenses_write  on expenses for insert with check (has_permission(organization_id, 'treasury.manage'));

grant select, insert on expense_categories to authenticated;
grant select, insert on expenses           to authenticated;

-- Seeds the default category set (§30 examples) for orgs created before
-- this migration. New orgs get them via create_organization below.
insert into expense_categories (organization_id, name)
select o.id, cat
from organizations o
cross join (values ('المواصلات'), ('الرواتب'), ('الإيجار'), ('الكهرباء'), ('الإنترنت'), ('الصيانة'), ('التسويق'), ('مصروفات مكتبية'), ('أخرى')) as defaults(cat)
on conflict (organization_id, name) do nothing;

create or replace function create_expense(
  org_id uuid,
  p_category_id uuid,
  p_treasury_account_id uuid,
  p_amount numeric,
  p_expense_date date,
  p_payment_method text,
  p_description text,
  p_responsible_user uuid
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  new_expense_id uuid;
  account_id uuid;
begin
  if auth.uid() is null then
    raise exception 'يجب تسجيل الدخول أولاً';
  end if;
  if not is_org_member(org_id) then
    raise exception 'أنت لست عضوًا في هذه المؤسسة';
  end if;
  if not has_permission(org_id, 'treasury.manage') then
    raise exception 'ليس لديك صلاحية تسجيل المصروفات';
  end if;
  if p_amount <= 0 then
    raise exception 'يجب أن يكون المبلغ أكبر من صفر';
  end if;

  account_id := coalesce(p_treasury_account_id, ensure_default_treasury_account(org_id));
  if not exists (select 1 from treasury_accounts where id = account_id and organization_id = org_id) then
    raise exception 'حساب الخزنة لا ينتمي إلى هذه المؤسسة';
  end if;

  insert into expenses (organization_id, category_id, treasury_account_id, amount, expense_date, payment_method, description, responsible_user, created_by)
  values (org_id, p_category_id, account_id, p_amount, coalesce(p_expense_date, current_date), nullif(p_payment_method, ''), nullif(p_description, ''), p_responsible_user, auth.uid())
  returning id into new_expense_id;

  insert into treasury_movements (organization_id, treasury_account_id, direction, amount, category, movement_date, source_type, source_id, description, created_by)
  values (org_id, account_id, 'out', p_amount, 'expense', coalesce(p_expense_date, current_date), 'expense', new_expense_id, nullif(p_description, ''), auth.uid());

  return new_expense_id;
end;
$$;

grant execute on function create_expense(uuid, uuid, uuid, numeric, date, text, text, uuid) to authenticated;

-- ============================================================
-- 3. Partners + withdrawals
-- ============================================================
create table partners (
  id                uuid primary key default gen_random_uuid(),
  organization_id   uuid not null references organizations(id) on delete cascade,
  name              text not null,
  phone             text,
  created_at        timestamptz not null default now()
);
create index partners_org_idx on partners(organization_id);

create table partner_withdrawals (
  id                    uuid primary key default gen_random_uuid(),
  organization_id       uuid not null references organizations(id) on delete cascade,
  partner_id            uuid not null references partners(id) on delete restrict,
  treasury_account_id   uuid not null references treasury_accounts(id) on delete restrict,
  amount                numeric(14,2) not null check (amount > 0),
  withdrawal_date       date not null default current_date,
  description           text,
  notes                 text,
  created_by            uuid references auth.users(id),
  created_at            timestamptz not null default now()
);
create index partner_withdrawals_org_idx on partner_withdrawals(organization_id);

alter table partners            enable row level security;
alter table partner_withdrawals enable row level security;

create policy partners_select on partners for select using (is_org_member(organization_id));
create policy partners_write  on partners for insert with check (has_permission(organization_id, 'treasury.manage'));
create policy partner_withdrawals_select on partner_withdrawals for select using (is_org_member(organization_id));
create policy partner_withdrawals_write  on partner_withdrawals for insert with check (has_permission(organization_id, 'treasury.manage'));

grant select, insert on partners            to authenticated;
grant select, insert on partner_withdrawals to authenticated;

-- §34: withdrawals are tracked separately and must NOT automatically
-- reduce operating profit — this function only ever touches treasury and
-- partner_withdrawals, never sales_invoices/profit_total.
create or replace function record_partner_withdrawal(
  org_id uuid,
  p_partner_id uuid,
  p_treasury_account_id uuid,
  p_amount numeric,
  p_withdrawal_date date,
  p_description text,
  p_notes text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  new_withdrawal_id uuid;
  account_id uuid;
begin
  if auth.uid() is null then
    raise exception 'يجب تسجيل الدخول أولاً';
  end if;
  if not is_org_member(org_id) then
    raise exception 'أنت لست عضوًا في هذه المؤسسة';
  end if;
  if not has_permission(org_id, 'treasury.manage') then
    raise exception 'ليس لديك صلاحية تسجيل سحوبات الشركاء';
  end if;
  if not exists (select 1 from partners where id = p_partner_id and organization_id = org_id) then
    raise exception 'هذا الشريك لا ينتمي إلى هذه المؤسسة';
  end if;
  if p_amount <= 0 then
    raise exception 'يجب أن يكون المبلغ أكبر من صفر';
  end if;

  account_id := coalesce(p_treasury_account_id, ensure_default_treasury_account(org_id));

  insert into partner_withdrawals (organization_id, partner_id, treasury_account_id, amount, withdrawal_date, description, notes, created_by)
  values (org_id, p_partner_id, account_id, p_amount, coalesce(p_withdrawal_date, current_date), nullif(p_description, ''), nullif(p_notes, ''), auth.uid())
  returning id into new_withdrawal_id;

  insert into treasury_movements (organization_id, treasury_account_id, direction, amount, category, movement_date, source_type, source_id, description, created_by)
  values (org_id, account_id, 'out', p_amount, 'partner_withdrawal', coalesce(p_withdrawal_date, current_date), 'partner_withdrawal', new_withdrawal_id, nullif(p_description, ''), auth.uid());

  return new_withdrawal_id;
end;
$$;

grant execute on function record_partner_withdrawal(uuid, uuid, uuid, numeric, date, text, text) to authenticated;

-- ============================================================
-- 4. Manual "other" treasury movements — §31 lists "Other income" and
--    "Other approved payments" as movement types that don't come from
--    another module.
-- ============================================================
create or replace function record_treasury_movement(
  org_id uuid,
  p_treasury_account_id uuid,
  p_direction text,
  p_amount numeric,
  p_movement_date date,
  p_description text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  new_movement_id uuid;
  account_id uuid;
begin
  if auth.uid() is null then
    raise exception 'يجب تسجيل الدخول أولاً';
  end if;
  if not is_org_member(org_id) then
    raise exception 'أنت لست عضوًا في هذه المؤسسة';
  end if;
  if not has_permission(org_id, 'treasury.manage') then
    raise exception 'ليس لديك صلاحية تسجيل حركات الخزنة';
  end if;
  if p_direction not in ('in', 'out') then
    raise exception 'نوع الحركة غير صحيح';
  end if;
  if p_amount <= 0 then
    raise exception 'يجب أن يكون المبلغ أكبر من صفر';
  end if;

  account_id := coalesce(p_treasury_account_id, ensure_default_treasury_account(org_id));

  insert into treasury_movements (organization_id, treasury_account_id, direction, amount, category, movement_date, source_type, description, created_by)
  values (org_id, account_id, p_direction, p_amount, case when p_direction = 'in' then 'other_income' else 'other_payment' end, coalesce(p_movement_date, current_date), 'manual', nullif(p_description, ''), auth.uid())
  returning id into new_movement_id;

  return new_movement_id;
end;
$$;

grant execute on function record_treasury_movement(uuid, uuid, text, numeric, date, text) to authenticated;

-- ============================================================
-- 5. Sales representatives (§32-33)
-- ============================================================
create table sales_representatives (
  id                      uuid primary key default gen_random_uuid(),
  organization_id         uuid not null references organizations(id) on delete cascade,
  name                    text not null,
  phone                   text,
  fixed_salary            numeric(14,2) not null default 0,
  transportation_allowance numeric(14,2) not null default 0,
  -- Configurable per rep (§33: "must be confirmed by the business") rather
  -- than one global assumption — the business picks the basis when they
  -- set up each rep.
  commission_basis        text not null default 'net_sales' check (commission_basis in ('sales_value','net_sales','gross_profit','collected_amount')),
  commission_rate         numeric(5,2) not null default 0, -- percentage, e.g. 5.00 = 5%
  is_active               boolean not null default true,
  created_at              timestamptz not null default now()
);
create index sales_representatives_org_idx on sales_representatives(organization_id);

alter table sales_representatives enable row level security;
create policy sales_representatives_select on sales_representatives for select using (is_org_member(organization_id));
create policy sales_representatives_write  on sales_representatives for insert with check (has_permission(organization_id, 'manage_settings'));
create policy sales_representatives_update on sales_representatives for update using (has_permission(organization_id, 'manage_settings'));
create policy sales_representatives_delete on sales_representatives for delete using (has_permission(organization_id, 'manage_settings'));

grant select, insert, update, delete on sales_representatives to authenticated;

alter table sales_invoices
  add column sales_rep_id uuid references sales_representatives(id) on delete set null,
  add column commission_basis_snapshot text,
  add column commission_amount numeric(14,2) not null default 0;

-- ============================================================
-- 6. Retrofit create_purchase_invoice — post a real treasury movement
--    when the invoice is paid (partly or fully) at creation.
-- ============================================================
create or replace function create_purchase_invoice(
  org_id uuid,
  p_supplier_id uuid,
  p_warehouse_id uuid,
  p_invoice_number text,
  p_invoice_date date,
  items jsonb,
  p_discount_total numeric,
  p_tax_total numeric,
  p_amount_paid numeric,
  p_payment_method text,
  p_notes text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  new_invoice_id uuid;
  new_payment_id uuid;
  account_id uuid;
  item jsonb;
  v_product_id uuid;
  v_quantity numeric(14,3);
  v_unit_cost numeric(14,2);
  v_discount numeric(14,2);
  v_line_total numeric(14,2);
  v_subtotal numeric(14,2) := 0;
  v_total numeric(14,2);
  v_old_qty numeric(14,3);
  v_old_avg numeric(14,2);
  v_new_qty numeric(14,3);
  v_new_avg numeric(14,2);
  v_payment_status text;
  v_paid numeric(14,2);
begin
  if auth.uid() is null then
    raise exception 'يجب تسجيل الدخول أولاً';
  end if;
  if not is_org_member(org_id) then
    raise exception 'أنت لست عضوًا في هذه المؤسسة';
  end if;
  if not has_permission(org_id, 'purchases.create') then
    raise exception 'ليس لديك صلاحية إنشاء فواتير الشراء';
  end if;
  if not exists (select 1 from suppliers where id = p_supplier_id and organization_id = org_id) then
    raise exception 'هذا المورد لا ينتمي إلى هذه المؤسسة';
  end if;
  if not exists (select 1 from warehouses where id = p_warehouse_id and organization_id = org_id) then
    raise exception 'هذا المخزن لا ينتمي إلى هذه المؤسسة';
  end if;
  if jsonb_array_length(items) = 0 then
    raise exception 'يجب إضافة صنف واحد على الأقل لفاتورة الشراء';
  end if;

  insert into purchase_invoices (organization_id, supplier_id, warehouse_id, invoice_number, invoice_date, notes, created_by)
  values (org_id, p_supplier_id, p_warehouse_id, nullif(p_invoice_number, ''), coalesce(p_invoice_date, current_date), nullif(p_notes, ''), auth.uid())
  returning id into new_invoice_id;

  for item in select * from jsonb_array_elements(items)
  loop
    v_product_id := (item->>'product_id')::uuid;
    v_quantity := (item->>'quantity')::numeric;
    v_unit_cost := (item->>'unit_cost')::numeric;
    v_discount := coalesce((item->>'discount')::numeric, 0);

    if not exists (select 1 from products where id = v_product_id and organization_id = org_id) then
      raise exception 'أحد المنتجات المختارة لا ينتمي إلى هذه المؤسسة';
    end if;
    if v_quantity <= 0 then
      raise exception 'يجب أن تكون الكمية أكبر من صفر';
    end if;

    v_line_total := (v_quantity * v_unit_cost) - v_discount;
    v_subtotal := v_subtotal + (v_quantity * v_unit_cost);

    insert into purchase_invoice_items (organization_id, purchase_invoice_id, product_id, quantity, unit_cost, discount, line_total)
    values (org_id, new_invoice_id, v_product_id, v_quantity, v_unit_cost, v_discount, v_line_total);

    select quantity, avg_cost into v_old_qty, v_old_avg
    from inventory_stock
    where product_id = v_product_id and warehouse_id = p_warehouse_id
    for update;

    if not found then
      v_old_qty := 0;
      v_old_avg := 0;
      insert into inventory_stock (organization_id, product_id, warehouse_id, quantity, avg_cost)
      values (org_id, v_product_id, p_warehouse_id, 0, 0);
    end if;

    v_new_qty := v_old_qty + v_quantity;
    v_new_avg := case when v_new_qty = 0 then 0 else ((v_old_qty * v_old_avg) + (v_quantity * v_unit_cost)) / v_new_qty end;

    update inventory_stock
    set quantity = v_new_qty, avg_cost = v_new_avg, updated_at = now()
    where product_id = v_product_id and warehouse_id = p_warehouse_id;

    insert into inventory_movements (organization_id, product_id, warehouse_id, movement_type, quantity_delta, unit_cost, reference_type, reference_id, created_by)
    values (org_id, v_product_id, p_warehouse_id, 'purchase', v_quantity, v_unit_cost, 'purchase_invoice', new_invoice_id, auth.uid());

    update product_prices set cost = v_new_avg, updated_at = now()
    where product_id = v_product_id and organization_id = org_id;
  end loop;

  v_total := v_subtotal - coalesce(p_discount_total, 0) + coalesce(p_tax_total, 0);
  v_paid := least(coalesce(p_amount_paid, 0), v_total);
  v_payment_status := case
    when v_paid <= 0 then 'unpaid'
    when v_paid >= v_total then 'paid'
    else 'partial'
  end;

  update purchase_invoices
  set subtotal = v_subtotal,
      discount_total = coalesce(p_discount_total, 0),
      tax_total = coalesce(p_tax_total, 0),
      total = v_total,
      amount_paid = v_paid,
      payment_status = v_payment_status,
      updated_at = now()
  where id = new_invoice_id;

  if v_paid > 0 then
    account_id := ensure_default_treasury_account(org_id);

    insert into supplier_payments (organization_id, supplier_id, purchase_invoice_id, amount, payment_date, payment_method, created_by)
    values (org_id, p_supplier_id, new_invoice_id, v_paid, coalesce(p_invoice_date, current_date), nullif(p_payment_method, ''), auth.uid())
    returning id into new_payment_id;

    insert into treasury_movements (organization_id, treasury_account_id, direction, amount, category, movement_date, source_type, source_id, description, created_by)
    values (org_id, account_id, 'out', v_paid, 'supplier_payment', coalesce(p_invoice_date, current_date), 'purchase_invoice', new_invoice_id, nullif(p_notes, ''), auth.uid());
  end if;

  return new_invoice_id;
end;
$$;

-- ============================================================
-- 7. Retrofit record_supplier_payment — post a real treasury movement.
-- ============================================================
create or replace function record_supplier_payment(
  org_id uuid,
  p_supplier_id uuid,
  p_purchase_invoice_id uuid,
  p_amount numeric,
  p_payment_date date,
  p_payment_method text,
  p_reference text,
  p_notes text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  new_payment_id uuid;
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
  if not has_permission(org_id, 'treasury.manage') then
    raise exception 'ليس لديك صلاحية تسجيل المدفوعات';
  end if;
  if not exists (select 1 from suppliers where id = p_supplier_id and organization_id = org_id) then
    raise exception 'هذا المورد لا ينتمي إلى هذه المؤسسة';
  end if;
  if p_amount <= 0 then
    raise exception 'يجب أن يكون المبلغ أكبر من صفر';
  end if;

  account_id := ensure_default_treasury_account(org_id);

  insert into supplier_payments (organization_id, supplier_id, purchase_invoice_id, amount, payment_date, payment_method, reference, notes, created_by)
  values (org_id, p_supplier_id, p_purchase_invoice_id, p_amount, coalesce(p_payment_date, current_date), nullif(p_payment_method, ''), nullif(p_reference, ''), nullif(p_notes, ''), auth.uid())
  returning id into new_payment_id;

  insert into treasury_movements (organization_id, treasury_account_id, direction, amount, category, movement_date, source_type, source_id, description, created_by)
  values (org_id, account_id, 'out', p_amount, 'supplier_payment', coalesce(p_payment_date, current_date), 'supplier_payment', new_payment_id, nullif(p_notes, ''), auth.uid());

  if p_purchase_invoice_id is not null then
    select total, amount_paid into v_total, v_amount_paid
    from purchase_invoices
    where id = p_purchase_invoice_id and organization_id = org_id
    for update;

    if found then
      v_amount_paid := v_amount_paid + p_amount;
      update purchase_invoices
      set amount_paid = v_amount_paid,
          payment_status = case when v_amount_paid >= v_total then 'paid' when v_amount_paid <= 0 then 'unpaid' else 'partial' end,
          updated_at = now()
      where id = p_purchase_invoice_id;
    end if;
  end if;

  return new_payment_id;
end;
$$;

-- ============================================================
-- 8. Retrofit create_sales_invoice — adds sales-rep + commission
--    (§32-33) and posts a real treasury movement when collected at
--    creation. Signature gains p_sales_rep_id, so the old overload is
--    dropped first to avoid an ambiguous duplicate.
-- ============================================================
drop function if exists create_sales_invoice(uuid, uuid, uuid, text, date, jsonb, numeric, numeric, numeric, text, text);

create or replace function create_sales_invoice(
  org_id uuid,
  p_customer_id uuid,
  p_warehouse_id uuid,
  p_invoice_number text,
  p_invoice_date date,
  items jsonb,
  p_discount_total numeric,
  p_tax_total numeric,
  p_amount_collected numeric,
  p_payment_method text,
  p_notes text,
  p_sales_rep_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  new_invoice_id uuid;
  new_collection_id uuid;
  account_id uuid;
  item jsonb;
  v_product_id uuid;
  v_quantity numeric(14,3);
  v_unit_price numeric(14,2);
  v_discount numeric(14,2);
  v_line_total numeric(14,2);
  v_unit_cost numeric(14,2);
  v_cost_total numeric(14,2);
  v_line_profit numeric(14,2);
  v_track_inventory boolean;
  v_old_qty numeric(14,3);
  v_old_avg numeric(14,2);
  v_subtotal numeric(14,2) := 0;
  v_cogs numeric(14,2) := 0;
  v_total numeric(14,2);
  v_net_sales numeric(14,2);
  v_profit numeric(14,2);
  v_payment_status text;
  v_collected numeric(14,2);
  v_commission_basis text;
  v_commission_rate numeric(5,2);
  v_commission_amount numeric(14,2) := 0;
begin
  if auth.uid() is null then
    raise exception 'يجب تسجيل الدخول أولاً';
  end if;
  if not is_org_member(org_id) then
    raise exception 'أنت لست عضوًا في هذه المؤسسة';
  end if;
  if not has_permission(org_id, 'sales.create') then
    raise exception 'ليس لديك صلاحية إنشاء فواتير البيع';
  end if;
  if not exists (select 1 from customers where id = p_customer_id and organization_id = org_id) then
    raise exception 'هذا العميل لا ينتمي إلى هذه المؤسسة';
  end if;
  if not exists (select 1 from warehouses where id = p_warehouse_id and organization_id = org_id) then
    raise exception 'هذا المخزن لا ينتمي إلى هذه المؤسسة';
  end if;
  if jsonb_array_length(items) = 0 then
    raise exception 'يجب إضافة صنف واحد على الأقل لفاتورة البيع';
  end if;
  if p_sales_rep_id is not null and not exists (select 1 from sales_representatives where id = p_sales_rep_id and organization_id = org_id) then
    raise exception 'هذا المندوب لا ينتمي إلى هذه المؤسسة';
  end if;

  insert into sales_invoices (organization_id, customer_id, warehouse_id, invoice_number, invoice_date, notes, created_by, sales_rep_id)
  values (org_id, p_customer_id, p_warehouse_id, nullif(p_invoice_number, ''), coalesce(p_invoice_date, current_date), nullif(p_notes, ''), auth.uid(), p_sales_rep_id)
  returning id into new_invoice_id;

  for item in select * from jsonb_array_elements(items)
  loop
    v_product_id := (item->>'product_id')::uuid;
    v_quantity := (item->>'quantity')::numeric;
    v_unit_price := (item->>'unit_price')::numeric;
    v_discount := coalesce((item->>'discount')::numeric, 0);

    select track_inventory into v_track_inventory from products where id = v_product_id and organization_id = org_id;
    if not found then
      raise exception 'أحد المنتجات المختارة لا ينتمي إلى هذه المؤسسة';
    end if;
    if v_quantity <= 0 then
      raise exception 'يجب أن تكون الكمية أكبر من صفر';
    end if;

    if v_track_inventory then
      select quantity, avg_cost into v_old_qty, v_old_avg
      from inventory_stock
      where product_id = v_product_id and warehouse_id = p_warehouse_id
      for update;

      if not found then
        v_old_qty := 0;
        v_old_avg := 0;
        insert into inventory_stock (organization_id, product_id, warehouse_id, quantity, avg_cost)
        values (org_id, v_product_id, p_warehouse_id, 0, 0);
      end if;

      v_unit_cost := v_old_avg;

      update inventory_stock
      set quantity = v_old_qty - v_quantity, updated_at = now()
      where product_id = v_product_id and warehouse_id = p_warehouse_id;

      insert into inventory_movements (organization_id, product_id, warehouse_id, movement_type, quantity_delta, unit_cost, reference_type, reference_id, created_by)
      values (org_id, v_product_id, p_warehouse_id, 'sale', -v_quantity, v_unit_cost, 'sales_invoice', new_invoice_id, auth.uid());
    else
      select coalesce(cost, 0) into v_unit_cost from product_prices where product_id = v_product_id and organization_id = org_id;
      v_unit_cost := coalesce(v_unit_cost, 0);
    end if;

    v_line_total := (v_quantity * v_unit_price) - v_discount;
    v_cost_total := v_quantity * v_unit_cost;
    v_line_profit := v_line_total - v_cost_total;

    insert into sales_invoice_items (organization_id, sales_invoice_id, product_id, quantity, unit_price, discount, line_total, unit_cost, cost_total, profit)
    values (org_id, new_invoice_id, v_product_id, v_quantity, v_unit_price, v_discount, v_line_total, v_unit_cost, v_cost_total, v_line_profit);

    v_subtotal := v_subtotal + (v_quantity * v_unit_price);
    v_cogs := v_cogs + v_cost_total;
  end loop;

  v_net_sales := v_subtotal - coalesce(p_discount_total, 0);
  v_total := v_net_sales + coalesce(p_tax_total, 0);
  v_profit := v_net_sales - v_cogs;
  v_collected := least(coalesce(p_amount_collected, 0), v_total);
  v_payment_status := case
    when v_collected <= 0 then 'unpaid'
    when v_collected >= v_total then 'paid'
    else 'partial'
  end;

  -- §33: commission basis/rate is captured on the invoice at creation
  -- time (historical integrity, §48) — later rate changes on the rep
  -- never retroactively change what this invoice earned.
  if p_sales_rep_id is not null then
    select commission_basis, commission_rate into v_commission_basis, v_commission_rate
    from sales_representatives where id = p_sales_rep_id;

    v_commission_amount := case v_commission_basis
      when 'sales_value' then v_subtotal * v_commission_rate / 100
      when 'net_sales' then v_net_sales * v_commission_rate / 100
      when 'gross_profit' then v_profit * v_commission_rate / 100
      when 'collected_amount' then v_collected * v_commission_rate / 100
      else 0
    end;
  end if;

  update sales_invoices
  set subtotal = v_subtotal,
      discount_total = coalesce(p_discount_total, 0),
      tax_total = coalesce(p_tax_total, 0),
      total = v_total,
      cogs_total = v_cogs,
      profit_total = v_profit,
      amount_paid = v_collected,
      payment_status = v_payment_status,
      commission_basis_snapshot = v_commission_basis,
      commission_amount = v_commission_amount,
      updated_at = now()
  where id = new_invoice_id;

  if v_collected > 0 then
    account_id := ensure_default_treasury_account(org_id);

    insert into customer_collections (organization_id, customer_id, sales_invoice_id, amount, collection_date, payment_method, created_by)
    values (org_id, p_customer_id, new_invoice_id, v_collected, coalesce(p_invoice_date, current_date), nullif(p_payment_method, ''), auth.uid())
    returning id into new_collection_id;

    insert into treasury_movements (organization_id, treasury_account_id, direction, amount, category, movement_date, source_type, source_id, description, created_by)
    values (org_id, account_id, 'in', v_collected, 'customer_collection', coalesce(p_invoice_date, current_date), 'sales_invoice', new_invoice_id, nullif(p_notes, ''), auth.uid());
  end if;

  return new_invoice_id;
end;
$$;

grant execute on function create_sales_invoice(uuid, uuid, uuid, text, date, jsonb, numeric, numeric, numeric, text, text, uuid) to authenticated;

-- ============================================================
-- 9. Retrofit record_customer_collection — post a real treasury
--    movement, and (§33) add incremental commission for reps on the
--    'collected_amount' basis, since that basis only earns as cash
--    actually comes in, not at invoice creation.
-- ============================================================
create or replace function record_customer_collection(
  org_id uuid,
  p_customer_id uuid,
  p_sales_invoice_id uuid,
  p_amount numeric,
  p_collection_date date,
  p_payment_method text,
  p_reference text,
  p_notes text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  new_collection_id uuid;
  account_id uuid;
  v_total numeric(14,2);
  v_amount_paid numeric(14,2);
  v_sales_rep_id uuid;
  v_commission_basis text;
  v_commission_rate numeric(5,2);
begin
  if auth.uid() is null then
    raise exception 'يجب تسجيل الدخول أولاً';
  end if;
  if not is_org_member(org_id) then
    raise exception 'أنت لست عضوًا في هذه المؤسسة';
  end if;
  if not has_permission(org_id, 'treasury.manage') then
    raise exception 'ليس لديك صلاحية تسجيل التحصيلات';
  end if;
  if not exists (select 1 from customers where id = p_customer_id and organization_id = org_id) then
    raise exception 'هذا العميل لا ينتمي إلى هذه المؤسسة';
  end if;
  if p_amount <= 0 then
    raise exception 'يجب أن يكون المبلغ أكبر من صفر';
  end if;

  account_id := ensure_default_treasury_account(org_id);

  insert into customer_collections (organization_id, customer_id, sales_invoice_id, amount, collection_date, payment_method, reference, notes, created_by)
  values (org_id, p_customer_id, p_sales_invoice_id, p_amount, coalesce(p_collection_date, current_date), nullif(p_payment_method, ''), nullif(p_reference, ''), nullif(p_notes, ''), auth.uid())
  returning id into new_collection_id;

  insert into treasury_movements (organization_id, treasury_account_id, direction, amount, category, movement_date, source_type, source_id, description, created_by)
  values (org_id, account_id, 'in', p_amount, 'customer_collection', coalesce(p_collection_date, current_date), 'customer_collection', new_collection_id, nullif(p_notes, ''), auth.uid());

  if p_sales_invoice_id is not null then
    select total, amount_paid, sales_rep_id, commission_basis_snapshot
    into v_total, v_amount_paid, v_sales_rep_id, v_commission_basis
    from sales_invoices
    where id = p_sales_invoice_id and organization_id = org_id
    for update;

    if found then
      v_amount_paid := v_amount_paid + p_amount;

      if v_sales_rep_id is not null and v_commission_basis = 'collected_amount' then
        select commission_rate into v_commission_rate from sales_representatives where id = v_sales_rep_id;
        update sales_invoices
        set amount_paid = v_amount_paid,
            payment_status = case when v_amount_paid >= v_total then 'paid' when v_amount_paid <= 0 then 'unpaid' else 'partial' end,
            commission_amount = commission_amount + (p_amount * coalesce(v_commission_rate, 0) / 100),
            updated_at = now()
        where id = p_sales_invoice_id;
      else
        update sales_invoices
        set amount_paid = v_amount_paid,
            payment_status = case when v_amount_paid >= v_total then 'paid' when v_amount_paid <= 0 then 'unpaid' else 'partial' end,
            updated_at = now()
        where id = p_sales_invoice_id;
      end if;
    end if;
  end if;

  return new_collection_id;
end;
$$;

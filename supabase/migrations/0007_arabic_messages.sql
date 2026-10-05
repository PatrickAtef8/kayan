-- Kayan — Arabic-only pass
-- Two things were leaking English to the UI:
--  1. The system role display names ("Owner", "Admin", ...) seeded in 0001.
--  2. Every `raise exception` message in the Phase 1/3/4 RPC functions —
--     Postgres passes that text straight through as error.message, and it
--     was landing unfiltered in error toasts across the app.
-- This is additive (UPDATE + CREATE OR REPLACE FUNCTION), safe to run on
-- top of 0001-0006 without touching any data.

-- ============================================================
-- 1. Role display names
-- ============================================================
update roles set name = 'المالك'        where key = 'owner'   and organization_id is null;
update roles set name = 'مدير'          where key = 'admin'   and organization_id is null;
update roles set name = 'محاسب'         where key = 'accountant' and organization_id is null;
update roles set name = 'مندوب مبيعات'  where key = 'sales'   and organization_id is null;
update roles set name = 'أمين مخزن'     where key = 'warehouse' and organization_id is null;

-- ============================================================
-- 2. create_organization (0002) — translated messages
-- ============================================================
create or replace function create_organization(
  org_name text,
  org_business_type text,
  org_country text,
  org_currency text,
  org_language text,
  module_keys text[]
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  new_org_id uuid;
  owner_role_id uuid;
  mk text;
begin
  if auth.uid() is null then
    raise exception 'يجب تسجيل الدخول أولاً';
  end if;

  insert into organizations (name, business_type, country, currency, language)
  values (org_name, org_business_type, org_country, org_currency, org_language)
  returning id into new_org_id;

  select id into owner_role_id from roles where key = 'owner' and organization_id is null;

  insert into organization_users (organization_id, user_id, role_id, status)
  values (new_org_id, auth.uid(), owner_role_id, 'active');

  foreach mk in array module_keys loop
    insert into organization_modules (organization_id, module_key, enabled)
    values (new_org_id, mk, true)
    on conflict (organization_id, module_key) do nothing;
  end loop;

  return new_org_id;
end;
$$;

-- ============================================================
-- 3. create_purchase_invoice (0005) — translated messages
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
  v_payment_status := case
    when coalesce(p_amount_paid, 0) <= 0 then 'unpaid'
    when p_amount_paid >= v_total then 'paid'
    else 'partial'
  end;

  update purchase_invoices
  set subtotal = v_subtotal,
      discount_total = coalesce(p_discount_total, 0),
      tax_total = coalesce(p_tax_total, 0),
      total = v_total,
      amount_paid = least(coalesce(p_amount_paid, 0), v_total),
      payment_status = v_payment_status,
      updated_at = now()
  where id = new_invoice_id;

  if coalesce(p_amount_paid, 0) > 0 then
    insert into supplier_payments (organization_id, supplier_id, purchase_invoice_id, amount, payment_date, payment_method, created_by)
    values (org_id, p_supplier_id, new_invoice_id, least(p_amount_paid, v_total), coalesce(p_invoice_date, current_date), nullif(p_payment_method, ''), auth.uid());
  end if;

  return new_invoice_id;
end;
$$;

-- ============================================================
-- 4. record_supplier_payment (0005) — translated messages
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

  insert into supplier_payments (organization_id, supplier_id, purchase_invoice_id, amount, payment_date, payment_method, reference, notes, created_by)
  values (org_id, p_supplier_id, p_purchase_invoice_id, p_amount, coalesce(p_payment_date, current_date), nullif(p_payment_method, ''), nullif(p_reference, ''), nullif(p_notes, ''), auth.uid())
  returning id into new_payment_id;

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
-- 5. create_sales_invoice (0006) — translated messages
-- ============================================================
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
  p_notes text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  new_invoice_id uuid;
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
  v_payment_status text;
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

  insert into sales_invoices (organization_id, customer_id, warehouse_id, invoice_number, invoice_date, notes, created_by)
  values (org_id, p_customer_id, p_warehouse_id, nullif(p_invoice_number, ''), coalesce(p_invoice_date, current_date), nullif(p_notes, ''), auth.uid())
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
  v_payment_status := case
    when coalesce(p_amount_collected, 0) <= 0 then 'unpaid'
    when p_amount_collected >= v_total then 'paid'
    else 'partial'
  end;

  update sales_invoices
  set subtotal = v_subtotal,
      discount_total = coalesce(p_discount_total, 0),
      tax_total = coalesce(p_tax_total, 0),
      total = v_total,
      cogs_total = v_cogs,
      profit_total = v_net_sales - v_cogs,
      amount_paid = least(coalesce(p_amount_collected, 0), v_total),
      payment_status = v_payment_status,
      updated_at = now()
  where id = new_invoice_id;

  if coalesce(p_amount_collected, 0) > 0 then
    insert into customer_collections (organization_id, customer_id, sales_invoice_id, amount, collection_date, payment_method, created_by)
    values (org_id, p_customer_id, new_invoice_id, least(p_amount_collected, v_total), coalesce(p_invoice_date, current_date), nullif(p_payment_method, ''), auth.uid());
  end if;

  return new_invoice_id;
end;
$$;

-- ============================================================
-- 6. record_customer_collection (0006) — translated messages
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
    raise exception 'ليس لديك صلاحية تسجيل التحصيلات';
  end if;
  if not exists (select 1 from customers where id = p_customer_id and organization_id = org_id) then
    raise exception 'هذا العميل لا ينتمي إلى هذه المؤسسة';
  end if;
  if p_amount <= 0 then
    raise exception 'يجب أن يكون المبلغ أكبر من صفر';
  end if;

  insert into customer_collections (organization_id, customer_id, sales_invoice_id, amount, collection_date, payment_method, reference, notes, created_by)
  values (org_id, p_customer_id, p_sales_invoice_id, p_amount, coalesce(p_collection_date, current_date), nullif(p_payment_method, ''), nullif(p_reference, ''), nullif(p_notes, ''), auth.uid())
  returning id into new_collection_id;

  if p_sales_invoice_id is not null then
    select total, amount_paid into v_total, v_amount_paid
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
  end if;

  return new_collection_id;
end;
$$;

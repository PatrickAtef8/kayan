-- Kayan — Phase 22: discounts, tiered discounts, bonus, net (effective) unit price
--
-- One pricing engine (`_pricing`) is shared by the sales invoice RPC, the
-- purchase invoice RPC and the UI preview RPC, so what the screen shows is
-- exactly what gets posted.
--
-- Rules implemented (decisions the brief leaves open are flagged "ASSUMPTION"):
--   * Line discount            — per item, EGP (already existed on the form).
--   * Invoice discount         — optional, EGP, entered by the user.
--   * Cash discount            — optional, EGP, entered by the user. Applied ONLY
--                                when the invoice's payment method is Cash and
--                                something is actually collected/paid now;
--                                for Visa / InstaPay / anything else it is ignored.
--   * Tiered discount          — user-defined tiers (min amount → EGP discount).
--                                ASSUMPTION: measured on the invoice's own value
--                                after line discounts; the highest tier reached
--                                applies (tiers do not stack).
--   * Bonus                    — user-defined rules (buy X of A → get Y of B).
--                                ASSUMPTION: repeating by default (24 bought with
--                                a "12 → 1" rule gives 2), switchable per rule.
--   * discount_total (invoice) — now the TOTAL of every discount type, so the
--                                existing identity net = subtotal − discount_total
--                                still holds in every report.
--   * Invoice-level discounts (invoice + cash + tier) are allocated across the
--     paid lines pro-rata by line value; the last line absorbs the rounding.
--   * Bonus of the SAME product is folded into the purchased line:
--     12 × 100 + 1 bonus → 13 units, effective unit price 1200/13 = 92.31.
--     Bonus of ANOTHER product becomes its own zero-revenue line (stock and
--     COGS still move).
--   * Returns (sales and purchases) value goods at that effective price, so a
--     full return of everything gives back exactly the net amount (no rounding
--     drift) and COGS / inventory / profit reverse consistently.

-- ============================================================
-- 0. Rep identity (needed by the invoice RPCs; policies come in 0023)
-- ============================================================
alter table sales_representatives add column if not exists user_id uuid references auth.users(id) on delete set null;
create unique index if not exists sales_representatives_user_uidx on sales_representatives(organization_id, user_id) where user_id is not null;
alter table customers add column if not exists sales_rep_id uuid references sales_representatives(id) on delete set null;
create index if not exists customers_rep_idx on customers(sales_rep_id);

create or replace function current_rep_id(target_org uuid)
returns uuid language sql security definer stable set search_path = public as $$
  select sr.id from sales_representatives sr
  where sr.organization_id = target_org and sr.user_id = auth.uid() and sr.is_active
  limit 1
$$;

-- A member is "restricted to their own data" when they hold the Sales
-- Representative role AND are linked to a representative record.
create or replace function is_restricted_rep(target_org uuid)
returns boolean language sql security definer stable set search_path = public as $$
  select exists (
    select 1
    from organization_users ou
    join roles r on r.id = ou.role_id
    where ou.organization_id = target_org and ou.user_id = auth.uid() and ou.status = 'active' and r.key = 'sales'
  ) and current_rep_id(target_org) is not null
$$;
grant execute on function current_rep_id(uuid), is_restricted_rep(uuid) to authenticated;

create or replace function is_cash_payment(m text)
returns boolean language sql immutable as $$
  select lower(btrim(coalesce(m, ''))) in ('cash', 'نقدًا', 'نقدا', 'نقدي', 'نقداً', 'كاش')
$$;
grant execute on function is_cash_payment(text) to authenticated;

-- ============================================================
-- 1. Rules: tiers + bonus (shared by sales and purchases)
-- ============================================================
create table discount_tiers (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  applies_to      text not null check (applies_to in ('sales', 'purchases')),
  min_amount      numeric(14,2) not null check (min_amount > 0),
  discount_amount numeric(14,2) not null check (discount_amount > 0),
  is_active       boolean not null default true,
  created_at      timestamptz not null default now(),
  unique (organization_id, applies_to, min_amount)
);
create table bonus_rules (
  id               uuid primary key default gen_random_uuid(),
  organization_id  uuid not null references organizations(id) on delete cascade,
  applies_to       text not null check (applies_to in ('sales', 'purchases')),
  product_id       uuid not null references products(id) on delete cascade,
  min_quantity     numeric(14,3) not null check (min_quantity > 0),
  bonus_product_id uuid not null references products(id) on delete cascade,
  bonus_quantity   numeric(14,3) not null check (bonus_quantity > 0),
  is_repeating     boolean not null default true,
  is_active        boolean not null default true,
  created_at       timestamptz not null default now()
);
create index discount_tiers_org_idx on discount_tiers(organization_id, applies_to);
create index bonus_rules_org_idx on bonus_rules(organization_id, applies_to, product_id);

alter table discount_tiers enable row level security;
alter table bonus_rules    enable row level security;
create policy discount_tiers_select on discount_tiers for select using (organization_id in (select user_org_ids()));
create policy discount_tiers_write  on discount_tiers for insert with check (has_permission(organization_id, 'manage_settings'));
create policy discount_tiers_update on discount_tiers for update using (has_permission(organization_id, 'manage_settings'));
create policy discount_tiers_delete on discount_tiers for delete using (has_permission(organization_id, 'manage_settings'));
create policy bonus_rules_select on bonus_rules for select using (organization_id in (select user_org_ids()));
create policy bonus_rules_write  on bonus_rules for insert with check (has_permission(organization_id, 'manage_settings'));
create policy bonus_rules_update on bonus_rules for update using (has_permission(organization_id, 'manage_settings'));
create policy bonus_rules_delete on bonus_rules for delete using (has_permission(organization_id, 'manage_settings'));
grant select, insert, update, delete on discount_tiers, bonus_rules to authenticated;

-- A rule's products must belong to the same organization (RLS can't see that).
create or replace function check_bonus_rule_products() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from products where id = NEW.product_id and organization_id = NEW.organization_id)
     or not exists (select 1 from products where id = NEW.bonus_product_id and organization_id = NEW.organization_id) then
    raise exception 'أحد المنتجات المختارة لا ينتمي إلى هذه المؤسسة';
  end if;
  return NEW;
end $$;
create trigger bonus_rules_products before insert or update on bonus_rules for each row execute function check_bonus_rule_products();
create trigger audit_discount_tiers after insert or update or delete on discount_tiers for each row execute function audit_row_change('discount_tier', '');
create trigger audit_bonus_rules    after insert or update or delete on bonus_rules    for each row execute function audit_row_change('bonus_rule', '');

-- ============================================================
-- 2. Columns on invoices / items
-- ============================================================
alter table sales_invoices
  add column if not exists payment_method text,
  add column if not exists line_discount_total numeric(14,2) not null default 0,
  add column if not exists invoice_discount numeric(14,2) not null default 0,
  add column if not exists cash_discount numeric(14,2) not null default 0,
  add column if not exists tier_discount numeric(14,2) not null default 0,
  add column if not exists bonus_units numeric(14,3) not null default 0,
  add column if not exists bonus_cost numeric(14,2) not null default 0;
alter table purchase_invoices
  add column if not exists payment_method text,
  add column if not exists line_discount_total numeric(14,2) not null default 0,
  add column if not exists invoice_discount numeric(14,2) not null default 0,
  add column if not exists cash_discount numeric(14,2) not null default 0,
  add column if not exists tier_discount numeric(14,2) not null default 0,
  add column if not exists bonus_units numeric(14,3) not null default 0;

alter table sales_invoice_items
  add column if not exists bonus_quantity numeric(14,3) not null default 0,
  add column if not exists is_bonus boolean not null default false,
  add column if not exists allocated_discount numeric(14,2) not null default 0,
  add column if not exists net_total numeric(14,2) not null default 0,
  add column if not exists effective_unit_price numeric(14,4) not null default 0;
alter table purchase_invoice_items
  add column if not exists bonus_quantity numeric(14,3) not null default 0,
  add column if not exists is_bonus boolean not null default false,
  add column if not exists allocated_discount numeric(14,2) not null default 0,
  add column if not exists net_total numeric(14,2) not null default 0,
  add column if not exists effective_unit_cost numeric(14,4) not null default 0;

alter table sales_return_items    alter column unit_price type numeric(14,4);
alter table purchase_return_items alter column unit_cost  type numeric(14,4);

-- Backfill history: before this phase the invoice-level discount was spread
-- pro-rata by reports at read time; store that same allocation now so every
-- report keeps its numbers and returns on old invoices use the net price.
update sales_invoice_items it
set allocated_discount = case when i.subtotal > 0 then round(i.discount_total * (it.quantity * it.unit_price) / i.subtotal, 2) else 0 end
from sales_invoices i where i.id = it.sales_invoice_id;
update sales_invoice_items set net_total = line_total - allocated_discount, effective_unit_price = (line_total - allocated_discount) / quantity,
  profit = profit - allocated_discount;  -- item profit is now net of its share of invoice-level discounts
update sales_invoices set invoice_discount = discount_total;

update purchase_invoice_items it
set allocated_discount = case when i.subtotal > 0 then round(i.discount_total * (it.quantity * it.unit_cost) / i.subtotal, 2) else 0 end
from purchase_invoices i where i.id = it.purchase_invoice_id;
update purchase_invoice_items set net_total = line_total - allocated_discount, effective_unit_cost = (line_total - allocated_discount) / quantity;
update purchase_invoices set invoice_discount = discount_total;

-- ============================================================
-- 3. The pricing engine
-- ============================================================
create or replace function _pricing(
  org_id uuid, p_applies text, items jsonb,
  p_invoice_discount numeric, p_cash_discount numeric,
  p_payment_method text, p_amount_paid numeric, p_tax numeric
)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  e jsonb;
  rule record;
  v_q numeric; v_p numeric; v_d numeric;
  v_gross numeric(14,2) := 0;
  v_line_disc numeric(14,2) := 0;
  v_base numeric(14,2);
  v_tier numeric(14,2) := 0;
  v_inv numeric(14,2) := greatest(coalesce(p_invoice_discount, 0), 0);
  v_cash numeric(14,2) := 0;
  v_times numeric;
  v_bonus jsonb := '[]'::jsonb;
  v_disc numeric(14,2);
  v_net numeric(14,2);
begin
  if p_applies not in ('sales', 'purchases') then raise exception 'نوع العملية غير مدعوم'; end if;
  if items is null or jsonb_array_length(items) = 0 then
    raise exception 'يجب إضافة صنف واحد على الأقل للفاتورة';
  end if;

  for e in select * from jsonb_array_elements(items) loop
    v_q := (e->>'quantity')::numeric;
    v_p := case p_applies when 'sales' then (e->>'unit_price')::numeric else (e->>'unit_cost')::numeric end;
    v_d := coalesce((e->>'discount')::numeric, 0);
    if v_q is null or v_q <= 0 then raise exception 'يجب أن تكون الكمية أكبر من صفر'; end if;
    if v_p is null or v_p < 0 then raise exception 'السعر غير صحيح'; end if;
    if v_d < 0 or v_d > v_q * v_p then raise exception 'خصم الصنف غير صحيح'; end if;
    v_gross := v_gross + round(v_q * v_p, 2);
    v_line_disc := v_line_disc + v_d;
  end loop;
  v_base := v_gross - v_line_disc;

  select t.discount_amount into v_tier
  from discount_tiers t
  where t.organization_id = org_id and t.applies_to = p_applies and t.is_active and t.min_amount <= v_base
  order by t.min_amount desc limit 1;
  v_tier := coalesce(v_tier, 0);

  if is_cash_payment(p_payment_method) and coalesce(p_amount_paid, 0) > 0 then
    v_cash := greatest(coalesce(p_cash_discount, 0), 0);
  end if;

  if v_inv + v_cash + v_tier > v_base then
    raise exception 'إجمالي الخصومات أكبر من قيمة الفاتورة';
  end if;

  for rule in
    select r.*, agg.q
    from bonus_rules r
    join (
      select (x->>'product_id')::uuid as pid, sum((x->>'quantity')::numeric) as q
      from jsonb_array_elements(items) x group by 1
    ) agg on agg.pid = r.product_id
    where r.organization_id = org_id and r.applies_to = p_applies and r.is_active and agg.q >= r.min_quantity
    order by r.created_at, r.id
  loop
    v_times := case when rule.is_repeating then floor(rule.q / rule.min_quantity) else 1 end;
    v_bonus := v_bonus || jsonb_build_object('trigger', rule.product_id, 'product', rule.bonus_product_id, 'qty', v_times * rule.bonus_quantity);
  end loop;

  v_disc := v_line_disc + v_inv + v_cash + v_tier;
  v_net := v_gross - v_disc;
  return jsonb_build_object(
    'gross', v_gross, 'line_discount', v_line_disc, 'base', v_base,
    'tier_discount', v_tier, 'invoice_discount', v_inv, 'cash_discount', v_cash,
    'invoice_level_discount', v_inv + v_cash + v_tier,
    'discount_total', v_disc, 'net', v_net,
    'tax', coalesce(p_tax, 0), 'total', v_net + coalesce(p_tax, 0),
    'bonus', v_bonus
  );
end $$;
revoke all on function _pricing(uuid, text, jsonb, numeric, numeric, text, numeric, numeric) from public, anon, authenticated;

-- What the invoice screens call to show tiers / bonus / totals before saving.
create or replace function pricing_preview(
  org_id uuid, p_applies text, items jsonb,
  p_invoice_discount numeric default 0, p_cash_discount numeric default 0,
  p_payment_method text default null, p_amount_paid numeric default 0, p_tax numeric default 0
)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'يجب تسجيل الدخول أولاً'; end if;
  if not is_org_member(org_id) then raise exception 'أنت لست عضوًا في هذه المؤسسة'; end if;
  return _pricing(org_id, p_applies, items, p_invoice_discount, p_cash_discount, p_payment_method, p_amount_paid, p_tax);
end $$;
revoke all on function pricing_preview(uuid, text, jsonb, numeric, numeric, text, numeric, numeric) from public, anon;
grant execute on function pricing_preview(uuid, text, jsonb, numeric, numeric, text, numeric, numeric) to authenticated;

-- ============================================================
-- 4. Stock helpers (internal; callable only from the SECURITY DEFINER RPCs)
-- ============================================================
create or replace function _consume_stock(org_id uuid, p_product uuid, p_wh uuid, p_qty numeric, p_ref uuid)
returns numeric language plpgsql security definer set search_path = public as $$
declare v_track boolean; v_old_qty numeric(14,3); v_old_avg numeric(14,2); v_cost numeric(14,2);
begin
  select track_inventory into v_track from products where id = p_product and organization_id = org_id;
  if not found then raise exception 'أحد المنتجات المختارة لا ينتمي إلى هذه المؤسسة'; end if;
  if v_track then
    select quantity, avg_cost into v_old_qty, v_old_avg
    from inventory_stock where product_id = p_product and warehouse_id = p_wh for update;
    if not found then
      v_old_qty := 0; v_old_avg := 0;
      insert into inventory_stock (organization_id, product_id, warehouse_id, quantity, avg_cost) values (org_id, p_product, p_wh, 0, 0);
    end if;
    v_cost := v_old_avg;
    update inventory_stock set quantity = v_old_qty - p_qty, updated_at = now() where product_id = p_product and warehouse_id = p_wh;
    insert into inventory_movements (organization_id, product_id, warehouse_id, movement_type, quantity_delta, unit_cost, reference_type, reference_id, created_by)
    values (org_id, p_product, p_wh, 'sale', -p_qty, v_cost, 'sales_invoice', p_ref, auth.uid());
  else
    select coalesce(cost, 0) into v_cost from product_prices where product_id = p_product and organization_id = org_id limit 1;
    v_cost := coalesce(v_cost, 0);
  end if;
  return v_cost;
end $$;

create or replace function _receive_stock(org_id uuid, p_product uuid, p_wh uuid, p_qty numeric, p_unit_cost numeric, p_ref uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_old_qty numeric(14,3); v_old_avg numeric(14,2); v_new_qty numeric(14,3); v_new_avg numeric(14,2);
begin
  select quantity, avg_cost into v_old_qty, v_old_avg
  from inventory_stock where product_id = p_product and warehouse_id = p_wh for update;
  if not found then
    v_old_qty := 0; v_old_avg := 0;
    insert into inventory_stock (organization_id, product_id, warehouse_id, quantity, avg_cost) values (org_id, p_product, p_wh, 0, 0);
  end if;
  v_new_qty := v_old_qty + p_qty;
  v_new_avg := case when v_new_qty = 0 then 0 else ((v_old_qty * v_old_avg) + (p_qty * p_unit_cost)) / v_new_qty end;
  update inventory_stock set quantity = v_new_qty, avg_cost = v_new_avg, updated_at = now() where product_id = p_product and warehouse_id = p_wh;
  insert into inventory_movements (organization_id, product_id, warehouse_id, movement_type, quantity_delta, unit_cost, reference_type, reference_id, created_by)
  values (org_id, p_product, p_wh, 'purchase', p_qty, p_unit_cost, 'purchase_invoice', p_ref, auth.uid());
  update product_prices set cost = v_new_avg, updated_at = now() where product_id = p_product and organization_id = org_id;
end $$;
revoke all on function _consume_stock(uuid, uuid, uuid, numeric, uuid) from public, anon, authenticated;
revoke all on function _receive_stock(uuid, uuid, uuid, numeric, numeric, uuid) from public, anon, authenticated;

-- ============================================================
-- 5. create_sales_invoice (replaces the 12-arg version)
-- ============================================================
drop function if exists create_sales_invoice(uuid, uuid, uuid, text, date, jsonb, numeric, numeric, numeric, text, text, uuid);
create or replace function create_sales_invoice(
  org_id uuid, p_customer_id uuid, p_warehouse_id uuid, p_invoice_number text, p_invoice_date date,
  items jsonb, p_discount_total numeric, p_tax_total numeric, p_amount_collected numeric,
  p_payment_method text, p_notes text,
  p_sales_rep_id uuid default null, p_cash_discount numeric default 0
)
returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  new_invoice_id uuid;
  account_id uuid;
  e jsonb; b record;
  v_pr jsonb; v_bonus jsonb;
  v_rep uuid; v_cust_rep uuid;
  v_product_id uuid; v_q numeric(14,3); v_price numeric(14,2); v_ldisc numeric(14,2);
  v_same numeric(14,3); v_done uuid[] := '{}';
  v_idx int := 0; v_n int;
  v_base_line numeric(14,2); v_base_sum numeric(14,2); v_level numeric(14,2);
  v_alloc numeric(14,2); v_alloc_used numeric(14,2) := 0;
  v_units numeric(14,3); v_unit_cost numeric(14,2); v_cost_total numeric(14,2); v_net_line numeric(14,2);
  v_gross numeric(14,2); v_disc_total numeric(14,2); v_net numeric(14,2); v_total numeric(14,2);
  v_cogs numeric(14,2) := 0; v_bonus_units numeric(14,3) := 0; v_bonus_cost numeric(14,2) := 0;
  v_profit numeric(14,2); v_collected numeric(14,2); v_status text;
  v_commission_basis text; v_commission_rate numeric(5,2); v_commission numeric(14,2) := 0;
begin
  if auth.uid() is null then raise exception 'يجب تسجيل الدخول أولاً'; end if;
  if not is_org_member(org_id) then raise exception 'أنت لست عضوًا في هذه المؤسسة'; end if;
  if not has_permission(org_id, 'sales.create') then raise exception 'ليس لديك صلاحية إنشاء فواتير البيع'; end if;

  select sales_rep_id into v_cust_rep from customers where id = p_customer_id and organization_id = org_id;
  if not found then raise exception 'هذا العميل لا ينتمي إلى هذه المؤسسة'; end if;
  if not exists (select 1 from warehouses where id = p_warehouse_id and organization_id = org_id) then
    raise exception 'هذا المخزن لا ينتمي إلى هذه المؤسسة';
  end if;
  if items is null or jsonb_array_length(items) = 0 then
    raise exception 'يجب إضافة صنف واحد على الأقل لفاتورة البيع';
  end if;

  v_rep := p_sales_rep_id;
  if is_restricted_rep(org_id) then
    v_rep := current_rep_id(org_id);
    if v_cust_rep is distinct from v_rep then raise exception 'هذا العميل غير تابع لك'; end if;
  elsif v_rep is null then
    v_rep := v_cust_rep;
  end if;
  if v_rep is not null and not exists (select 1 from sales_representatives where id = v_rep and organization_id = org_id) then
    raise exception 'هذا المندوب لا ينتمي إلى هذه المؤسسة';
  end if;

  v_pr := _pricing(org_id, 'sales', items, p_discount_total, p_cash_discount, p_payment_method, p_amount_collected, p_tax_total);
  v_bonus := v_pr->'bonus';
  v_gross := (v_pr->>'gross')::numeric;
  v_base_sum := (v_pr->>'base')::numeric;
  v_level := (v_pr->>'invoice_level_discount')::numeric;
  v_disc_total := (v_pr->>'discount_total')::numeric;
  v_net := (v_pr->>'net')::numeric;
  v_total := (v_pr->>'total')::numeric;
  v_n := jsonb_array_length(items);

  insert into sales_invoices (organization_id, customer_id, warehouse_id, invoice_number, invoice_date, notes, created_by, sales_rep_id, payment_method)
  values (org_id, p_customer_id, p_warehouse_id, nullif(p_invoice_number, ''), coalesce(p_invoice_date, current_date), nullif(p_notes, ''), auth.uid(), v_rep, nullif(p_payment_method, ''))
  returning id into new_invoice_id;

  for e in select * from jsonb_array_elements(items) loop
    v_idx := v_idx + 1;
    v_product_id := (e->>'product_id')::uuid;
    v_q := (e->>'quantity')::numeric;
    v_price := (e->>'unit_price')::numeric;
    v_ldisc := coalesce((e->>'discount')::numeric, 0);

    v_same := 0;
    if not (v_product_id = any (v_done)) then
      select coalesce(sum((x->>'qty')::numeric), 0) into v_same
      from jsonb_array_elements(v_bonus) x
      where (x->>'trigger')::uuid = v_product_id and (x->>'product')::uuid = v_product_id;
      v_done := v_done || v_product_id;
    end if;

    v_base_line := round(v_q * v_price, 2) - v_ldisc;
    v_alloc := case
      when v_idx = v_n then v_level - v_alloc_used
      when v_base_sum > 0 then round(v_level * v_base_line / v_base_sum, 2)
      else 0 end;
    v_alloc_used := v_alloc_used + v_alloc;

    v_units := v_q + v_same;
    v_unit_cost := _consume_stock(org_id, v_product_id, p_warehouse_id, v_units, new_invoice_id);
    v_cost_total := round(v_units * v_unit_cost, 2);
    v_net_line := v_base_line - v_alloc;

    insert into sales_invoice_items (organization_id, sales_invoice_id, product_id, quantity, unit_price, discount, line_total,
                                     unit_cost, cost_total, profit, bonus_quantity, allocated_discount, net_total, effective_unit_price)
    values (org_id, new_invoice_id, v_product_id, v_q, v_price, v_ldisc, v_base_line,
            v_unit_cost, v_cost_total, v_net_line - v_cost_total, v_same, v_alloc, v_net_line, v_net_line / v_units);

    v_cogs := v_cogs + v_cost_total;
    v_bonus_units := v_bonus_units + v_same;
    v_bonus_cost := v_bonus_cost + round(v_same * v_unit_cost, 2);
  end loop;

  for b in
    select (x->>'product')::uuid as pid, sum((x->>'qty')::numeric) as q
    from jsonb_array_elements(v_bonus) x
    where (x->>'trigger') <> (x->>'product') group by 1
  loop
    v_unit_cost := _consume_stock(org_id, b.pid, p_warehouse_id, b.q, new_invoice_id);
    v_cost_total := round(b.q * v_unit_cost, 2);
    insert into sales_invoice_items (organization_id, sales_invoice_id, product_id, quantity, unit_price, discount, line_total,
                                     unit_cost, cost_total, profit, is_bonus, net_total, effective_unit_price)
    values (org_id, new_invoice_id, b.pid, b.q, 0, 0, 0, v_unit_cost, v_cost_total, -v_cost_total, true, 0, 0);
    v_cogs := v_cogs + v_cost_total;
    v_bonus_units := v_bonus_units + b.q;
    v_bonus_cost := v_bonus_cost + v_cost_total;
  end loop;

  v_profit := v_net - v_cogs;
  v_collected := least(coalesce(p_amount_collected, 0), v_total);
  v_status := case when v_collected <= 0 then 'unpaid' when v_collected >= v_total then 'paid' else 'partial' end;

  if v_rep is not null then
    select commission_basis, commission_rate into v_commission_basis, v_commission_rate from sales_representatives where id = v_rep;
    v_commission := case v_commission_basis
      when 'sales_value' then v_gross * v_commission_rate / 100
      when 'net_sales' then v_net * v_commission_rate / 100
      when 'gross_profit' then v_profit * v_commission_rate / 100
      when 'collected_amount' then v_collected * v_commission_rate / 100
      else 0 end;
  end if;

  update sales_invoices
  set subtotal = v_gross, discount_total = v_disc_total,
      line_discount_total = (v_pr->>'line_discount')::numeric,
      invoice_discount = (v_pr->>'invoice_discount')::numeric,
      cash_discount = (v_pr->>'cash_discount')::numeric,
      tier_discount = (v_pr->>'tier_discount')::numeric,
      bonus_units = v_bonus_units, bonus_cost = v_bonus_cost,
      tax_total = coalesce(p_tax_total, 0), total = v_total,
      cogs_total = v_cogs, profit_total = v_profit,
      amount_paid = v_collected, payment_status = v_status,
      commission_basis_snapshot = v_commission_basis, commission_amount = v_commission,
      updated_at = now()
  where id = new_invoice_id;

  if v_collected > 0 then
    account_id := ensure_default_treasury_account(org_id);
    insert into customer_collections (organization_id, customer_id, sales_invoice_id, amount, collection_date, payment_method, created_by)
    values (org_id, p_customer_id, new_invoice_id, v_collected, coalesce(p_invoice_date, current_date), nullif(p_payment_method, ''), auth.uid());
    insert into treasury_movements (organization_id, treasury_account_id, direction, amount, category, movement_date, source_type, source_id, description, created_by)
    values (org_id, account_id, 'in', v_collected, 'customer_collection', coalesce(p_invoice_date, current_date), 'sales_invoice', new_invoice_id, nullif(p_notes, ''), auth.uid());
  end if;

  return new_invoice_id;
end $$;
revoke all on function create_sales_invoice(uuid, uuid, uuid, text, date, jsonb, numeric, numeric, numeric, text, text, uuid, numeric) from public, anon;
grant execute on function create_sales_invoice(uuid, uuid, uuid, text, date, jsonb, numeric, numeric, numeric, text, text, uuid, numeric) to authenticated;

-- ============================================================
-- 6. create_purchase_invoice (replaces the 11-arg version)
-- ============================================================
drop function if exists create_purchase_invoice(uuid, uuid, uuid, text, date, jsonb, numeric, numeric, numeric, text, text);
create or replace function create_purchase_invoice(
  org_id uuid, p_supplier_id uuid, p_warehouse_id uuid, p_invoice_number text, p_invoice_date date,
  items jsonb, p_discount_total numeric, p_tax_total numeric, p_amount_paid numeric,
  p_payment_method text, p_notes text,
  p_cash_discount numeric default 0
)
returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  new_invoice_id uuid; account_id uuid;
  e jsonb; b record; v_pr jsonb; v_bonus jsonb;
  v_product_id uuid; v_q numeric(14,3); v_cost numeric(14,2); v_ldisc numeric(14,2);
  v_same numeric(14,3); v_done uuid[] := '{}'; v_idx int := 0; v_n int;
  v_base_line numeric(14,2); v_base_sum numeric(14,2); v_level numeric(14,2);
  v_alloc numeric(14,2); v_alloc_used numeric(14,2) := 0; v_units numeric(14,3); v_net_line numeric(14,2);
  v_gross numeric(14,2); v_disc_total numeric(14,2); v_total numeric(14,2);
  v_bonus_units numeric(14,3) := 0; v_paid numeric(14,2); v_status text;
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

  v_pr := _pricing(org_id, 'purchases', items, p_discount_total, p_cash_discount, p_payment_method, p_amount_paid, p_tax_total);
  v_bonus := v_pr->'bonus';
  v_gross := (v_pr->>'gross')::numeric; v_base_sum := (v_pr->>'base')::numeric;
  v_level := (v_pr->>'invoice_level_discount')::numeric; v_disc_total := (v_pr->>'discount_total')::numeric;
  v_total := (v_pr->>'total')::numeric; v_n := jsonb_array_length(items);

  insert into purchase_invoices (organization_id, supplier_id, warehouse_id, invoice_number, invoice_date, notes, created_by, payment_method)
  values (org_id, p_supplier_id, p_warehouse_id, nullif(p_invoice_number, ''), coalesce(p_invoice_date, current_date), nullif(p_notes, ''), auth.uid(), nullif(p_payment_method, ''))
  returning id into new_invoice_id;

  for e in select * from jsonb_array_elements(items) loop
    v_idx := v_idx + 1;
    v_product_id := (e->>'product_id')::uuid;
    v_q := (e->>'quantity')::numeric;
    v_cost := (e->>'unit_cost')::numeric;
    v_ldisc := coalesce((e->>'discount')::numeric, 0);
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

    insert into purchase_invoice_items (organization_id, purchase_invoice_id, product_id, quantity, unit_cost, discount, line_total,
                                        bonus_quantity, allocated_discount, net_total, effective_unit_cost)
    values (org_id, new_invoice_id, v_product_id, v_q, v_cost, v_ldisc, v_base_line, v_same, v_alloc, v_net_line, v_net_line / v_units);

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

  v_paid := least(coalesce(p_amount_paid, 0), v_total);
  v_status := case when v_paid <= 0 then 'unpaid' when v_paid >= v_total then 'paid' else 'partial' end;

  update purchase_invoices
  set subtotal = v_gross, discount_total = v_disc_total,
      line_discount_total = (v_pr->>'line_discount')::numeric, invoice_discount = (v_pr->>'invoice_discount')::numeric,
      cash_discount = (v_pr->>'cash_discount')::numeric, tier_discount = (v_pr->>'tier_discount')::numeric,
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
end $$;
revoke all on function create_purchase_invoice(uuid, uuid, uuid, text, date, jsonb, numeric, numeric, numeric, text, text, numeric) from public, anon;
grant execute on function create_purchase_invoice(uuid, uuid, uuid, text, date, jsonb, numeric, numeric, numeric, text, text, numeric) to authenticated;

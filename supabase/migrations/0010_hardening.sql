-- Kayan — Phase 7: Production hardening (SRS §46, §47, §49, §50, §57, §64 Phase 7)
--
-- Every change below was first reproduced as a real exploit against the
-- schema produced by migrations 0001–0009 (see docs/SECURITY_AUDIT.md for
-- the finding list), and each one is covered by supabase/tests/20_* and
-- 30_*. Nothing here changes what a legitimate user can do through the
-- application; it closes the paths that only exist when someone talks to
-- the API directly.
--
-- Read this before running it on a database that holds real data:
--   * §3  removes direct INSERT/UPDATE/DELETE on ledger tables. All app
--     writes already go through the SECURITY DEFINER RPCs, which keep
--     working (they run as the table owner).
--   * §4  audit_logs becomes readable only with the new `audit.view`
--     permission (owner, admin, accountant) and can no longer be written
--     by users.
--   * §5  disabled modules are now enforced in the database (§11).
--   * §6  a second identical financial submission within 5 seconds is
--     rejected (double-click / retry protection, §49).
--   No data is modified or deleted. Everything is additive or a
--   privilege reduction, and can be reverted by re-granting.

-- ============================================================
-- 1. Function exposure
--    * ensure_default_treasury_account is an internal helper with no
--      permission check of its own — but it was executable by everyone,
--      including anonymous callers, for ANY organization id.
--    * Postgres grants EXECUTE to PUBLIC on new functions by default, so
--      anon could call every RPC (they fail on auth.uid(), but there is no
--      reason for them to be reachable at all).
-- ============================================================
revoke all on function ensure_default_treasury_account(uuid) from public, anon, authenticated;
revoke execute on all functions in schema public from public, anon;
alter default privileges in schema public revoke execute on functions from public, anon;

-- ============================================================
-- 2. Tenant-safe treasury balance
--    treasury_balances summed movements by account id only. Combined with
--    the missing account-ownership check in the RPCs (§8) that let one
--    tenant change another tenant's cash balance. Match on organization too.
-- ============================================================
create or replace view treasury_balances
with (security_invoker = true) as
select
  a.id as treasury_account_id,
  a.organization_id,
  a.name,
  a.opening_balance,
  a.opening_balance
    + coalesce((select sum(amount) from treasury_movements m where m.treasury_account_id = a.id and m.organization_id = a.organization_id and m.direction = 'in'), 0)
    - coalesce((select sum(amount) from treasury_movements m where m.treasury_account_id = a.id and m.organization_id = a.organization_id and m.direction = 'out'), 0)
    as balance
from treasury_accounts a;

-- ============================================================
-- 3. Ledger tables are written by RPCs only (§47, §49, §52)
--    "The server must calculate authoritative financial values." Until now
--    anyone with the matching permission could INSERT a collection with no
--    treasury movement, edit an invoice's profit, or DELETE an invoice and
--    leave stock and cash inconsistent.
-- ============================================================
revoke insert, update, delete on purchase_invoices      from authenticated;
revoke insert                 on purchase_invoice_items from authenticated;
revoke insert, update         on inventory_stock        from authenticated;
revoke insert                 on inventory_movements    from authenticated;
revoke insert                 on supplier_payments      from authenticated;
revoke insert, update, delete on sales_invoices         from authenticated;
revoke insert                 on sales_invoice_items    from authenticated;
revoke insert                 on customer_collections   from authenticated;
revoke insert                 on treasury_movements     from authenticated;
revoke insert                 on expenses               from authenticated;
revoke insert                 on partner_withdrawals    from authenticated;

-- Organizations and memberships are created by create_organization() only.
revoke insert on organizations from authenticated;

-- Drop the now-unreachable write policies so a future careless GRANT does
-- not silently re-open them.
drop policy if exists purchase_invoices_write        on purchase_invoices;
drop policy if exists purchase_invoices_update       on purchase_invoices;
drop policy if exists purchase_invoices_delete       on purchase_invoices;
drop policy if exists purchase_invoice_items_write   on purchase_invoice_items;
drop policy if exists inventory_stock_write          on inventory_stock;
drop policy if exists inventory_stock_update         on inventory_stock;
drop policy if exists inventory_movements_write      on inventory_movements;
drop policy if exists supplier_payments_write        on supplier_payments;
drop policy if exists sales_invoices_write           on sales_invoices;
drop policy if exists sales_invoices_update          on sales_invoices;
drop policy if exists sales_invoices_delete          on sales_invoices;
drop policy if exists sales_invoice_items_write      on sales_invoice_items;
drop policy if exists customer_collections_write     on customer_collections;
drop policy if exists treasury_movements_write       on treasury_movements;
drop policy if exists expenses_write                 on expenses;
drop policy if exists partner_withdrawals_write      on partner_withdrawals;
drop policy if exists org_insert                     on organizations;

-- Phase 5 bug found while probing: the Partners screen edits and deletes
-- partners, but 0008 only granted SELECT/INSERT, so both silently failed
-- ("permission denied", swallowed by the server action).
grant update, delete on partners to authenticated;
create policy partners_update on partners for update
  using (has_permission(organization_id, 'treasury.manage'))
  with check (has_permission(organization_id, 'treasury.manage'));
create policy partners_delete on partners for delete
  using (has_permission(organization_id, 'treasury.manage'));

-- Membership: the "org has no members yet, so anyone may insert" escape in
-- 0001 is no longer needed (create_organization is SECURITY DEFINER).
drop policy if exists org_users_manage on organization_users;
create policy org_users_manage on organization_users
  for insert with check (has_permission(organization_id, 'manage_settings'));

-- ============================================================
-- 4. Audit log (§46): complete, tamper-resistant, permission-controlled
-- ============================================================
alter table audit_logs add column if not exists user_email text;

insert into permissions (key, description, category) values
  ('audit.view', 'View the audit log', 'settings')
on conflict (key) do nothing;

insert into role_permissions (role_id, permission_key)
select r.id, 'audit.view'
from roles r
where r.organization_id is null and r.key in ('owner', 'admin', 'accountant')
on conflict do nothing;

-- Before: every member could read every audit row and INSERT forged ones
-- attributed to any user. Now: read needs audit.view, and nobody writes
-- directly — rows come only from the triggers below.
drop policy if exists audit_select on audit_logs;
drop policy if exists audit_insert on audit_logs;
create policy audit_select on audit_logs
  for select using (has_permission(organization_id, 'audit.view'));
revoke insert on audit_logs from authenticated;

create or replace function forbid_audit_change()
returns trigger
language plpgsql
as $$
begin
  raise exception 'سجل العمليات لا يمكن تعديله أو حذفه';
end;
$$;

create trigger audit_logs_immutable
  before update or delete on audit_logs
  for each row execute function forbid_audit_change();

-- One generic trigger writes every audit row.
--   TG_ARGV[0] = entity prefix for the action ('expense' -> expense.created)
--   TG_ARGV[1] = 'final' to record the row as it stands at COMMIT. Invoices
--                are inserted as an empty header and filled in by the RPC
--                afterwards, so they use a deferred trigger and re-read the
--                finished row.
create or replace function audit_row_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row jsonb;
  v_before jsonb;
  v_after jsonb;
  v_org uuid;
  v_id uuid;
  v_claims text;
  v_email text;
begin
  if TG_OP = 'DELETE' then
    v_row := to_jsonb(OLD);
  else
    v_row := to_jsonb(NEW);
  end if;

  v_org := coalesce(v_row ->> 'organization_id', case when TG_TABLE_NAME = 'organizations' then v_row ->> 'id' end)::uuid;
  v_id := nullif(v_row ->> 'id', '')::uuid;

  if TG_OP = 'INSERT' then
    v_after := v_row;
    if TG_ARGV[1] = 'final' and v_id is not null then
      execute format('select to_jsonb(t) from public.%I t where t.id = $1', TG_TABLE_NAME) into v_after using v_id;
      v_after := coalesce(v_after, v_row);
    end if;
  elsif TG_OP = 'UPDATE' then
    v_before := to_jsonb(OLD);
    v_after := v_row;
  else
    v_before := v_row;
  end if;

  v_claims := nullif(current_setting('request.jwt.claims', true), '');
  if v_claims is not null then
    begin
      v_email := v_claims::jsonb ->> 'email';
    exception when others then
      v_email := null;
    end;
  end if;

  insert into audit_logs (organization_id, user_id, user_email, action, entity, entity_id, before_data, after_data)
  values (
    v_org, auth.uid(), v_email,
    TG_ARGV[0] || '.' || case TG_OP when 'INSERT' then 'created' when 'UPDATE' then 'updated' else 'deleted' end,
    TG_ARGV[0], v_id, v_before, v_after
  );

  return null;
end;
$$;

-- Money movements and business documents (final state, at commit)
create constraint trigger audit_sales_invoices     after insert on sales_invoices     deferrable initially deferred for each row execute function audit_row_change('sales_invoice', 'final');
create constraint trigger audit_purchase_invoices  after insert on purchase_invoices  deferrable initially deferred for each row execute function audit_row_change('purchase_invoice', 'final');
create trigger audit_customer_collections after insert on customer_collections for each row execute function audit_row_change('customer_collection', '');
create trigger audit_supplier_payments    after insert on supplier_payments    for each row execute function audit_row_change('supplier_payment', '');
create trigger audit_expenses             after insert on expenses             for each row execute function audit_row_change('expense', '');
create trigger audit_partner_withdrawals  after insert on partner_withdrawals  for each row execute function audit_row_change('partner_withdrawal', '');
create trigger audit_treasury_manual      after insert on treasury_movements   for each row when (NEW.source_type = 'manual') execute function audit_row_change('treasury_movement', '');
create trigger audit_stock_adjustments    after insert on inventory_movements  for each row when (NEW.movement_type = 'adjustment') execute function audit_row_change('inventory_adjustment', '');
create trigger audit_other_balances_ins   after insert on other_balances       for each row execute function audit_row_change('other_balance', '');
create trigger audit_other_balances_upd   after update on other_balances       for each row execute function audit_row_change('other_balance', '');

-- Configuration, people and prices
create trigger audit_product_price_change after update on product_prices       for each row when (OLD.selling_price is distinct from NEW.selling_price) execute function audit_row_change('product_price', '');
create trigger audit_representatives      after insert or update or delete on sales_representatives for each row execute function audit_row_change('sales_representative', '');
create trigger audit_modules              after insert or update or delete on organization_modules  for each row execute function audit_row_change('module', '');
create trigger audit_members              after insert or update or delete on organization_users    for each row execute function audit_row_change('user', '');
create trigger audit_organization         after update on organizations        for each row execute function audit_row_change('organization', '');
create trigger audit_customers_deleted    after delete on customers            for each row execute function audit_row_change('customer', '');
create trigger audit_suppliers_deleted    after delete on suppliers            for each row execute function audit_row_change('supplier', '');
create trigger audit_products_deleted     after delete on products             for each row execute function audit_row_change('product', '');
create trigger audit_warehouses_deleted   after delete on warehouses           for each row execute function audit_row_change('warehouse', '');
create trigger audit_partners_changed     after update or delete on partners   for each row execute function audit_row_change('partner', '');

-- ============================================================
-- 5. Disabled modules are enforced in the database (§11)
--    "Frontend hiding alone is not sufficient." A BEFORE INSERT trigger
--    fires for direct inserts AND for the SECURITY DEFINER RPCs alike, so
--    every way of creating a record is covered without touching the RPCs.
--    Core modules (products, warehouses, reports) are never blocked.
-- ============================================================
create or replace function is_module_enabled(target_org uuid, module text)
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select exists (
    select 1 from organization_modules
    where organization_id = target_org and module_key = module and enabled
  );
$$;
revoke all on function is_module_enabled(uuid, text) from public, anon;
grant execute on function is_module_enabled(uuid, text) to authenticated;

create or replace function enforce_module_enabled()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if not is_module_enabled(NEW.organization_id, TG_ARGV[0]) then
    raise exception 'هذه الوحدة غير مفعّلة لمؤسستك';
  end if;
  return NEW;
end;
$$;

-- Trigger names start with "a_" / "b_" so they run in that order (Postgres
-- fires same-event triggers alphabetically): module check first, then the
-- duplicate guard.
create trigger a_enforce_module before insert on customers            for each row execute function enforce_module_enabled('customers');
create trigger a_enforce_module before insert on suppliers            for each row execute function enforce_module_enabled('suppliers');
create trigger a_enforce_module before insert on sales_invoices       for each row execute function enforce_module_enabled('sales');
create trigger a_enforce_module before insert on purchase_invoices    for each row execute function enforce_module_enabled('purchases');
create trigger a_enforce_module before insert on expenses             for each row execute function enforce_module_enabled('expenses');
create trigger a_enforce_module before insert on partners             for each row execute function enforce_module_enabled('partners');
create trigger a_enforce_module before insert on partner_withdrawals  for each row execute function enforce_module_enabled('partners');
create trigger a_enforce_module before insert on sales_representatives for each row execute function enforce_module_enabled('representatives');
create trigger a_enforce_module before insert on treasury_movements   for each row when (NEW.source_type = 'manual') execute function enforce_module_enabled('treasury');
create trigger a_enforce_module before insert on inventory_movements  for each row when (NEW.movement_type = 'adjustment') execute function enforce_module_enabled('inventory');

-- ============================================================
-- 6. Duplicate-submission guard (§49: double payments, double collections,
--    concurrent invoice creation)
--    The forms already disable the button while saving; this is the
--    server-side backstop for double clicks, retries after a dropped
--    connection, and two tabs. An identical record by the same user
--    within 5 seconds is refused. A per-key advisory lock makes two
--    truly concurrent identical requests take turns, so the second one
--    sees the first one's committed row instead of racing past it.
--    Limits, stated honestly: it compares the columns listed per table
--    (it is not a substitute for a client-generated idempotency key), and
--    two genuinely distinct sales to the same customer, warehouse and
--    date with no invoice number inside 5 seconds would also be refused.
-- ============================================================
create or replace function guard_duplicate_submission()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cond text;
  v_key text;
  v_dup boolean;
begin
  select string_agg(format('t.%1$I is not distinct from ($3).%1$I', c), ' and ')
  into v_cond
  from unnest(TG_ARGV) as c;

  select TG_TABLE_NAME || ':' || NEW.organization_id::text || ':' || coalesce(NEW.created_by::text, '') || ':' ||
         string_agg(coalesce(to_jsonb(NEW) ->> c, ''), '|')
  into v_key
  from unnest(TG_ARGV) as c;

  perform pg_advisory_xact_lock(hashtextextended(v_key, 0));

  execute format(
    'select exists (select 1 from %I.%I t where t.organization_id = $1 and t.created_by is not distinct from $2 and t.created_at > now() - interval ''5 seconds'' and %s)',
    TG_TABLE_SCHEMA, TG_TABLE_NAME, v_cond
  ) into v_dup using NEW.organization_id, NEW.created_by, NEW;

  if v_dup then
    raise exception 'تم تسجيل عملية مطابقة منذ لحظات. راجع السجل قبل إعادة المحاولة.';
  end if;

  return NEW;
end;
$$;

create trigger b_duplicate_guard before insert on sales_invoices       for each row execute function guard_duplicate_submission('customer_id', 'warehouse_id', 'invoice_number', 'invoice_date');
create trigger b_duplicate_guard before insert on purchase_invoices    for each row execute function guard_duplicate_submission('supplier_id', 'warehouse_id', 'invoice_number', 'invoice_date');
create trigger b_duplicate_guard before insert on customer_collections for each row execute function guard_duplicate_submission('customer_id', 'sales_invoice_id', 'amount', 'collection_date', 'payment_method', 'reference');
create trigger b_duplicate_guard before insert on supplier_payments    for each row execute function guard_duplicate_submission('supplier_id', 'purchase_invoice_id', 'amount', 'payment_date', 'payment_method', 'reference');
create trigger b_duplicate_guard before insert on expenses             for each row execute function guard_duplicate_submission('category_id', 'treasury_account_id', 'amount', 'expense_date', 'description');
create trigger b_duplicate_guard before insert on partner_withdrawals  for each row execute function guard_duplicate_submission('partner_id', 'treasury_account_id', 'amount', 'withdrawal_date', 'description');
create trigger b_duplicate_guard before insert on treasury_movements   for each row when (NEW.source_type = 'manual') execute function guard_duplicate_submission('treasury_account_id', 'direction', 'amount', 'movement_date', 'description');

-- ============================================================
-- 7. Privilege escalation: protect organization owners (§50)
--    Only an owner may add, change, disable or remove an owner, and an
--    organization can never be left without an active owner by an API
--    user. Service-role / DBA operations (auth.uid() is null) are not
--    blocked, so account deletion by an operator still works.
-- ============================================================
create or replace function protect_org_owners()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_owner_role uuid;
  v_remaining int;
begin
  if auth.uid() is null then
    return coalesce(NEW, OLD);
  end if;

  select id into v_owner_role from roles where key = 'owner' and organization_id is null;

  if TG_OP = 'INSERT' then
    -- The very first member of a new organization is its owner
    -- (create_organization); after that only an owner may add another.
    if NEW.role_id = v_owner_role
       and exists (select 1 from organization_users o where o.organization_id = NEW.organization_id)
       and not exists (select 1 from organization_users o where o.organization_id = NEW.organization_id and o.user_id = auth.uid() and o.role_id = v_owner_role and o.status = 'active') then
      raise exception 'فقط المالك يمكنه إضافة مالك آخر';
    end if;
    return NEW;
  end if;

  if OLD.role_id = v_owner_role or (TG_OP = 'UPDATE' and NEW.role_id = v_owner_role) then
    if not exists (select 1 from organization_users o where o.organization_id = OLD.organization_id and o.user_id = auth.uid() and o.role_id = v_owner_role and o.status = 'active') then
      raise exception 'فقط المالك يمكنه تعديل عضوية المالك';
    end if;
  end if;

  if OLD.role_id = v_owner_role and OLD.status = 'active'
     and (TG_OP = 'DELETE' or NEW.role_id is distinct from v_owner_role or NEW.status <> 'active') then
    select count(*) into v_remaining
    from organization_users o
    where o.organization_id = OLD.organization_id and o.role_id = v_owner_role and o.status = 'active' and o.id <> OLD.id;
    if v_remaining = 0 then
      raise exception 'لا يمكن ترك المؤسسة بدون مالك';
    end if;
  end if;

  return coalesce(NEW, OLD);
end;
$$;

create trigger protect_owners
  before insert or update or delete on organization_users
  for each row execute function protect_org_owners();

-- ============================================================
-- 8. RPCs that trusted caller-supplied ids (IDOR, §50)
--    Same signatures and behaviour as 0008, plus ownership checks:
--    * record_treasury_movement / record_partner_withdrawal accepted ANY
--      treasury account id, so one tenant could post movements onto
--      another tenant's cashbox.
--    * create_expense accepted another tenant's expense category.
--    * record_customer_collection / record_supplier_payment accepted an
--      invoice that belongs to a different customer/supplier or tenant.
--    Also rejects NULL/absurd amounts with an Arabic message instead of a
--    raw database error.
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
  if p_amount is null or p_amount <= 0 then
    raise exception 'يجب أن يكون المبلغ أكبر من صفر';
  end if;
  if p_amount > 999999999999 then
    raise exception 'المبلغ كبير جدًا';
  end if;
  if p_treasury_account_id is not null
     and not exists (select 1 from treasury_accounts where id = p_treasury_account_id and organization_id = org_id) then
    raise exception 'حساب الخزنة لا ينتمي إلى هذه المؤسسة';
  end if;

  account_id := coalesce(p_treasury_account_id, ensure_default_treasury_account(org_id));

  insert into treasury_movements (organization_id, treasury_account_id, direction, amount, category, movement_date, source_type, description, created_by)
  values (org_id, account_id, p_direction, p_amount, case when p_direction = 'in' then 'other_income' else 'other_payment' end, coalesce(p_movement_date, current_date), 'manual', nullif(p_description, ''), auth.uid())
  returning id into new_movement_id;

  return new_movement_id;
end;
$$;

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
  if p_amount is null or p_amount <= 0 then
    raise exception 'يجب أن يكون المبلغ أكبر من صفر';
  end if;
  if p_amount > 999999999999 then
    raise exception 'المبلغ كبير جدًا';
  end if;
  if p_treasury_account_id is not null
     and not exists (select 1 from treasury_accounts where id = p_treasury_account_id and organization_id = org_id) then
    raise exception 'حساب الخزنة لا ينتمي إلى هذه المؤسسة';
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
  if p_amount is null or p_amount <= 0 then
    raise exception 'يجب أن يكون المبلغ أكبر من صفر';
  end if;
  if p_amount > 999999999999 then
    raise exception 'المبلغ كبير جدًا';
  end if;
  if p_category_id is not null
     and not exists (select 1 from expense_categories where id = p_category_id and organization_id = org_id) then
    raise exception 'تصنيف المصروف لا ينتمي إلى هذه المؤسسة';
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
  if p_amount is null or p_amount <= 0 then
    raise exception 'يجب أن يكون المبلغ أكبر من صفر';
  end if;
  if p_amount > 999999999999 then
    raise exception 'المبلغ كبير جدًا';
  end if;
  if p_purchase_invoice_id is not null
     and not exists (select 1 from purchase_invoices where id = p_purchase_invoice_id and organization_id = org_id and supplier_id = p_supplier_id) then
    raise exception 'هذه الفاتورة لا تخص هذا المورد';
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
-- 9. Audited manual stock adjustment (§20)
--    "Manual stock editing must be restricted and audited." The
--    inventory.adjust permission existed but there was no safe way to use
--    it: it only worked by writing inventory_stock directly, unaudited.
--    A reason is mandatory and lands in the audit log via the movement.
-- ============================================================
create or replace function adjust_inventory_stock(
  org_id uuid,
  p_product_id uuid,
  p_warehouse_id uuid,
  p_quantity_delta numeric,
  p_reason text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_old_qty numeric(14,3);
  v_avg numeric(14,2);
  v_movement_id uuid;
begin
  if auth.uid() is null then
    raise exception 'يجب تسجيل الدخول أولاً';
  end if;
  if not is_org_member(org_id) then
    raise exception 'أنت لست عضوًا في هذه المؤسسة';
  end if;
  if not has_permission(org_id, 'inventory.adjust') then
    raise exception 'ليس لديك صلاحية تسوية المخزون';
  end if;
  if not exists (select 1 from products where id = p_product_id and organization_id = org_id) then
    raise exception 'هذا المنتج لا ينتمي إلى هذه المؤسسة';
  end if;
  if not exists (select 1 from warehouses where id = p_warehouse_id and organization_id = org_id) then
    raise exception 'هذا المخزن لا ينتمي إلى هذه المؤسسة';
  end if;
  if p_quantity_delta is null or p_quantity_delta = 0 then
    raise exception 'أدخل كمية التسوية';
  end if;
  if abs(p_quantity_delta) > 999999999 then
    raise exception 'الكمية كبيرة جدًا';
  end if;
  if coalesce(trim(p_reason), '') = '' then
    raise exception 'سبب التسوية مطلوب';
  end if;

  select quantity, avg_cost into v_old_qty, v_avg
  from inventory_stock
  where product_id = p_product_id and warehouse_id = p_warehouse_id and organization_id = org_id
  for update;

  if not found then
    v_old_qty := 0;
    v_avg := 0;
    insert into inventory_stock (organization_id, product_id, warehouse_id, quantity, avg_cost)
    values (org_id, p_product_id, p_warehouse_id, 0, 0);
  end if;

  if v_old_qty + p_quantity_delta < 0 then
    raise exception 'لا يمكن أن يصبح رصيد المخزون سالبًا بسبب التسوية';
  end if;

  update inventory_stock
  set quantity = v_old_qty + p_quantity_delta, updated_at = now()
  where product_id = p_product_id and warehouse_id = p_warehouse_id and organization_id = org_id;

  insert into inventory_movements (organization_id, product_id, warehouse_id, movement_type, quantity_delta, unit_cost, reference_type, note, created_by)
  values (org_id, p_product_id, p_warehouse_id, 'adjustment', p_quantity_delta, v_avg, 'manual_adjustment', trim(p_reason), auth.uid())
  returning id into v_movement_id;

  return v_movement_id;
end;
$$;
revoke all on function adjust_inventory_stock(uuid, uuid, uuid, numeric, text) from public, anon;
grant execute on function adjust_inventory_stock(uuid, uuid, uuid, numeric, text) to authenticated;

-- ============================================================
-- 10. Onboarding: validate input, seed defaults (§10, §30)
--     * unknown module keys were stored verbatim
--     * a NULL module array crashed the function
--     * 0008 promised default expense categories for new organizations
--       ("New orgs get them via create_organization below") but never
--       delivered — new companies started with an empty category list.
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
  known_modules constant text[] := array['products','warehouses','customers','suppliers','sales','purchases','inventory','expenses','treasury','representatives','partners','offers','reports'];
  default_categories constant text[] := array['المواصلات','الرواتب','الإيجار','الكهرباء','الإنترنت','الصيانة','التسويق','مصروفات مكتبية','أخرى'];
  cat text;
begin
  if auth.uid() is null then
    raise exception 'يجب تسجيل الدخول أولاً';
  end if;
  if coalesce(trim(org_name), '') = '' then
    raise exception 'اسم الشركة مطلوب';
  end if;
  if length(org_name) > 120 then
    raise exception 'اسم الشركة طويل جدًا';
  end if;

  foreach mk in array coalesce(module_keys, array[]::text[]) loop
    if not (mk = any (known_modules)) then
      raise exception 'وحدة غير معروفة';
    end if;
  end loop;

  insert into organizations (name, business_type, country, currency, language)
  values (trim(org_name), org_business_type, coalesce(nullif(org_country, ''), 'EG'), coalesce(nullif(org_currency, ''), 'EGP'), coalesce(nullif(org_language, ''), 'ar'))
  returning id into new_org_id;

  select id into owner_role_id from roles where key = 'owner' and organization_id is null;

  insert into organization_users (organization_id, user_id, role_id, status)
  values (new_org_id, auth.uid(), owner_role_id, 'active');

  foreach mk in array coalesce(module_keys, array[]::text[]) loop
    insert into organization_modules (organization_id, module_key, enabled)
    values (new_org_id, mk, true)
    on conflict (organization_id, module_key) do nothing;
  end loop;

  foreach cat in array default_categories loop
    insert into expense_categories (organization_id, name) values (new_org_id, cat)
    on conflict (organization_id, name) do nothing;
  end loop;

  perform ensure_default_treasury_account(new_org_id);

  return new_org_id;
end;
$$;

-- ============================================================
-- 11. Performance (§57): indexes for the report and dashboard queries
-- ============================================================
create index if not exists sales_invoices_org_date_idx        on sales_invoices (organization_id, invoice_date desc);
create index if not exists sales_invoices_org_created_idx     on sales_invoices (organization_id, created_at desc);
create index if not exists sales_invoices_rep_idx             on sales_invoices (sales_rep_id) where sales_rep_id is not null;
create index if not exists sales_invoice_items_org_prod_idx   on sales_invoice_items (organization_id, product_id);
create index if not exists purchase_invoices_org_date_idx     on purchase_invoices (organization_id, invoice_date desc);
create index if not exists purchase_invoices_org_created_idx  on purchase_invoices (organization_id, created_at desc);
create index if not exists customer_collections_org_date_idx  on customer_collections (organization_id, collection_date);
create index if not exists customer_collections_invoice_idx   on customer_collections (sales_invoice_id) where sales_invoice_id is not null;
create index if not exists supplier_payments_org_date_idx     on supplier_payments (organization_id, payment_date);
create index if not exists supplier_payments_invoice_idx      on supplier_payments (purchase_invoice_id) where purchase_invoice_id is not null;
create index if not exists expenses_org_date_idx              on expenses (organization_id, expense_date);
create index if not exists treasury_movements_org_date_idx    on treasury_movements (organization_id, movement_date desc);
create index if not exists inventory_movements_org_created_idx on inventory_movements (organization_id, created_at desc);
create index if not exists audit_logs_org_created_idx         on audit_logs (organization_id, created_at desc);
create index if not exists organization_users_user_idx        on organization_users (user_id) where status = 'active';

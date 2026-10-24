-- test helpers: impersonate users the way PostgREST does, and record PASS/FAIL results
create schema if not exists lab;
create table if not exists lab.results (id serial primary key, suite text, name text, ok boolean, detail text);
truncate lab.results;

create or replace function lab.as_user(uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', uid, 'email', 'u@x.test', 'role', 'authenticated')::text, false);
  execute 'set role authenticated';
end $$;
create or replace function lab.as_anon() returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', '', false); execute 'set role anon'; end $$;
create or replace function lab.as_owner() returns void language plpgsql as $$
begin execute 'reset role'; perform set_config('request.jwt.claims', '', false); end $$;

-- run SQL as the CURRENT role; report 'ALLOWED' or 'denied: <message>'
create or replace function lab.try(q text) returns text language plpgsql as $$
begin execute q; return 'ALLOWED'; exception when others then return 'denied: ' || sqlerrm; end $$;
-- run a scalar query as the CURRENT role
create or replace function lab.val(q text) returns text language plpgsql as $$
declare r text; begin execute q into r; return coalesce(r, '<null>'); exception when others then return 'ERR: ' || sqlerrm; end $$;

-- record a result (definer so it works while impersonating; arguments are evaluated as the caller)
create or replace function lab.check(p_suite text, p_name text, p_ok boolean, p_detail text default null) returns void
language sql security definer as $$ insert into lab.results (suite, name, ok, detail) values (p_suite, p_name, coalesce(p_ok, false), p_detail) $$;

grant usage on schema lab to anon, authenticated;
grant execute on all functions in schema lab to anon, authenticated;

-- catch-all leak scan: every column whose name looks like cost/cogs/profit/margin, in every table,
-- as seen by one user. Returns the columns that actually hand that user data (count > 0).
create or replace function lab.leaks(p_user uuid) returns table(tbl text, col text, readable_nonnull bigint) language plpgsql as $$
declare r record; n bigint;
begin
  perform lab.as_user(p_user);
  for r in select c.table_name t, c.column_name cn
           from information_schema.columns c
           join information_schema.tables tt on tt.table_name = c.table_name and tt.table_schema = c.table_schema and tt.table_type = 'BASE TABLE'
           where c.table_schema = 'public' and (c.column_name ~ 'cost' or c.column_name ~ 'cogs' or c.column_name = 'profit' or c.column_name ~ 'margin' or c.column_name = 'total_value')
           order by 1, 2
  loop
    begin execute format('select count(%I) from %I', r.cn, r.t) into n; exception when others then n := -1; end;
    if n <> 0 then tbl := r.t; col := r.cn; readable_nonnull := n; return next; end if;
  end loop;
end $$;
grant execute on function lab.leaks(uuid) to authenticated, anon;

-- Fulfilment (0044): stock moves when the storekeeper confirms. These cases are about permissions, costs
-- and isolation and want goods on the shelf when an invoice is posted, so a test-only trigger confirms
-- every line at commit through the same *_core stock functions. cases/80_fulfilment.sql drives the real RPCs.
create or replace function lab.autoconfirm() returns trigger language plpgsql security definer set search_path = public as $$
declare l record; v_kind text := case TG_TABLE_NAME when 'sales_invoices' then 'sales' else 'purchase' end;
begin
  for l in select * from invoice_stock_lines
           where kind = v_kind and invoice_id = NEW.id and ordered_units > fulfilled_units + cancelled_units order by seq
  loop
    if v_kind = 'sales' then
      perform _consume_stock_core(l.organization_id, l.product_id, l.warehouse_id, l.ordered_units - l.fulfilled_units - l.cancelled_units, NEW.id);
    else
      perform set_config('kayan.batch_expiry', coalesce(l.expiry_date::text, ''), true);
      perform _receive_stock_core(l.organization_id, l.product_id, l.warehouse_id, l.ordered_units - l.fulfilled_units - l.cancelled_units, coalesce(l.unit_cost, 0), NEW.id);
    end if;
    update invoice_stock_lines set fulfilled_units = ordered_units - cancelled_units where id = l.id;
  end loop;
  perform _fulfil_refresh(v_kind, NEW.id);
  return NEW;
end $$;
create or replace function lab.autoconfirm_on() returns void language plpgsql as $$
begin
  drop trigger if exists zz_autoconfirm on sales_invoices;
  drop trigger if exists zz_autoconfirm on purchase_invoices;
  create constraint trigger zz_autoconfirm after insert on sales_invoices deferrable initially deferred for each row execute function lab.autoconfirm();
  create constraint trigger zz_autoconfirm after insert on purchase_invoices deferrable initially deferred for each row execute function lab.autoconfirm();
end $$;
create or replace function lab.autoconfirm_off() returns void language plpgsql as $$
begin
  drop trigger if exists zz_autoconfirm on sales_invoices;
  drop trigger if exists zz_autoconfirm on purchase_invoices;
end $$;
select lab.autoconfirm_on();

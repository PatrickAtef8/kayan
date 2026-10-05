-- Kayan — Phase 26: treasury summary shows sales collections minus recorded
-- expenses (by type), straight from the same treasury movements the balance uses.

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
  v_collections numeric;
  v_exp_types jsonb;
  v_exp_total numeric;
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

  -- Cash actually received from customers (incl. cash taken at the invoice) …
  select coalesce(sum(amount), 0) into v_collections
  from treasury_movements
  where organization_id = org_id and direction = 'in' and category in ('customer_collection', 'sales_cash')
    and (p_from is null or movement_date >= p_from) and (p_to is null or movement_date <= p_to);

  -- … and what was paid out as recorded expenses, split by type (operating,
  -- rep expenses, salaries, commission payouts).
  select coalesce(jsonb_agg(jsonb_build_object('type', t.expense_type, 'total', t.total) order by t.total desc), '[]'::jsonb),
         coalesce(sum(t.total), 0)
  into v_exp_types, v_exp_total
  from (
    select e.expense_type, sum(m.amount) as total
    from treasury_movements m
    join expenses e on e.id = m.source_id
    where m.organization_id = org_id and m.direction = 'out' and m.category = 'expense'
      and (p_from is null or m.movement_date >= p_from) and (p_to is null or m.movement_date <= p_to)
    group by e.expense_type
  ) t;

  return jsonb_build_object(
    'sales_collections', v_collections,
    'recorded_expenses', v_exp_total,
    'collections_minus_expenses', v_collections - v_exp_total,
    'expenses_by_type', v_exp_types,
    'opening', v_base + v_before,
    'total_in', v_in,
    'total_out', v_out,
    'closing', v_base + v_before + v_in - v_out,
    'accounts', v_accounts,
    'by_category', v_by_category
  );
end;
$$;
revoke all on function report_treasury_summary(uuid, date, date) from public, anon;
grant execute on function report_treasury_summary(uuid, date, date) to authenticated;

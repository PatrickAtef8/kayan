-- 0057 — رأس المال العام is now ONE complete figure.
--
-- Until now report_financial_position returned two numbers that shared five of their six lines:
--   general_capital = inventory + receivables + cash                  − payables − other liabilities
--   net_position    = inventory + receivables + cash + other assets   − payables − other liabilities
-- The first one counted the company's "other liabilities" but ignored its "other assets" (money the owner records
-- under أصول أخرى), so recording an asset never moved the headline figure while recording a liability did. As a
-- management figure that is lopsided: everything the business owns must be set against everything it owes.
--
-- Decision (accountant's view): رأس المال العام = all assets − all liabilities, i.e. the former net_position.
--   رأس المال العام = قيمة المخزون + مديونية العملاء + الأرصدة النقدية + أصول أخرى
--                     − مديونية الموردين − التزامات أخرى
-- Both JSON keys are kept and now carry the same value, so nothing that reads either key breaks. The screen shows
-- a single card. When no other assets are recorded the number is unchanged.
-- (Still a management figure, not statutory equity — to be confirmed with the company's accountant, as in §41.)

create or replace function public.report_financial_position(org_id uuid)
 returns jsonb
 language plpgsql
 stable
 set search_path to 'public'
as $function$
declare
  v_inventory numeric;
  v_negative int;
  v_receivables numeric;
  v_cash numeric;
  v_payables numeric;
  v_other_assets numeric;
  v_other_liabilities numeric;
  v_capital numeric;
  v_items jsonb;
begin
  perform assert_report_access(org_id, true);

  select coalesce(sum(s.quantity * coalesce(sc.avg_cost, 0)), 0) + _stock_value_pending(org_id), count(*) filter (where s.quantity < 0)
  into v_inventory, v_negative
  from inventory_stock s left join stock_costs sc on sc.stock_id = s.id where s.organization_id = org_id;

  select coalesce(sum(balance), 0) into v_receivables from customer_balances where organization_id = org_id;
  select coalesce(sum(balance), 0) into v_cash from treasury_balances where organization_id = org_id;
  select coalesce(sum(balance), 0) into v_payables from supplier_balances where organization_id = org_id;

  select
    coalesce(sum(amount) filter (where kind = 'asset'), 0),
    coalesce(sum(amount) filter (where kind = 'liability'), 0)
  into v_other_assets, v_other_liabilities
  from other_balances where organization_id = org_id and is_active;

  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'kind', kind, 'name', name, 'amount', amount, 'notes', notes) order by created_at desc), '[]'::jsonb)
  into v_items
  from other_balances where organization_id = org_id and is_active;

  v_capital := v_inventory + v_receivables + v_cash + v_other_assets - v_payables - v_other_liabilities;

  return jsonb_build_object(
    'inventory_value', v_inventory,
    'receivables', v_receivables,
    'cash', v_cash,
    'other_assets', v_other_assets,
    'payables', v_payables,
    'other_liabilities', v_other_liabilities,
    'general_capital', v_capital,
    'net_position', v_capital,
    'negative_stock_items', v_negative,
    'other_items', v_items
  );
end;
$function$;

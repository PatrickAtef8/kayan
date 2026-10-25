-- 0058 — رأس المال العام also subtracts the commissions reps have earned but the company has not paid yet.
--
-- Cash already reflects everything that was actually paid (expenses, salaries and commission payouts are all
-- treasury movements). What it cannot show is a debt that exists but has not been paid: earned commission.
-- The system already tracks it per rep (rep_commission_balances = cumulative earned − cumulative paid), so the
-- figure is taken from there — nothing is entered by hand.
--   رأس المال العام = المخزون + مديونية العملاء + النقدية + أصول أخرى
--                     − مديونية الموردين − عمولات مناديب مستحقة − التزامات أخرى
-- New JSON key: commissions_payable. general_capital and net_position keep the same (now lower) value.

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
  v_commissions numeric;
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

  -- commissions the reps have earned and the company has not paid yet (all months). An overpaid rep is not a debt of
  -- the company, so only positive balances count and an overpayment never hides what another rep is owed.
  select coalesce(sum(greatest(payable, 0)), 0) into v_commissions from rep_commission_balances where organization_id = org_id;

  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'kind', kind, 'name', name, 'amount', amount, 'notes', notes) order by created_at desc), '[]'::jsonb)
  into v_items
  from other_balances where organization_id = org_id and is_active;

  v_capital := v_inventory + v_receivables + v_cash + v_other_assets - v_payables - v_commissions - v_other_liabilities;

  return jsonb_build_object(
    'inventory_value', v_inventory,
    'receivables', v_receivables,
    'cash', v_cash,
    'other_assets', v_other_assets,
    'payables', v_payables,
    'commissions_payable', v_commissions,
    'other_liabilities', v_other_liabilities,
    'general_capital', v_capital,
    'net_position', v_capital,
    'negative_stock_items', v_negative,
    'other_items', v_items
  );
end;
$function$;

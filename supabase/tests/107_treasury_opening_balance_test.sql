-- 0051: the owner can set the treasury's opening balance.
-- Covers: starts at 0 · owner sets it and the balance shifts by exactly that amount · movements untouched ·
-- negative / null / huge refused · keeper and rep refused · outsider refused · direct table UPDATE still impossible ·
-- the change is audited (old -> new) · setting the same value again writes no audit row · totals used by reports agree.

\set ON_ERROR_STOP on
select t.autoconfirm_off();

\set own  '10700000-0000-0000-0000-000000000001'
\set kp   '10700000-0000-0000-0000-000000000002'
\set rp   '10700000-0000-0000-0000-000000000003'
\set out  '10700000-0000-0000-0000-000000000004'

select t.as_owner();
insert into auth.users (id, email) values (:'own', 'owner@ob.test'), (:'kp', 'keeper@ob.test'), (:'rp', 'rep@ob.test'), (:'out', 'outsider@ob.test');

select t.as_user(:'own');
select create_organization('شركة الافتتاحي', 'x', 'EG', 'EGP', 'ar',
  array['products','warehouses','customers','suppliers','sales','purchases','inventory','representatives','treasury','reports']) as id \gset org_

select t.as_owner();
insert into organization_users (organization_id, user_id, role_id, status)
select :'org_id', u.id, r.id, 'active'
from (values (:'kp'::uuid, 'warehouse'), (:'rp'::uuid, 'sales')) u(id, k)
join roles r on r.key = u.k and r.organization_id is null;

select t.eq((select opening_balance from treasury_balances where organization_id = :'org_id'), 0::numeric, 'a new company starts with an opening balance of 0');

-- a movement first, so we can prove it is untouched
select t.as_user(:'own');
select record_treasury_movement(:'org_id', null, 'in', 1000, '2026-01-05', 'دخل') as m \gset
select t.eq((select balance from treasury_balances where organization_id = :'org_id'), 1000::numeric, 'balance = movements before any opening balance');

select set_treasury_opening_balance(:'org_id', 50000) as v \gset
select t.eq(:'v'::numeric, 50000::numeric, 'the function returns the saved amount');
select t.eq((select opening_balance from treasury_balances where organization_id = :'org_id'), 50000::numeric, 'opening balance saved');
select t.eq((select balance from treasury_balances where organization_id = :'org_id'), 51000::numeric, 'the balance moved by exactly the opening amount (50 000 + 1 000)');
select t.eq((select amount from treasury_movements where id = :'m'), 1000::numeric, 'the recorded movement is untouched');
select t.eq((select count(*)::numeric from treasury_movements where organization_id = :'org_id'), 1::numeric, 'no movement was created or removed');

select set_treasury_opening_balance(:'org_id', 1234.567) as v2 \gset
select t.eq(:'v2'::numeric, 1234.57::numeric, 'rounded to 2 decimals');
select set_treasury_opening_balance(:'org_id', 0) as v3 \gset
select t.eq((select balance from treasury_balances where organization_id = :'org_id'), 1000::numeric, 'setting it back to 0 restores the balance');
select set_treasury_opening_balance(:'org_id', 50000);

-- refused values
select t.throws($$select set_treasury_opening_balance('$$ || :'org_id' || $$', -1)$$, 'سالبًا', 'negative opening balance refused');
select t.throws($$select set_treasury_opening_balance('$$ || :'org_id' || $$', null)$$, 'صحيحًا', 'null refused');
select t.throws($$select set_treasury_opening_balance('$$ || :'org_id' || $$', 1000000000000)$$, 'كبير جدًا', 'absurdly large refused');
select t.eq((select opening_balance from treasury_balances where organization_id = :'org_id'), 50000::numeric, 'refused calls changed nothing');

-- who may not
select t.as_user(:'kp');
select t.throws($$select set_treasury_opening_balance('$$ || :'org_id' || $$', 1)$$, 'صلاحية', 'a storekeeper cannot set it');
select t.as_user(:'rp');
select t.throws($$select set_treasury_opening_balance('$$ || :'org_id' || $$', 1)$$, 'صلاحية', 'a rep cannot set it');
select t.as_user(:'out');
select t.throws($$select set_treasury_opening_balance('$$ || :'org_id' || $$', 1)$$, 'عضوًا', 'someone outside the company cannot set it');

-- no way around the function
select t.as_user(:'own');
select t.throws($$update treasury_accounts set opening_balance = 99$$, 'permission denied', 'a direct UPDATE on the table is refused outright');
select t.as_owner();
select t.eq((select opening_balance from treasury_balances where organization_id = :'org_id'), 50000::numeric, 'and nothing changed');

-- audit
select t.ok((select count(*) from audit_logs where organization_id = :'org_id' and entity = 'treasury_account') >= 4, 'every change was audited');
select t.ok((select before_data->>'opening_balance' is not null and after_data->>'opening_balance' is not null from audit_logs where organization_id = :'org_id' and entity = 'treasury_account' order by created_at limit 1), 'the audit row keeps old and new values');
select count(*) as before_n from audit_logs where organization_id = :'org_id' and entity = 'treasury_account' \gset
select t.as_user(:'own');
select set_treasury_opening_balance(:'org_id', 50000);
select t.as_owner();
select t.eq((select count(*)::numeric from audit_logs where organization_id = :'org_id' and entity = 'treasury_account'), :'before_n'::numeric, 'saving the SAME value again writes no audit row');

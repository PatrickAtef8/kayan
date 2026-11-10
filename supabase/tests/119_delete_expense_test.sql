\set ON_ERROR_STOP on
select t.autoconfirm_off();

select t.as_owner();
insert into auth.users (id, email) values
  ('11900000-0000-0000-0000-000000000001', 'exp-owner@exp.test'),
  ('11900000-0000-0000-0000-000000000002', 'exp-other@exp.test');

select t.as_user('11900000-0000-0000-0000-000000000001');
select create_organization('شركة المصروفات', 'x', 'EG', 'EGP', 'ar', array['expenses','treasury']) as id \gset e_
select t.as_user('11900000-0000-0000-0000-000000000002');
select create_organization('شركة أخرى', 'x', 'EG', 'EGP', 'ar', array['expenses','treasury']) as id \gset o_

select t.as_user('11900000-0000-0000-0000-000000000001');
select create_expense(:'e_id', null, null, 150, current_date, 'cash', 'إيجار', '11900000-0000-0000-0000-000000000001', 'operating', null) as id \gset x_
select t.eq((select count(*) from expenses where id = :'x_id'), 1, 'the expense exists');
select t.eq((select count(*) from treasury_movements where source_type = 'expense' and source_id = :'x_id'), 1, 'it moved cash out of the treasury');

-- somebody from another company cannot delete it
select t.as_user('11900000-0000-0000-0000-000000000002');
select t.throws(format($q$select delete_expense(%L, %L)$q$, :'e_id', :'x_id'), 'عضوًا', 'a non-member cannot delete it');

-- the owner can; cash comes back, the audit trail records it
select t.as_user('11900000-0000-0000-0000-000000000001');
select delete_expense(:'e_id', :'x_id');
select t.eq((select count(*) from expenses where id = :'x_id'), 0, 'the expense is gone');
select t.eq((select count(*) from treasury_movements where source_type = 'expense' and source_id = :'x_id'), 0, 'its treasury movement is gone, so the balance is restored');
select t.eq((select count(*) from audit_logs where organization_id = :'e_id' and action = 'expense.deleted' and entity_id = :'x_id'), 1, 'the deletion is in the audit trail');
select t.throws(format($q$select delete_expense(%L, %L)$q$, :'e_id', :'x_id'), 'غير موجود', 'deleting twice is reported, not silent');

-- a plain DELETE is still not allowed from a session
select create_expense(:'e_id', null, null, 20, current_date, null, 'x', '11900000-0000-0000-0000-000000000001', 'operating', null) as id \gset y_
select t.throws(format($q$delete from expenses where id = %L$q$, :'y_id'), 'permission denied', 'no direct DELETE');

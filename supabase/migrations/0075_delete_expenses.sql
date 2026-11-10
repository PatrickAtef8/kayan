-- 0075: an expense can be deleted by the person who may record it.
--
-- Until now expenses were insert-only (0070 revoked delete/update from every browser role), so a wrong or duplicated expense could never
-- be removed. A plain DELETE is still not granted: the only way is delete_expense(), which in ONE transaction
--   * checks the caller may manage the treasury of that company,
--   * removes the treasury movement the expense created (so the treasury balance, the cash report and the dashboard move back),
--   * removes the expense's attachment records,
--   * removes the expense itself (rep expenses / salaries / commission payouts are derived from this table, so rep balances move back too),
--   * and writes «expense.deleted» to the audit trail with the full row as it was (the audit page already lists it).
-- Reports, balances and the dashboard read from `expenses` / `treasury_movements` directly, so nothing else needs touching.

create trigger audit_expenses_deleted after delete on expenses for each row execute function audit_row_change('expense', '');

create or replace function delete_expense(org_id uuid, p_expense_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'يجب تسجيل الدخول أولاً';
  end if;
  if not is_org_member(org_id) then
    raise exception 'أنت لست عضوًا في هذه المؤسسة';
  end if;
  if not has_permission(org_id, 'treasury.manage') then
    raise exception 'ليس لديك صلاحية حذف المصروفات';
  end if;

  perform 1 from expenses where id = p_expense_id and organization_id = org_id for update;
  if not found then
    raise exception 'المصروف غير موجود أو تم حذفه بالفعل';
  end if;

  delete from treasury_movements where organization_id = org_id and source_type = 'expense' and source_id = p_expense_id;
  delete from attachments       where organization_id = org_id and entity_type = 'expense'  and entity_id = p_expense_id;
  delete from expenses          where id = p_expense_id and organization_id = org_id;
end;
$$;

revoke all on function delete_expense(uuid, uuid) from public, anon;
grant execute on function delete_expense(uuid, uuid) to authenticated;

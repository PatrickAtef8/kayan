-- Kayan — 0051: let the owner set the treasury's OPENING BALANCE (the cash that existed before the first record).
-- Until now treasury_accounts.opening_balance was created as 0 and nothing could change it, so a business that
-- started with cash in hand always showed a balance that was too low by exactly that amount.
-- Re-runnable. Only a function + an audit trigger: no movement, invoice or stock logic is touched.

create or replace function set_treasury_opening_balance(org_id uuid, p_amount numeric)
returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare
  account_id uuid;
  v_amount numeric(14,2);
begin
  if auth.uid() is null then
    raise exception 'يجب تسجيل الدخول أولاً';
  end if;
  if not is_org_member(org_id) then
    raise exception 'أنت لست عضوًا في هذه المؤسسة';
  end if;
  if not has_permission(org_id, 'treasury.manage') then
    raise exception 'ليس لديك صلاحية تعديل الرصيد الافتتاحي للخزنة';
  end if;
  if p_amount is null then
    raise exception 'أدخل مبلغًا صحيحًا';
  end if;
  if p_amount < 0 then
    raise exception 'الرصيد الافتتاحي لا يمكن أن يكون سالبًا';
  end if;
  if p_amount > 999999999999 then
    raise exception 'المبلغ كبير جدًا';
  end if;

  v_amount := round(p_amount, 2);
  account_id := ensure_default_treasury_account(org_id);
  update treasury_accounts set opening_balance = v_amount where id = account_id and organization_id = org_id;
  return v_amount;
end;
$$;
revoke all on function set_treasury_opening_balance(uuid, numeric) from public, anon;
grant execute on function set_treasury_opening_balance(uuid, numeric) to authenticated;

-- Changing the starting cash shifts every balance, so it is always written to the audit log (who, when, old -> new).
drop trigger if exists audit_treasury_opening on treasury_accounts;
create trigger audit_treasury_opening
  after update of opening_balance on treasury_accounts
  for each row when (OLD.opening_balance is distinct from NEW.opening_balance)
  execute function audit_row_change('treasury_account', '');

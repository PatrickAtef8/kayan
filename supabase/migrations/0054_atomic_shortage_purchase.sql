-- Kayan — 0054: saving a purchase invoice FROM a shortage report and linking it to that report is ONE transaction.
--
-- BEFORE: the app called create_purchase_invoice and then, as a second request, link_shortage_to_purchase.
--   Two transactions: if the link was refused (report resolved / superseded in the meantime, another purchase already
--   covers the shortage, the product is not on the invoice ...) the invoice stayed saved and the owner got only a warning —
--   an invoice (with its stock-in order for the storekeeper, notifications and a supplier balance) tied to no report.
-- NOW: one SECURITY INVOKER function runs both calls inside a single statement. Any error raised by the link step
--   propagates, PostgreSQL rolls the whole statement back, and nothing remains: no invoice, no lines, no notifications,
--   no supplier balance, and the invoice number counter (0053) is not consumed either.
--   SECURITY INVOKER on purpose: the two functions it calls do their own permission checks for the signed-in user,
--   so this wrapper gives nobody any power they did not already have.

create or replace function create_purchase_invoice_for_shortage(
  org_id uuid, p_report_id uuid,
  p_supplier_id uuid, p_warehouse_id uuid, p_invoice_number text, p_invoice_date date, items jsonb,
  p_discount_pct numeric, p_tax_total numeric, p_amount_paid numeric, p_payment_method text, p_notes text,
  p_cash_discount_pct numeric, p_bonus_items jsonb, p_due_date date,
  p_additional boolean default false
) returns jsonb
language plpgsql set search_path = public as $$
declare
  v_invoice uuid;
  v_link jsonb;
begin
  if auth.uid() is null then raise exception 'يجب تسجيل الدخول أولاً'; end if;
  if p_report_id is null then raise exception 'بلاغ النقص مطلوب'; end if;
  -- fail before doing any work for someone who may not link anyway (the link function re-checks everything)
  if not is_org_member(org_id) then raise exception 'أنت لست عضوًا في هذه المؤسسة'; end if;
  if not is_org_owner(org_id) then raise exception 'ربط بلاغ النقص بفاتورة شراء للمالك فقط'; end if;

  v_invoice := create_purchase_invoice(
    org_id, p_supplier_id, p_warehouse_id, p_invoice_number, p_invoice_date, items,
    p_discount_pct, p_tax_total, p_amount_paid, p_payment_method, p_notes,
    p_cash_discount_pct, p_bonus_items, p_due_date);

  -- NO exception handler here, deliberately: a failing link must undo the invoice above.
  v_link := link_shortage_to_purchase(org_id, p_report_id, v_invoice, coalesce(p_additional, false));

  return jsonb_build_object('purchase_invoice_id', v_invoice, 'report_id', p_report_id, 'status', v_link->>'status');
end $$;

revoke all on function create_purchase_invoice_for_shortage(uuid, uuid, uuid, uuid, text, date, jsonb, numeric, numeric, numeric, text, text, numeric, jsonb, date, boolean) from public, anon;
grant execute on function create_purchase_invoice_for_shortage(uuid, uuid, uuid, uuid, text, date, jsonb, numeric, numeric, numeric, text, text, numeric, jsonb, date, boolean) to authenticated;

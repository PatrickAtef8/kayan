-- Kayan — Phase 14: Global Search (§44)
--
-- §44 asks for search "by name, invoice number, product, customer,
-- supplier, representative..." — read as a single cross-entity search
-- experience (a topbar box), not five separate lookups. This RPC backs
-- exactly that: one query, ilike across the handful of tables people
-- actually look things up by name/number for, returning enough to render
-- a result list and route straight to the right page.
--
-- Scope decisions:
--   1. Five entity types: customers, suppliers, products, sales invoices,
--      purchase invoices. Warehouses/representatives/partners are few
--      enough per org that a dropdown already finds them faster than
--      search — this is for the entities that can run into the hundreds
--      or thousands.
--   2. No amount/date/status matching here — those are exact-value or
--      range filters, not text search, and are handled by each list
--      page's own filters (added alongside this), not by typing "500"
--      into a name search box.
--   3. Gated only on is_org_member, not view_financial — results carry a
--      name/number/date, never an amount, so there's nothing for
--      view_financial to protect here. (List pages/reports still gate
--      amounts exactly as before — this RPC just helps you FIND the
--      record, then the normal permission checks apply once you open it.)
--   4. Capped at 6 results per entity type (30 total) — a search box
--      dropdown, not a report; if someone needs more than that they want
--      the actual filtered list page, which the "عرض كل النتائج" link
--      in the UI sends them to.

create or replace function global_search(org_id uuid, p_query text, p_limit int default 6)
returns table (
  entity_type text,
  entity_id uuid,
  title text,
  subtitle text
)
language plpgsql
stable
set search_path = public
as $$
declare
  v_limit int := least(greatest(coalesce(p_limit, 6), 1), 20);
  v_query text := trim(coalesce(p_query, ''));
begin
  if auth.uid() is null then
    raise exception 'يجب تسجيل الدخول أولاً';
  end if;
  if not is_org_member(org_id) then
    raise exception 'أنت لست عضوًا في هذه المؤسسة';
  end if;
  if length(v_query) < 2 then
    return;
  end if;

  return query
  (
    select 'customer'::text, c.id, c.name, coalesce(c.phone, '')
    from customers c
    where c.organization_id = org_id and (c.name ilike '%' || v_query || '%' or c.phone ilike '%' || v_query || '%')
    order by c.name
    limit v_limit
  )
  union all
  (
    select 'supplier'::text, s.id, s.name, coalesce(s.phone, '')
    from suppliers s
    where s.organization_id = org_id and (s.name ilike '%' || v_query || '%' or s.phone ilike '%' || v_query || '%')
    order by s.name
    limit v_limit
  )
  union all
  (
    select 'product'::text, p.id, p.name, coalesce(p.sku, '')
    from products p
    where p.organization_id = org_id and (p.name ilike '%' || v_query || '%' or p.sku ilike '%' || v_query || '%')
    order by p.name
    limit v_limit
  )
  union all
  (
    select 'sales_invoice'::text, i.id, coalesce(i.invoice_number, i.id::text), coalesce(c.name, '') || ' — ' || i.invoice_date::text
    from sales_invoices i left join customers c on c.id = i.customer_id
    where i.organization_id = org_id and i.invoice_number ilike '%' || v_query || '%'
    order by i.invoice_date desc
    limit v_limit
  )
  union all
  (
    select 'purchase_invoice'::text, pi.id, coalesce(pi.invoice_number, pi.id::text), coalesce(s.name, '') || ' — ' || pi.invoice_date::text
    from purchase_invoices pi left join suppliers s on s.id = pi.supplier_id
    where pi.organization_id = org_id and pi.invoice_number ilike '%' || v_query || '%'
    order by pi.invoice_date desc
    limit v_limit
  );
end;
$$;

revoke all on function global_search(uuid, text, int) from public, anon;
grant execute on function global_search(uuid, text, int) to authenticated;

-- Search-by-name/sku/number needs an index or it becomes a sequential
-- scan the moment an org has a real catalog (§57's own performance
-- requirement). trigram indexes make ILIKE '%...%' actually usable.
create extension if not exists pg_trgm;

create index if not exists customers_name_trgm_idx on customers using gin (name gin_trgm_ops);
create index if not exists suppliers_name_trgm_idx on suppliers using gin (name gin_trgm_ops);
create index if not exists products_name_trgm_idx  on products  using gin (name gin_trgm_ops);
create index if not exists sales_invoices_number_trgm_idx    on sales_invoices    using gin (invoice_number gin_trgm_ops);
create index if not exists purchase_invoices_number_trgm_idx on purchase_invoices using gin (invoice_number gin_trgm_ops);

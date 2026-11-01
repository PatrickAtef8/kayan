-- 0069: search that works for Arabic and stays fast.
--
-- Found while auditing every search box of the application:
--   * Arabic spelling variants never matched: «احمد» did not find «أحمد», «مدرسه» did not find «مدرسة», «٠١٠» did not find «010».
--   * The top-bar search (global_search) treated "%" and "_" typed by the user as wildcards, did not look at barcodes (the products page
--     does), and listed matches alphabetically instead of "starts with what you typed" first.
--   * Phone / SKU / barcode searches had no index (only names and invoice numbers had), so they scanned every row of the company.
--   * The customers / suppliers / products lists put the raw text into a PostgREST filter: a "," or ")" in the search broke the request
--     and the list silently came back empty.
-- Added (read-only, nothing existing is changed or removed):
--   ar_norm(text)            one canonical spelling: no diacritics / tatweel, alef forms → ا, ى → ي, ة → ه, ؤ → و, ئ → ي, Arabic digits → 0-9, lower case
--   trigram indexes on ar_norm(...) for the searched columns
--   search_entity_page(...)  one page of customers / suppliers / products matching a text, with the total — used by the list pages
--   global_search(...)       same signature as before, now normalised, wildcard-safe, barcode-aware, "starts with" first

create extension if not exists pg_trgm;

create or replace function ar_norm(t text) returns text
language sql immutable parallel safe as $$
  select lower(translate(
    regexp_replace(coalesce(t, ''), '[\u064B-\u065F\u0670\u0640]', '', 'g'),
    'أإآٱىةؤئ٠١٢٣٤٥٦٧٨٩۰۱۲۳۴۵۶۷۸۹',
    'اااايهوي01234567890123456789'))
$$;

create index if not exists customers_name_norm_trgm_idx  on customers  using gin (ar_norm(name)    gin_trgm_ops);
create index if not exists customers_phone_norm_trgm_idx on customers  using gin (ar_norm(phone)   gin_trgm_ops);
create index if not exists suppliers_name_norm_trgm_idx  on suppliers  using gin (ar_norm(name)    gin_trgm_ops);
create index if not exists suppliers_phone_norm_trgm_idx on suppliers  using gin (ar_norm(phone)   gin_trgm_ops);
create index if not exists products_name_norm_trgm_idx   on products   using gin (ar_norm(name)    gin_trgm_ops);
create index if not exists products_sku_norm_trgm_idx    on products   using gin (ar_norm(sku)     gin_trgm_ops);
create index if not exists products_barcode_norm_trgm_idx on products  using gin (ar_norm(barcode) gin_trgm_ops);

-- A text as a LITERAL "contains" pattern for LIKE ("%" and "_" are not wildcards).
create or replace function like_contains(t text) returns text
language sql immutable parallel safe as $$
  select '%' || replace(replace(replace(t, '\', '\\'), '%', '\%'), '_', '\_') || '%'
$$;

-- One page of matches + the total. SECURITY INVOKER: row-level security decides what the caller may see (a rep sees only their customers).
-- Newest first, like the lists themselves. Result: { "total": n, "ids": [uuid, …] }
create or replace function search_entity_page(p_org uuid, p_entity text, p_query text, p_limit int default 20, p_offset int default 0)
returns jsonb
language plpgsql stable set search_path = public as $$
declare
  v_pat    text := like_contains(ar_norm(btrim(coalesce(p_query, ''))));
  v_limit  int  := least(greatest(coalesce(p_limit, 20), 1), 100);
  v_offset int  := greatest(coalesce(p_offset, 0), 0);
  v_total  bigint;
  v_ids    uuid[];
begin
  if auth.uid() is null then raise exception 'يجب تسجيل الدخول أولاً'; end if;
  if not is_org_member(p_org) then raise exception 'أنت لست عضوًا في هذه المؤسسة'; end if;

  if p_entity = 'customers' then
    with m as (select c.id, c.created_at from customers c
               where c.organization_id = p_org and (ar_norm(c.name) like v_pat or ar_norm(c.phone) like v_pat))
    select (select count(*) from m),
           coalesce((select array_agg(p.id order by p.created_at desc, p.id) from (select id, created_at from m order by created_at desc, id limit v_limit offset v_offset) p), '{}')
      into v_total, v_ids;
  elsif p_entity = 'suppliers' then
    with m as (select s.id, s.created_at from suppliers s
               where s.organization_id = p_org and (ar_norm(s.name) like v_pat or ar_norm(s.phone) like v_pat))
    select (select count(*) from m),
           coalesce((select array_agg(p.id order by p.created_at desc, p.id) from (select id, created_at from m order by created_at desc, id limit v_limit offset v_offset) p), '{}')
      into v_total, v_ids;
  elsif p_entity = 'products' then
    with m as (select x.id, x.created_at from products x
               where x.organization_id = p_org and (ar_norm(x.name) like v_pat or ar_norm(x.sku) like v_pat or ar_norm(x.barcode) like v_pat))
    select (select count(*) from m),
           coalesce((select array_agg(p.id order by p.created_at desc, p.id) from (select id, created_at from m order by created_at desc, id limit v_limit offset v_offset) p), '{}')
      into v_total, v_ids;
  else
    raise exception 'unknown entity %', p_entity;
  end if;
  return jsonb_build_object('total', v_total, 'ids', to_jsonb(v_ids));
end $$;

revoke all on function search_entity_page(uuid, text, text, int, int) from public, anon;
grant execute on function search_entity_page(uuid, text, text, int, int) to authenticated;

-- The top-bar search. Same inputs and outputs as before.
create or replace function global_search(org_id uuid, p_query text, p_limit int default 6)
returns table (entity_type text, entity_id uuid, title text, subtitle text)
language plpgsql stable set search_path = public as $$
declare
  v_limit  int  := least(greatest(coalesce(p_limit, 6), 1), 20);
  v_query  text := btrim(coalesce(p_query, ''));
  v_norm   text := ar_norm(v_query);
  v_pat    text := like_contains(v_norm);
  v_prefix text := replace(replace(replace(v_norm, '\', '\\'), '%', '\%'), '_', '\_') || '%';
  v_inv    text := like_contains(v_query);
begin
  if auth.uid() is null then raise exception 'يجب تسجيل الدخول أولاً'; end if;
  if not is_org_member(org_id) then raise exception 'أنت لست عضوًا في هذه المؤسسة'; end if;
  if length(v_query) < 2 then return; end if;

  return query
  (
    select 'customer'::text, c.id, c.name, coalesce(c.phone, '')
    from customers c
    where c.organization_id = org_id and (ar_norm(c.name) like v_pat or ar_norm(c.phone) like v_pat)
    order by (ar_norm(c.name) like v_prefix) desc, c.name
    limit v_limit
  )
  union all
  (
    select 'supplier'::text, s.id, s.name, coalesce(s.phone, '')
    from suppliers s
    where s.organization_id = org_id and (ar_norm(s.name) like v_pat or ar_norm(s.phone) like v_pat)
    order by (ar_norm(s.name) like v_prefix) desc, s.name
    limit v_limit
  )
  union all
  (
    select 'product'::text, p.id, p.name, coalesce(nullif(p.sku, ''), p.barcode, '')
    from products p
    where p.organization_id = org_id and (ar_norm(p.name) like v_pat or ar_norm(p.sku) like v_pat or ar_norm(p.barcode) like v_pat)
    order by (ar_norm(p.name) like v_prefix) desc, p.name
    limit v_limit
  )
  union all
  (
    select 'sales_invoice'::text, i.id, coalesce(i.invoice_number, i.id::text), coalesce(c.name, '') || ' — ' || i.invoice_date::text
    from sales_invoices i left join customers c on c.id = i.customer_id
    where i.organization_id = org_id and i.invoice_number ilike v_inv
    order by i.invoice_date desc
    limit v_limit
  )
  union all
  (
    select 'purchase_invoice'::text, pi.id, coalesce(pi.invoice_number, pi.id::text), coalesce(s.name, '') || ' — ' || pi.invoice_date::text
    from purchase_invoices pi left join suppliers s on s.id = pi.supplier_id
    where pi.organization_id = org_id and pi.invoice_number ilike v_inv
    order by pi.invoice_date desc
    limit v_limit
  );
end $$;

revoke all on function global_search(uuid, text, int) from public, anon;
grant execute on function global_search(uuid, text, int) to authenticated;

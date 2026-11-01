-- 0069: Arabic-aware, wildcard-safe, paged search.
\set ON_ERROR_STOP on
select t.autoconfirm_off();

select t.as_owner();
insert into auth.users (id, email) values ('11900000-0000-0000-0000-000000000001', 'srch@srch.test');
select t.as_user('11900000-0000-0000-0000-000000000001');
select create_organization('شركة البحث', 'x', 'EG', 'EGP', 'ar', array['customers','suppliers']) as id \gset s_

select t.as_owner();
insert into customers (organization_id, name, phone) values
  (:'s_id', 'أحمد علي', '01012345678'),
  (:'s_id', 'مدرسة النور', null),
  (:'s_id', '50% خصم', null),
  (:'s_id', 'محمود', '٠١١١٢٢٢٣٣٣٣');
insert into products (organization_id, name, sku, barcode, unit) values (:'s_id', 'سكر', 'SKU-9', '6221234567890', 'قطعة');

-- spelling variants collapse to one form
select t.eq_text(ar_norm('أَحمد إبراهيم'), 'احمد ابراهيم', 'diacritics and alef forms');
select t.eq_text(ar_norm('مدرسة مصطفى'), 'مدرسه مصطفي', 'ta marbuta and alef maqsura');
select t.eq_text(ar_norm('٠١٠ ۱۲'), '010 12', 'Arabic and Persian digits');

select t.as_user('11900000-0000-0000-0000-000000000001');
select (search_entity_page(:'s_id', 'customers', 'احمد', 20, 0) ->> 'total')::numeric as n \gset r1_
select t.eq(:r1_n, 1, 'احمد finds أحمد');
select (search_entity_page(:'s_id', 'customers', 'مدرسه', 20, 0) ->> 'total')::numeric as n \gset r2_
select t.eq(:r2_n, 1, 'مدرسه finds مدرسة');
select (search_entity_page(:'s_id', 'customers', '0111', 20, 0) ->> 'total')::numeric as n \gset r3_
select t.eq(:r3_n, 1, 'western digits find an Arabic-digit phone');
select (search_entity_page(:'s_id', 'customers', '%', 20, 0) ->> 'total')::numeric as n \gset r4_
select t.eq(:r4_n, 1, '"%" is a literal, not "everything"');
select (search_entity_page(:'s_id', 'customers', '_', 20, 0) ->> 'total')::numeric as n \gset r5_
select t.eq(:r5_n, 0, '"_" is a literal, not "any character"');
select (search_entity_page(:'s_id', 'customers', 'ع', 1, 0) -> 'ids' ->> 0) is not null as has_id \gset r6_
select t.ok(:'r6_has_id'::boolean, 'a page carries ids');
select (search_entity_page(:'s_id', 'products', '62212', 20, 0) ->> 'total')::numeric as n \gset r7_
select t.eq(:r7_n, 1, 'products are found by barcode');

-- the top bar
select count(*)::numeric as n from global_search(:'s_id', 'احمد', 6) \gset g1_
select t.eq(:g1_n, 1, 'global search is Arabic-aware');
select count(*)::numeric as n from global_search(:'s_id', '6221234', 6) where entity_type = 'product' \gset g2_
select t.eq(:g2_n, 1, 'global search finds a product by barcode');
select count(*)::numeric as n from global_search(:'s_id', '0%', 6) \gset g3_
select t.eq(:g3_n, 1, 'global search: "0%" matches only the name that really contains it (the "%" is not a wildcard)');

-- another company's data is never reachable
select t.throws($q$select search_entity_page(gen_random_uuid(), 'customers', 'x', 20, 0)$q$, 'لست عضوًا', 'not a member: refused');
select t.throws(format($q$select search_entity_page(%L, 'warehouses', 'x', 20, 0)$q$, :'s_id'), 'unknown entity', 'unknown entity refused');

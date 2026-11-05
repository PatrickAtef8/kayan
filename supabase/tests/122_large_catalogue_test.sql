-- Catalogues beyond 1000 rows: the pickers in the invoice forms use search_entity_page, which must find ANY record (PostgREST caps a plain list at 1000).
\set ON_ERROR_STOP on
select t.autoconfirm_off();
select t.as_owner();
insert into auth.users (id, email) values ('12200000-0000-0000-0000-000000000001', 'big@big.test');
select t.as_user('12200000-0000-0000-0000-000000000001');
select create_organization('شركة كبيرة', 'x', 'EG', 'EGP', 'ar', array['customers', 'suppliers', 'products']) as id \gset big_

select t.as_owner();
insert into customers (organization_id, name) select :'big_id', 'عميل رقم ' || g from generate_series(1, 1500) g;
insert into suppliers (organization_id, name) select :'big_id', 'مورد رقم ' || g from generate_series(1, 1500) g;
insert into products (organization_id, name, unit) select :'big_id', 'منتج رقم ' || g, 'قطعة' from generate_series(1, 1500) g;

select t.as_user('12200000-0000-0000-0000-000000000001');
select t.eq((search_entity_page(:'big_id', 'customers', '', 30, 0) ->> 'total')::numeric, 1500, 'customers: the empty search sees all 1500');
select t.eq(jsonb_array_length(search_entity_page(:'big_id', 'customers', '', 30, 0) -> 'ids'), 30, 'customers: a page is 30 ids');
select t.eq((search_entity_page(:'big_id', 'customers', 'رقم 1499', 30, 0) ->> 'total')::numeric, 1, 'customers: record #1499 (beyond the 1000 cap) is found by name');
select t.eq((search_entity_page(:'big_id', 'suppliers', 'رقم 1500', 30, 0) ->> 'total')::numeric, 1, 'suppliers: record #1500 is found');
select t.eq((search_entity_page(:'big_id', 'products', 'رقم 1234', 30, 0) ->> 'total')::numeric, 1, 'products: record #1234 is found');
select t.eq((search_entity_page(:'big_id', 'products', 'منتج', 100, 1400) ->> 'total')::numeric, 1500, 'products: deep paging works (total stays 1500)');
select t.eq(jsonb_array_length(search_entity_page(:'big_id', 'products', 'منتج', 100, 1400) -> 'ids'), 100, 'products: the last page is full');
select t.eq((search_entity_page(:'big_id', 'products', '%', 30, 0) ->> 'total')::numeric, 0, 'a literal % is not a wildcard');

-- Kayan — 0073: two plans, not three packages.
--
-- Until now a company bought one of three packages (basic / professional / complete) and chose a payment option on top of it.
-- There are now exactly TWO plans and a plan IS a way of paying:
--     'one_time'  — a perpetual license paid once + hosting & maintenance paid separately every month
--     'monthly'   — one all-inclusive monthly price
-- Each has its own prices, limits and modules, edited by the Super Admin under /admin/packages.
--
-- What this migration does (data and rules only — no table is created or dropped, nothing a company has paid for changes):
--   1. licenses and orders that carry an old package key are re-keyed to their payment option ('basic' + 'monthly' → 'monthly', …).
--      The entitlements snapshot stored in each license / order is NOT touched: a company keeps exactly the modules and limits it bought.
--   2. package_key and payment_option must agree from now on (a check constraint), so a renewal can never be quoted against a plan
--      the company does not have.
--   3. admin_grant_complimentary_license always writes the 'one_time' plan (free access never expires, like a perpetual license);
--      the p_package argument is kept so existing callers keep working, and is ignored.
-- Pricing overrides saved by the admin while there were three packages (platform_pricing_config) are keyed basic/professional/complete,
-- match no plan and are ignored by the application; the admin enters the two prices once on the new page. History rows are kept.
--
-- Run BEFORE deploying the application code (the code asks for plan keys 'monthly' and 'one_time'; an old license key would not match).
-- Safe to run twice.

-- 1. re-key
update organization_licenses set package_key = payment_option, updated_at = now() where package_key is distinct from payment_option;
update billing_orders        set package_key = payment_option                    where package_key is distinct from payment_option;

-- 2. one word, two columns
alter table organization_licenses drop constraint if exists organization_licenses_plan_is_option;
alter table organization_licenses add  constraint organization_licenses_plan_is_option check (package_key = payment_option);
alter table billing_orders        drop constraint if exists billing_orders_plan_is_option;
alter table billing_orders        add  constraint billing_orders_plan_is_option check (package_key = payment_option);

-- 3. free access = the 'one_time' plan
create or replace function admin_grant_complimentary_license(p_admin uuid, p_org uuid, p_package text, p_entitlements jsonb) returns text
language plpgsql security definer set search_path = public as $$
declare v_lic organization_licenses; v_existed boolean;
begin
  if not exists (select 1 from organizations where id = p_org) then return 'not_found'; end if;
  perform pg_advisory_xact_lock(hashtextextended('billing:' || p_org::text, 0));
  select * into v_lic from organization_licenses where organization_id = p_org;
  v_existed := found;
  if v_existed and not v_lic.complimentary then return 'has_paid_license'; end if;
  insert into organization_licenses (organization_id, package_key, payment_option, entitlements, licensed_at, access_paid_through, complimentary)
  values (p_org, 'one_time', 'one_time', p_entitlements, now(), timestamptz '2100-01-01', true)
  on conflict (organization_id) do update set package_key = excluded.package_key, entitlements = excluded.entitlements, updated_at = now();
  perform admin_audit(p_admin, 'license.grant_complimentary', 'organization', p_org::text, jsonb_build_object('plan', 'one_time'));
  return case when v_existed then 'refreshed' else 'granted' end;
end $$;

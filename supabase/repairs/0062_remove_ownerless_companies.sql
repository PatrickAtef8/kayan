-- OPTIONAL clean-up after deleting users from Supabase -> Authentication.
-- Deleting a user removes its membership but NOT the company, so companies of deleted users stay in the database
-- (shown in /admin/companies as "no owner"), together with all their data.
-- Step 1: look. Step 2: only if the list is what you expect, run the delete. It cannot be undone.

-- 1) companies that no longer have any active owner
select o.id, o.name, o.created_at
from organizations o
where not exists (select 1 from organization_users ou join roles r on r.id = ou.role_id
                  where ou.organization_id = o.id and ou.status = 'active' and r.key = 'owner')
order by o.created_at;

-- 2) delete them (cascades to their data). Uncomment to run.
-- delete from organizations o
-- where not exists (select 1 from organization_users ou join roles r on r.id = ou.role_id
--                   where ou.organization_id = o.id and ou.status = 'active' and r.key = 'owner');

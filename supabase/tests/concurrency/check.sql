\set ON_ERROR_STOP on
-- :name = label, :ok = true/false (computed by the shell)
select t.as_owner();
select t.ok(:ok::boolean, :'name');

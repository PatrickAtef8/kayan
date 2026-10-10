-- Tiny assertion helpers for the database tests (no pgTAP dependency, so the
-- suite runs on any stock PostgreSQL). A failed assertion raises an
-- exception, which makes psql (ON_ERROR_STOP) exit non-zero.
--
-- Tests run as plain autocommit statements on purpose: every RPC call is
-- then its own transaction with its own now(), exactly like production
-- (rows written by one RPC share a timestamp; rows from different requests
-- must not).

drop schema if exists t cascade;
create schema t;
grant usage on schema t to authenticated, anon;

-- Become a signed-in user (session-level, so it persists across statements).
create function t.as_user(uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', uid, 'email', 'user-' || left(uid::text, 8) || '@test.local')::text, false);
  execute 'set role authenticated';
end $$;

-- Become an unauthenticated (anon) caller.
create function t.as_anon() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '', false);
  execute 'set role anon';
end $$;

-- Back to the table owner (what migrations / SECURITY DEFINER bodies run as).
create function t.as_owner() returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claims', '', false);
end $$;

create function t.ok(cond boolean, label text) returns void language plpgsql as $$
begin
  if cond is not true then
    raise exception 'FAIL - %', label;
  end if;
  raise notice 'ok   - %', label;
end $$;

create function t.eq(actual numeric, expected numeric, label text) returns void language plpgsql as $$
begin
  if actual is null or abs(actual - expected) > 0.005 then
    raise exception 'FAIL - %: expected %, got %', label, expected, coalesce(actual::text, 'NULL');
  end if;
  raise notice 'ok   - % (= %)', label, expected;
end $$;

create function t.eq_text(actual text, expected text, label text) returns void language plpgsql as $$
begin
  if actual is distinct from expected then
    raise exception 'FAIL - %: expected %, got %', label, coalesce(expected, 'NULL'), coalesce(actual, 'NULL');
  end if;
  raise notice 'ok   - % (= %)', label, expected;
end $$;

-- Asserts that running `sql` raises an error whose message contains `pattern`.
create function t.throws(sql text, pattern text, label text) returns void language plpgsql as $$
begin
  begin
    execute sql;
  exception when others then
    if sqlerrm ilike '%' || pattern || '%' then
      raise notice 'ok   - % (rejected: %)', label, left(sqlerrm, 80);
      return;
    end if;
    raise exception 'FAIL - %: raised the wrong error: %', label, sqlerrm;
  end;
  raise exception 'FAIL - %: expected an error containing "%", but the statement succeeded', label, pattern;
end $$;

-- Asserts that `sql` (a select) returns zero rows under the current role.
create function t.empty(sql text, label text) returns void language plpgsql as $$
declare n bigint;
begin
  execute 'select count(*) from (' || sql || ') q' into n;
  if n <> 0 then
    raise exception 'FAIL - %: expected 0 rows, got %', label, n;
  end if;
  raise notice 'ok   - % (0 rows)', label;
end $$;


-- Runs a data-modifying statement and returns how many rows it touched.
-- Under RLS a forbidden UPDATE/DELETE does not error, it silently touches 0
-- rows — which is exactly what these tests need to assert.
create function t.affected(sql text) returns bigint language plpgsql as $$
declare n bigint;
begin
  execute sql;
  get diagnostics n = row_count;
  return n;
end $$;

grant execute on all functions in schema t to authenticated, anon;

-- Since migration 0034 the average cost lives in stock_costs (RLS-protected), not on inventory_stock.
-- Tests that assert on stock valuation read it through this view (it runs with the owner's rights).
create view t.stock_with_cost as
  select s.*, sc.avg_cost from inventory_stock s left join stock_costs sc on sc.stock_id = s.id;
grant select on t.stock_with_cost to authenticated;

-- Local test only: stand-ins for the Supabase API roles so migrations and isolation checks
-- behave the same on a plain Postgres. Never run this against Supabase.
do $$
declare r text;
begin
  foreach r in array array['anon', 'authenticated', 'service_role'] loop
    if not exists (select 1 from pg_roles where rolname = r) then
      execute format('create role %I nologin', r);
    end if;
  end loop;
end $$;

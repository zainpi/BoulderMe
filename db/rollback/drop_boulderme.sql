-- Removes BoulderMe from the PulseDeals database: schema `boulderme` and role `boulderme_api` only.
-- Back up first (OPERATIONS.md). This deletes every BoulderMe record and cannot be undone.
begin;
drop schema if exists boulderme cascade;
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'boulderme_api') then
    execute 'drop owned by boulderme_api';
    execute 'drop role boulderme_api';
  end if;
end $$;
commit;

-- Proves Supabase's API roles cannot reach schema boulderme and that boulderme_api has exactly the
-- intended access and nothing in PulseDeals' schema. Read-only. Run as postgres.
-- Each query returns one row per failed expectation: empty results = pass.

-- 1. API roles, PUBLIC, RLS and boulderme_api's reach outside its schema
select format('%s has %s on boulderme.%s', r, p, c.relname) as failure
from (values ('anon'), ('authenticated'), ('service_role')) roles(r), pg_class c,
     unnest(array['SELECT', 'INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES', 'TRIGGER']) p
where c.relnamespace = 'boulderme'::regnamespace and c.relkind = 'r' and has_table_privilege(r, c.oid, p)
union all
select format('%s has USAGE on schema boulderme', r)
from (values ('anon'), ('authenticated'), ('service_role')) roles(r)
where has_schema_privilege(r, 'boulderme', 'USAGE')
union all
select 'PUBLIC has a grant on schema boulderme'
from pg_namespace n, aclexplode(coalesce(n.nspacl, acldefault('n', n.nspowner))) a
where n.nspname = 'boulderme' and a.grantee = 0
union all
select format('PUBLIC has %s on boulderme.%s', a.privilege_type, c.relname)
from pg_class c, aclexplode(coalesce(c.relacl, acldefault('r', c.relowner))) a
where c.relnamespace = 'boulderme'::regnamespace and c.relkind = 'r' and a.grantee = 0
union all
select format('RLS disabled on boulderme.%s', relname)
from pg_class where relnamespace = 'boulderme'::regnamespace and relkind = 'r' and not relrowsecurity
union all
select 'boulderme_api has elevated attributes'
from pg_roles where rolname = 'boulderme_api' and (rolsuper or rolcreaterole or rolcreatedb or rolbypassrls or rolreplication)
union all
-- USAGE on public comes from Postgres' default PUBLIC grant and is harmless without object grants.
select 'boulderme_api has CREATE on schema public' where has_schema_privilege('boulderme_api', 'public', 'CREATE')
union all
select format('boulderme_api can %s public.%s', p, c.relname)
from pg_class c, unnest(array['SELECT', 'INSERT', 'UPDATE', 'DELETE']) p
where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'v', 'm', 'p') and has_table_privilege('boulderme_api', c.oid, p)
union all
-- Trigger and event-trigger functions cannot be called directly, so they are skipped.
select format('boulderme_api can execute public.%s', p.oid::regprocedure)
from pg_proc p
where p.pronamespace = 'public'::regnamespace and p.prorettype not in ('trigger'::regtype, 'event_trigger'::regtype)
  and has_function_privilege('boulderme_api', p.oid, 'EXECUTE');

-- 2. boulderme_api's privileges on each boulderme table match the design
with expected(tbl, privs) as (values
  ('accounts', 'SELECT,INSERT,UPDATE,DELETE'), ('refresh_sessions', 'SELECT,INSERT,UPDATE,DELETE'),
  ('auth_nonces', 'SELECT,INSERT,UPDATE,DELETE'), ('tombstones', 'SELECT,INSERT,UPDATE,DELETE'),
  ('profiles', 'SELECT,INSERT,UPDATE,DELETE'), ('gym_access', 'SELECT,INSERT,UPDATE,DELETE'),
  ('availability_slots', 'SELECT,INSERT,UPDATE,DELETE'), ('chats', 'SELECT,INSERT,UPDATE,DELETE'),
  ('invitations', 'SELECT,INSERT,UPDATE,DELETE'), ('chat_messages', 'SELECT,INSERT,UPDATE,DELETE'),
  ('chat_read_states', 'SELECT,INSERT,UPDATE,DELETE'), ('blocks', 'SELECT,INSERT,UPDATE,DELETE'),
  ('idempotency_keys', 'SELECT,INSERT,UPDATE,DELETE'), ('rate_limits', 'SELECT,INSERT,UPDATE,DELETE'),
  ('gyms', 'SELECT'), ('gym_requests', 'SELECT,INSERT'), ('reports', 'SELECT,INSERT'), ('schema_migrations', '')
),
actual as (
  select c.relname as tbl,
         (select coalesce(string_agg(x, ','), '')
          from unnest(array['SELECT', 'INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES', 'TRIGGER']) x
          where has_table_privilege('boulderme_api', c.oid, x)) as privs
  from pg_class c where c.relnamespace = 'boulderme'::regnamespace and c.relkind = 'r'
)
select format('boulderme_api on %s: expected [%s], has [%s]', coalesce(e.tbl, a.tbl), e.privs, a.privs) as failure
from expected e full join actual a using (tbl)
where e.privs is distinct from a.privs;

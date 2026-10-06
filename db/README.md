# db/

Postgres migrations for schema `boulderme` inside the PulseDeals Supabase project. Built in T2; how to run everything is in `SETUP.md` section 2.

| Path | What |
|---|---|
| `migrations/0001_boulderme_schema.sql` | Schema, all tables from `docs/domain-model.md`, indexes, checks, role `boulderme_api`, grants, RLS |
| `seeds/gyms_ontario.sql` | Curated Ontario gyms, verified against each gym's own site. Idempotent (upsert by `slug`) |
| `seeds/dev_synthetic.sql` | Three fake members for local/staging. Refuses to run unless `boulderme.allow_synthetic = on` |
| `rollback/drop_boulderme.sql` | Drops schema `boulderme` and role `boulderme_api`, nothing else |
| `tests/constraints_test.sql` | Proves the database rejects bad data (grades, styles, slots, one pending invite per pair, ...) |
| `tests/isolation_check.sql` | Proves `anon`/`authenticated`/`service_role` can't reach `boulderme` and `boulderme_api` can't reach PulseDeals |
| `tests/local_supabase_roles.sql` | Creates Supabase's API roles on a plain local Postgres |

Applied migrations are recorded in `boulderme.schema_migrations`, never in `supabase_migrations.schema_migrations` (that is PulseDeals' history, and extra rows there would break its `supabase db push`).

Access model: `boulderme_api` gets full read/write on member tables, read-only on `gyms`, and read + insert on `gym_requests` and `reports` (the operator reviews those with SQL as `postgres`). RLS is on everywhere with one policy for `boulderme_api`, so any other role sees nothing even if it were granted access by mistake. The schema is not in PostgREST's exposed schemas.

Rules:
- Every object lives in schema `boulderme`. Never create, alter or drop anything in `public`, `auth`, `storage` or other PulseDeals objects.
- Migrations are additive and numbered: `migrations/0001_<name>.sql`, `0002_...`.
- `rollback/drop_boulderme.sql` removes only `boulderme` objects and the `boulderme_api` role.
- `seeds/gyms_ontario.sql` is the curated gym list (real data, safe for production). `seeds/dev_synthetic.sql` is synthetic test data and must never run in production.
- Take a backup before applying anything to PulseDeals (see `OPERATIONS.md`).

## Gyms still to confirm

Seeded 2026-10-06 with `verified_on = null` because the street address came from a third-party page, not the gym's own site. Check each, then `update boulderme.gyms set verified_on = current_date where slug = '...'`:

- `ethos-climbing` (Toronto): address from the Waterfront BIA listing.
- `rock-room` (Thunder Bay): address from TBNewsWatch.
- `the-boiler-room-climbing-gym-belleville`: address from Waze.
- `alt-rock` (Barrie): address from a search snippet of its map page; "has ropes" inferred from harness sales.
- `toprock-climbing` (Brampton): address is official; "has ropes" (auto-belays) comes from Bramptonist.
- `joe-rockheads` (Toronto): address from sister gym Rock Oasis' site.

Left out on purpose: Quebec gyms (Altitude Gatineau, Bloc 9.81), closed or not yet open gyms (Vertical Reality Ottawa, Climbers Corner and Collingwood Climbing Centre), gyms with no official site (Peaks, St. Catharines), and university or community walls.

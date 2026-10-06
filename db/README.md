# db/

Postgres migrations for schema `boulderme` inside the PulseDeals Supabase project. Built in T2.

Rules:
- Every object lives in schema `boulderme`. Never create, alter or drop anything in `public`, `auth`, `storage` or other PulseDeals objects.
- Migrations are additive and numbered: `migrations/0001_<name>.sql`, `0002_...`.
- `rollback/drop_boulderme.sql` removes only `boulderme` objects and the `boulderme_api` role.
- `seeds/gyms_ontario.sql` is the curated gym list (real data, safe for production). `seeds/dev_synthetic.sql` is synthetic test data and must never run in production.
- Take a backup before applying anything to PulseDeals (see `OPERATIONS.md`).

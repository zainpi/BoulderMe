# Setup

This guide grows as each part is built. Steps marked **(later)** land with the thread that builds that part.

## 1. Read the contract first

- API: `docs/api/openapi.yaml`. View it nicely with `npx -y @redocly/cli@2 preview-docs docs/api/openapi.yaml` and open the printed local URL.
- Decisions: `docs/adr/0001-architecture.md`.

## 2. Database

Schema `boulderme` already exists in the PulseDeals Supabase project (migration `0001` applied 2026-10-06, Ontario gyms seeded). To run it yourself somewhere else, or to finish the connection for the API:

**Local scratch database (for development and tests)**

```sh
createdb boulderme_dev
psql -d boulderme_dev -f db/tests/local_supabase_roles.sql   # stand-ins for Supabase's anon/authenticated roles
for f in db/migrations/*.sql; do psql -v ON_ERROR_STOP=1 -d boulderme_dev -f "$f"; done
psql -d boulderme_dev -f db/seeds/gyms_ontario.sql
PGOPTIONS="-c boulderme.allow_synthetic=on" psql -d boulderme_dev -f db/seeds/dev_synthetic.sql   # never on production
psql -d boulderme_dev -f db/tests/constraints_test.sql       # every line should say PASS
psql -d boulderme_dev -f db/tests/isolation_check.sql        # both queries should return 0 rows
```

**Let the API log in as `boulderme_api` (do this once, before T3's Worker connects)**

The migration creates `boulderme_api` without a password and unable to log in. In the Supabase dashboard, open the PulseDeals project, then SQL Editor, and run (replace the placeholder with a long random password, e.g. from `openssl rand -base64 32`; do not paste it into chat or commit it):

```sql
alter role boulderme_api with login password '<new password>';
```

Then build `DATABASE_URL` from Project → Connect → Transaction pooler: user `boulderme_api.mjagaepkilhbmpfdsduw`, port `6543`, database `postgres`, plus the password above. Save it as the Worker secret `DATABASE_URL` (`npx wrangler secret put DATABASE_URL`) and in `api/.dev.vars` for local use.

**New migrations** go in `db/migrations/NNNN_<name>.sql`, each wrapped in `begin; ... commit;` and ending with an insert into `boulderme.schema_migrations`. Apply them with the SQL editor or `psql` as `postgres`, after the backup in `OPERATIONS.md`. Do not use `supabase db push` or the Supabase migrations table: that history belongs to PulseDeals.

## 3. API (later, T3/T4)

1. Install Node 22: https://nodejs.org
2. `cd api && npm install`
3. Copy names from `.env.example` into `api/.dev.vars` (gitignored) and fill in local values.
4. `npm test`, then `npx wrangler dev` to serve on `http://localhost:8787`.
5. Check: `curl http://localhost:8787/v1/health`.

## 4. iOS app

1. Install Xcode 16 or newer from the Mac App Store (Xcode 26 adds Liquid Glass on floating controls).
2. Open `ios/BoulderMe.xcodeproj`. No generator or packages are needed.
3. Choose the **BoulderMe** scheme and an iPhone simulator, press Run. The Debug configuration talks to a local Worker at `http://localhost:8787`.
4. On the Welcome screen tap **Explore the demo**; no accounts are needed.
5. To run on your own iPhone, copy `ios/Config/Local.xcconfig.example` to `ios/Config/Local.xcconfig` and set `DEVELOPMENT_TEAM`.

From the command line: `xcodebuild -project ios/BoulderMe.xcodeproj -scheme BoulderMe -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test`.

## 5. Cloudflare and Apple (later, T8)

Covered when staging is deployed: creating the Cloudflare API token, adding GitHub secrets, enabling Sign in with Apple for the bundle id, and uploading to TestFlight. You sign in, accept terms and handle payment screens yourself; never paste secrets into chat.

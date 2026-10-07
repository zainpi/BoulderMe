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

## 3. API

1. Install Node 22: https://nodejs.org
2. `cd api && npm install`
3. `npm test` (no database needed; see `api/README.md` to also run the tests against a local Postgres).
4. For `wrangler dev`, create `api/.dev.vars` (gitignored) with the names from `.env.example`. Local values: `DATABASE_URL` pointing at your scratch database as `boulderme_api`, random keys from `openssl rand -base64 32` for `ACCESS_TOKEN_SIGNING_KEY`, `APPLE_TOKEN_ENCRYPTION_KEY` and `RATE_LIMIT_SALT`, and `APPLE_BUNDLE_ID` set to the app's bundle id. The Apple key values can stay empty until T8.
5. `npx wrangler dev` serves on `http://localhost:8787`. Check: `curl http://localhost:8787/v1/health`.

Deploying (T8) needs the `boulderme_api` password from section 2 and your Cloudflare account; `npm run deploy:dry-run` only bundles.

## 4. iOS app

1. Install Xcode 16 or newer from the Mac App Store (Xcode 26 adds Liquid Glass on floating controls).
2. Open `ios/BoulderMe.xcodeproj`. No generator or packages are needed.
3. Choose the **BoulderMe** scheme and an iPhone simulator, press Run. The Debug configuration talks to a local Worker at `http://localhost:8787`.
4. On the Welcome screen tap **Explore the demo**; no accounts are needed.
5. To run on your own iPhone, copy `ios/Config/Local.xcconfig.example` to `ios/Config/Local.xcconfig` and set `DEVELOPMENT_TEAM`.

From the command line: `xcodebuild -project ios/BoulderMe.xcodeproj -scheme BoulderMe -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test`.

## 5. Staging on Cloudflare

Staging is https://boulderme-api-staging.runsit.ca, a Worker custom domain in the Cloudflare account that already serves runsit.ca. GitHub Actions deploys it (`.github/workflows/deploy-staging.yml`) by hand from the Actions tab, and on every push to `main` that touches `api/`.

One-time setup, all done by you (never paste these values into chat):

1. **Cloudflare API token.** Cloudflare dashboard → My Profile → API Tokens → Create Token → template **Edit Cloudflare Workers**. Under Zone Resources pick `runsit.ca`. Create it and copy the token.
2. **GitHub secrets** on `zainpi/BoulderMe` → Settings → Secrets and variables → Actions → New repository secret:
   - `CLOUDFLARE_API_TOKEN`: the token from step 1.
   - `CLOUDFLARE_ACCOUNT_ID`: the Account ID shown in the Cloudflare dashboard sidebar (Workers & Pages overview).
   - `STAGING_DATABASE_URL`: the `boulderme_api` pooler URL from section 2.
3. Actions → **deploy-staging** → Run workflow.

The first run generates `ACCESS_TOKEN_SIGNING_KEY`, `APPLE_TOKEN_ENCRYPTION_KEY` and `RATE_LIMIT_SALT` as Worker secrets and keeps them afterwards. `APPLE_BUNDLE_ID` is a plain var in `api/wrangler.toml` (`com.zainpi.boulderme.staging`); don't also add it as a secret.

Each run deploys, waits for `/v1/health` to report `database: ok`, then runs `api/e2e/staging-check.mjs`: three test climbers sign in through a staging-only test login, go through invite → accept → chat → block, and probe the isolation and failure paths, and then every test account is deleted. The test login's key is random per run and removed when the run ends. To run the same check on your machine against `wrangler dev --env staging`, put any `E2E_IDENTITY_KEY` in `api/.dev.vars` and run `API_BASE_URL=http://localhost:8787 E2E_IDENTITY_KEY=<same> APPLE_BUNDLE_ID=com.zainpi.boulderme.staging node e2e/staging-check.mjs` from `api/`.

Staging and (later) production use the same `boulderme` schema, because BoulderMe gets one schema in PulseDeals. Test climbers are named `E2E …` and deleted by the check; deleted accounts leave a small tombstone row.

## 6. Apple (later)

Real Sign in with Apple, the Apple key for revocation (`APPLE_TEAM_ID`, `APPLE_KEY_ID`, `APPLE_PRIVATE_KEY` Worker secrets) and TestFlight wait for the Apple Developer Program enrollment. You sign in, accept terms and handle payment screens yourself.

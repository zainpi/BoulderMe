# Setup

This guide grows as each part is built. Steps marked **(later)** land with the thread that builds that part.

## 1. Read the contract first

- API: `docs/api/openapi.yaml`. View it nicely with `npx -y @redocly/cli@2 preview-docs docs/api/openapi.yaml` and open the printed local URL.
- Decisions: `docs/adr/0001-architecture.md`.

## 2. Database (later, T2)

Migrations for schema `boulderme` are applied to the PulseDeals Supabase project after a backup. Steps will cover: taking the backup, applying `db/migrations/*.sql`, setting the `boulderme_api` password, and building `DATABASE_URL` from the pooler connection string (Supabase dashboard → Project → Connect → Transaction pooler).

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

From the command line: `xcodebuild -project ios/BoulderMe.xcodeproj -scheme BoulderMe -destination 'platform=iOS Simulator,name=iPhone 16' test`.

## 5. Cloudflare and Apple (later, T8)

Covered when staging is deployed: creating the Cloudflare API token, adding GitHub secrets, enabling Sign in with Apple for the bundle id, and uploading to TestFlight. You sign in, accept terms and handle payment screens yourself; never paste secrets into chat.

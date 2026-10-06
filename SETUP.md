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

## 4. iOS app (later, T5 to T7)

1. Install Xcode from the Mac App Store.
2. Open `ios/BoulderMe.xcodeproj` (or generate it as T5 documents).
3. Choose the **BoulderMe (Debug)** scheme and an iPhone simulator, press Run.
4. On the Welcome screen tap **Explore demo**; no accounts are needed.

## 5. Cloudflare and Apple (later, T8)

Covered when staging is deployed: creating the Cloudflare API token, adding GitHub secrets, enabling Sign in with Apple for the bundle id, and uploading to TestFlight. You sign in, accept terms and handle payment screens yourself; never paste secrets into chat.

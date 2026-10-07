# api/

Cloudflare Worker (TypeScript) implementing `docs/api/openapi.yaml`. T3 built auth, profile, gyms, gym access, availability, pause and discovery; T4 adds invitations, chats, blocks, reports, export and deletion.

## Run it

```sh
cd api
npm install
npm test                 # in-memory repository only
npm run typecheck
npm run deploy:dry-run   # bundles the Worker without deploying
npx wrangler dev         # needs api/.dev.vars, see SETUP.md section 3
```

To also run every test against Postgres as role `boulderme_api` (what CI does), create a scratch database as in `SETUP.md` section 2, give the local `boulderme_api` a throwaway password, and set:

```sh
export TEST_DATABASE_URL=postgres://boulderme_api:<local password>@localhost:5432/boulderme_test
export TEST_ADMIN_DATABASE_URL=postgres://postgres:<local password>@localhost:5432/boulderme_test
npm test
```

The Postgres suites truncate every `boulderme` table, so only point them at a scratch database, never at PulseDeals.

## Layout

| Path | What |
|---|---|
| `src/index.ts` | Worker entry: opens one pooled connection per request, daily housekeeping cron |
| `src/app.ts` | Pipeline: routing, request ids, bearer auth, rate limits, error envelope, sanitized logs |
| `src/routes/` | Handlers. `index.ts` is the route table with each route's rate limit |
| `src/auth/` | Sign in with Apple (JWKS verification, code exchange), access/refresh tokens, crypto helpers |
| `src/db/repository.ts` | Storage interface; `postgres.ts` (production) and `memory.ts` (tests) implement it |
| `src/validation.ts` | Request schemas (zod), mirroring the OpenAPI input schemas |
| `src/cursor.ts`, `src/idempotency.ts`, `src/domain.ts`, `src/wire.ts` | Cursors, `Idempotency-Key`, shared product rules, wire mapping |
| `test/` | Route tests. Each suite runs against both repositories; every response is checked against `openapi.yaml` |

## Rules worth knowing

- Every response is validated against the OpenAPI contract in tests (`test/support/contract.ts`). An undocumented status or field fails the test, so change the contract first.
- Access tokens: HS256, 15 minutes, carry the session family id; each request checks the account is active and the family is not revoked, so sign-out and deletion take effect at once.
- Refresh tokens: 256-bit, SHA-256 hashed at rest, single use. Replaying a used one revokes the whole family (`refresh_token_reused`).
- Apple: identity token signature (Apple JWKS), `iss`, `aud` = `APPLE_BUNDLE_ID`, `exp`, and `nonce` = SHA-256 of a single-use server nonce. The Apple refresh token from the code exchange is stored AES-GCM encrypted for revocation at deletion. Without `APPLE_TEAM_ID`/`APPLE_KEY_ID`/`APPLE_PRIVATE_KEY` the exchange is skipped (local development).
- Rate limits are fixed windows in `boulderme.rate_limits`: per account on signed-in routes, per hashed `X-Client-Installation-Id` on sign-in routes. Limits are in `src/routes/index.ts`.
- Hidden, blocked, deleted and non-UUID ids are all `404 not_found`.

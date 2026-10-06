# ADR 0001: Architecture for BoulderMe v1

- Status: Accepted
- Date: 2026-10-06
- Deciders: owlz (product owner), Claude (engineering)

## Context

BoulderMe is a cozy, playful iPhone app that helps boulderers find similarly skilled partners at specific gyms. Members describe their grade range, styles, availability and the gyms they climb at, including whether they hold a membership or a guest pass there. Everything is self-reported: no gym verification, no GPS. Signed-in members discover opted-in profiles by gym, send one-to-one session invitations, and chat only after an invitation is accepted. Members can block, report, pause discovery, export and delete their data.

The owner asked to host the data in the existing **PulseDeals** Supabase project rather than create a new one. That project is on Supabase's free plan (no point-in-time recovery), runs Postgres 17 in `eu-west-1`, keeps its own tables in `public` with a `pulsedeals_` prefix, and does not use Supabase Auth (`auth.users` is empty).

Out of scope for v1: subscriptions or paywall, push notifications, group sessions, live location, gym verification, AI features, content feeds, share extension, third-party community logins, commerce.

## Decisions

| Concern | Decision | Why |
|---|---|---|
| Client | SwiftUI, iOS 17+. Liquid Glass (`glassEffect`) only on floating controls, guarded by `#available(iOS 26.0, *)`, with `Material` fallback | Native, matches the spec; keeps older phones supported |
| API runtime | Cloudflare Worker in TypeScript, versioned REST under `/v1`, contract in `docs/api/openapi.yaml` | Free tier covers launch; the contract lets iOS and backend work in parallel |
| Database | PulseDeals Supabase Postgres, new schema `boulderme` | Owner's request; one database to run |
| Isolation from PulseDeals | All objects in schema `boulderme`. The schema is **not** added to PostgREST's exposed schemas. A dedicated login role `boulderme_api` has grants only on `boulderme.*`. `anon`, `authenticated` and `public` get no grants. RLS is enabled with no policies (deny-all) as defence in depth. No changes to `public`, `auth`, `storage` or any PulseDeals object or role | PulseDeals data and API stay untouched; the Worker never holds the service-role key |
| DB connection | Worker connects as `boulderme_api` through the Supabase connection pooler (transaction mode); connection string stored as a Worker secret `DATABASE_URL` | Works from Workers; least privilege |
| Auth | Sign in with Apple validated in the Worker (Apple JWKS signature, `iss`, `aud`, `exp`, hashed nonce, stable `sub`). App-issued access tokens (JWT, HS256, 15 minutes) and opaque refresh tokens (256-bit, 60 days, SHA-256 hashed at rest, single-use rotation with reuse detection that revokes the family). Apple refresh token stored encrypted (AES-GCM, key in Worker secret) for revocation at deletion | Supabase Auth is not used, so BoulderMe users never appear in PulseDeals' `auth.users` |
| Chat transport | REST + foreground polling every 5 seconds while a chat is open | No push in v1; simple and cheap. Realtime can come later |
| Gyms | Curated seed list in `boulderme.gyms`, starting with **Ontario, Canada** (`CA-ON`). Members can suggest missing gyms into a review queue | Needs real gym names; launch region chosen by the owner |
| Grades | V-scale integers 0 to 17 (`grade_min`/`grade_max`) | Ontario gyms commonly grade on the V-scale; integer ranges make overlap queries trivial |
| Age | Members confirm they are 18+ during onboarding (`adult_confirmed`) | The app arranges in-person meetups with strangers; an adults-only default is the safer, reversible choice |
| Moderation | Reports land in `boulderme.reports`; the operator reviews them with the SQL runbook in `OPERATIONS.md`. No admin API in v1 | Smallest attack surface for a single operator |
| Demo mode | iOS ships fake services with local fixtures, clearly labeled, isolated from real accounts | UI can be built and reviewed before Apple/Cloudflare setup |
| iOS builds | On the owner's Mac (Xcode) through a session on their device; GitHub Actions macOS runner for CI | The cloud container is Linux |
| Repo | Monorepo `zainpi/BoulderMe`: `ios/`, `api/`, `db/`, `docs/` | One place for contract, server and client |

## Wire conventions

Defined once in `docs/api/openapi.yaml` and binding on both sides: `snake_case` fields; opaque lowercase UUIDs; RFC 3339 UTC timestamps; nullable fields always present; `{items, next_cursor}` pages with opaque cursors (limit default 20, max 50); a single `Error` envelope with stable `code`s; `Idempotency-Key` on creates; `revision` on profile writes for conflict detection. The client domain model maps from these DTOs and never depends on database rows.

## Consequences

- BoulderMe shares PulseDeals' free-tier limits (500 MB database, connection caps, egress) and its pause-on-inactivity behaviour. If either app grows, the first step is moving PulseDeals' org to Pro or moving `boulderme` to its own project with `pg_dump -n boulderme`.
- With no PITR on the free plan, every migration is preceded by a `pg_dump` backup (see `OPERATIONS.md`).
- Canadian members reach an EU database, adding roughly 100 ms per query round trip. Acceptable for v1; the Worker batches queries per request to keep it to one or two round trips.
- Polling chat costs Worker requests (about 12 per minute per open chat). Within the free tier (100k requests/day) for early usage; revisit before growth.
- Removing BoulderMe from PulseDeals is a single `DROP SCHEMA boulderme CASCADE; DROP ROLE boulderme_api;` (script in `db/`).

## Alternatives considered

- **Supabase Auth + PostgREST directly from the app.** Rejected: puts BoulderMe users into PulseDeals' auth tables and exposes the schema to the public API.
- **A separate Supabase project.** Cleaner isolation, but the owner asked to reuse PulseDeals, and the free plan allows two projects per org; kept as the migration path.
- **Supabase Realtime for chat.** Deferred; needs RLS policies and client auth tokens that v1 deliberately avoids.

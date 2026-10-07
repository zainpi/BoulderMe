# Threat model

Scope: BoulderMe v1 (iOS app, Cloudflare Worker, `boulderme` schema inside the PulseDeals Supabase project). Method: STRIDE per asset, plus the people-safety risks specific to meeting strangers.

## Assets

1. Members' physical safety when meeting a stranger at a gym.
2. Member data (profiles, availability, gyms, messages, reports).
3. Session credentials (access/refresh tokens, Apple tokens).
4. PulseDeals' data and service, which share the database.
5. Operator secrets (`DATABASE_URL`, token signing key, Apple keys, encryption key).

## Trust boundaries

```
iPhone app ──HTTPS──▶ Cloudflare Worker ──TLS, role boulderme_api──▶ Supabase Postgres
                         │                                              ├─ schema boulderme (ours)
                         └──HTTPS──▶ Apple (JWKS, token, revoke)         └─ schema public (PulseDeals, untouched)
```

The app is untrusted. The Worker is the only component that talks to the database.

## Threats and mitigations

| # | Threat | Mitigation | Verified by |
|---|---|---|---|
| S1 | Forged or replayed Apple identity token | Verify signature against Apple JWKS, `iss`, `aud` = bundle id, `exp`, and nonce claim = SHA-256 of a single-use server nonce | T3 auth tests |
| S1b | Staging test sign-in used to create accounts | Only installed when `ENVIRONMENT` is `staging` and the Worker secret `E2E_IDENTITY_KEY` is set; HS256 tokens need that key, issuer `boulderme-e2e`, the staging bundle id and an `e2e-` subject; the key is random per `deploy-staging` run and removed when the run ends | `test/e2e-signin.test.ts` |
| S2 | Stolen refresh token | Hashed at rest, single-use rotation, reuse revokes the family, 60 day expiry, sign-out revokes | T3 rotation tests |
| S3 | Access token theft | 15 minute TTL; Keychain storage; HTTPS only | Config review |
| T1 | Client tampers with ids to read or write another member's data | Every query is scoped by the authenticated `account_id`; no client-supplied owner ids | T3/T4 two-account isolation tests; `api/e2e/staging-check.mjs` on staging |
| T2 | Bypassing product rules (chat before acceptance, inviting a blocked member) | Rules enforced in the Worker inside transactions, plus DB constraints (partial unique index for open invites, check constraints) | T4 rule tests |
| R1 | Abuser denies sending harassing messages | Report stores a message snapshot and ids at report time | T4 report tests |
| I1 | Discovery leaks private data | Discovery returns only `ProfileCard` fields; no location, no exact last-seen; blocked/paused hidden; `not_found` for anything hidden | T3 discovery tests |
| I2 | Enumerating members by id | UUIDv4 ids, auth required everywhere, hidden = `not_found`, rate limits on discovery and profile reads | T3 tests |
| I3 | PulseDeals data exposed through BoulderMe, or vice versa | `boulderme_api` has no grants outside `boulderme`; `anon`/`authenticated` have none on `boulderme`; schema not exposed to PostgREST; RLS deny-all | T2 grant check script |
| I4 | Secrets leaked in logs or repo | Secrets only in Worker secrets / GitHub encrypted secrets; `.env.example` lists names only; structured logs exclude bodies, tokens and names; secret scanning on the repo | T8 review |
| D1 | Spam invites or messages | Per-account and per-installation rate limits (invites 20/day, messages 60/min, reports 20/day, discovery 120/min); body cap 16 KiB | T3/T4 tests |
| D2 | BoulderMe load starves PulseDeals (shared free-tier DB) | Pooler in transaction mode, small per-request query count, `statement_timeout` on `boulderme_api`, connection limit on the role | T2 role settings |
| E1 | SQL injection | Parameterized queries only; no dynamic SQL from input | Code review, tests |
| E2 | Worker compromise gives access to PulseDeals | Worker never holds the Supabase service-role key; its role can only touch `boulderme` | T2 grant check |
| P1 | Unwanted contact | No messaging until an invitation is accepted; one pending invite per pair; decline is silent | T4 tests |
| P2 | Stalking via availability and gyms | No GPS; availability is weekly windows, not live check-ins; members can pause discovery or remove gyms instantly; block hides both ways | Design |
| P3 | Minors meeting adults | 18+ confirmation in onboarding; `underage` report reason; App Store age rating 17+ | T6 onboarding, T8 release |
| P4 | Harassment continues after block | Block closes chat, cancels invites, hides profiles both ways, silent to the other side | T4 tests |
| P5 | Unsafe meetups | In-app safety tips: meet only at the gym, tell a friend, report concerns; gyms are public staffed places by design | T7 UI |

## Residual risks (accepted for v1)

- Self-reported gym access and grades can be false. Labeled clearly in the UI.
- One operator reviews reports manually; response time depends on them. `OPERATIONS.md` sets a review cadence.
- No photo or identity verification.
- Free-plan database has no PITR; mitigated with pre-migration dumps.

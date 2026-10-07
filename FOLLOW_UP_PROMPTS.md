# Follow-up prompts

**How to use this file:** copy one prompt below (the text inside a grey box) and paste it into your BoulderMe project chat, or into a new chat that has access to the `zainpi/BoulderMe` repo. Replace anything in `[square brackets]` first. Never paste passwords, API keys or tokens into a prompt.

## Progress note (2026-10-07)

- **Verified:** repo created, API contract (`docs/api/openapi.yaml`) lints clean, architecture, privacy, threat model, screen map and feature matrix written.
- **Database (T2):** schema `boulderme` is live in PulseDeals with the Ontario gym list; isolation check passes. The `boulderme_api` password was set on 2026-10-07; it goes into the Worker secret `DATABASE_URL` at deploy time (T8).
- **API (T3):** sign-in, sessions, profile, gyms, availability, pause and discovery are built and tested against a local Postgres (not deployed yet).
- **Not done yet:** invitations, chat, safety and deletion routes (T4), the iOS screens that use the API, CI for iOS, staging. See `docs/feature-matrix.md`.
- **Next prompt:** "Build the API invitations, chat and safety" from Future ideas.

## 1. Build the database schema (done 2026-10-06)

When: done; kept for reference. Prerequisite: Supabase connector connected (done).

```text
In zainpi/BoulderMe, do task T2: create the boulderme schema migrations in db/ following docs/domain-model.md and docs/adr/0001-architecture.md. Back up first, apply to the PulseDeals Supabase project, seed the Ontario gym list, and prove anon/authenticated can't read boulderme.*.
```

Expected result: migrations merged, schema live in PulseDeals, a grant check that passes.

## 2. Build the API sign-in, profiles and discovery (done 2026-10-07)

When: done; kept for reference. Prerequisite: none for local tests.

```text
In zainpi/BoulderMe, do task T3: build the Cloudflare Worker in api/ for auth, profile, gyms, availability and discovery routes exactly as docs/api/openapi.yaml defines them, with vitest tests and an in-memory repository.
```

Expected result: a PR with passing typecheck and tests and a successful `wrangler deploy --dry-run`.

## 3. Build the iOS shell and demo mode

When: in parallel with prompt 2. Prerequisite: Xcode on your Mac.

```text
In zainpi/BoulderMe, do task T5: create the SwiftUI app shell in ios/ with the cozy design system, the four tabs from docs/screen-map.md, and a clearly labeled demo mode using local fixtures. Build it on my Mac.
```

Expected result: the app runs in the simulator and you can tap Explore demo.

## Future ideas (need earlier steps first)

- **Build the API invitations, chat and safety (T4):** `In zainpi/BoulderMe, do task T4: add invitations, chat, blocks, reports, data export and account deletion to the Worker in api/, exactly as docs/api/openapi.yaml defines them, with tests for every server-side rule.`
- **Understand the app:** `Explain how BoulderMe works end to end, using the docs in zainpi/BoulderMe, in plain language.`
- **Change the look:** `In zainpi/BoulderMe, make the design [describe the change, e.g. warmer colors, rounder cards] and check it with large text and dark mode.`
- **Diagnose an error:** `BoulderMe shows this error: [paste the error with any personal data removed]. Find the cause and fix it.`
- **Security review:** `Review zainpi/BoulderMe against docs/threat-model.md and report anything not yet mitigated.`
- **Go live on staging:** `Deploy the BoulderMe Worker to Cloudflare staging and walk me through the account steps I must do myself.`

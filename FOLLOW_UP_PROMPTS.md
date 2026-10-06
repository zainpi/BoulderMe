# Follow-up prompts

**How to use this file:** copy one prompt below (the text inside a grey box) and paste it into your BoulderMe project chat, or into a new chat that has access to the `zainpi/BoulderMe` repo. Replace anything in `[square brackets]` first. Never paste passwords, API keys or tokens into a prompt.

## Progress note (2026-10-06)

- **Verified:** repo created, API contract (`docs/api/openapi.yaml`) lints clean, architecture, privacy, threat model, screen map and feature matrix written.
- **Not done yet:** database schema, Worker API, iOS app, CI, staging. See `docs/feature-matrix.md`.
- **Next three prompts, in order:** 1, 2, 3 below.

## 1. Build the database schema

When: now. Prerequisite: Supabase connector connected (done).

```text
In zainpi/BoulderMe, do task T2: create the boulderme schema migrations in db/ following docs/domain-model.md and docs/adr/0001-architecture.md. Back up first, apply to the PulseDeals Supabase project, seed the Ontario gym list, and prove anon/authenticated can't read boulderme.*.
```

Expected result: migrations merged, schema live in PulseDeals, a grant check that passes.

## 2. Build the API sign-in, profiles and discovery

When: after prompt 1. Prerequisite: none for local tests.

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

- **Understand the app:** `Explain how BoulderMe works end to end, using the docs in zainpi/BoulderMe, in plain language.`
- **Change the look:** `In zainpi/BoulderMe, make the design [describe the change, e.g. warmer colors, rounder cards] and check it with large text and dark mode.`
- **Diagnose an error:** `BoulderMe shows this error: [paste the error with any personal data removed]. Find the cause and fix it.`
- **Security review:** `Review zainpi/BoulderMe against docs/threat-model.md and report anything not yet mitigated.`
- **Go live on staging:** `Deploy the BoulderMe Worker to Cloudflare staging and walk me through the account steps I must do myself.`

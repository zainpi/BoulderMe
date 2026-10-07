# Follow-up prompts

**How to use this file:** copy one prompt below (the text inside a grey box) and paste it into your BoulderMe project chat, or into a new chat that has access to the `zainpi/BoulderMe` repo. Replace anything in `[square brackets]` first. Never paste passwords, API keys or tokens into a prompt.

## Progress note (2026-10-07)

- **Verified:** repo created, API contract (`docs/api/openapi.yaml`) lints clean, architecture, privacy, threat model, screen map and feature matrix written.
- **Database (T2):** schema `boulderme` is live in PulseDeals with the Ontario gym list; isolation check passes. The `boulderme_api` password was set on 2026-10-07; it goes into the Worker secret `DATABASE_URL` at deploy time (T8). Migration `0002_account_deletion` (T4) is in the repo but not applied to PulseDeals yet; apply it before the Worker is deployed.
- **API (T3, T4):** sign-in, sessions, profile, gyms, availability, pause, discovery, invitations, chat, blocks, reports, data export and account deletion are built and tested against a local Postgres (not deployed yet).
- **iOS (T5, T6, T7):** app shell, demo mode, Sign in with Apple, onboarding, profile, gyms, availability, settings, discovery, invites, chat, blocking and reporting are built and pass CI. They talk to the Worker routes in `docs/api/openapi.yaml`. Settings links to privacy, terms and support point at runsit.ca/boulderme/ (pages merged in zainpi/runIT#7).
- **Staging (T8):** workflow `deploy-staging` deploys the Worker to https://boulderme-api-staging.runsit.ca and runs a three-climber end-to-end check (passes against a local Worker). The first real run needs the GitHub secrets in `SETUP.md` §5 and migration 0002 applied.
- **Not done yet:** first staging run, production deploy, TestFlight. See `docs/feature-matrix.md`.
- **Next prompts:** 4 below to try sign-in locally, then "Apply the account-deletion migration" from Future ideas.

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

## 4. Try sign-in against a local Worker

When: after the Worker sign-in routes (T3) are merged. Prerequisite: a paid Apple Developer team with Sign in with Apple enabled for `com.zainpi.boulderme.debug`.

```text
In zainpi/BoulderMe, run the Worker locally with wrangler dev, turn on Sign in with Apple for Debug in ios/Config/Local.xcconfig, and walk me through signing in on the simulator and finishing onboarding. Fix anything that doesn't match docs/api/openapi.yaml.
```

Expected result: you sign in, finish onboarding, and see your own card on the Profile tab.

## 5. Check the privacy, terms and support pages are live

When: before App Store submission. The pages were merged in zainpi/runIT#7 and the app already links to them.

```text
Check that https://runsit.ca/boulderme/privacy/, /terms/ and /support/ load. If they don't, deploy runsit.ca from zainpi/runIT main.
```

Expected result: Settings → About opens the live pages, and the same URLs go into App Store Connect.

## Future ideas (need earlier steps first)

- **Apply the account-deletion migration:** `In zainpi/BoulderMe, apply db/migrations/0002_account_deletion.sql to the PulseDeals Supabase project the same way as 0001 (back up first, record it in boulderme.schema_migrations, rerun the isolation check).`
- **Understand the app:** `Explain how BoulderMe works end to end, using the docs in zainpi/BoulderMe, in plain language.`
- **Change the look:** `In zainpi/BoulderMe, make the design [describe the change, e.g. warmer colors, rounder cards] and check it with large text and dark mode.`
- **Diagnose an error:** `BoulderMe shows this error: [paste the error with any personal data removed]. Find the cause and fix it.`
- **Security review:** `Review zainpi/BoulderMe against docs/threat-model.md and report anything not yet mitigated.`
- **Re-check staging:** `Run the deploy-staging workflow in zainpi/BoulderMe and fix whatever the end-to-end check reports.`

# BoulderMe working notes

- **Contract first.** `docs/api/openapi.yaml` is the source of truth for every route and field. Change it in the same PR as server or client code that needs a change, and keep `npx -y @redocly/cli@2 lint docs/api/openapi.yaml` clean.
- Wire format: snake_case, lowercase UUIDs, RFC 3339 UTC timestamps, nullable fields always present, `{items, next_cursor}` pages, `Error` envelope with stable `code` values from `ErrorCode`.
- Database: only schema `boulderme` and role `boulderme_api` inside the PulseDeals Supabase project. Never touch `public`, `auth`, `storage` or PulseDeals objects. Back up before any migration (`OPERATIONS.md`).
- Rules (blocks, invitation-before-chat, visibility) are enforced in the Worker and DB, never only in the app. Hidden or blocked = `404 not_found`.
- Never commit secrets. `.env.example` lists names only.
- Keep `docs/feature-matrix.md`, `docs/privacy-inventory.md` and `FOLLOW_UP_PROMPTS.md` current when a PR changes what they describe.
- Branches: `t<N>-<short-name>` per task; PRs into `main`.

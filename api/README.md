# api/

Cloudflare Worker (TypeScript) implementing `docs/api/openapi.yaml`. Built in T3 (auth, profiles, gyms, discovery) and T4 (invitations, chat, safety, deletion).

Planned layout: `src/routes/`, `src/domain/`, `src/db/` (Postgres repository + in-memory repository for tests), `test/`, `wrangler.toml`. Tooling: wrangler, vitest, TypeScript strict.

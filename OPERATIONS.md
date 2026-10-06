# Operations

Runbooks for keeping BoulderMe healthy. Sections marked **(later)** get exact commands when the part they cover is built.

## Golden rules

- BoulderMe lives inside the PulseDeals database. Only ever touch schema `boulderme` and role `boulderme_api`.
- The free Supabase plan has no point-in-time recovery: **back up before every migration.**
- Never print secret values in commands, logs or chat.

## Backup before a migration

```sh
# DATABASE_ADMIN_URL = the project's direct connection string for the postgres user (from the Supabase dashboard; do not save it in the repo)
mkdir -p db/backups
pg_dump "$DATABASE_ADMIN_URL" --schema=boulderme --format=custom --file="db/backups/boulderme-$(date -u +%Y%m%dT%H%M%SZ).dump"
# First time only, also keep a schema-only snapshot of PulseDeals' public schema plus row counts:
pg_dump "$DATABASE_ADMIN_URL" --schema=public --schema-only --file="db/backups/public-schema-$(date -u +%Y%m%dT%H%M%SZ).sql"
```

`db/backups/` is gitignored. Copy dumps somewhere safe off the laptop.

Restore only BoulderMe: `pg_restore --dbname="$DATABASE_ADMIN_URL" --schema=boulderme --clean <file>.dump`.

## Health checks

- **Daily:** `GET /v1/health` returns `status: ok` and `database: ok`. Check open reports (below).
- **Weekly:** Cloudflare dashboard → Workers → `boulderme-api` → errors and request count (stay under 100k/day). Supabase dashboard → Database size (shared 500 MB with PulseDeals).
- **Monthly:** Update dependencies (`npm outdated` in `api/`), rebuild the app with the current Xcode, test restoring the latest backup into a scratch database.

## Moderation (reports)

Review open reports at least every two days. Exact SQL lands with T4; the shape is:

```sql
-- Open reports, oldest first
select id, reason, context, created_at, details, message_snapshot
from boulderme.reports where status = 'open' order by created_at;

-- Mark reviewed
update boulderme.reports set status = 'actioned', reviewer_note = '<what you did>', resolved_at = now() where id = '<report id>';
```

Actions available: dismiss, hide the reported member from discovery (`update boulderme.profiles set discoverable = false ...`), or suspend the account (`update boulderme.accounts set status = 'deleting' ...` then run deletion). Serious safety threats go to local police; keep the report row.

## Deleting a member's data on request

Members delete themselves in Settings → Delete account. If someone asks by email, verify they control the account (ask them to sign in and use the in-app button); the operator path is the deletion job from T4 **(later)**.

## Pausing or shutting down

- **Pause the API:** Cloudflare dashboard → Workers → `boulderme-api` → Settings → disable routes, or deploy the maintenance build **(later)**. The app shows its offline state.
- **Remove BoulderMe from PulseDeals entirely:** back up, then run `db/rollback/drop_boulderme.sql` **(later)**. This drops only schema `boulderme` and role `boulderme_api`.

## Rollback

- **Worker:** `npx wrangler rollback` to the previous version (no data impact).
- **Database:** migrations are additive; to undo the latest one, run its paired down script **(later)** or restore the pre-migration `boulderme` dump. PulseDeals data is never affected.

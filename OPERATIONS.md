# Operations

Runbooks for keeping BoulderMe healthy. Sections marked **(later)** get exact commands when the part they cover is built.

## Golden rules

- BoulderMe lives inside the PulseDeals database. Only ever touch schema `boulderme` and role `boulderme_api`.
- The free Supabase plan has no point-in-time recovery: **back up before every migration.**
- Never print secret values in commands, logs or chat.

## Backup before a migration

With the database password (dashboard → Project Settings → Database):

```sh
# DATABASE_ADMIN_URL = the project's direct connection string for the postgres user (do not save it in the repo)
mkdir -p db/backups
pg_dump "$DATABASE_ADMIN_URL" --schema=boulderme --format=custom --file="db/backups/boulderme-$(date -u +%Y%m%dT%H%M%SZ).dump"
pg_dump "$DATABASE_ADMIN_URL" --schema=public --schema-only --file="db/backups/public-schema-$(date -u +%Y%m%dT%H%M%SZ).sql"
```

`db/backups/` is gitignored. Copy dumps somewhere safe off the laptop.

Restore only BoulderMe: `pg_restore --dbname="$DATABASE_ADMIN_URL" --schema=boulderme --clean <file>.dump`.

**What was done for migration 0001 (2026-10-06).** No database password was available to Claude, so instead of `pg_dump` the pre-migration state of PulseDeals' `public` schema was captured through the Supabase connector: a catalog-derived DDL snapshot (tables, constraints, indexes, functions, triggers, policies, grants) plus a row count and md5 checksum per table. These live in the project's shared files at `boulderme/t2/backup/`. PulseDeals row data was deliberately not copied. After the migration the DDL snapshot was byte-identical and every table's checksum matched, except `pulsedeals_deals`, which PulseDeals' own sync keeps changing (BoulderMe has no access to it). Before migrations that change existing BoulderMe data, take a real `pg_dump` of `boulderme` as above.

## Health checks

- **Daily:** `GET /v1/health` returns `status: ok` and `database: ok`. Check open reports (below).
- **Weekly:** Cloudflare dashboard → Workers → `boulderme-api` → errors and request count (stay under 100k/day). Supabase dashboard → Database size (shared 500 MB with PulseDeals).
- **Monthly:** Update dependencies (`npm outdated` in `api/`), rebuild the app with the current Xcode, test restoring the latest backup into a scratch database.

## Housekeeping (automatic)

The Worker's daily cron (04:17 UTC, `wrangler.toml`) marks pending invitations whose time has passed as `expired`, deletes expired sign-in nonces, rate-limit windows older than two days, idempotency keys older than 24 hours, and refresh sessions that expired or were revoked more than 30 days ago, then retries Apple token revocation for deleted accounts (below). Its log line is `"event":"housekeeping"` with a count per table and `apple_revocations` (`done`, `retry`, `failed`). Nothing to do unless it stops appearing or `failed` is above zero.

## Moderation (reports)

Review open reports at least every two days. Run these as `postgres` in the Supabase SQL editor (the API role cannot change reports). Never tell the reported member who reported them.

```sql
-- 1. Open reports, oldest first, with how often each member has been reported
select r.id, r.created_at, r.reason, r.context, r.reported_id,
       (select count(*) from boulderme.reports x where x.reported_id = r.reported_id) as times_reported,
       p.display_name, r.details, r.message_snapshot, r.invitation_id
from boulderme.reports r
left join boulderme.profiles p on p.account_id = r.reported_id
where r.status = 'open'
order by r.created_at;

-- 2. Claim one while you look into it
update boulderme.reports set status = 'reviewing' where id = '<report id>';

-- 3. Close it: 'dismissed' (nothing wrong) or 'actioned' (you did something below)
update boulderme.reports
set status = 'actioned', reviewer_note = '<what you did>', resolved_at = now()
where id = '<report id>';
```

Actions, mildest first:

```sql
-- Hide the member from discovery (they can turn it back on, so pair with a warning by email if you have one)
update boulderme.profiles set discoverable = false where account_id = '<member id>';

-- Suspend: signs them out everywhere and refuses sign-in; their data stays for review
update boulderme.accounts set status = 'deleting' where id = '<member id>';
update boulderme.refresh_sessions set revoked_at = now() where account_id = '<member id>' and revoked_at is null;

-- Lift a suspension
update boulderme.accounts set status = 'active' where id = '<member id>' and status = 'deleting';

-- Remove the account for good (same function the app's Delete account button uses)
select boulderme.delete_account('<member id>', now());
```

Serious safety threats go to local police; keep the report row. Reports are kept through account deletion; delete resolved ones older than a year (`delete from boulderme.reports where resolved_at < now() - interval '1 year';`).

## Deleting a member's data on request

Members delete themselves in Settings → Delete account (`DELETE /v1/me`). If someone asks by email, verify they control the account (ask them to sign in and use the in-app button). If they cannot, and you are satisfied it is them, run `select boulderme.delete_account('<account id>', now());` as `postgres`.

Deletion is immediate and cannot be undone. It leaves a tombstone holding the Apple ID hash; the Worker revokes the member's Apple sign-in right away and the daily cron retries with backoff up to 8 attempts. Check stuck ones with:

```sql
select account_id, apple_revocation_status, attempts, next_attempt_at
from boulderme.tombstones where apple_revocation_status in ('pending', 'failed');
```

While a tombstone is `pending`, the same Apple ID cannot sign in again; once it is `done`, `failed` or `not_needed`, signing in starts a brand new account. A `failed` revocation means the member should remove BoulderMe under Settings → Apple ID → Sign in with Apple themselves; the stored token is already erased.

## Pausing or shutting down

- **Pause the API:** Cloudflare dashboard → Workers → `boulderme-api` → Settings → disable routes, or deploy the maintenance build **(later)**. The app shows its offline state.
- **Remove BoulderMe from PulseDeals entirely:** back up, then run `db/rollback/drop_boulderme.sql` as `postgres`. This drops only schema `boulderme` and role `boulderme_api`.

## Rollback

- **Worker:** `npx wrangler rollback` to the previous version (no data impact).
- **Database:** migrations are additive; to undo the latest one, write a reverse migration or restore the pre-migration `boulderme` dump. PulseDeals data is never affected.

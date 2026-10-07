# Domain model

Server records live in Postgres schema `boulderme` (migrations in `db/migrations/`). Wire shapes are in `docs/api/openapi.yaml`; this file describes the records behind them and the rules that bind them. All ids are UUIDs, all timestamps `timestamptz` in UTC.

| Entity | Key fields | Rules |
|---|---|---|
| **Account** | `id`, `apple_sub_hash` (unique), `apple_refresh_token_enc`, `status` (`active`, `deleting`, `deleted`), `last_active_on` (date), `created_at` | One per Apple subject. `last_active_on` is a date, never a precise time |
| **RefreshSession** | `id`, `account_id`, `family_id`, `token_hash` (unique), `expires_at`, `used_at`, `revoked_at`, `client_installation_id` | Single use. Reusing a used token revokes the whole family |
| **AuthNonce** | `nonce_hash`, `expires_at`, `used_at` | 10 minute life, single use |
| **Profile** | `account_id` (PK), `revision`, `display_name` (1 to 40), `grade_min`, `grade_max` (0 to 17, min ≤ max), `styles` (≤ 6), `intro` (≤ 280), `discoverable`, `adult_confirmed`, `discovery_explained`, `updated_at` | Discoverable requires a complete profile, `adult_confirmed`, and ≥ 1 gym |
| **Gym** | `id`, `name`, `city`, `region` (`CA-ON`), `country`, `address`, `website_url`, `is_bouldering_only`, `is_active`, `source_url`, `verified_on` | Curated by the operator; seed starts with Ontario |
| **GymAccess** | `account_id`, `gym_id` (PK pair), `access_type` (`membership`, `guest_pass`), `updated_at` | ≤ 10 per account. Always self-reported |
| **AvailabilitySlot** | `id`, `account_id`, `weekday` (1 to 7), `start_minute`, `end_minute` (30 minute steps, ≥ 30 long), `time_zone` (IANA), `gym_id` (nullable) | ≤ 21 per account |
| **Invitation** | `id`, `sender_id`, `recipient_id`, `gym_id`, `proposed_start_at`, `duration_minutes`, `note` (≤ 200), `status`, `chat_id`, `created_at`, `responded_at`, `expires_at` | See state machine below. Partial unique index: one `pending` per unordered pair |
| **ChatThread** | `id`, `account_low_id`, `account_high_id` (unique pair, low < high), `status` (`open`, `closed`), `created_at`, `updated_at` | Created on the pair's first accepted invitation; reopened by a later acceptance unless blocked |
| **ChatReadState** | `chat_id`, `account_id`, `last_read_message_id` | Drives unread counts |
| **ChatMessage** | `id`, `chat_id`, `sender_id` (nullable after deletion), `body` (1 to 1000), `created_at` | Only while the chat is `open` |
| **Block** | `blocker_id`, `blocked_id` (PK pair), `blocked_display_name`, `created_at` | Symmetric effect: hides both ways, cancels pending invites and unfinished sessions, closes chat |
| **Report** | `id`, `reporter_id`, `reported_id`, `context`, `invitation_id`, `message_id`, `reason`, `details`, `message_snapshot`, `status`, `reviewer_note`, `created_at`, `resolved_at` | `message_snapshot` keeps the reported text even if later deleted |
| **GymRequest** | `id`, `account_id`, `name`, `city`, `region`, `website_url`, `note`, `status` | Review queue only |
| **IdempotencyKey** | `account_id`, `key`, `route`, `request_hash`, `response_status`, `response_body`, `created_at` | 24 hour retention. Same key + different body → `idempotency_mismatch` |
| **RateLimit** | `bucket` (`account:<id>:<route>` or `client:<hash>:<route>`), `window_start`, `count` | Fixed windows; client key is a salted hash of the installation id, never an IP |
| **Tombstone** | `apple_sub_hash`, `account_id`, `deleted_at`, `apple_revocation_status`, `attempts` | Stops resurrection; drives durable Apple token revocation retries |

## Invitation state machine

```
pending ──accept (recipient)──▶ accepted ──cancel (either)──▶ cancelled
   │
   ├──decline (recipient)──▶ declined
   ├──cancel (sender)──────▶ cancelled
   ├──block or deletion (either)──▶ cancelled
   └──now ≥ expires_at─────▶ expired   (expires_at = proposed_start_at)

accepted ──block or deletion (either), before the session ends──▶ cancelled
```

Any other transition returns `409 invalid_state`. An accepted session can be cancelled until `proposed_start_at + duration_minutes`. Expiry is evaluated on read and by the daily cleanup, and a stale `pending` row is marked `expired` before a new invitation for the pair is created, so it never holds the one-per-pair slot.

Other invitation rules (all `api/src/routes/invitations.ts`): the sender needs a profile with the 18+ confirmation; the recipient must be discoverable and active, with no block either way (`not_found`); both must list the gym; the time must be 1 hour to 60 days ahead; at most 20 sent per 24 hours.

## Chats

- Accepting an invitation opens the pair's chat, creating it the first time and reopening it later. Its id is stored on the invitation.
- Messages are stamped at the server's time, or 1 ms after the chat's newest message if that is later, while the chat row is locked, so `(created_at, id)` order always matches send order and polling with `after` never skips one.
- Reading messages moves the reader's `chat_read_states` marker forward to the newest message returned (never backwards); sending moves the sender's marker to their own message.
- A block closes the chat and hides it from both; unblocking leaves it `closed` (readable, no sending) until a new invitation is accepted.

## Account deletion

`boulderme.delete_account(account_id, now)` (migration 0002) does everything in one transaction; see `docs/privacy-inventory.md` for what is removed and kept. The Apple ID hash moves to `tombstones`; sign-in with it answers `account_deleted` while revocation is `pending` and creates a new account afterwards.

## Visibility rules

- A member is **visible in discovery** when `discoverable = true`, account `active`, profile complete, lists the searched gym, and no block exists in either direction.
- A **public profile** is readable when visible in discovery, or when the pair shares any invitation or chat, and no block exists.
- **Chats and messages** are readable only by the two participants. Sending requires `open`.
- Every "not allowed to see" case returns `404 not_found`, the same as a missing record.

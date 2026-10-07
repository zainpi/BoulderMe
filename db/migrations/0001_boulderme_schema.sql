-- 0001_boulderme_schema.sql
-- Creates schema `boulderme`, its tables, and the least-privilege role `boulderme_api`.
-- Runs as `postgres` on the PulseDeals Supabase project. Touches nothing outside schema
-- `boulderme` except creating role `boulderme_api` (NOLOGIN; the password is set by hand,
-- see SETUP.md). Applied history lives in boulderme.schema_migrations, not in
-- supabase_migrations, so PulseDeals' own migration history stays untouched.

begin;

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'boulderme_api') then
    create role boulderme_api nologin noinherit nocreatedb nocreaterole;
  end if;
end $$;

create schema if not exists boulderme;
revoke all on schema boulderme from public;

create table boulderme.schema_migrations (
  version    text primary key,
  applied_at timestamptz not null default now()
);

create function boulderme.touch_updated_at() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.updated_at := now();
  return new;
end $$;

-- ------------------------------------------------------------------ accounts and auth

create table boulderme.accounts (
  id                      uuid primary key default gen_random_uuid(),
  apple_sub_hash          text not null unique,
  apple_refresh_token_enc text,
  status                  text not null default 'active' check (status in ('active', 'deleting', 'deleted')),
  last_active_on          date not null default current_date,
  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now(),
  deleted_at              timestamptz,
  check ((status = 'deleted') = (deleted_at is not null))
);

create table boulderme.refresh_sessions (
  id                     uuid primary key default gen_random_uuid(),
  account_id             uuid not null references boulderme.accounts (id) on delete cascade,
  family_id              uuid not null,
  token_hash             text not null unique,
  client_installation_id text check (char_length(client_installation_id) <= 128),
  created_at             timestamptz not null default now(),
  expires_at             timestamptz not null,
  used_at                timestamptz,
  revoked_at             timestamptz
);
create index refresh_sessions_account_idx on boulderme.refresh_sessions (account_id);
create index refresh_sessions_family_idx on boulderme.refresh_sessions (family_id);
create index refresh_sessions_expires_idx on boulderme.refresh_sessions (expires_at);

create table boulderme.auth_nonces (
  nonce_hash text primary key,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  used_at    timestamptz
);
create index auth_nonces_expires_idx on boulderme.auth_nonces (expires_at);

create table boulderme.tombstones (
  apple_sub_hash          text primary key,
  account_id              uuid not null,
  deleted_at              timestamptz not null default now(),
  apple_revocation_status text not null default 'pending' check (apple_revocation_status in ('pending', 'done', 'failed', 'not_needed')),
  attempts                integer not null default 0 check (attempts >= 0),
  next_attempt_at         timestamptz
);
create index tombstones_revocation_idx on boulderme.tombstones (next_attempt_at) where apple_revocation_status = 'pending';

-- ------------------------------------------------------------------ profile

create table boulderme.profiles (
  account_id          uuid primary key references boulderme.accounts (id) on delete cascade,
  revision            integer not null default 1 check (revision >= 1),
  display_name        text not null check (char_length(display_name) between 1 and 40),
  grade_min           smallint not null check (grade_min between 0 and 17),
  grade_max           smallint not null check (grade_max between 0 and 17),
  styles              text[] not null default '{}' check (
                        cardinality(styles) <= 6
                        and styles <@ array['slab', 'vertical', 'overhang', 'roof', 'crimps', 'slopers', 'pinches',
                                            'dynamic', 'technical', 'power', 'comp_style', 'highball']::text[]),
  intro               text check (char_length(intro) <= 280),
  discoverable        boolean not null default false,
  adult_confirmed     boolean not null default false,
  discovery_explained boolean not null default false,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  check (grade_min <= grade_max),
  -- "at least one gym" is checked in the Worker; the rest is enforced here too.
  check (not discoverable or (adult_confirmed and discovery_explained))
);
create index profiles_discoverable_idx on boulderme.profiles (grade_min, grade_max) where discoverable;

-- ------------------------------------------------------------------ gyms

create table boulderme.gyms (
  id                 uuid primary key default gen_random_uuid(),
  slug               text not null unique check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  name               text not null check (char_length(name) between 2 and 80),
  city               text not null check (char_length(city) between 2 and 60),
  region             text not null check (region ~ '^[A-Z]{2}-[A-Z0-9]{1,3}$'),
  country            text not null check (country ~ '^[A-Z]{2}$'),
  address            text check (char_length(address) <= 200),
  website_url        text check (website_url ~ '^https://'),
  is_bouldering_only boolean not null,
  is_active          boolean not null default true,
  source_url         text,
  verified_on        date,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);
create index gyms_listing_idx on boulderme.gyms (region, city, name) where is_active;

create table boulderme.gym_access (
  account_id  uuid not null references boulderme.accounts (id) on delete cascade,
  gym_id      uuid not null references boulderme.gyms (id) on delete cascade,
  access_type text not null check (access_type in ('membership', 'guest_pass')),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  primary key (account_id, gym_id)
);
create index gym_access_gym_idx on boulderme.gym_access (gym_id, access_type);

create table boulderme.gym_requests (
  id          uuid primary key default gen_random_uuid(),
  account_id  uuid references boulderme.accounts (id) on delete set null,
  name        text not null check (char_length(name) between 2 and 80),
  city        text not null check (char_length(city) between 2 and 60),
  region      text not null check (region ~ '^[A-Z]{2}-[A-Z0-9]{1,3}$'),
  website_url text check (char_length(website_url) <= 200),
  note        text check (char_length(note) <= 280),
  status      text not null default 'submitted' check (status in ('submitted', 'added', 'rejected')),
  created_at  timestamptz not null default now(),
  reviewed_at timestamptz
);
create index gym_requests_account_idx on boulderme.gym_requests (account_id, created_at desc);
create index gym_requests_open_idx on boulderme.gym_requests (created_at) where status = 'submitted';

-- ------------------------------------------------------------------ availability

create table boulderme.availability_slots (
  id           uuid primary key default gen_random_uuid(),
  account_id   uuid not null references boulderme.accounts (id) on delete cascade,
  weekday      smallint not null check (weekday between 1 and 7),
  start_minute smallint not null check (start_minute between 0 and 1410 and start_minute % 30 = 0),
  end_minute   smallint not null check (end_minute between 30 and 1440 and end_minute % 30 = 0),
  time_zone    text not null check (char_length(time_zone) between 1 and 64),
  gym_id       uuid references boulderme.gyms (id) on delete set null,
  created_at   timestamptz not null default now(),
  check (end_minute - start_minute >= 30)
);
create index availability_account_idx on boulderme.availability_slots (account_id);
create index availability_weekday_idx on boulderme.availability_slots (weekday, start_minute);

-- ------------------------------------------------------------------ chats and invitations

create table boulderme.chats (
  id              uuid primary key default gen_random_uuid(),
  account_low_id  uuid not null references boulderme.accounts (id),
  account_high_id uuid not null references boulderme.accounts (id),
  status          text not null default 'open' check (status in ('open', 'closed')),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  check (account_low_id < account_high_id),
  unique (account_low_id, account_high_id)
);
create index chats_high_idx on boulderme.chats (account_high_id);

create table boulderme.invitations (
  id                uuid primary key default gen_random_uuid(),
  sender_id         uuid not null references boulderme.accounts (id),
  recipient_id      uuid not null references boulderme.accounts (id),
  gym_id            uuid not null references boulderme.gyms (id),
  proposed_start_at timestamptz not null,
  duration_minutes  smallint not null default 120 check (duration_minutes between 30 and 300),
  note              text check (char_length(note) <= 200),
  status            text not null default 'pending'
                      check (status in ('pending', 'accepted', 'declined', 'cancelled', 'expired')),
  chat_id           uuid references boulderme.chats (id),
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  responded_at      timestamptz,
  expires_at        timestamptz not null,
  check (sender_id <> recipient_id),
  check (status <> 'accepted' or chat_id is not null)
);
-- One pending invitation per unordered pair.
create unique index invitations_one_pending_per_pair
  on boulderme.invitations (least(sender_id, recipient_id), greatest(sender_id, recipient_id))
  where status = 'pending';
create index invitations_recipient_idx on boulderme.invitations (recipient_id, created_at desc, id desc);
create index invitations_sender_idx on boulderme.invitations (sender_id, created_at desc, id desc);
create index invitations_pending_expiry_idx on boulderme.invitations (expires_at) where status = 'pending';
create index invitations_chat_idx on boulderme.invitations (chat_id, proposed_start_at) where status = 'accepted';

create table boulderme.chat_messages (
  id         uuid primary key default gen_random_uuid(),
  chat_id    uuid not null references boulderme.chats (id) on delete cascade,
  sender_id  uuid references boulderme.accounts (id) on delete set null,
  body       text not null check (char_length(body) between 1 and 1000),
  created_at timestamptz not null default now()
);
create index chat_messages_chat_idx on boulderme.chat_messages (chat_id, created_at desc, id desc);

create table boulderme.chat_read_states (
  chat_id              uuid not null references boulderme.chats (id) on delete cascade,
  account_id           uuid not null references boulderme.accounts (id) on delete cascade,
  last_read_message_id uuid references boulderme.chat_messages (id) on delete set null,
  updated_at           timestamptz not null default now(),
  primary key (chat_id, account_id)
);

-- ------------------------------------------------------------------ safety

create table boulderme.blocks (
  blocker_id           uuid not null references boulderme.accounts (id) on delete cascade,
  blocked_id           uuid not null references boulderme.accounts (id) on delete cascade,
  blocked_display_name text check (char_length(blocked_display_name) <= 40),
  created_at           timestamptz not null default now(),
  primary key (blocker_id, blocked_id),
  check (blocker_id <> blocked_id)
);
create index blocks_blocked_idx on boulderme.blocks (blocked_id);

create table boulderme.reports (
  id               uuid primary key default gen_random_uuid(),
  reporter_id      uuid references boulderme.accounts (id) on delete set null,
  reported_id      uuid not null references boulderme.accounts (id),
  context          text not null check (context in ('profile', 'invitation', 'message')),
  invitation_id    uuid references boulderme.invitations (id) on delete set null,
  message_id       uuid references boulderme.chat_messages (id) on delete set null,
  reason           text not null check (reason in ('harassment', 'inappropriate_content', 'spam', 'fake_profile',
                                                   'safety_concern', 'underage', 'other')),
  details          text check (char_length(details) <= 1000),
  message_snapshot text check (char_length(message_snapshot) <= 1000),
  status           text not null default 'open' check (status in ('open', 'reviewing', 'actioned', 'dismissed')),
  reviewer_note    text,
  created_at       timestamptz not null default now(),
  resolved_at      timestamptz
);
create index reports_queue_idx on boulderme.reports (status, created_at);
create index reports_reporter_idx on boulderme.reports (reporter_id, created_at desc);
create index reports_reported_idx on boulderme.reports (reported_id);

-- ------------------------------------------------------------------ request plumbing

create table boulderme.idempotency_keys (
  account_id      uuid not null references boulderme.accounts (id) on delete cascade,
  key             uuid not null,
  route           text not null,
  request_hash    text not null,
  response_status smallint not null,
  response_body   jsonb,
  created_at      timestamptz not null default now(),
  primary key (account_id, key)
);
create index idempotency_keys_created_idx on boulderme.idempotency_keys (created_at);

create table boulderme.rate_limits (
  bucket       text not null,
  window_start timestamptz not null,
  count        integer not null default 0 check (count >= 0),
  primary key (bucket, window_start)
);
create index rate_limits_window_idx on boulderme.rate_limits (window_start);

-- ------------------------------------------------------------------ updated_at triggers

create trigger accounts_touch before update on boulderme.accounts
  for each row execute function boulderme.touch_updated_at();
create trigger profiles_touch before update on boulderme.profiles
  for each row execute function boulderme.touch_updated_at();
create trigger gyms_touch before update on boulderme.gyms
  for each row execute function boulderme.touch_updated_at();
create trigger gym_access_touch before update on boulderme.gym_access
  for each row execute function boulderme.touch_updated_at();
create trigger chats_touch before update on boulderme.chats
  for each row execute function boulderme.touch_updated_at();
create trigger invitations_touch before update on boulderme.invitations
  for each row execute function boulderme.touch_updated_at();

-- ------------------------------------------------------------------ privileges
-- Nobody but boulderme_api (and the owner, postgres) gets anything. Supabase's API roles are
-- revoked explicitly even though nothing granted them access, so a later default-privilege
-- change cannot open this schema up by accident.

revoke all on all tables in schema boulderme from public, anon, authenticated, service_role;
revoke all on all functions in schema boulderme from public, anon, authenticated, service_role;
revoke all on schema boulderme from anon, authenticated, service_role;

grant usage on schema boulderme to boulderme_api;
grant select, insert, update, delete on
  boulderme.accounts, boulderme.refresh_sessions, boulderme.auth_nonces, boulderme.tombstones,
  boulderme.profiles, boulderme.gym_access, boulderme.availability_slots, boulderme.chats,
  boulderme.invitations, boulderme.chat_messages, boulderme.chat_read_states, boulderme.blocks,
  boulderme.idempotency_keys, boulderme.rate_limits
  to boulderme_api;
grant select on boulderme.gyms to boulderme_api;                    -- curated by the operator
grant select, insert on boulderme.gym_requests to boulderme_api;    -- reviewed by the operator
grant select, insert on boulderme.reports to boulderme_api;         -- moderated via SQL runbook
grant execute on function boulderme.touch_updated_at() to boulderme_api;

-- RLS on every table as defence in depth: only boulderme_api has a policy. Not FORCEd, so the
-- owner (postgres, used for seeding and the moderation runbook) is unaffected.
do $$
declare t record;
begin
  for t in select tablename from pg_tables where schemaname = 'boulderme' loop
    execute format('alter table boulderme.%I enable row level security', t.tablename);
    if t.tablename <> 'schema_migrations' then
      execute format('create policy boulderme_api_all on boulderme.%I to boulderme_api using (true) with check (true)',
                     t.tablename);
    end if;
  end loop;
end $$;

alter role boulderme_api set search_path = boulderme;
alter role boulderme_api set statement_timeout = '5s';

insert into boulderme.schema_migrations (version) values ('0001_boulderme_schema');

commit;

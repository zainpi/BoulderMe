// Repository backed by the `boulderme` schema, connected as role `boulderme_api` through the
// Supabase transaction pooler. Every statement is parameterized; nothing from a request is
// ever spliced into SQL text.

import postgres from "postgres";
import type {
  AccessType, AccountRecord, AuthState, ClimbingStyle, DiscoveryQuery, DiscoveryRow, GymAccessRecord,
  GymListQuery, GymRecord, GymRequestFields, GymRequestRecord, IdempotencyClaim, ProfileFields,
  ProfileRecord, PublicProfileRow, RefreshSessionRecord, Repository, SlotFields, SlotRecord,
} from "./repository";
import { TIME_OF_DAY_RANGES } from "../domain";

type Sql = postgres.Sql | postgres.TransactionSql;
type Row = Record<string, any>;

export function connect(databaseUrl: string): postgres.Sql {
  return postgres(databaseUrl, {
    // The transaction pooler (pgbouncer) does not support prepared statements.
    prepare: false,
    max: 1,
    idle_timeout: 5,
    connect_timeout: 5,
    fetch_types: false,
    onnotice: () => {},
  });
}

const PROFILE_COLUMNS = `p.account_id, p.revision, p.display_name, p.grade_min, p.grade_max, p.styles, p.intro,
  p.discoverable, p.adult_confirmed, p.discovery_explained, p.updated_at`;
const GYM_COLUMNS = `g.id, g.name, g.city, g.region, g.country, g.address, g.website_url, g.is_bouldering_only, g.is_active`;
const SLOT_JSON = `json_build_object('id', s.id, 'weekday', s.weekday, 'start_minute', s.start_minute,
  'end_minute', s.end_minute, 'time_zone', s.time_zone, 'gym_id', s.gym_id)`;

export class PostgresRepository implements Repository {
  constructor(private readonly sql: Sql, private readonly inTransaction = false) {}

  async transaction<T>(fn: (repo: Repository) => Promise<T>): Promise<T> {
    if (this.inTransaction) return fn(this);
    const root = this.sql as postgres.Sql;
    return (await root.begin((tx) => fn(new PostgresRepository(tx, true)))) as T;
  }

  private q(text: string, params: unknown[] = []): Promise<Row[]> {
    return this.sql.unsafe(text, params as any[]) as unknown as Promise<Row[]>;
  }

  async ping(): Promise<void> {
    await this.q("select 1");
  }

  // ---------------------------------------------------------------- plumbing

  async hitRateLimit(bucket: string, windowStart: Date): Promise<number> {
    const rows = await this.q(
      `insert into boulderme.rate_limits (bucket, window_start, count) values ($1, $2, 1)
       on conflict (bucket, window_start) do update set count = boulderme.rate_limits.count + 1
       returning count`,
      [bucket, windowStart],
    );
    return Number(rows[0]!.count);
  }

  async claimIdempotencyKey(accountId: string, key: string, route: string, requestHash: string, now: Date): Promise<IdempotencyClaim> {
    await this.q(
      `delete from boulderme.idempotency_keys
       where account_id = $1 and key = $2 and created_at < $3::timestamptz - interval '24 hours'`,
      [accountId, key, now],
    );
    const inserted = await this.q(
      `insert into boulderme.idempotency_keys (account_id, key, route, request_hash, response_status, created_at)
       values ($1, $2, $3, $4, 0, $5)
       on conflict (account_id, key) do nothing
       returning key`,
      [accountId, key, route, requestHash, now],
    );
    if (inserted.length > 0) return { claimed: true };
    const rows = await this.q(
      `select route, request_hash, response_status, response_body from boulderme.idempotency_keys
       where account_id = $1 and key = $2`,
      [accountId, key],
    );
    const row = rows[0]!;
    return {
      claimed: false,
      stored: { route: row.route, requestHash: row.request_hash, status: Number(row.response_status), body: parseJsonValue(row.response_body) },
    };
  }

  async completeIdempotencyKey(accountId: string, key: string, status: number, body: unknown): Promise<void> {
    await this.q(
      `update boulderme.idempotency_keys set response_status = $3, response_body = $4::text::jsonb
       where account_id = $1 and key = $2`,
      [accountId, key, status, JSON.stringify(body)],
    );
  }

  // ---------------------------------------------------------------- auth

  async createNonce(nonceHash: string, expiresAt: Date): Promise<void> {
    await this.q(`insert into boulderme.auth_nonces (nonce_hash, expires_at) values ($1, $2)`, [nonceHash, expiresAt]);
  }

  async consumeNonce(nonceHash: string, now: Date): Promise<boolean> {
    const rows = await this.q(
      `update boulderme.auth_nonces set used_at = $2
       where nonce_hash = $1 and used_at is null and expires_at > $2
       returning nonce_hash`,
      [nonceHash, now],
    );
    return rows.length === 1;
  }

  async findAccountByAppleSub(appleSubHash: string): Promise<AccountRecord | null> {
    const rows = await this.q(`select id, status, created_at from boulderme.accounts where apple_sub_hash = $1`, [appleSubHash]);
    return rows[0] ? toAccount(rows[0]) : null;
  }

  async hasPendingTombstone(appleSubHash: string): Promise<boolean> {
    const rows = await this.q(
      `select 1 from boulderme.tombstones where apple_sub_hash = $1 and apple_revocation_status = 'pending'`,
      [appleSubHash],
    );
    return rows.length > 0;
  }

  async createAccount(appleSubHash: string): Promise<{ account: AccountRecord; created: boolean }> {
    const inserted = await this.q(
      `insert into boulderme.accounts (apple_sub_hash) values ($1)
       on conflict (apple_sub_hash) do nothing
       returning id, status, created_at`,
      [appleSubHash],
    );
    if (inserted[0]) return { account: toAccount(inserted[0]), created: true };
    const existing = await this.findAccountByAppleSub(appleSubHash);
    return { account: existing!, created: false };
  }

  async setAppleRefreshToken(accountId: string, encrypted: string): Promise<void> {
    await this.q(`update boulderme.accounts set apple_refresh_token_enc = $2 where id = $1`, [accountId, encrypted]);
  }

  async createRefreshSession(input: { accountId: string; familyId: string; tokenHash: string; clientInstallationId: string | null; expiresAt: Date }): Promise<void> {
    await this.q(
      `insert into boulderme.refresh_sessions (account_id, family_id, token_hash, client_installation_id, expires_at)
       values ($1, $2, $3, $4, $5)`,
      [input.accountId, input.familyId, input.tokenHash, input.clientInstallationId, input.expiresAt],
    );
  }

  async findRefreshSessionForUpdate(tokenHash: string): Promise<RefreshSessionRecord | null> {
    const rows = await this.q(
      `select id, account_id, family_id, client_installation_id, expires_at, used_at, revoked_at
       from boulderme.refresh_sessions where token_hash = $1 for update`,
      [tokenHash],
    );
    const r = rows[0];
    if (!r) return null;
    return {
      id: r.id, accountId: r.account_id, familyId: r.family_id, clientInstallationId: r.client_installation_id,
      expiresAt: toDate(r.expires_at), usedAt: toDateOrNull(r.used_at), revokedAt: toDateOrNull(r.revoked_at),
    };
  }

  async markRefreshSessionUsed(id: string, now: Date): Promise<void> {
    await this.q(`update boulderme.refresh_sessions set used_at = $2 where id = $1`, [id, now]);
  }

  async revokeSessionFamily(familyId: string, now: Date): Promise<void> {
    await this.q(
      `update boulderme.refresh_sessions set revoked_at = $2 where family_id = $1 and revoked_at is null`,
      [familyId, now],
    );
  }

  async authenticate(accountId: string, familyId: string): Promise<AuthState | null> {
    // One round trip: record today's activity (date precision only) and read status + session.
    const rows = await this.q(
      `with touched as (
         update boulderme.accounts set last_active_on = current_date
         where id = $1 and status = 'active' and last_active_on < current_date
         returning id
       )
       select a.status,
              exists (select 1 from boulderme.refresh_sessions r
                      where r.family_id = $2 and r.account_id = $1 and r.revoked_at is null) as session_active
       from boulderme.accounts a where a.id = $1`,
      [accountId, familyId],
    );
    const r = rows[0];
    return r ? { status: r.status, sessionActive: r.session_active } : null;
  }

  async getAccount(accountId: string): Promise<AccountRecord | null> {
    const rows = await this.q(`select id, status, created_at from boulderme.accounts where id = $1`, [accountId]);
    return rows[0] ? toAccount(rows[0]) : null;
  }

  async lockAccount(accountId: string): Promise<void> {
    await this.q(`select 1 from boulderme.accounts where id = $1 for update`, [accountId]);
  }

  // ---------------------------------------------------------------- profile

  async getProfile(accountId: string): Promise<ProfileRecord | null> {
    const rows = await this.q(`select ${PROFILE_COLUMNS} from boulderme.profiles p where p.account_id = $1`, [accountId]);
    return rows[0] ? toProfile(rows[0]) : null;
  }

  async insertProfile(accountId: string, f: ProfileFields): Promise<ProfileRecord | null> {
    const rows = await this.q(
      `insert into boulderme.profiles as p (account_id, display_name, grade_min, grade_max, styles, intro,
         adult_confirmed, discovery_explained)
       values ($1, $2, $3, $4, $5::text[], $6, $7, $8)
       on conflict (account_id) do nothing
       returning ${PROFILE_COLUMNS}`,
      [accountId, f.displayName, f.gradeMin, f.gradeMax, pgTextArray(f.styles), f.intro, f.adultConfirmed, f.discoveryExplained],
    );
    return rows[0] ? toProfile(rows[0]) : null;
  }

  async updateProfile(accountId: string, expectedRevision: number, f: ProfileFields, discoverable: boolean): Promise<ProfileRecord | null> {
    const rows = await this.q(
      `update boulderme.profiles as p set display_name = $3, grade_min = $4, grade_max = $5, styles = $6::text[],
         intro = $7, adult_confirmed = $8, discovery_explained = $9, discoverable = $10, revision = p.revision + 1
       where p.account_id = $1 and p.revision = $2
       returning ${PROFILE_COLUMNS}`,
      [accountId, expectedRevision, f.displayName, f.gradeMin, f.gradeMax, pgTextArray(f.styles), f.intro, f.adultConfirmed,
        f.discoveryExplained, discoverable],
    );
    return rows[0] ? toProfile(rows[0]) : null;
  }

  async setDiscoverable(accountId: string, discoverable: boolean): Promise<ProfileRecord | null> {
    const rows = await this.q(
      `update boulderme.profiles as p set discoverable = $2,
         revision = case when p.discoverable = $2 then p.revision else p.revision + 1 end
       where p.account_id = $1
       returning ${PROFILE_COLUMNS}`,
      [accountId, discoverable],
    );
    return rows[0] ? toProfile(rows[0]) : null;
  }

  // ---------------------------------------------------------------- gyms

  async listGyms(query: GymListQuery): Promise<GymRecord[]> {
    const rows = await this.q(
      `select ${GYM_COLUMNS} from boulderme.gyms g
       where g.is_active
         and ($1::text is null or g.name ilike $1 escape '\\' or g.city ilike $1 escape '\\')
         and ($2::text is null or g.region = $2)
         and ($3::text is null or (g.city, g.name, g.id) > ($3, $4, $5::uuid))
       order by g.city, g.name, g.id
       limit $6`,
      [
        query.q === null ? null : `%${escapeLike(query.q)}%`,
        query.region,
        query.after?.city ?? null, query.after?.name ?? null, query.after?.id ?? null,
        query.limit,
      ],
    );
    return rows.map(toGym);
  }

  async getGym(gymId: string): Promise<GymRecord | null> {
    const rows = await this.q(`select ${GYM_COLUMNS} from boulderme.gyms g where g.id = $1`, [gymId]);
    return rows[0] ? toGym(rows[0]) : null;
  }

  async listGymAccess(accountId: string): Promise<GymAccessRecord[]> {
    const rows = await this.q(
      `select ${GYM_COLUMNS}, ga.access_type, ga.updated_at as access_updated_at
       from boulderme.gym_access ga join boulderme.gyms g on g.id = ga.gym_id
       where ga.account_id = $1
       order by g.city, g.name, g.id`,
      [accountId],
    );
    return rows.map(toGymAccess);
  }

  async upsertGymAccess(accountId: string, gymId: string, accessType: AccessType): Promise<GymAccessRecord> {
    await this.q(
      `insert into boulderme.gym_access (account_id, gym_id, access_type) values ($1, $2, $3)
       on conflict (account_id, gym_id) do update set access_type = excluded.access_type
       where boulderme.gym_access.access_type is distinct from excluded.access_type`,
      [accountId, gymId, accessType],
    );
    const rows = await this.q(
      `select ${GYM_COLUMNS}, ga.access_type, ga.updated_at as access_updated_at
       from boulderme.gym_access ga join boulderme.gyms g on g.id = ga.gym_id
       where ga.account_id = $1 and ga.gym_id = $2`,
      [accountId, gymId],
    );
    return toGymAccess(rows[0]!);
  }

  async deleteGymAccess(accountId: string, gymId: string): Promise<boolean> {
    const rows = await this.q(
      `delete from boulderme.gym_access where account_id = $1 and gym_id = $2 returning gym_id`,
      [accountId, gymId],
    );
    return rows.length > 0;
  }

  async createGymRequest(accountId: string, f: GymRequestFields): Promise<GymRequestRecord> {
    const rows = await this.q(
      `insert into boulderme.gym_requests (account_id, name, city, region, website_url, note)
       values ($1, $2, $3, $4, $5, $6)
       returning id, name, city, region, status, created_at`,
      [accountId, f.name, f.city, f.region, f.websiteUrl, f.note],
    );
    const r = rows[0]!;
    return { id: r.id, name: r.name, city: r.city, region: r.region, status: r.status, createdAt: toDate(r.created_at) };
  }

  // ---------------------------------------------------------------- availability

  async listSlots(accountId: string): Promise<SlotRecord[]> {
    const rows = await this.q(
      `select id, weekday, start_minute, end_minute, time_zone, gym_id from boulderme.availability_slots
       where account_id = $1 order by weekday, start_minute, id`,
      [accountId],
    );
    return rows.map(toSlot);
  }

  async insertSlot(accountId: string, f: SlotFields): Promise<SlotRecord> {
    const rows = await this.q(
      `insert into boulderme.availability_slots (account_id, weekday, start_minute, end_minute, time_zone, gym_id)
       values ($1, $2, $3, $4, $5, $6)
       returning id, weekday, start_minute, end_minute, time_zone, gym_id`,
      [accountId, f.weekday, f.startMinute, f.endMinute, f.timeZone, f.gymId],
    );
    return toSlot(rows[0]!);
  }

  async updateSlot(accountId: string, slotId: string, f: SlotFields): Promise<SlotRecord | null> {
    const rows = await this.q(
      `update boulderme.availability_slots set weekday = $3, start_minute = $4, end_minute = $5, time_zone = $6, gym_id = $7
       where account_id = $1 and id = $2
       returning id, weekday, start_minute, end_minute, time_zone, gym_id`,
      [accountId, slotId, f.weekday, f.startMinute, f.endMinute, f.timeZone, f.gymId],
    );
    return rows[0] ? toSlot(rows[0]) : null;
  }

  async deleteSlot(accountId: string, slotId: string): Promise<void> {
    await this.q(`delete from boulderme.availability_slots where account_id = $1 and id = $2`, [accountId, slotId]);
  }

  // ---------------------------------------------------------------- counts

  async countUnreadChats(accountId: string): Promise<number> {
    const rows = await this.q(
      `select count(*)::int as n
       from boulderme.chats c
       left join boulderme.chat_read_states rs on rs.chat_id = c.id and rs.account_id = $1
       left join boulderme.chat_messages lr on lr.id = rs.last_read_message_id
       where (c.account_low_id = $1 or c.account_high_id = $1)
         and not exists (
           select 1 from boulderme.blocks b
           where (b.blocker_id = c.account_low_id and b.blocked_id = c.account_high_id)
              or (b.blocker_id = c.account_high_id and b.blocked_id = c.account_low_id))
         and exists (
           select 1 from boulderme.chat_messages m
           where m.chat_id = c.id and m.sender_id is distinct from $1
             and (lr.id is null or (m.created_at, m.id) > (lr.created_at, lr.id)))`,
      [accountId],
    );
    return rows[0]!.n;
  }

  async countPendingIncomingInvitations(accountId: string, now: Date): Promise<number> {
    const rows = await this.q(
      `select count(*)::int as n
       from boulderme.invitations i join boulderme.accounts s on s.id = i.sender_id
       where i.recipient_id = $1 and i.status = 'pending' and i.expires_at > $2 and s.status = 'active'
         and not exists (
           select 1 from boulderme.blocks b
           where (b.blocker_id = $1 and b.blocked_id = i.sender_id) or (b.blocker_id = i.sender_id and b.blocked_id = $1))`,
      [accountId, now],
    );
    return rows[0]!.n;
  }

  // ---------------------------------------------------------------- discovery

  async discover(query: DiscoveryQuery): Promise<DiscoveryRow[]> {
    const tod = query.timeOfDay ? TIME_OF_DAY_RANGES[query.timeOfDay] : null;
    const rows = await this.q(
      `with candidates as (
         select ${PROFILE_COLUMNS}, ga.access_type, a.last_active_on::text as last_active_on,
                least(p.grade_max, $14::int) - greatest(p.grade_min, $13::int) + 1 as overlap
         from boulderme.profiles p
         join boulderme.accounts a on a.id = p.account_id and a.status = 'active'
         join boulderme.gym_access ga on ga.account_id = p.account_id and ga.gym_id = $2
         where p.discoverable
           and p.adult_confirmed and p.discovery_explained
           and p.account_id <> $1
           and p.grade_min <= $4 and p.grade_max >= $3
           and ($5::text is null or ga.access_type = $5)
           and not exists (
             select 1 from boulderme.blocks b
             where (b.blocker_id = $1 and b.blocked_id = p.account_id) or (b.blocker_id = p.account_id and b.blocked_id = $1))
           and ($6::int is null and $7::int is null or exists (
             select 1 from boulderme.availability_slots s
             where s.account_id = p.account_id and (s.gym_id is null or s.gym_id = $2)
               and ($6::int is null or s.weekday = $6)
               and ($7::int is null or (s.start_minute < $8 and s.end_minute > $7))))
       )
       select c.*,
              coalesce((select json_agg(${SLOT_JSON} order by s.weekday, s.start_minute, s.id)
                        from boulderme.availability_slots s
                        where s.account_id = c.account_id and (s.gym_id is null or s.gym_id = $2)), '[]') as slots
       from candidates c
       where $9::int is null
          or c.overlap < $9
          or (c.overlap = $9 and c.last_active_on < $10)
          or (c.overlap = $9 and c.last_active_on = $10 and c.account_id > $11::uuid)
       order by c.overlap desc, c.last_active_on desc, c.account_id
       limit $12`,
      [
        query.callerId, query.gymId, query.gradeMin, query.gradeMax, query.accessType,
        query.weekday, tod?.[0] ?? null, tod?.[1] ?? null,
        query.after?.overlap ?? null, query.after?.lastActiveOn ?? null, query.after?.accountId ?? null,
        query.limit, query.rankMin, query.rankMax,
      ],
    );
    return rows.map((r) => ({
      profile: toProfile(r),
      accessType: r.access_type,
      slots: parseJson(r.slots).map(toSlot),
      lastActiveOn: r.last_active_on,
      overlap: Number(r.overlap),
    }));
  }

  async getVisibleProfile(callerId: string, targetId: string): Promise<PublicProfileRow | null> {
    const rows = await this.q(
      `select ${PROFILE_COLUMNS}, a.last_active_on::text as last_active_on
       from boulderme.profiles p
       join boulderme.accounts a on a.id = p.account_id and a.status = 'active'
       where p.account_id = $2
         and not exists (
           select 1 from boulderme.blocks b
           where (b.blocker_id = $1 and b.blocked_id = $2) or (b.blocker_id = $2 and b.blocked_id = $1))
         and (
           p.account_id = $1
           or (p.discoverable and exists (select 1 from boulderme.gym_access ga where ga.account_id = $2))
           or exists (select 1 from boulderme.invitations i
                      where (i.sender_id = $1 and i.recipient_id = $2) or (i.sender_id = $2 and i.recipient_id = $1))
           or exists (select 1 from boulderme.chats c
                      where c.account_low_id = least($1::uuid, $2::uuid) and c.account_high_id = greatest($1::uuid, $2::uuid)))`,
      [callerId, targetId],
    );
    const r = rows[0];
    if (!r) return null;
    const [gyms, slots] = await Promise.all([this.listGymAccess(targetId), this.listSlots(targetId)]);
    return { profile: toProfile(r), gyms, slots, lastActiveOn: r.last_active_on };
  }

  // ---------------------------------------------------------------- housekeeping

  async purgeExpired(now: Date): Promise<Record<string, number>> {
    const count = async (text: string) => (await this.q(text, [now])).length;
    return {
      auth_nonces: await count(`delete from boulderme.auth_nonces where expires_at < $1 - interval '1 day' returning 1`),
      rate_limits: await count(`delete from boulderme.rate_limits where window_start < $1 - interval '2 days' returning 1`),
      idempotency_keys: await count(`delete from boulderme.idempotency_keys where created_at < $1 - interval '24 hours' returning 1`),
      refresh_sessions: await count(
        `delete from boulderme.refresh_sessions
         where expires_at < $1 - interval '30 days' or revoked_at < $1 - interval '30 days' returning 1`),
    };
  }
}

// ------------------------------------------------------------------ row mapping

function toDate(v: unknown): Date {
  return v instanceof Date ? v : new Date(String(v));
}

function toDateOrNull(v: unknown): Date | null {
  return v === null || v === undefined ? null : toDate(v);
}

function parseJsonValue(v: unknown): unknown {
  return typeof v === "string" ? JSON.parse(v) : v;
}

function parseJson(v: unknown): Row[] {
  return typeof v === "string" ? JSON.parse(v) : (v as Row[]);
}

function parseTextArray(v: unknown): string[] {
  if (Array.isArray(v)) return v;
  // With fetch_types off, text[] can arrive in Postgres array literal form: {a,b}
  const s = String(v ?? "{}");
  const inner = s.slice(1, -1);
  return inner === "" ? [] : inner.split(",").map((x) => x.replace(/^"|"$/g, ""));
}

function toAccount(r: Row): AccountRecord {
  return { id: r.id, status: r.status, createdAt: toDate(r.created_at) };
}

function toProfile(r: Row): ProfileRecord {
  return {
    accountId: r.account_id,
    revision: Number(r.revision),
    displayName: r.display_name,
    gradeMin: Number(r.grade_min),
    gradeMax: Number(r.grade_max),
    styles: parseTextArray(r.styles) as ClimbingStyle[],
    intro: r.intro,
    discoverable: r.discoverable,
    adultConfirmed: r.adult_confirmed,
    discoveryExplained: r.discovery_explained,
    updatedAt: toDate(r.updated_at),
  };
}

function toGym(r: Row): GymRecord {
  return {
    id: r.id, name: r.name, city: r.city, region: r.region, country: r.country, address: r.address,
    websiteUrl: r.website_url, isBoulderingOnly: r.is_bouldering_only, isActive: r.is_active,
  };
}

function toGymAccess(r: Row): GymAccessRecord {
  return { gym: toGym(r), accessType: r.access_type, updatedAt: toDate(r.access_updated_at) };
}

function toSlot(r: Row): SlotRecord {
  return {
    id: r.id, weekday: Number(r.weekday), startMinute: Number(r.start_minute), endMinute: Number(r.end_minute),
    timeZone: r.time_zone, gymId: r.gym_id,
  };
}

/** Postgres array literal; elements are quoted so any text is safe. */
function pgTextArray(values: string[]): string {
  return `{${values.map((v) => `"${v.replace(/["\\]/g, (c) => `\\${c}`)}"`).join(",")}}`;
}

function escapeLike(s: string): string {
  return s.replace(/[\\%_]/g, (c) => `\\${c}`);
}

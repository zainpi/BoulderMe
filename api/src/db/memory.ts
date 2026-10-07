// In-memory Repository for route tests. Mirrors the SQL in postgres.ts rule for rule; the
// shared contract suite in test/ runs against both so they cannot drift apart.

import type {
  AccessType, AccountRecord, AccountStatus, AuthState, DiscoveryQuery, DiscoveryRow, GymAccessRecord,
  GymListQuery, GymRecord, GymRequestFields, GymRequestRecord, IdempotencyClaim, ProfileFields, ProfileRecord,
  PublicProfileRow, RefreshSessionRecord, Repository, SlotFields, SlotRecord, StoredIdempotentResponse,
} from "./repository";
import { slotOverlapsTimeOfDay, utcDate } from "../domain";

interface AccountRow extends AccountRecord {
  appleSubHash: string;
  appleRefreshTokenEnc: string | null;
  lastActiveOn: string;
}

interface SessionRow extends RefreshSessionRecord {
  tokenHash: string;
}

interface GymAccessRow {
  accountId: string;
  gymId: string;
  accessType: AccessType;
  updatedAt: Date;
}

interface IdempotencyRow extends StoredIdempotentResponse {
  createdAt: Date;
}

export interface InvitationRow {
  id: string;
  senderId: string;
  recipientId: string;
  status: "pending" | "accepted" | "declined" | "cancelled" | "expired";
  expiresAt: Date;
}

export interface ChatRow {
  id: string;
  lowId: string;
  highId: string;
}

export interface MessageRow {
  id: string;
  chatId: string;
  senderId: string | null;
  createdAt: Date;
}

export interface MemoryState {
  accounts: Map<string, AccountRow>;
  sessions: SessionRow[];
  nonces: Map<string, { expiresAt: Date; usedAt: Date | null }>;
  tombstones: Map<string, "pending" | "done" | "failed" | "not_needed">;
  profiles: Map<string, ProfileRecord>;
  gyms: Map<string, GymRecord>;
  gymAccess: GymAccessRow[];
  gymRequests: (GymRequestRecord & { accountId: string; websiteUrl: string | null; note: string | null })[];
  slots: (SlotRecord & { accountId: string })[];
  invitations: InvitationRow[];
  chats: ChatRow[];
  messages: MessageRow[];
  readStates: Map<string, string>; // `${chatId}:${accountId}` -> last read message id
  blocks: { blockerId: string; blockedId: string }[];
  idempotency: Map<string, IdempotencyRow>;
  rateLimits: Map<string, number>;
}

export function emptyState(): MemoryState {
  return {
    accounts: new Map(), sessions: [], nonces: new Map(), tombstones: new Map(), profiles: new Map(),
    gyms: new Map(), gymAccess: [], gymRequests: [], slots: [], invitations: [], chats: [], messages: [],
    readStates: new Map(), blocks: [], idempotency: new Map(), rateLimits: new Map(),
  };
}

export class MemoryRepository implements Repository {
  state: MemoryState;
  private lock: Promise<void> = Promise.resolve();

  constructor(
    state: MemoryState = emptyState(),
    private readonly clock: () => Date = () => new Date(),
    private readonly inTransaction = false,
  ) {
    this.state = state;
  }

  async transaction<T>(fn: (repo: Repository) => Promise<T>): Promise<T> {
    if (this.inTransaction) return fn(this);
    // Serialize transactions and roll back on error, like a database would.
    const previous = this.lock;
    let release!: () => void;
    this.lock = new Promise((resolve) => (release = resolve));
    await previous;
    const snapshot = structuredClone(this.state);
    try {
      return await fn(new MemoryRepository(this.state, this.clock, true));
    } catch (err) {
      this.restore(snapshot);
      throw err;
    } finally {
      release();
    }
  }

  private restore(snapshot: MemoryState): void {
    Object.assign(this.state, snapshot);
  }

  async ping(): Promise<void> {}

  // ---------------------------------------------------------------- plumbing

  async hitRateLimit(bucket: string, windowStart: Date): Promise<number> {
    const key = `${bucket}@${windowStart.toISOString()}`;
    const count = (this.state.rateLimits.get(key) ?? 0) + 1;
    this.state.rateLimits.set(key, count);
    return count;
  }

  async claimIdempotencyKey(accountId: string, key: string, route: string, requestHash: string, now: Date): Promise<IdempotencyClaim> {
    const id = `${accountId}:${key}`;
    const existing = this.state.idempotency.get(id);
    if (existing && existing.createdAt.getTime() >= now.getTime() - 86_400_000) {
      const { route: r, requestHash: h, status, body } = existing;
      return { claimed: false, stored: { route: r, requestHash: h, status, body } };
    }
    this.state.idempotency.set(id, { route, requestHash, status: 0, body: null, createdAt: now });
    return { claimed: true };
  }

  async completeIdempotencyKey(accountId: string, key: string, status: number, body: unknown): Promise<void> {
    const row = this.state.idempotency.get(`${accountId}:${key}`);
    if (row) {
      row.status = status;
      row.body = structuredClone(body);
    }
  }

  // ---------------------------------------------------------------- auth

  async createNonce(nonceHash: string, expiresAt: Date): Promise<void> {
    this.state.nonces.set(nonceHash, { expiresAt, usedAt: null });
  }

  async consumeNonce(nonceHash: string, now: Date): Promise<boolean> {
    const n = this.state.nonces.get(nonceHash);
    if (!n || n.usedAt || n.expiresAt <= now) return false;
    n.usedAt = now;
    return true;
  }

  async findAccountByAppleSub(appleSubHash: string): Promise<AccountRecord | null> {
    for (const a of this.state.accounts.values()) if (a.appleSubHash === appleSubHash) return account(a);
    return null;
  }

  async hasPendingTombstone(appleSubHash: string): Promise<boolean> {
    return this.state.tombstones.get(appleSubHash) === "pending";
  }

  async createAccount(appleSubHash: string): Promise<{ account: AccountRecord; created: boolean }> {
    const existing = await this.findAccountByAppleSub(appleSubHash);
    if (existing) return { account: existing, created: false };
    const row: AccountRow = {
      id: crypto.randomUUID(), status: "active", createdAt: this.clock(), appleSubHash, appleRefreshTokenEnc: null,
      lastActiveOn: utcDate(this.clock()),
    };
    this.state.accounts.set(row.id, row);
    return { account: account(row), created: true };
  }

  async setAppleRefreshToken(accountId: string, encrypted: string): Promise<void> {
    const a = this.state.accounts.get(accountId);
    if (a) a.appleRefreshTokenEnc = encrypted;
  }

  async createRefreshSession(input: { accountId: string; familyId: string; tokenHash: string; clientInstallationId: string | null; expiresAt: Date }): Promise<void> {
    if (this.state.sessions.some((s) => s.tokenHash === input.tokenHash)) throw new Error("duplicate token hash");
    this.state.sessions.push({ id: crypto.randomUUID(), usedAt: null, revokedAt: null, ...input });
  }

  async findRefreshSessionForUpdate(tokenHash: string): Promise<RefreshSessionRecord | null> {
    const s = this.state.sessions.find((x) => x.tokenHash === tokenHash);
    if (!s) return null;
    const { tokenHash: _, ...rest } = s;
    return { ...rest };
  }

  async markRefreshSessionUsed(id: string, now: Date): Promise<void> {
    const s = this.state.sessions.find((x) => x.id === id);
    if (s) s.usedAt = now;
  }

  async revokeSessionFamily(familyId: string, now: Date): Promise<void> {
    for (const s of this.state.sessions) if (s.familyId === familyId && !s.revokedAt) s.revokedAt = now;
  }

  async authenticate(accountId: string, familyId: string): Promise<AuthState | null> {
    const a = this.state.accounts.get(accountId);
    if (!a) return null;
    const today = utcDate(this.clock());
    if (a.status === "active" && a.lastActiveOn < today) a.lastActiveOn = today;
    const sessionActive = this.state.sessions.some((s) => s.familyId === familyId && s.accountId === accountId && !s.revokedAt);
    return { status: a.status, sessionActive };
  }

  async getAccount(accountId: string): Promise<AccountRecord | null> {
    const a = this.state.accounts.get(accountId);
    return a ? account(a) : null;
  }

  async lockAccount(): Promise<void> {}

  // ---------------------------------------------------------------- profile

  async getProfile(accountId: string): Promise<ProfileRecord | null> {
    const p = this.state.profiles.get(accountId);
    return p ? { ...p, styles: [...p.styles] } : null;
  }

  async insertProfile(accountId: string, f: ProfileFields): Promise<ProfileRecord | null> {
    if (this.state.profiles.has(accountId)) return null;
    const p: ProfileRecord = { accountId, revision: 1, discoverable: false, updatedAt: this.clock(), ...f, styles: [...f.styles] };
    this.state.profiles.set(accountId, p);
    return this.getProfile(accountId);
  }

  async updateProfile(accountId: string, expectedRevision: number, f: ProfileFields, discoverable: boolean): Promise<ProfileRecord | null> {
    const p = this.state.profiles.get(accountId);
    if (!p || p.revision !== expectedRevision) return null;
    Object.assign(p, f, { styles: [...f.styles], discoverable, revision: p.revision + 1, updatedAt: this.clock() });
    return this.getProfile(accountId);
  }

  async setDiscoverable(accountId: string, discoverable: boolean): Promise<ProfileRecord | null> {
    const p = this.state.profiles.get(accountId);
    if (!p) return null;
    if (p.discoverable !== discoverable) Object.assign(p, { discoverable, revision: p.revision + 1, updatedAt: this.clock() });
    return this.getProfile(accountId);
  }

  // ---------------------------------------------------------------- gyms

  async listGyms(query: GymListQuery): Promise<GymRecord[]> {
    const q = query.q?.toLowerCase() ?? null;
    return [...this.state.gyms.values()]
      .filter((g) => g.isActive)
      .filter((g) => q === null || g.name.toLowerCase().includes(q) || g.city.toLowerCase().includes(q))
      .filter((g) => query.region === null || g.region === query.region)
      .sort(compareGyms)
      .filter((g) => !query.after || compareGyms(g, query.after) > 0)
      .slice(0, query.limit)
      .map((g) => ({ ...g }));
  }

  async getGym(gymId: string): Promise<GymRecord | null> {
    const g = this.state.gyms.get(gymId);
    return g ? { ...g } : null;
  }

  async listGymAccess(accountId: string): Promise<GymAccessRecord[]> {
    return this.state.gymAccess
      .filter((ga) => ga.accountId === accountId)
      .map((ga) => ({ gym: { ...this.state.gyms.get(ga.gymId)! }, accessType: ga.accessType, updatedAt: ga.updatedAt }))
      .sort((a, b) => compareGyms(a.gym, b.gym));
  }

  async upsertGymAccess(accountId: string, gymId: string, accessType: AccessType): Promise<GymAccessRecord> {
    const existing = this.state.gymAccess.find((ga) => ga.accountId === accountId && ga.gymId === gymId);
    if (!existing) this.state.gymAccess.push({ accountId, gymId, accessType, updatedAt: this.clock() });
    else if (existing.accessType !== accessType) Object.assign(existing, { accessType, updatedAt: this.clock() });
    return (await this.listGymAccess(accountId)).find((ga) => ga.gym.id === gymId)!;
  }

  async deleteGymAccess(accountId: string, gymId: string): Promise<boolean> {
    const before = this.state.gymAccess.length;
    this.state.gymAccess = this.state.gymAccess.filter((ga) => !(ga.accountId === accountId && ga.gymId === gymId));
    return this.state.gymAccess.length < before;
  }

  async createGymRequest(accountId: string, f: GymRequestFields): Promise<GymRequestRecord> {
    const row = { id: crypto.randomUUID(), accountId, status: "submitted" as const, createdAt: this.clock(), ...f };
    this.state.gymRequests.push(row);
    return { id: row.id, name: row.name, city: row.city, region: row.region, status: row.status, createdAt: row.createdAt };
  }

  // ---------------------------------------------------------------- availability

  async listSlots(accountId: string): Promise<SlotRecord[]> {
    return this.state.slots
      .filter((s) => s.accountId === accountId)
      .sort((a, b) => a.weekday - b.weekday || a.startMinute - b.startMinute || cmp(a.id, b.id))
      .map(({ accountId: _, ...s }) => s);
  }

  async insertSlot(accountId: string, f: SlotFields): Promise<SlotRecord> {
    const row = { id: crypto.randomUUID(), accountId, ...f };
    this.state.slots.push(row);
    const { accountId: _, ...slot } = row;
    return slot;
  }

  async updateSlot(accountId: string, slotId: string, f: SlotFields): Promise<SlotRecord | null> {
    const row = this.state.slots.find((s) => s.accountId === accountId && s.id === slotId);
    if (!row) return null;
    Object.assign(row, f);
    const { accountId: _, ...slot } = row;
    return { ...slot };
  }

  async deleteSlot(accountId: string, slotId: string): Promise<void> {
    this.state.slots = this.state.slots.filter((s) => !(s.accountId === accountId && s.id === slotId));
  }

  // ---------------------------------------------------------------- counts

  async countUnreadChats(accountId: string): Promise<number> {
    let n = 0;
    for (const c of this.state.chats) {
      if (c.lowId !== accountId && c.highId !== accountId) continue;
      if (this.blockedEitherWay(c.lowId, c.highId)) continue;
      const lastReadId = this.state.readStates.get(`${c.id}:${accountId}`);
      const lastRead = lastReadId ? this.state.messages.find((m) => m.id === lastReadId) : undefined;
      const unread = this.state.messages.some(
        (m) => m.chatId === c.id && m.senderId !== accountId && (!lastRead || compareMessages(m, lastRead) > 0),
      );
      if (unread) n++;
    }
    return n;
  }

  async countPendingIncomingInvitations(accountId: string, now: Date): Promise<number> {
    return this.state.invitations.filter(
      (i) => i.recipientId === accountId && i.status === "pending" && i.expiresAt > now
        && this.state.accounts.get(i.senderId)?.status === "active" && !this.blockedEitherWay(accountId, i.senderId),
    ).length;
  }

  // ---------------------------------------------------------------- discovery

  async discover(q: DiscoveryQuery): Promise<DiscoveryRow[]> {
    const rows: DiscoveryRow[] = [];
    for (const p of this.state.profiles.values()) {
      const a = this.state.accounts.get(p.accountId);
      if (!a || a.status !== "active") continue;
      if (!p.discoverable || !p.adultConfirmed || !p.discoveryExplained || p.accountId === q.callerId) continue;
      if (p.gradeMin > q.gradeMax || p.gradeMax < q.gradeMin) continue;
      const access = this.state.gymAccess.find((ga) => ga.accountId === p.accountId && ga.gymId === q.gymId);
      if (!access || (q.accessType && access.accessType !== q.accessType)) continue;
      if (this.blockedEitherWay(q.callerId, p.accountId)) continue;
      const slots = (await this.listSlots(p.accountId)).filter((s) => s.gymId === null || s.gymId === q.gymId);
      if (q.weekday !== null || q.timeOfDay !== null) {
        const match = slots.some((s) => (q.weekday === null || s.weekday === q.weekday)
          && (q.timeOfDay === null || slotOverlapsTimeOfDay(s, q.timeOfDay)));
        if (!match) continue;
      }
      const overlap = Math.min(p.gradeMax, q.rankMax) - Math.max(p.gradeMin, q.rankMin) + 1;
      rows.push({ profile: { ...p, styles: [...p.styles] }, accessType: access.accessType, slots, lastActiveOn: a.lastActiveOn, overlap });
    }
    rows.sort((x, y) => y.overlap - x.overlap || cmp(y.lastActiveOn, x.lastActiveOn) || cmp(x.profile.accountId, y.profile.accountId));
    const after = q.after;
    return rows
      .filter((r) => !after || r.overlap < after.overlap
        || (r.overlap === after.overlap && r.lastActiveOn < after.lastActiveOn)
        || (r.overlap === after.overlap && r.lastActiveOn === after.lastActiveOn && r.profile.accountId > after.accountId))
      .slice(0, q.limit);
  }

  async getVisibleProfile(callerId: string, targetId: string): Promise<PublicProfileRow | null> {
    const p = this.state.profiles.get(targetId);
    const a = this.state.accounts.get(targetId);
    if (!p || !a || a.status !== "active") return null;
    if (this.blockedEitherWay(callerId, targetId)) return null;
    const gyms = await this.listGymAccess(targetId);
    const shared = this.state.invitations.some(
      (i) => (i.senderId === callerId && i.recipientId === targetId) || (i.senderId === targetId && i.recipientId === callerId),
    ) || this.state.chats.some((c) => (c.lowId === callerId && c.highId === targetId) || (c.lowId === targetId && c.highId === callerId));
    const visible = targetId === callerId || (p.discoverable && gyms.length > 0) || shared;
    if (!visible) return null;
    return { profile: { ...p, styles: [...p.styles] }, gyms, slots: await this.listSlots(targetId), lastActiveOn: a.lastActiveOn };
  }

  // ---------------------------------------------------------------- housekeeping

  async purgeExpired(now: Date): Promise<Record<string, number>> {
    const day = 86_400_000;
    let nonces = 0;
    for (const [k, n] of this.state.nonces) if (n.expiresAt.getTime() < now.getTime() - day) { this.state.nonces.delete(k); nonces++; }
    let keys = 0;
    for (const [k, r] of this.state.idempotency) if (r.createdAt.getTime() < now.getTime() - day) { this.state.idempotency.delete(k); keys++; }
    const before = this.state.sessions.length;
    const cutoff = now.getTime() - 30 * day;
    this.state.sessions = this.state.sessions.filter(
      (s) => !(s.expiresAt.getTime() < cutoff || (s.revokedAt && s.revokedAt.getTime() < cutoff)),
    );
    let windows = 0;
    for (const k of [...this.state.rateLimits.keys()]) {
      if (new Date(k.slice(k.lastIndexOf("@") + 1)).getTime() < now.getTime() - 2 * day) { this.state.rateLimits.delete(k); windows++; }
    }
    return { auth_nonces: nonces, rate_limits: windows, idempotency_keys: keys, refresh_sessions: before - this.state.sessions.length };
  }

  // ---------------------------------------------------------------- test helpers

  addGym(g: Partial<GymRecord> & Pick<GymRecord, "name" | "city">): GymRecord {
    const gym: GymRecord = {
      id: crypto.randomUUID(), region: "CA-ON", country: "CA", address: null, websiteUrl: null, isBoulderingOnly: true,
      isActive: true, ...g,
    };
    this.state.gyms.set(gym.id, gym);
    return gym;
  }

  setAccountStatus(accountId: string, status: AccountStatus): void {
    this.state.accounts.get(accountId)!.status = status;
  }

  setLastActiveOn(accountId: string, date: string): void {
    this.state.accounts.get(accountId)!.lastActiveOn = date;
  }

  addBlock(blockerId: string, blockedId: string): void {
    this.state.blocks.push({ blockerId, blockedId });
  }

  addInvitation(row: Omit<InvitationRow, "id">): InvitationRow {
    const inv = { id: crypto.randomUUID(), ...row };
    this.state.invitations.push(inv);
    return inv;
  }

  addTombstone(appleSubHash: string, status: "pending" | "done" = "pending"): void {
    this.state.tombstones.set(appleSubHash, status);
  }

  private blockedEitherWay(a: string, b: string): boolean {
    return this.state.blocks.some((x) => (x.blockerId === a && x.blockedId === b) || (x.blockerId === b && x.blockedId === a));
  }
}

function account(a: AccountRow): AccountRecord {
  return { id: a.id, status: a.status, createdAt: a.createdAt };
}

function cmp(a: string, b: string): number {
  return a < b ? -1 : a > b ? 1 : 0;
}

function compareGyms(a: { city: string; name: string; id: string }, b: { city: string; name: string; id: string }): number {
  return cmp(a.city, b.city) || cmp(a.name, b.name) || cmp(a.id, b.id);
}

function compareMessages(a: MessageRow, b: MessageRow): number {
  return a.createdAt.getTime() - b.createdAt.getTime() || cmp(a.id, b.id);
}

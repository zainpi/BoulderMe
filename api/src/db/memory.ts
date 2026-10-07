// In-memory Repository for route tests. Mirrors the SQL in postgres.ts rule for rule; the
// shared contract suite in test/ runs against both so they cannot drift apart.

import type {
  AccessType, AccountRecord, AccountStatus, AuthState, BlockRecord, ChatRecord, DiscoveryQuery, DiscoveryRow,
  GymAccessRecord, GymListQuery, GymRecord, GymRequestFields, GymRequestRecord, IdempotencyClaim, InvitationFields,
  InvitationListQuery, InvitationRecord, InvitationStatus, MessageListQuery, MessageRecord, PartyRecord,
  PendingRevocation, ProfileFields, ProfileRecord, PublicProfileRow, RefreshSessionRecord, ReportFields, ReportRecord,
  Repository, RevocationOutcome, SlotFields, SlotRecord, StoredIdempotentResponse, TimeKey,
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
  gymId: string;
  proposedStartAt: Date;
  durationMinutes: number;
  note: string | null;
  status: InvitationStatus;
  chatId: string | null;
  createdAt: Date;
  respondedAt: Date | null;
  expiresAt: Date;
}

export interface ChatRow {
  id: string;
  lowId: string;
  highId: string;
  status: "open" | "closed";
  createdAt: Date;
  updatedAt: Date;
}

export type MessageRow = MessageRecord;

interface BlockRow {
  blockerId: string;
  blockedId: string;
  displayName: string | null;
  createdAt: Date;
}

interface TombstoneRow {
  accountId: string;
  status: "pending" | "done" | "failed" | "not_needed";
  attempts: number;
  nextAttemptAt: Date | null;
}

interface ReportRow extends ReportFields {
  record: ReportRecord;
}

export interface MemoryState {
  accounts: Map<string, AccountRow>;
  sessions: SessionRow[];
  nonces: Map<string, { expiresAt: Date; usedAt: Date | null }>;
  tombstones: Map<string, TombstoneRow>;
  profiles: Map<string, ProfileRecord>;
  gyms: Map<string, GymRecord>;
  gymAccess: GymAccessRow[];
  gymRequests: (GymRequestRecord & { accountId: string; websiteUrl: string | null; note: string | null })[];
  slots: (SlotRecord & { accountId: string })[];
  invitations: InvitationRow[];
  chats: ChatRow[];
  messages: MessageRow[];
  readStates: Map<string, string>; // `${chatId}:${accountId}` -> last read message id
  blocks: BlockRow[];
  reports: ReportRow[];
  idempotency: Map<string, IdempotencyRow>;
  rateLimits: Map<string, number>;
}

export function emptyState(): MemoryState {
  return {
    accounts: new Map(), sessions: [], nonces: new Map(), tombstones: new Map(), profiles: new Map(),
    gyms: new Map(), gymAccess: [], gymRequests: [], slots: [], invitations: [], chats: [], messages: [],
    readStates: new Map(), blocks: [], reports: [], idempotency: new Map(), rateLimits: new Map(),
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
    return this.state.tombstones.get(appleSubHash)?.status === "pending";
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
      if (this.isBlocked(c.lowId, c.highId)) continue;
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
        && this.state.accounts.get(i.senderId)?.status === "active" && !this.isBlocked(accountId, i.senderId),
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
      if (this.isBlocked(q.callerId, p.accountId)) continue;
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
    if (this.isBlocked(callerId, targetId)) return null;
    const gyms = await this.listGymAccess(targetId);
    const shared = this.state.invitations.some(
      (i) => (i.senderId === callerId && i.recipientId === targetId) || (i.senderId === targetId && i.recipientId === callerId),
    ) || this.state.chats.some((c) => (c.lowId === callerId && c.highId === targetId) || (c.lowId === targetId && c.highId === callerId));
    const visible = targetId === callerId || (p.discoverable && gyms.length > 0) || shared;
    if (!visible) return null;
    return { profile: { ...p, styles: [...p.styles] }, gyms, slots: await this.listSlots(targetId), lastActiveOn: a.lastActiveOn };
  }

  // ---------------------------------------------------------------- invitations

  async blockedEitherWay(a: string, b: string): Promise<boolean> {
    return this.isBlocked(a, b);
  }

  async countInvitationsSentSince(senderId: string, since: Date): Promise<number> {
    return this.state.invitations.filter((i) => i.senderId === senderId && i.createdAt > since).length;
  }

  async expireStalePending(a: string, b: string, now: Date): Promise<void> {
    for (const i of this.state.invitations) {
      if (samePair(i.senderId, i.recipientId, a, b) && i.status === "pending" && i.expiresAt <= now) i.status = "expired";
    }
  }

  async insertInvitation(f: InvitationFields, now: Date): Promise<string | null> {
    if (this.state.invitations.some((i) => samePair(i.senderId, i.recipientId, f.senderId, f.recipientId) && i.status === "pending")) {
      return null;
    }
    const row: InvitationRow = {
      id: crypto.randomUUID(), ...f, status: "pending", chatId: null, createdAt: now, respondedAt: null, expiresAt: f.proposedStartAt,
    };
    this.state.invitations.push(row);
    return row.id;
  }

  async getInvitation(callerId: string, invitationId: string, now: Date): Promise<InvitationRecord | null> {
    const i = this.state.invitations.find((x) => x.id === invitationId);
    if (!i || (i.senderId !== callerId && i.recipientId !== callerId) || this.isBlocked(i.senderId, i.recipientId)) return null;
    return this.invitationRecord(i, now);
  }

  async listInvitations(q: InvitationListQuery): Promise<InvitationRecord[]> {
    return this.state.invitations
      .filter((i) => (q.box === "incoming" ? i.recipientId : i.senderId) === q.callerId)
      .filter((i) => !this.isBlocked(i.senderId, i.recipientId))
      .filter((i) => q.status === null || effectiveStatus(i, q.now) === q.status)
      .sort((a, b) => compareTimeKeys({ at: b.createdAt, id: b.id }, { at: a.createdAt, id: a.id }))
      .filter((i) => !q.after || compareTimeKeys({ at: i.createdAt, id: i.id }, q.after) < 0)
      .slice(0, q.limit)
      .map((i) => this.invitationRecord(i, q.now));
  }

  async setInvitationStatus(invitationId: string, status: InvitationStatus, now: Date, opts: { responded?: boolean; chatId?: string } = {}): Promise<void> {
    const i = this.state.invitations.find((x) => x.id === invitationId);
    if (!i) return;
    i.status = status;
    if (opts.responded) i.respondedAt = now;
    if (opts.chatId) i.chatId = opts.chatId;
  }

  async cancelOpenInvitationsBetween(a: string, b: string, now: Date): Promise<void> {
    for (const i of this.state.invitations) {
      if (!samePair(i.senderId, i.recipientId, a, b)) continue;
      if ((i.status === "pending" && i.expiresAt > now) || (i.status === "accepted" && sessionNotOver(i, now))) i.status = "cancelled";
    }
    await this.expireStalePending(a, b, now);
  }

  // ---------------------------------------------------------------- chats

  async openChat(a: string, b: string, now: Date): Promise<string> {
    const [lowId, highId] = a < b ? [a, b] : [b, a];
    const existing = this.state.chats.find((c) => c.lowId === lowId && c.highId === highId);
    if (existing) {
      existing.status = "open";
      existing.updatedAt = this.clock();
      return existing.id;
    }
    const chat: ChatRow = { id: crypto.randomUUID(), lowId, highId, status: "open", createdAt: now, updatedAt: this.clock() };
    this.state.chats.push(chat);
    return chat.id;
  }

  async closeChatBetween(a: string, b: string): Promise<void> {
    for (const c of this.state.chats) {
      if (samePair(c.lowId, c.highId, a, b) && c.status === "open") Object.assign(c, { status: "closed", updatedAt: this.clock() });
    }
  }

  async listChats(callerId: string, after: TimeKey | null, limit: number, now: Date): Promise<ChatRecord[]> {
    return this.visibleChats(callerId)
      .map((c) => this.chatRecord(c, callerId, now))
      .sort((x, y) => compareTimeKeys({ at: y.activityAt, id: y.id }, { at: x.activityAt, id: x.id }))
      .filter((c) => !after || compareTimeKeys({ at: c.activityAt, id: c.id }, after) < 0)
      .slice(0, limit);
  }

  async getChat(callerId: string, chatId: string, now: Date): Promise<ChatRecord | null> {
    const c = this.visibleChats(callerId).find((x) => x.id === chatId);
    return c ? this.chatRecord(c, callerId, now) : null;
  }

  async chatStatus(callerId: string, chatId: string): Promise<"open" | "closed" | null> {
    return this.visibleChats(callerId).find((x) => x.id === chatId)?.status ?? null;
  }

  async getMessage(chatId: string, messageId: string): Promise<MessageRecord | null> {
    const m = this.state.messages.find((x) => x.chatId === chatId && x.id === messageId);
    return m ? { ...m } : null;
  }

  async listMessages(q: MessageListQuery): Promise<MessageRecord[]> {
    const inChat = this.state.messages.filter((m) => m.chatId === q.chatId).map((m) => ({ ...m }));
    const key = (m: MessageRecord) => ({ at: m.createdAt, id: m.id });
    if (q.after) {
      const after = q.after;
      return inChat.filter((m) => compareTimeKeys(key(m), after) > 0).sort((a, b) => compareTimeKeys(key(a), key(b))).slice(0, q.limit);
    }
    const before = q.before;
    return inChat
      .filter((m) => !before || compareTimeKeys(key(m), before) < 0)
      .sort((a, b) => compareTimeKeys(key(b), key(a)))
      .slice(0, q.limit);
  }

  async insertMessage(chatId: string, senderId: string, body: string, now: Date): Promise<MessageRecord> {
    const newest = Math.max(...this.state.messages.filter((m) => m.chatId === chatId).map((m) => m.createdAt.getTime() + 1));
    const m: MessageRow = { id: crypto.randomUUID(), chatId, senderId, body, createdAt: new Date(Math.max(now.getTime(), newest)) };
    this.state.messages.push(m);
    return { ...m };
  }

  async markRead(chatId: string, accountId: string, messageId: string): Promise<void> {
    const key = `${chatId}:${accountId}`;
    const next = this.state.messages.find((m) => m.id === messageId);
    const current = this.state.messages.find((m) => m.id === this.state.readStates.get(key));
    if (!next) return;
    if (!current || compareMessages(next, current) > 0) this.state.readStates.set(key, messageId);
  }

  // ---------------------------------------------------------------- safety

  async getBlock(blockerId: string, blockedId: string): Promise<BlockRecord | null> {
    const b = this.state.blocks.find((x) => x.blockerId === blockerId && x.blockedId === blockedId);
    return b ? blockRecord(b) : null;
  }

  async insertBlock(blockerId: string, blockedId: string, displayName: string, now: Date): Promise<BlockRecord> {
    if (!this.state.blocks.some((x) => x.blockerId === blockerId && x.blockedId === blockedId)) {
      this.state.blocks.push({ blockerId, blockedId, displayName, createdAt: now });
    }
    return (await this.getBlock(blockerId, blockedId))!;
  }

  async deleteBlock(blockerId: string, blockedId: string): Promise<void> {
    this.state.blocks = this.state.blocks.filter((x) => !(x.blockerId === blockerId && x.blockedId === blockedId));
  }

  async listBlocks(blockerId: string, after: TimeKey | null, limit: number): Promise<BlockRecord[]> {
    const key = (b: BlockRow) => ({ at: b.createdAt, id: b.blockedId });
    return this.state.blocks
      .filter((b) => b.blockerId === blockerId)
      .sort((x, y) => compareTimeKeys(key(y), key(x)))
      .filter((b) => !after || compareTimeKeys(key(b), after) < 0)
      .slice(0, limit)
      .map(blockRecord);
  }

  async findMessageInCallersChat(callerId: string, messageId: string): Promise<MessageRecord | null> {
    const m = this.state.messages.find((x) => x.id === messageId);
    const c = m && this.state.chats.find((x) => x.id === m.chatId);
    return m && c && (c.lowId === callerId || c.highId === callerId) ? { ...m } : null;
  }

  async invitationIsBetween(invitationId: string, a: string, b: string): Promise<boolean> {
    return this.state.invitations.some((i) => i.id === invitationId && samePair(i.senderId, i.recipientId, a, b));
  }

  async insertReport(f: ReportFields, now: Date): Promise<ReportRecord> {
    const record: ReportRecord = { id: crypto.randomUUID(), reportedId: f.reportedId, context: f.context, reason: f.reason, status: "open", createdAt: now };
    this.state.reports.push({ ...f, record });
    return { ...record };
  }

  async listReportsFiled(reporterId: string): Promise<ReportRecord[]> {
    return this.state.reports
      .filter((r) => r.reporterId === reporterId)
      .map((r) => ({ ...r.record }))
      .sort((a, b) => compareTimeKeys({ at: b.createdAt, id: b.id }, { at: a.createdAt, id: a.id }));
  }

  async listGymRequests(accountId: string): Promise<GymRequestRecord[]> {
    return this.state.gymRequests
      .filter((r) => r.accountId === accountId)
      .map((r) => ({ id: r.id, name: r.name, city: r.city, region: r.region, status: r.status, createdAt: r.createdAt }))
      .sort((a, b) => compareTimeKeys({ at: b.createdAt, id: b.id }, { at: a.createdAt, id: a.id }));
  }

  // ---------------------------------------------------------------- account deletion (mirrors boulderme.delete_account)

  async deleteAccount(accountId: string, now: Date): Promise<void> {
    const a = this.state.accounts.get(accountId);
    if (!a || a.status === "deleted") return;
    this.state.tombstones.set(a.appleSubHash, {
      accountId, status: a.appleRefreshTokenEnc === null ? "not_needed" : "pending", attempts: 0, nextAttemptAt: now,
    });
    for (const i of this.state.invitations) {
      if (i.senderId !== accountId && i.recipientId !== accountId) continue;
      if ((i.status === "pending" && i.expiresAt > now) || (i.status === "accepted" && sessionNotOver(i, now))) i.status = "cancelled";
      else if (i.status === "pending") i.status = "expired";
    }
    for (const c of this.state.chats) {
      if ((c.lowId === accountId || c.highId === accountId) && c.status === "open") Object.assign(c, { status: "closed", updatedAt: this.clock() });
    }
    const removed = new Set(this.state.messages.filter((m) => m.senderId === accountId).map((m) => m.id));
    this.state.messages = this.state.messages.filter((m) => !removed.has(m.id));
    for (const [k, v] of [...this.state.readStates]) {
      if (k.endsWith(`:${accountId}`)) this.state.readStates.delete(k);
      else if (removed.has(v)) this.state.readStates.delete(k);
    }
    this.state.profiles.delete(accountId);
    this.state.gymAccess = this.state.gymAccess.filter((x) => x.accountId !== accountId);
    this.state.slots = this.state.slots.filter((x) => x.accountId !== accountId);
    this.state.blocks = this.state.blocks.filter((x) => x.blockerId !== accountId);
    this.state.gymRequests = this.state.gymRequests.filter((x) => x.accountId !== accountId);
    for (const k of [...this.state.idempotency.keys()]) if (k.startsWith(`${accountId}:`)) this.state.idempotency.delete(k);
    for (const s of this.state.sessions) if (s.accountId === accountId && !s.revokedAt) s.revokedAt = now;
    Object.assign(a, { status: "deleted", appleSubHash: `deleted:${accountId}` });
  }

  async listPendingRevocations(now: Date, limit: number, accountId?: string): Promise<PendingRevocation[]> {
    return [...this.state.tombstones]
      .filter(([, t]) => t.status === "pending" && (!t.nextAttemptAt || t.nextAttemptAt <= now))
      .filter(([, t]) => accountId === undefined || t.accountId === accountId)
      .slice(0, limit)
      .map(([hash, t]) => ({
        appleSubHash: hash, accountId: t.accountId, tokenEnc: this.state.accounts.get(t.accountId)?.appleRefreshTokenEnc ?? null, attempts: t.attempts,
      }));
  }

  async recordRevocation(appleSubHash: string, accountId: string, outcome: RevocationOutcome): Promise<void> {
    const t = this.state.tombstones.get(appleSubHash);
    if (!t || t.accountId !== accountId) return;
    t.attempts++;
    t.status = outcome.kind === "retry" ? "pending" : outcome.kind;
    t.nextAttemptAt = outcome.kind === "retry" ? outcome.nextAttemptAt : null;
    const a = this.state.accounts.get(accountId);
    if (outcome.kind !== "retry" && a?.status === "deleted") a.appleRefreshTokenEnc = null;
  }

  // ---------------------------------------------------------------- housekeeping

  async purgeExpired(now: Date): Promise<Record<string, number>> {
    const day = 86_400_000;
    let expired = 0;
    for (const i of this.state.invitations) if (i.status === "pending" && i.expiresAt <= now) { i.status = "expired"; expired++; }
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
    return { invitations_expired: expired, auth_nonces: nonces, rate_limits: windows, idempotency_keys: keys, refresh_sessions: before - this.state.sessions.length };
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
    this.state.blocks.push({ blockerId, blockedId, displayName: null, createdAt: this.clock() });
  }

  addInvitation(row: Omit<InvitationRow, "id" | "chatId">): InvitationRow {
    const inv: InvitationRow = { id: crypto.randomUUID(), chatId: null, ...row };
    if (row.status === "accepted") {
      const [lowId, highId] = row.senderId < row.recipientId ? [row.senderId, row.recipientId] : [row.recipientId, row.senderId];
      inv.chatId = this.state.chats.find((c) => c.lowId === lowId && c.highId === highId)?.id ?? null;
      if (!inv.chatId) {
        inv.chatId = crypto.randomUUID();
        this.state.chats.push({ id: inv.chatId, lowId, highId, status: "open", createdAt: row.createdAt, updatedAt: row.createdAt });
      }
    }
    this.state.invitations.push(inv);
    return inv;
  }

  addTombstone(appleSubHash: string, status: "pending" | "done" = "pending"): void {
    this.state.tombstones.set(appleSubHash, { accountId: crypto.randomUUID(), status, attempts: 0, nextAttemptAt: null });
  }

  private isBlocked(a: string, b: string): boolean {
    return this.state.blocks.some((x) => (x.blockerId === a && x.blockedId === b) || (x.blockerId === b && x.blockedId === a));
  }

  private party(accountId: string): PartyRecord {
    const p = this.state.profiles.get(accountId);
    return { accountId, displayName: p?.displayName ?? null, gradeMin: p?.gradeMin ?? null, gradeMax: p?.gradeMax ?? null };
  }

  private invitationRecord(i: InvitationRow, now: Date): InvitationRecord {
    return {
      id: i.id, status: effectiveStatus(i, now), sender: this.party(i.senderId), recipient: this.party(i.recipientId),
      gym: { ...this.state.gyms.get(i.gymId)! }, proposedStartAt: i.proposedStartAt, durationMinutes: i.durationMinutes,
      note: i.note, chatId: i.chatId, createdAt: i.createdAt, respondedAt: i.respondedAt, expiresAt: i.expiresAt,
    };
  }

  private visibleChats(callerId: string): ChatRow[] {
    return this.state.chats.filter((c) => (c.lowId === callerId || c.highId === callerId) && !this.isBlocked(c.lowId, c.highId));
  }

  private chatRecord(c: ChatRow, callerId: string, now: Date): ChatRecord {
    const messages = this.state.messages.filter((m) => m.chatId === c.id).sort((a, b) => compareMessages(b, a));
    const lastRead = this.state.messages.find((m) => m.id === this.state.readStates.get(`${c.id}:${callerId}`));
    const upcoming = this.state.invitations
      .filter((i) => i.chatId === c.id && i.status === "accepted" && sessionNotOver(i, now))
      .sort((a, b) => a.proposedStartAt.getTime() - b.proposedStartAt.getTime() || cmp(a.id, b.id))[0];
    return {
      id: c.id,
      status: c.status,
      other: this.party(c.lowId === callerId ? c.highId : c.lowId),
      lastMessage: messages[0] ? { ...messages[0] } : null,
      unreadCount: messages.filter((m) => m.senderId !== callerId && (!lastRead || compareMessages(m, lastRead) > 0)).length,
      upcoming: upcoming ? this.invitationRecord(upcoming, now) : null,
      createdAt: c.createdAt,
      updatedAt: c.updatedAt,
      activityAt: messages[0]?.createdAt ?? c.createdAt,
    };
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

function compareTimeKeys(a: TimeKey, b: TimeKey): number {
  return a.at.getTime() - b.at.getTime() || cmp(a.id, b.id);
}

function samePair(x: string, y: string, a: string, b: string): boolean {
  return (x === a && y === b) || (x === b && y === a);
}

function effectiveStatus(i: InvitationRow, now: Date): InvitationStatus {
  return i.status === "pending" && i.expiresAt <= now ? "expired" : i.status;
}

function sessionNotOver(i: InvitationRow, now: Date): boolean {
  return i.proposedStartAt.getTime() + i.durationMinutes * 60_000 > now.getTime();
}

function blockRecord(b: BlockRow): BlockRecord {
  return { blockedId: b.blockedId, displayName: b.displayName ?? "Climber", createdAt: b.createdAt };
}

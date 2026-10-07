// The storage boundary. Routes talk only to this interface; `postgres.ts` implements it for
// production and `memory.ts` for route tests. Every method is scoped by the caller's account
// id where the data is personal, so a route can never read or write another member's rows.

export type AccountStatus = "active" | "deleting" | "deleted";
export type AccessType = "membership" | "guest_pass";
export type ClimbingStyle =
  | "slab" | "vertical" | "overhang" | "roof" | "crimps" | "slopers" | "pinches"
  | "dynamic" | "technical" | "power" | "comp_style" | "highball";
export type TimeOfDay = "morning" | "afternoon" | "evening";
export type InvitationStatus = "pending" | "accepted" | "declined" | "cancelled" | "expired";
export type ReportContext = "profile" | "invitation" | "message";
export type ReportReason =
  | "harassment" | "inappropriate_content" | "spam" | "fake_profile" | "safety_concern" | "underage" | "other";

export interface AccountRecord {
  id: string;
  status: AccountStatus;
  createdAt: Date;
}

export interface RefreshSessionRecord {
  id: string;
  accountId: string;
  familyId: string;
  clientInstallationId: string | null;
  expiresAt: Date;
  usedAt: Date | null;
  revokedAt: Date | null;
}

export interface ProfileRecord {
  accountId: string;
  revision: number;
  displayName: string;
  gradeMin: number;
  gradeMax: number;
  styles: ClimbingStyle[];
  intro: string | null;
  discoverable: boolean;
  adultConfirmed: boolean;
  discoveryExplained: boolean;
  updatedAt: Date;
}

export interface ProfileFields {
  displayName: string;
  gradeMin: number;
  gradeMax: number;
  styles: ClimbingStyle[];
  intro: string | null;
  adultConfirmed: boolean;
  discoveryExplained: boolean;
}

export interface GymRecord {
  id: string;
  name: string;
  city: string;
  region: string;
  country: string;
  address: string | null;
  websiteUrl: string | null;
  isBoulderingOnly: boolean;
  isActive: boolean;
}

export interface GymAccessRecord {
  gym: GymRecord;
  accessType: AccessType;
  updatedAt: Date;
}

export interface GymRequestFields {
  name: string;
  city: string;
  region: string;
  websiteUrl: string | null;
  note: string | null;
}

export interface GymRequestRecord {
  id: string;
  name: string;
  city: string;
  region: string;
  status: "submitted" | "added" | "rejected";
  createdAt: Date;
}

export interface SlotFields {
  weekday: number;
  startMinute: number;
  endMinute: number;
  timeZone: string;
  gymId: string | null;
}

export interface SlotRecord extends SlotFields {
  id: string;
}

/** Keyset position in the gym list, which is ordered by city, then name, then id. */
export interface GymListKey {
  city: string;
  name: string;
  id: string;
}

export interface GymListQuery {
  q: string | null;
  region: string | null;
  after: GymListKey | null;
  limit: number;
}

/** Keyset position in discovery results: best overlap, then most recently active, then id. */
export interface DiscoveryKey {
  overlap: number;
  lastActiveOn: string; // YYYY-MM-DD
  accountId: string;
}

export interface DiscoveryQuery {
  callerId: string;
  gymId: string;
  gradeMin: number;
  gradeMax: number;
  /** Range used for ranking by overlap: the requested range, or the caller's own. */
  rankMin: number;
  rankMax: number;
  accessType: AccessType | null;
  weekday: number | null;
  timeOfDay: TimeOfDay | null;
  after: DiscoveryKey | null;
  limit: number;
}

export interface DiscoveryRow {
  profile: ProfileRecord;
  accessType: AccessType;
  /** Slots that apply at the searched gym (gym-specific or "any of my gyms"). */
  slots: SlotRecord[];
  lastActiveOn: string;
  overlap: number;
}

export interface PublicProfileRow {
  profile: ProfileRecord;
  gyms: GymAccessRecord[];
  slots: SlotRecord[];
  lastActiveOn: string;
}

/** One side of an invitation or chat. Name and grades are null once that member's profile is gone. */
export interface PartyRecord {
  accountId: string;
  displayName: string | null;
  gradeMin: number | null;
  gradeMax: number | null;
}

export interface InvitationRecord {
  id: string;
  /** Effective status: a `pending` row past `expiresAt` reads as `expired`. */
  status: InvitationStatus;
  sender: PartyRecord;
  recipient: PartyRecord;
  gym: GymRecord;
  proposedStartAt: Date;
  durationMinutes: number;
  note: string | null;
  chatId: string | null;
  createdAt: Date;
  respondedAt: Date | null;
  expiresAt: Date;
}

export interface InvitationFields {
  senderId: string;
  recipientId: string;
  gymId: string;
  proposedStartAt: Date;
  durationMinutes: number;
  note: string | null;
}

/** Keyset position for lists ordered newest first by a timestamp, then id. */
export interface TimeKey {
  at: Date;
  id: string;
}

export interface InvitationListQuery {
  callerId: string;
  box: "incoming" | "outgoing";
  status: InvitationStatus | null;
  after: TimeKey | null;
  limit: number;
  now: Date;
}

export interface MessageRecord {
  id: string;
  chatId: string;
  senderId: string | null;
  body: string;
  createdAt: Date;
}

export interface ChatRecord {
  id: string;
  status: "open" | "closed";
  other: PartyRecord;
  lastMessage: MessageRecord | null;
  unreadCount: number;
  upcoming: InvitationRecord | null;
  createdAt: Date;
  updatedAt: Date;
  /** Newest message time, or the chat's creation time when it has none. Orders the chat list. */
  activityAt: Date;
}

export interface MessageListQuery {
  chatId: string;
  /** History mode: newest first, strictly older than this position. */
  before: TimeKey | null;
  /** Polling mode: oldest first, strictly newer than this position. */
  after: TimeKey | null;
  limit: number;
}

export interface BlockRecord {
  blockedId: string;
  displayName: string;
  createdAt: Date;
}

export interface ReportFields {
  reporterId: string;
  reportedId: string;
  context: ReportContext;
  invitationId: string | null;
  messageId: string | null;
  reason: ReportReason;
  details: string | null;
  messageSnapshot: string | null;
}

export interface ReportRecord {
  id: string;
  reportedId: string;
  context: ReportContext;
  reason: ReportReason;
  status: "open" | "reviewing" | "actioned" | "dismissed";
  createdAt: Date;
}

export interface PendingRevocation {
  appleSubHash: string;
  accountId: string;
  /** Encrypted Apple refresh token; null when it is already gone. */
  tokenEnc: string | null;
  attempts: number;
}

export type RevocationOutcome =
  | { kind: "done" }
  | { kind: "retry"; nextAttemptAt: Date }
  | { kind: "failed" };

export interface AuthState {
  status: AccountStatus;
  /** False once the token's session family was revoked (sign-out or refresh-token reuse). */
  sessionActive: boolean;
}

export interface StoredIdempotentResponse {
  route: string;
  requestHash: string;
  status: number;
  body: unknown;
}

export type IdempotencyClaim =
  | { claimed: true }
  | { claimed: false; stored: StoredIdempotentResponse };

export interface Repository {
  /** Runs `fn` atomically. Nested calls join the outer transaction. */
  transaction<T>(fn: (repo: Repository) => Promise<T>): Promise<T>;
  ping(): Promise<void>;

  // ---- request plumbing
  /** Adds one hit to a fixed-window bucket and returns the new count. */
  hitRateLimit(bucket: string, windowStart: Date): Promise<number>;
  /**
   * Claims `(accountId, key)` for this request. Concurrent claims of the same key wait for
   * the first transaction to finish. Keys older than 24 hours are treated as unused.
   */
  claimIdempotencyKey(accountId: string, key: string, route: string, requestHash: string, now: Date): Promise<IdempotencyClaim>;
  completeIdempotencyKey(accountId: string, key: string, status: number, body: unknown): Promise<void>;

  // ---- auth
  createNonce(nonceHash: string, expiresAt: Date): Promise<void>;
  /** Marks the nonce used. False if it is unknown, expired or already used. */
  consumeNonce(nonceHash: string, now: Date): Promise<boolean>;
  findAccountByAppleSub(appleSubHash: string): Promise<AccountRecord | null>;
  hasPendingTombstone(appleSubHash: string): Promise<boolean>;
  /** Creates the account, or returns the existing one if the subject already has one. */
  createAccount(appleSubHash: string): Promise<{ account: AccountRecord; created: boolean }>;
  setAppleRefreshToken(accountId: string, encrypted: string): Promise<void>;
  createRefreshSession(input: {
    accountId: string;
    familyId: string;
    tokenHash: string;
    clientInstallationId: string | null;
    expiresAt: Date;
  }): Promise<void>;
  /** Finds a refresh session and locks it until the transaction ends. */
  findRefreshSessionForUpdate(tokenHash: string): Promise<RefreshSessionRecord | null>;
  markRefreshSessionUsed(id: string, now: Date): Promise<void>;
  revokeSessionFamily(familyId: string, now: Date): Promise<void>;
  /** Account status plus whether the session family is still live; records today's activity. */
  authenticate(accountId: string, familyId: string): Promise<AuthState | null>;
  getAccount(accountId: string): Promise<AccountRecord | null>;
  /** Locks the account row so per-account limits (gyms, slots) can be checked safely. */
  lockAccount(accountId: string): Promise<void>;

  // ---- profile
  getProfile(accountId: string): Promise<ProfileRecord | null>;
  /** Null when a profile already exists. */
  insertProfile(accountId: string, fields: ProfileFields): Promise<ProfileRecord | null>;
  /** Null when the stored revision is not `expectedRevision`. Bumps the revision. */
  updateProfile(accountId: string, expectedRevision: number, fields: ProfileFields, discoverable: boolean): Promise<ProfileRecord | null>;
  setDiscoverable(accountId: string, discoverable: boolean): Promise<ProfileRecord | null>;

  // ---- gyms
  listGyms(query: GymListQuery): Promise<GymRecord[]>;
  getGym(gymId: string): Promise<GymRecord | null>;
  listGymAccess(accountId: string): Promise<GymAccessRecord[]>;
  upsertGymAccess(accountId: string, gymId: string, accessType: AccessType): Promise<GymAccessRecord>;
  deleteGymAccess(accountId: string, gymId: string): Promise<boolean>;
  createGymRequest(accountId: string, fields: GymRequestFields): Promise<GymRequestRecord>;

  // ---- availability
  listSlots(accountId: string): Promise<SlotRecord[]>;
  insertSlot(accountId: string, fields: SlotFields): Promise<SlotRecord>;
  updateSlot(accountId: string, slotId: string, fields: SlotFields): Promise<SlotRecord | null>;
  deleteSlot(accountId: string, slotId: string): Promise<void>;

  // ---- counts for /v1/me
  countUnreadChats(accountId: string): Promise<number>;
  countPendingIncomingInvitations(accountId: string, now: Date): Promise<number>;

  // ---- discovery
  discover(query: DiscoveryQuery): Promise<DiscoveryRow[]>;
  /** The target's profile if the caller may see it (see docs/domain-model.md), else null. */
  getVisibleProfile(callerId: string, targetId: string): Promise<PublicProfileRow | null>;

  // ---- invitations
  blockedEitherWay(a: string, b: string): Promise<boolean>;
  countInvitationsSentSince(senderId: string, since: Date): Promise<number>;
  /** Marks the pair's `pending` invitations whose time has passed as `expired`. */
  expireStalePending(a: string, b: string, now: Date): Promise<void>;
  /** Null when the pair already has a pending invitation (either direction). */
  insertInvitation(fields: InvitationFields, now: Date): Promise<string | null>;
  /** The invitation if the caller is its sender or recipient and no block exists; locks it when asked. */
  getInvitation(callerId: string, invitationId: string, now: Date, forUpdate?: boolean): Promise<InvitationRecord | null>;
  listInvitations(query: InvitationListQuery): Promise<InvitationRecord[]>;
  /** Sets a new status. `responded` also stamps `responded_at`; `chatId` is stored when given. */
  setInvitationStatus(invitationId: string, status: InvitationStatus, now: Date, opts?: { responded?: boolean; chatId?: string }): Promise<void>;
  /** Cancels the pair's pending invitations and accepted sessions that have not ended. */
  cancelOpenInvitationsBetween(a: string, b: string, now: Date): Promise<void>;

  // ---- chats
  /** Creates the pair's chat or reopens it, and returns its id. */
  openChat(a: string, b: string, now: Date): Promise<string>;
  closeChatBetween(a: string, b: string): Promise<void>;
  /** Chats the caller is in, minus any hidden by a block, ordered by activity (newest first). */
  listChats(callerId: string, after: TimeKey | null, limit: number, now: Date): Promise<ChatRecord[]>;
  getChat(callerId: string, chatId: string, now: Date): Promise<ChatRecord | null>;
  /** The chat's status if the caller may see it; `forUpdate` locks the row (serializes sends). */
  chatStatus(callerId: string, chatId: string, forUpdate?: boolean): Promise<"open" | "closed" | null>;
  getMessage(chatId: string, messageId: string): Promise<MessageRecord | null>;
  listMessages(query: MessageListQuery): Promise<MessageRecord[]>;
  /** Stamped at `now`, or 1 ms after the chat's newest message, so order always follows insertion. */
  insertMessage(chatId: string, senderId: string, body: string, now: Date): Promise<MessageRecord>;
  /** Moves the read marker forward to `messageId`; never backwards. */
  markRead(chatId: string, accountId: string, messageId: string): Promise<void>;

  // ---- safety
  getBlock(blockerId: string, blockedId: string): Promise<BlockRecord | null>;
  insertBlock(blockerId: string, blockedId: string, displayName: string, now: Date): Promise<BlockRecord>;
  deleteBlock(blockerId: string, blockedId: string): Promise<void>;
  listBlocks(blockerId: string, after: TimeKey | null, limit: number): Promise<BlockRecord[]>;
  /** A message in a chat the caller is in (blocks do not matter for reporting). */
  findMessageInCallersChat(callerId: string, messageId: string): Promise<MessageRecord | null>;
  /** True when the invitation is between exactly these two members. */
  invitationIsBetween(invitationId: string, a: string, b: string): Promise<boolean>;
  insertReport(fields: ReportFields, now: Date): Promise<ReportRecord>;
  listReportsFiled(reporterId: string): Promise<ReportRecord[]>;
  listGymRequests(accountId: string): Promise<GymRequestRecord[]>;

  // ---- account deletion
  /**
   * Deletes the member's data and marks the account deleted, in the caller's transaction:
   * profile, gyms, availability, sent messages, own blocks, gym requests and read markers go;
   * open invitations are cancelled, chats closed, every session revoked. The Apple subject
   * hash moves to a tombstone (`pending` revocation when an Apple token is stored).
   */
  deleteAccount(accountId: string, now: Date): Promise<void>;
  /** Tombstones due for an Apple revocation attempt, optionally only for one account. */
  listPendingRevocations(now: Date, limit: number, accountId?: string): Promise<PendingRevocation[]>;
  /** Records a revocation attempt; `done` and `failed` also erase the stored Apple token. */
  recordRevocation(appleSubHash: string, accountId: string, outcome: RevocationOutcome): Promise<void>;

  // ---- housekeeping
  purgeExpired(now: Date): Promise<Record<string, number>>;
}

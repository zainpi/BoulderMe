// Test harness: runs the real request pipeline against either the in-memory repository or a
// local Postgres (when TEST_DATABASE_URL is set), with a fake Apple that signs real JWTs.

import { SignJWT, createLocalJWKSet, exportJWK, exportPKCS8, generateKeyPair, type JWK } from "jose";
import postgres from "postgres";
import { handle, type Deps } from "../../src/app";
import { APPLE_ISSUER, LiveAppleClient } from "../../src/auth/apple";
import { sha256Hex } from "../../src/auth/crypto";
import { MemoryRepository } from "../../src/db/memory";
import { PostgresRepository, connect } from "../../src/db/postgres";
import type { AccountStatus, GymRecord, Repository } from "../../src/db/repository";
import { assertMatchesContract } from "./contract";

export const BUNDLE_ID = "app.boulderme.test";
const ACCESS_KEY = Buffer.from("a".repeat(32)).toString("base64");
const ENCRYPTION_KEY = Buffer.from("e".repeat(32)).toString("base64");

export type Backend = "memory" | "postgres";

export const BACKENDS: Backend[] = process.env.TEST_DATABASE_URL ? ["memory", "postgres"] : ["memory"];

export interface Session {
  access_token: string;
  refresh_token: string;
  account_id: string;
  is_new_account: boolean;
}

export interface TestResponse {
  status: number;
  headers: Headers;
  body: any;
}

interface AppleKeys {
  privateKey: CryptoKey;
  jwks: { keys: JWK[] };
  esPrivateKeyPem: string;
}

let appleKeys: Promise<AppleKeys> | null = null;

function keys(): Promise<AppleKeys> {
  appleKeys ??= (async () => {
    const { privateKey, publicKey } = await generateKeyPair("RS256", { extractable: true });
    const jwk = { ...(await exportJWK(publicKey)), kid: "test-key", alg: "RS256", use: "sig" };
    const es = await generateKeyPair("ES256", { extractable: true });
    return { privateKey, jwks: { keys: [jwk] }, esPrivateKeyPem: await exportPKCS8(es.privateKey) };
  })();
  return appleKeys;
}

export class Harness {
  clock = new Date();
  logs: Record<string, unknown>[] = [];
  /** What the fake Apple token endpoint answers next. */
  appleTokenResponse: { status: number; body: unknown } = { status: 200, body: { refresh_token: "apple-refresh-token-secret" } };
  private subCounter = 0;
  deps!: Deps;

  private constructor(readonly backend: Backend, readonly repo: Repository, private readonly admin: postgres.Sql | null, private readonly apiSql: postgres.Sql | null) {}

  static async create(backend: Backend): Promise<Harness> {
    if (backend === "memory") {
      const h: Harness = new Harness(backend, null as never, null, null);
      const repo = new MemoryRepository(undefined, () => h.clock);
      return h.init(repo);
    }
    const admin = postgres(process.env.TEST_ADMIN_DATABASE_URL!, { onnotice: () => {}, max: 1 });
    await resetDatabase(admin);
    const apiSql = connect(process.env.TEST_DATABASE_URL!);
    const h = new Harness(backend, new PostgresRepository(apiSql), admin, apiSql);
    return h.init(h.repo);
  }

  private async init(repo: Repository): Promise<this> {
    (this as { repo: Repository }).repo = repo;
    const k = await keys();
    this.deps = {
      repo,
      config: {
        environment: "test",
        version: "test",
        accessTokenSigningKey: ACCESS_KEY,
        appleTokenEncryptionKey: ENCRYPTION_KEY,
        rateLimitSalt: "salt",
      },
      apple: new LiveAppleClient(
        { bundleId: BUNDLE_ID, teamId: "TEAM123456", keyId: "KEY1234567", privateKey: k.esPrivateKeyPem },
        createLocalJWKSet(k.jwks),
        async () => new Response(JSON.stringify(this.appleTokenResponse.body), { status: this.appleTokenResponse.status }),
      ),
      now: () => this.clock,
      log: (e) => this.logs.push(e),
    };
    return this;
  }

  async close(): Promise<void> {
    await this.apiSql?.end();
    await this.admin?.end();
  }

  advance(seconds: number): void {
    this.clock = new Date(this.clock.getTime() + seconds * 1000);
  }

  // ---------------------------------------------------------------- HTTP

  async request(method: string, path: string, opts: { token?: string; body?: unknown; headers?: Record<string, string>; rawBody?: string } = {}): Promise<TestResponse> {
    const headers: Record<string, string> = { ...opts.headers };
    if (opts.token) headers.authorization = `Bearer ${opts.token}`;
    let body: string | undefined;
    if (opts.rawBody !== undefined) body = opts.rawBody;
    else if (opts.body !== undefined) {
      body = JSON.stringify(opts.body);
      headers["content-type"] ??= "application/json";
    }
    const res = await handle(new Request(`http://localhost${path}`, { method, headers, body }), this.deps);
    const text = await res.text();
    const parsed = text === "" ? null : JSON.parse(text);
    assertMatchesContract(method, new URL(`http://localhost${path}`).pathname, res.status, parsed);
    return { status: res.status, headers: res.headers, body: parsed };
  }

  // ---------------------------------------------------------------- Apple

  async appleToken(claims: { sub: string; nonce?: string | null; aud?: string; iss?: string; expiresIn?: number }, signingKey?: CryptoKey): Promise<string> {
    const k = await keys();
    const now = Math.floor(this.clock.getTime() / 1000);
    const payload: Record<string, unknown> = { email_verified: true };
    if (claims.nonce !== null) payload.nonce = claims.nonce;
    return new SignJWT(payload)
      .setProtectedHeader({ alg: "RS256", kid: "test-key" })
      .setIssuer(claims.iss ?? APPLE_ISSUER)
      .setAudience(claims.aud ?? BUNDLE_ID)
      .setSubject(claims.sub)
      .setIssuedAt(now)
      .setExpirationTime(now + (claims.expiresIn ?? 600))
      .sign(signingKey ?? k.privateKey);
  }

  async nonce(): Promise<string> {
    const res = await this.request("POST", "/v1/auth/nonce");
    if (res.status !== 201) throw new Error(`nonce failed: ${res.status}`);
    return res.body.nonce;
  }

  async signInResponse(sub: string): Promise<TestResponse> {
    const nonce = await this.nonce();
    const identity_token = await this.appleToken({ sub, nonce: await sha256Hex(nonce) });
    return this.request("POST", "/v1/auth/apple", { body: { identity_token, authorization_code: "code", nonce } });
  }

  async signIn(sub = `apple-sub-${++this.subCounter}-${crypto.randomUUID()}`): Promise<Session> {
    const res = await this.signInResponse(sub);
    if (res.status !== 200) throw new Error(`sign-in failed: ${res.status} ${JSON.stringify(res.body)}`);
    return res.body;
  }

  // ---------------------------------------------------------------- member setup through the API

  async createProfile(s: Session, overrides: Record<string, unknown> = {}): Promise<any> {
    const res = await this.request("PUT", "/v1/me/profile", {
      token: s.access_token,
      body: {
        revision: 0, display_name: "Climber", grade_min: 3, grade_max: 5, styles: ["slab"], intro: null,
        adult_confirmed: true, discovery_explained: true, ...overrides,
      },
    });
    if (res.status !== 200) throw new Error(`profile failed: ${res.status} ${JSON.stringify(res.body)}`);
    return res.body;
  }

  async addGymAccess(s: Session, gymId: string, accessType = "membership"): Promise<void> {
    const res = await this.request("PUT", `/v1/me/gyms/${gymId}`, { token: s.access_token, body: { access_type: accessType } });
    if (res.status !== 200) throw new Error(`gym access failed: ${res.status} ${JSON.stringify(res.body)}`);
  }

  async addSlot(s: Session, slot: Record<string, unknown>): Promise<any> {
    const res = await this.request("POST", "/v1/me/availability", {
      token: s.access_token,
      headers: { "idempotency-key": crypto.randomUUID() },
      body: { time_zone: "America/Toronto", ...slot },
    });
    if (res.status !== 201) throw new Error(`slot failed: ${res.status} ${JSON.stringify(res.body)}`);
    return res.body;
  }

  /** A discoverable member at `gymId`. */
  async climber(gymId: string, profile: Record<string, unknown> = {}, accessType = "membership"): Promise<Session> {
    const s = await this.signIn();
    await this.createProfile(s, profile);
    await this.addGymAccess(s, gymId, accessType);
    const res = await this.request("PUT", "/v1/me/discovery", { token: s.access_token, body: { discoverable: true } });
    if (res.status !== 200) throw new Error(`discovery failed: ${res.status}`);
    return s;
  }

  // ---------------------------------------------------------------- operator-only setup (not reachable through the API)

  async addGym(g: Partial<GymRecord> & Pick<GymRecord, "name" | "city">): Promise<GymRecord> {
    const gym: GymRecord = {
      id: crypto.randomUUID(), region: "CA-ON", country: "CA", address: null, websiteUrl: null, isBoulderingOnly: true, isActive: true, ...g,
    };
    if (this.admin) {
      const slug = `${gym.name}-${gym.id.slice(0, 8)}`.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "");
      await this.admin`insert into boulderme.gyms (id, slug, name, city, region, country, address, website_url, is_bouldering_only, is_active)
        values (${gym.id}, ${slug}, ${gym.name}, ${gym.city}, ${gym.region}, ${gym.country}, ${gym.address}, ${gym.websiteUrl}, ${gym.isBoulderingOnly}, ${gym.isActive})`;
    } else {
      (this.repo as MemoryRepository).state.gyms.set(gym.id, gym);
    }
    return gym;
  }

  async block(blockerId: string, blockedId: string): Promise<void> {
    if (this.admin) await this.admin`insert into boulderme.blocks (blocker_id, blocked_id) values (${blockerId}, ${blockedId})`;
    else (this.repo as MemoryRepository).addBlock(blockerId, blockedId);
  }

  async invitation(senderId: string, recipientId: string, gymId: string, status = "pending"): Promise<void> {
    const start = new Date(this.clock.getTime() + 2 * 86_400_000);
    if (this.admin) {
      let chatId: string | null = null;
      if (status === "accepted") {
        const [low, high] = [senderId, recipientId].sort();
        const [chat] = await this.admin`insert into boulderme.chats (account_low_id, account_high_id) values (${low!}, ${high!}) returning id`;
        chatId = chat!.id;
      }
      await this.admin`insert into boulderme.invitations (sender_id, recipient_id, gym_id, proposed_start_at, expires_at, status, chat_id)
        values (${senderId}, ${recipientId}, ${gymId}, ${start}, ${start}, ${status}, ${chatId})`;
    } else {
      (this.repo as MemoryRepository).addInvitation({ senderId, recipientId, status: status as never, expiresAt: start });
    }
  }

  async setAccountStatus(accountId: string, status: AccountStatus): Promise<void> {
    if (this.admin) {
      await this.admin`update boulderme.accounts set status = ${status}, deleted_at = ${status === "deleted" ? new Date() : null} where id = ${accountId}`;
    } else (this.repo as MemoryRepository).setAccountStatus(accountId, status);
  }

  async setLastActiveOn(accountId: string, date: string): Promise<void> {
    if (this.admin) await this.admin`update boulderme.accounts set last_active_on = ${date}::date where id = ${accountId}`;
    else (this.repo as MemoryRepository).setLastActiveOn(accountId, date);
  }

  async addTombstone(sub: string): Promise<void> {
    const hash = await sha256Hex(sub);
    if (this.admin) await this.admin`insert into boulderme.tombstones (apple_sub_hash, account_id) values (${hash}, ${crypto.randomUUID()})`;
    else (this.repo as MemoryRepository).addTombstone(hash);
  }

  async storedAppleToken(accountId: string): Promise<string | null> {
    if (this.admin) {
      const [row] = await this.admin`select apple_refresh_token_enc from boulderme.accounts where id = ${accountId}`;
      return row?.apple_refresh_token_enc ?? null;
    }
    return (this.repo as MemoryRepository).state.accounts.get(accountId)?.appleRefreshTokenEnc ?? null;
  }
}

async function resetDatabase(admin: postgres.Sql): Promise<void> {
  await admin.unsafe(`truncate boulderme.accounts, boulderme.refresh_sessions, boulderme.auth_nonces, boulderme.tombstones,
    boulderme.profiles, boulderme.gyms, boulderme.gym_access, boulderme.gym_requests, boulderme.availability_slots,
    boulderme.chats, boulderme.invitations, boulderme.chat_messages, boulderme.chat_read_states, boulderme.blocks,
    boulderme.reports, boulderme.idempotency_keys, boulderme.rate_limits cascade`);
}

export function encryptionKey(): string {
  return ENCRYPTION_KEY;
}

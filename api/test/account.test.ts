import { afterEach, beforeEach, describe, expect, it } from "vitest";
import type { GymRecord } from "../src/db/repository";
import { MAX_ATTEMPTS, revokeAppleTokens } from "../src/revocation";
import { BACKENDS, Harness, type Session } from "./support/harness";

describe.each(BACKENDS)("account deletion and export (%s)", (backend) => {
  let h: Harness;
  let gym: GymRecord;
  let blair: Session;
  beforeEach(async () => {
    h = await Harness.create(backend);
    gym = await h.addGym({ name: "Boulder Barn", city: "Toronto" });
    blair = await h.climber(gym.id, { display_name: "Blair" });
  });
  afterEach(async () => h.close());

  const get = (s: Session, path: string) => h.request("GET", path, { token: s.access_token });
  const del = (s: Session, body: unknown = { confirm: "DELETE" }) => h.request("DELETE", "/v1/me", { token: s.access_token, body });
  const revocationDeps = () => ({ repo: h.repo, apple: h.deps.apple, encryptionKey: h.deps.config.appleTokenEncryptionKey, log: h.deps.log });

  /** A member at the gym with a chat with Blair, a pending invite, messages, a block, a slot and a gym request. */
  async function busyMember(sub: string): Promise<{ s: Session; chatId: string; pendingId: string }> {
    const s = await h.signIn(sub);
    await h.createProfile(s, { display_name: "Alex" });
    await h.addGymAccess(s, gym.id);
    await h.request("PUT", "/v1/me/discovery", { token: s.access_token, body: { discoverable: true } });
    await h.addSlot(s, { weekday: 2, start_minute: 1080, end_minute: 1200 });
    const chatId = await h.connect(s, blair, gym.id);
    await h.send(s, chatId, "from alex");
    await h.send(blair, chatId, "from blair");
    const pendingId = (await h.invite(s, blair, gym.id)).body.invitation_id;
    const stranger = await h.climber(gym.id);
    await h.request("PUT", `/v1/blocks/${stranger.account_id}`, { token: s.access_token });
    await h.request("POST", "/v1/gym-requests", {
      token: s.access_token, headers: { "idempotency-key": crypto.randomUUID() }, body: { name: "New Wall", city: "Guelph", region: "CA-ON" },
    });
    return { s, chatId, pendingId };
  }

  it("needs the typed confirmation", async () => {
    const s = await h.signIn();
    const res = await del(s, { confirm: "delete" });
    expect(res.status).toBe(400);
    expect(res.body.error.details.fields.confirm).toBe("must_be_delete");
    expect((await get(s, "/v1/me")).status).toBe(200);
  });

  it("deletes the member's data, ends their sessions and leaves partners a closed, anonymized history", async () => {
    const { s: alex, chatId, pendingId } = await busyMember("sub-alex");
    const res = await del(alex);
    expect(res.status).toBe(202);
    expect(res.body).toBeNull();

    // Signed out everywhere at once.
    const me = await get(alex, "/v1/me");
    expect(me.status).toBe(401);
    expect(me.body.error.code).toBe("account_deleted");
    expect((await h.request("POST", "/v1/auth/refresh", { body: { refresh_token: alex.refresh_token } })).status).toBe(401);

    // Gone from discovery and profiles.
    expect((await get(blair, `/v1/discovery?gym_id=${gym.id}`)).body.items.map((c: any) => c.account_id)).not.toContain(alex.account_id);
    expect((await get(blair, `/v1/profiles/${alex.account_id}`)).status).toBe(404);

    // Blair keeps a readable, closed chat with only Blair's own messages.
    const chat = (await get(blair, `/v1/chats/${chatId}`)).body;
    expect(chat).toMatchObject({
      status: "closed", upcoming_session: null,
      other_member: { account_id: alex.account_id, display_name: "Deleted climber", grade_min: null, grade_max: null },
    });
    expect((await get(blair, `/v1/chats/${chatId}/messages`)).body.items.map((m: any) => m.body)).toEqual(["from blair"]);
    expect((await h.send(blair, chatId, "hello?")).body.error.code).toBe("chat_closed");
    const pending = (await get(blair, `/v1/invitations/${pendingId}`)).body;
    expect(pending).toMatchObject({ status: "cancelled", sender: { display_name: "Deleted climber", grade_min: null } });
    expect((await get(blair, "/v1/me")).body.pending_incoming_invitation_count).toBe(0);

    // Nothing personal remains.
    expect(await h.repo.getProfile(alex.account_id)).toBeNull();
    expect(await h.repo.listGymAccess(alex.account_id)).toEqual([]);
    expect(await h.repo.listSlots(alex.account_id)).toEqual([]);
    expect(await h.repo.listBlocks(alex.account_id, null, 10)).toEqual([]);
    expect(await h.repo.listGymRequests(alex.account_id)).toEqual([]);
    if (backend === "postgres") {
      const [account] = await h.adminQuery(`select status, apple_sub_hash, apple_refresh_token_enc, deleted_at from boulderme.accounts where id = $1`, [alex.account_id]);
      expect(account).toMatchObject({ status: "deleted", apple_sub_hash: `deleted:${alex.account_id}`, apple_refresh_token_enc: null });
      expect(account!.deleted_at).not.toBeNull();
      const [{ n }] = await h.adminQuery(`select count(*)::int as n from boulderme.chat_messages where sender_id = $1`, [alex.account_id]) as any;
      expect(n).toBe(0);
    }

    // Apple's token was revoked right away, so the same Apple ID can start over as a new account.
    expect(h.revokedAppleTokens).toEqual(["apple-refresh-token-secret"]);
    expect(await h.tombstoneStatus("sub-alex")).toBe("done");
    const again = await h.signInResponse("sub-alex");
    expect(again.status).toBe(200);
    expect(again.body.is_new_account).toBe(true);
    expect(again.body.account_id).not.toBe(alex.account_id);
  });

  it("keeps retrying Apple revocation and refuses sign-in until it finishes", async () => {
    const alex = await h.signIn("sub-retry");
    h.appleRevokeStatus = 503;
    expect((await del(alex)).status).toBe(202);
    expect(await h.tombstoneStatus("sub-retry")).toBe("pending");
    expect((await h.signInResponse("sub-retry")).body.error.code).toBe("account_deleted");
    expect(h.logs.some((l) => l.event === "apple_revocation_failed" && !JSON.stringify(l).includes("apple-refresh-token-secret"))).toBe(true);

    // Not due yet: the first retry waits five minutes.
    expect(await revokeAppleTokens(revocationDeps(), h.clock, { limit: 10 })).toEqual({ done: 0, retry: 0, failed: 0 });
    h.appleRevokeStatus = 200;
    h.advance(6 * 60);
    expect(await revokeAppleTokens(revocationDeps(), h.clock, { limit: 10 })).toEqual({ done: 1, retry: 0, failed: 0 });
    expect(await h.storedAppleToken(alex.account_id)).toBeNull();
    expect((await h.signInResponse("sub-retry")).status).toBe(200);
  });

  it("gives up after the last attempt and erases the token", async () => {
    const alex = await h.signIn("sub-give-up");
    h.appleRevokeStatus = 400;
    await del(alex);
    for (let i = 1; i < MAX_ATTEMPTS; i++) {
      h.advance(25 * 3600);
      await revokeAppleTokens(revocationDeps(), h.clock, { limit: 10 });
    }
    expect(await h.tombstoneStatus("sub-give-up")).toBe("failed");
    expect(await h.storedAppleToken(alex.account_id)).toBeNull();
  });

  it("deleting with no Apple token stored needs no revocation", async () => {
    h.appleTokenResponse = { status: 200, body: {} };
    const alex = await h.signIn("sub-no-token");
    await del(alex);
    expect(await h.tombstoneStatus("sub-no-token")).toBe("not_needed");
    expect(h.revokedAppleTokens).toEqual([]);
    expect((await h.signInResponse("sub-no-token")).body.is_new_account).toBe(true);
  });

  it("exports everything the member can see", async () => {
    const { s: alex, chatId } = await busyMember("sub-export");
    await h.request("POST", "/v1/reports", {
      token: alex.access_token, headers: { "idempotency-key": crypto.randomUUID() },
      body: { reported_account_id: blair.account_id, context: "profile", reason: "other" },
    });
    const res = await get(alex, "/v1/me/export");
    expect(res.status).toBe(200);
    expect(res.headers.get("content-disposition")).toContain("attachment");
    const x = res.body;
    expect(x.account.account_id).toBe(alex.account_id);
    expect(x.profile.display_name).toBe("Alex");
    expect(x.gyms).toHaveLength(1);
    expect(x.availability).toHaveLength(1);
    expect(x.invitations.map((i: any) => i.status).sort()).toEqual(["accepted", "pending"]);
    expect(x.chats).toHaveLength(1);
    expect(x.chats[0].chat.chat_id).toBe(chatId);
    expect(x.chats[0].messages.map((m: any) => m.body)).toEqual(["from blair", "from alex"]);
    expect(x.blocks).toHaveLength(1);
    expect(x.reports_filed).toHaveLength(1);
    expect(x.gym_requests.map((g: any) => g.name)).toEqual(["New Wall"]);
    // Blair's export does not include Alex's private data.
    const theirs = (await get(blair, "/v1/me/export")).body;
    expect(theirs.blocks).toEqual([]);
    expect(theirs.reports_filed).toEqual([]);
  });

  it("rate limits exports to 5 an hour", async () => {
    const s = await h.signIn();
    for (let i = 0; i < 5; i++) expect((await get(s, "/v1/me/export")).status).toBe(200);
    expect((await get(s, "/v1/me/export")).status).toBe(429);
  });
});

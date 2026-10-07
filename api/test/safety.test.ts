import { afterEach, beforeEach, describe, expect, it } from "vitest";
import type { GymRecord } from "../src/db/repository";
import { BACKENDS, Harness, type Session } from "./support/harness";

describe.each(BACKENDS)("blocks and reports (%s)", (backend) => {
  let h: Harness;
  let gym: GymRecord;
  let alex: Session;
  let blair: Session;
  beforeEach(async () => {
    h = await Harness.create(backend);
    gym = await h.addGym({ name: "Boulder Barn", city: "Toronto" });
    alex = await h.climber(gym.id, { display_name: "Alex" });
    blair = await h.climber(gym.id, { display_name: "Blair" });
  });
  afterEach(async () => h.close());

  const get = (s: Session, path: string) => h.request("GET", path, { token: s.access_token });
  const block = (s: Session, id: string) => h.request("PUT", `/v1/blocks/${id}`, { token: s.access_token });
  const report = (s: Session, body: Record<string, unknown>) =>
    h.request("POST", "/v1/reports", { token: s.access_token, headers: { "idempotency-key": crypto.randomUUID() }, body });

  describe("blocking", () => {
    it("closes the chat, cancels open invitations and hides the pair from each other at once", async () => {
      const chatId = await h.connect(alex, blair, gym.id);
      await h.send(blair, chatId, "hi");
      const pending = (await h.invite(blair, alex, gym.id)).body;

      const res = await block(alex, blair.account_id);
      expect(res.status).toBe(200);
      expect(res.body).toMatchObject({ blocked_account_id: blair.account_id, display_name: "Blair" });
      const again = await block(alex, blair.account_id);
      expect(again.body).toEqual(res.body);

      for (const [me, them] of [[alex, blair], [blair, alex]] as const) {
        expect((await get(me, "/v1/chats")).body.items).toEqual([]);
        expect((await get(me, `/v1/chats/${chatId}`)).status).toBe(404);
        expect((await get(me, `/v1/chats/${chatId}/messages`)).status).toBe(404);
        expect((await h.send(me, chatId, "still there?")).status).toBe(404);
        expect((await get(me, `/v1/invitations/${pending.invitation_id}`)).status).toBe(404);
        expect((await get(me, `/v1/profiles/${them.account_id}`)).status).toBe(404);
        expect((await get(me, `/v1/discovery?gym_id=${gym.id}`)).body.items).toEqual([]);
        expect((await h.invite(me, them, gym.id)).status).toBe(404);
        expect((await get(me, "/v1/me")).body).toMatchObject({ unread_chat_count: 0, pending_incoming_invitation_count: 0 });
      }
      expect((await get(alex, "/v1/blocks")).body.items.map((b: any) => b.blocked_account_id)).toEqual([blair.account_id]);
      // Blair is never told: Blair's own block list stays empty.
      expect((await get(blair, "/v1/blocks")).body.items).toEqual([]);
    });

    it("leaves the chat closed and old invitations cancelled after unblocking", async () => {
      const chatId = await h.connect(alex, blair, gym.id);
      const session = (await get(alex, "/v1/chats")).body.items[0].upcoming_session;
      const pending = (await h.invite(blair, alex, gym.id)).body;
      await block(alex, blair.account_id);
      const unblock = await h.request("DELETE", `/v1/blocks/${blair.account_id}`, { token: alex.access_token });
      expect(unblock.status).toBe(204);
      expect((await h.request("DELETE", `/v1/blocks/${blair.account_id}`, { token: alex.access_token })).status).toBe(204);

      const chat = await get(alex, `/v1/chats/${chatId}`);
      expect(chat.body).toMatchObject({ status: "closed", upcoming_session: null });
      const send = await h.send(blair, chatId, "hello again");
      expect(send.status).toBe(422);
      expect(send.body.error.code).toBe("chat_closed");
      expect((await get(alex, `/v1/invitations/${pending.invitation_id}`)).body.status).toBe("cancelled");
      expect((await get(alex, `/v1/invitations/${session.invitation_id}`)).body.status).toBe("cancelled");

      // A new accepted invitation reopens the same chat.
      expect(await h.connect(blair, alex, gym.id)).toBe(chatId);
      expect((await h.send(blair, chatId, "hello again")).status).toBe(201);
    });

    it("answers not_found for yourself, unknown and deleted accounts", async () => {
      const deleted = await h.climber(gym.id);
      await h.setAccountStatus(deleted.account_id, "deleted");
      for (const id of [alex.account_id, crypto.randomUUID(), deleted.account_id]) {
        expect((await block(alex, id)).status).toBe(404);
      }
    });

    it("pages the block list newest first", async () => {
      const others: Session[] = [];
      for (let i = 0; i < 3; i++) {
        others.push(await h.climber(gym.id, { display_name: `Other ${i}` }));
        await block(alex, others[i]!.account_id);
        h.advance(1);
      }
      const first = await get(alex, "/v1/blocks?limit=2");
      expect(first.body.items.map((b: any) => b.display_name)).toEqual(["Other 2", "Other 1"]);
      const second = await get(alex, `/v1/blocks?limit=2&cursor=${first.body.next_cursor}`);
      expect(second.body).toMatchObject({ items: [{ display_name: "Other 0" }], next_cursor: null });
    });
  });

  describe("reports", () => {
    it("files profile, invitation and message reports", async () => {
      const profile = await report(alex, { reported_account_id: blair.account_id, context: "profile", reason: "fake_profile" });
      expect(profile.status).toBe(201);
      expect(profile.body).toMatchObject({ reported_account_id: blair.account_id, context: "profile", reason: "fake_profile", status: "open" });

      const inv = (await h.invite(blair, alex, gym.id)).body;
      const invReport = await report(alex, {
        reported_account_id: blair.account_id, context: "invitation", invitation_id: inv.invitation_id, reason: "spam", details: "Keeps inviting",
      });
      expect(invReport.status).toBe(201);

      await h.request("POST", `/v1/invitations/${inv.invitation_id}/accept`, { token: alex.access_token });
      const chatId = (await get(alex, "/v1/chats")).body.items[0].chat_id;
      const msg = (await h.send(blair, chatId, "something nasty")).body;
      const msgReport = await report(alex, { reported_account_id: blair.account_id, context: "message", message_id: msg.message_id, reason: "harassment" });
      expect(msgReport.status).toBe(201);
      if (backend === "postgres") {
        const [row] = await h.adminQuery(`select message_snapshot, reporter_id from boulderme.reports where id = $1`, [msgReport.body.report_id]);
        expect(row).toEqual({ message_snapshot: "something nasty", reporter_id: alex.account_id });
      }
      // Reporting works after blocking too, and does not block by itself.
      await block(alex, blair.account_id);
      expect((await report(alex, { reported_account_id: blair.account_id, context: "message", message_id: msg.message_id, reason: "harassment" })).status).toBe(201);
    });

    it("only accepts invitations and messages that involve the reported member", async () => {
      const casey = await h.climber(gym.id);
      const inv = (await h.invite(blair, casey, gym.id)).body;
      expect((await report(alex, { reported_account_id: blair.account_id, context: "invitation", invitation_id: inv.invitation_id, reason: "spam" })).status).toBe(404);

      const chatId = await h.connect(alex, blair, gym.id);
      const mine = (await h.send(alex, chatId, "my own words")).body;
      expect((await report(alex, { reported_account_id: blair.account_id, context: "message", message_id: mine.message_id, reason: "spam" })).status).toBe(404);
      const theirChat = (await h.request("POST", `/v1/invitations/${inv.invitation_id}/accept`, { token: casey.access_token })).body.chat_id;
      const theirs = (await h.send(blair, theirChat, "not for alex")).body;
      expect((await report(alex, { reported_account_id: blair.account_id, context: "message", message_id: theirs.message_id, reason: "spam" })).status).toBe(404);

      expect((await report(alex, { reported_account_id: alex.account_id, context: "profile", reason: "spam" })).status).toBe(404);
      expect((await report(alex, { reported_account_id: crypto.randomUUID(), context: "profile", reason: "spam" })).status).toBe(404);
    });

    it("validates context ids and reasons", async () => {
      const missing = await report(alex, { reported_account_id: blair.account_id, context: "message", reason: "spam" });
      expect(missing.body.error.details.fields.message_id).toBe("required");
      const extra = await report(alex, { reported_account_id: blair.account_id, context: "profile", invitation_id: crypto.randomUUID(), reason: "spam" });
      expect(extra.body.error.details.fields.invitation_id).toBe("not_allowed_for_context");
      const reason = await report(alex, { reported_account_id: blair.account_id, context: "profile", reason: "rude" });
      expect(reason.body.error.details.fields.reason).toBe("invalid_value");
    });

    it("limits reports to 20 a day", async () => {
      for (let i = 0; i < 20; i++) {
        expect((await report(alex, { reported_account_id: blair.account_id, context: "profile", reason: "other" })).status).toBe(201);
      }
      expect((await report(alex, { reported_account_id: blair.account_id, context: "profile", reason: "other" })).status).toBe(429);
    });
  });
});

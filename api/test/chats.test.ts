import { afterEach, beforeEach, describe, expect, it } from "vitest";
import type { GymRecord } from "../src/db/repository";
import { BACKENDS, Harness, type Session } from "./support/harness";

describe.each(BACKENDS)("chats (%s)", (backend) => {
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
  const bodies = (res: { body: any }) => res.body.items.map((m: any) => m.body);

  it("has no chat until an invitation is accepted", async () => {
    const inv = (await h.invite(alex, blair, gym.id)).body;
    expect((await get(alex, "/v1/chats")).body).toEqual({ items: [], next_cursor: null });
    await h.request("POST", `/v1/invitations/${inv.invitation_id}/accept`, { token: blair.access_token });
    const chats = await get(alex, "/v1/chats");
    expect(chats.body.items).toHaveLength(1);
    const chat = chats.body.items[0];
    expect(chat).toMatchObject({
      status: "open", last_message: null, unread_count: 0,
      other_member: { account_id: blair.account_id, display_name: "Blair" },
      upcoming_session: { invitation_id: inv.invitation_id, status: "accepted" },
    });
    expect((await get(blair, `/v1/chats/${chat.chat_id}`)).body.other_member.account_id).toBe(alex.account_id);
  });

  it("sends messages, pages history newest first and polls oldest first", async () => {
    const chatId = await h.connect(alex, blair, gym.id);
    const sent: any[] = [];
    for (const [who, text] of [[alex, "hi"], [blair, "hey!"], [alex, "  tuesday?\nafter work  "], [blair, "deal"]] as const) {
      const res = await h.send(who, chatId, text);
      expect(res.status).toBe(201);
      sent.push(res.body);
    }
    expect(sent[2].body).toBe("tuesday?\nafter work");
    expect(sent[0].sender_account_id).toBe(alex.account_id);

    const page1 = await get(alex, `/v1/chats/${chatId}/messages?limit=3`);
    expect(bodies(page1)).toEqual(["deal", "tuesday?\nafter work", "hey!"]);
    const page2 = await get(alex, `/v1/chats/${chatId}/messages?limit=3&cursor=${page1.body.next_cursor}`);
    expect(bodies(page2)).toEqual(["hi"]);
    expect(page2.body.next_cursor).toBeNull();

    const poll = await get(blair, `/v1/chats/${chatId}/messages?after=${sent[0].message_id}`);
    expect(bodies(poll)).toEqual(["hey!", "tuesday?\nafter work", "deal"]);
    expect(poll.body.next_cursor).toBeNull();
    const nothingNew = await get(blair, `/v1/chats/${chatId}/messages?after=${sent[3].message_id}`);
    expect(nothingNew.body.items).toEqual([]);
  });

  it("keeps insertion order for messages sent in the same instant", async () => {
    const chatId = await h.connect(alex, blair, gym.id);
    const ids: string[] = [];
    for (let i = 0; i < 5; i++) ids.push((await h.send(alex, chatId, `m${i}`)).body.message_id);
    const poll = await get(blair, `/v1/chats/${chatId}/messages?after=${ids[0]}`);
    expect(bodies(poll)).toEqual(["m1", "m2", "m3", "m4"]);
  });

  it("counts unread messages and marks them read when fetched", async () => {
    const chatId = await h.connect(alex, blair, gym.id);
    const first = (await h.send(alex, chatId, "one")).body;
    await h.send(alex, chatId, "two");
    expect((await get(blair, `/v1/chats/${chatId}`)).body.unread_count).toBe(2);
    expect((await get(blair, "/v1/me")).body.unread_chat_count).toBe(1);
    expect((await get(alex, `/v1/chats/${chatId}`)).body.unread_count).toBe(0);

    // Polling from the first message reads up to "two".
    await get(blair, `/v1/chats/${chatId}/messages?after=${first.message_id}`);
    expect((await get(blair, `/v1/chats/${chatId}`)).body.unread_count).toBe(0);
    await h.send(alex, chatId, "three");
    const chat = (await get(blair, "/v1/chats")).body.items[0];
    expect(chat).toMatchObject({ unread_count: 1, last_message: { body: "three", sender_account_id: alex.account_id } });
    // Paging back through older history never moves the marker backwards.
    const latest = await get(blair, `/v1/chats/${chatId}/messages?limit=1`);
    await get(blair, `/v1/chats/${chatId}/messages?limit=1&cursor=${latest.body.next_cursor}`);
    expect((await get(blair, `/v1/chats/${chatId}`)).body.unread_count).toBe(0);
    // Replying marks everything before it read.
    await h.send(alex, chatId, "four");
    await h.send(blair, chatId, "ok");
    expect((await get(blair, "/v1/me")).body.unread_chat_count).toBe(0);
  });

  it("orders the chat list by latest message and pages it", async () => {
    const casey = await h.climber(gym.id, { display_name: "Casey" });
    const withBlair = await h.connect(alex, blair, gym.id);
    h.advance(1);
    const withCasey = await h.connect(alex, casey, gym.id);
    h.advance(1);
    expect((await get(alex, "/v1/chats")).body.items.map((c: any) => c.chat_id)).toEqual([withCasey, withBlair]);
    await h.send(blair, withBlair, "bump");
    const first = await get(alex, "/v1/chats?limit=1");
    expect(first.body.items[0].chat_id).toBe(withBlair);
    const second = await get(alex, `/v1/chats?limit=1&cursor=${first.body.next_cursor}`);
    expect(second.body.items[0].chat_id).toBe(withCasey);
    expect(second.body.next_cursor).toBeNull();
  });

  it("reuses the pair's chat for later sessions", async () => {
    const chatId = await h.connect(alex, blair, gym.id);
    await h.send(alex, chatId, "see you");
    expect(await h.connect(blair, alex, gym.id)).toBe(chatId);
    expect((await get(alex, "/v1/chats")).body.items).toHaveLength(1);
  });

  it("is invisible to anyone outside the pair", async () => {
    const chatId = await h.connect(alex, blair, gym.id);
    const msg = (await h.send(alex, chatId, "private")).body;
    const stranger = await h.climber(gym.id);
    expect((await get(stranger, `/v1/chats/${chatId}`)).status).toBe(404);
    expect((await get(stranger, `/v1/chats/${chatId}/messages`)).status).toBe(404);
    expect((await get(stranger, `/v1/chats/${chatId}/messages?after=${msg.message_id}`)).status).toBe(404);
    expect((await h.send(stranger, chatId, "hi")).status).toBe(404);
    expect((await get(stranger, `/v1/chats/${crypto.randomUUID()}`)).status).toBe(404);
  });

  it("validates message bodies and polling parameters", async () => {
    const chatId = await h.connect(alex, blair, gym.id);
    const blank = await h.send(alex, chatId, "   ");
    expect(blank.body.error.details.fields.body).toBe("required");
    const long = await h.send(alex, chatId, "x".repeat(1001));
    expect(long.body.error.details.fields.body).toBe("too_long");
    const unknown = await get(alex, `/v1/chats/${chatId}/messages?after=${crypto.randomUUID()}`);
    expect(unknown.body.error.details.fields.after).toBe("unknown_message");
    const msg = (await h.send(alex, chatId, "hi")).body;
    const both = await get(alex, `/v1/chats/${chatId}/messages?after=${msg.message_id}&cursor=abc`);
    expect(both.body.error.details.fields.after).toBe("not_with_cursor");
    const noKey = await h.request("POST", `/v1/chats/${chatId}/messages`, { token: alex.access_token, body: { body: "hi" } });
    expect(noKey.body.error.details.fields["Idempotency-Key"]).toBe("required");
  });

  it("replays a retried send instead of duplicating it", async () => {
    const chatId = await h.connect(alex, blair, gym.id);
    const key = crypto.randomUUID();
    const send = () => h.request("POST", `/v1/chats/${chatId}/messages`, { token: alex.access_token, headers: { "idempotency-key": key }, body: { body: "once" } });
    const a = await send();
    const b = await send();
    expect(b.body.message_id).toBe(a.body.message_id);
    expect((await get(blair, `/v1/chats/${chatId}/messages`)).body.items).toHaveLength(1);
  });

  it("rate limits sending to 60 messages a minute", async () => {
    const chatId = await h.connect(alex, blair, gym.id);
    for (let i = 0; i < 60; i++) expect((await h.send(alex, chatId, `m${i}`)).status).toBe(201);
    expect((await h.send(alex, chatId, "one too many")).status).toBe(429);
  });
});

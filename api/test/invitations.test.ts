import { afterEach, beforeEach, describe, expect, it } from "vitest";
import type { GymRecord } from "../src/db/repository";
import { BACKENDS, Harness, type Session } from "./support/harness";

describe.each(BACKENDS)("invitations (%s)", (backend) => {
  let h: Harness;
  let gym: GymRecord;
  let alex: Session;
  let blair: Session;
  beforeEach(async () => {
    h = await Harness.create(backend);
    gym = await h.addGym({ name: "Boulder Barn", city: "Toronto" });
    alex = await h.climber(gym.id, { display_name: "Alex", grade_min: 3, grade_max: 5 });
    blair = await h.climber(gym.id, { display_name: "Blair", grade_min: 4, grade_max: 6 });
  });
  afterEach(async () => h.close());

  const act = (s: Session, id: string, action: string) => h.request("POST", `/v1/invitations/${id}/${action}`, { token: s.access_token });
  const list = (s: Session, query: string) => h.request("GET", `/v1/invitations?${query}`, { token: s.access_token });

  it("sends an invitation both members can see, with replay-safe creation", async () => {
    const key = crypto.randomUUID();
    const start = new Date(h.clock.getTime() + 3 * 86_400_000);
    const body = { recipient_account_id: blair.account_id, gym_id: gym.id, proposed_start_at: start.toISOString(), note: "  Projecting the cave?  " };
    const res = await h.request("POST", "/v1/invitations", { token: alex.access_token, body, headers: { "idempotency-key": key } });
    expect(res.status).toBe(201);
    expect(res.body).toMatchObject({
      status: "pending", duration_minutes: 120, note: "Projecting the cave?", chat_id: null, responded_at: null,
      sender: { account_id: alex.account_id, display_name: "Alex", grade_min: 3, grade_max: 5 },
      recipient: { account_id: blair.account_id, display_name: "Blair", grade_min: 4, grade_max: 6 },
      gym: { gym_id: gym.id, name: "Boulder Barn" },
    });
    expect(res.body.expires_at).toBe(res.body.proposed_start_at);

    const replay = await h.request("POST", "/v1/invitations", { token: alex.access_token, body, headers: { "idempotency-key": key } });
    expect(replay.status).toBe(201);
    expect(replay.body.invitation_id).toBe(res.body.invitation_id);
    const mismatch = await h.request("POST", "/v1/invitations", {
      token: alex.access_token, body: { ...body, note: null }, headers: { "idempotency-key": key },
    });
    expect(mismatch.body.error.code).toBe("idempotency_mismatch");

    expect((await list(blair, "box=incoming")).body.items.map((i: any) => i.invitation_id)).toEqual([res.body.invitation_id]);
    expect((await list(alex, "box=outgoing")).body.items).toHaveLength(1);
    expect((await list(alex, "box=incoming")).body.items).toHaveLength(0);
    expect((await list(blair, "box=incoming&status=accepted")).body.items).toHaveLength(0);
    expect((await h.request("GET", `/v1/invitations/${res.body.invitation_id}`, { token: blair.access_token })).status).toBe(200);
    const me = await h.request("GET", "/v1/me", { token: blair.access_token });
    expect(me.body.pending_incoming_invitation_count).toBe(1);
  });

  it("requires the caller's own profile", async () => {
    const bare = await h.signIn();
    const res = await h.invite(bare, blair, gym.id);
    expect(res.status).toBe(422);
    expect(res.body.error.code).toBe("profile_incomplete");
  });

  it("answers not_found for self, unknown, paused, deleted and blocked recipients", async () => {
    const paused = await h.climber(gym.id);
    await h.request("PUT", "/v1/me/discovery", { token: paused.access_token, body: { discoverable: false } });
    const deleted = await h.climber(gym.id);
    await h.setAccountStatus(deleted.account_id, "deleted");
    const blockedByMe = await h.climber(gym.id);
    await h.block(alex.account_id, blockedByMe.account_id);
    const blockedMe = await h.climber(gym.id);
    await h.block(blockedMe.account_id, alex.account_id);
    const unknown = { ...blair, account_id: crypto.randomUUID() };
    for (const target of [alex, unknown, paused, deleted, blockedByMe, blockedMe]) {
      const res = await h.invite(alex, target, gym.id);
      expect(res.status).toBe(404);
      expect(res.body.error.code).toBe("not_found");
    }
    // The blocked side cannot invite either.
    expect((await h.invite(blockedMe, alex, gym.id)).status).toBe(404);
  });

  it("needs a gym both members list", async () => {
    const other = await h.addGym({ name: "Other Wall", city: "Toronto" });
    await h.addGymAccess(alex, other.id);
    for (const gymId of [other.id, crypto.randomUUID()]) {
      const res = await h.invite(alex, blair, gymId);
      expect(res.status).toBe(422);
      expect(res.body.error.code).toBe("gym_not_shared");
    }
  });

  it("needs a time between 1 hour and 60 days ahead", async () => {
    const at = (ms: number) => ({ proposed_start_at: new Date(h.clock.getTime() + ms).toISOString() });
    for (const ms of [30 * 60_000, -86_400_000, 61 * 86_400_000]) {
      const res = await h.invite(alex, blair, gym.id, at(ms));
      expect(res.status).toBe(422);
      expect(res.body.error.code).toBe("invalid_time");
    }
    expect((await h.invite(alex, blair, gym.id, at(61 * 60_000))).status).toBe(201);
    const bad = await h.invite(alex, blair, gym.id, { proposed_start_at: "tomorrow" });
    expect(bad.body.error.details.fields.proposed_start_at).toBe("invalid_timestamp");
  });

  it("allows one pending invitation per pair in either direction", async () => {
    const first = await h.invite(alex, blair, gym.id);
    expect(first.status).toBe(201);
    for (const [from, to] of [[alex, blair], [blair, alex]] as const) {
      const res = await h.invite(from, to, gym.id);
      expect(res.status).toBe(409);
      expect(res.body.error.code).toBe("invitation_already_open");
    }
    await act(blair, first.body.invitation_id, "decline");
    expect((await h.invite(blair, alex, gym.id)).status).toBe(201);
  });

  it("lets an expired invitation free the pair for a new one", async () => {
    const first = await h.invite(alex, blair, gym.id, { proposed_start_at: new Date(h.clock.getTime() + 2 * 3_600_000).toISOString() });
    await h.travel(3 * 3600, alex, blair);
    const read = await h.request("GET", `/v1/invitations/${first.body.invitation_id}`, { token: blair.access_token });
    expect(read.body.status).toBe("expired");
    expect((await list(blair, "box=incoming&status=expired")).body.items).toHaveLength(1);
    expect((await list(blair, "box=incoming&status=pending")).body.items).toHaveLength(0);
    expect((await h.request("GET", "/v1/me", { token: blair.access_token })).body.pending_incoming_invitation_count).toBe(0);
    const accept = await act(blair, first.body.invitation_id, "accept");
    expect(accept.status).toBe(409);
    expect(accept.body.error).toMatchObject({ code: "invalid_state", details: { status: "expired" } });
    expect((await h.invite(alex, blair, gym.id)).status).toBe(201);
  });

  it("limits each member to 20 new invitations a day", async () => {
    const others: Session[] = [];
    for (let i = 0; i < 21; i++) others.push(await h.climber(gym.id));
    for (let i = 0; i < 20; i++) expect((await h.invite(alex, others[i]!, gym.id)).status).toBe(201);
    const limited = await h.invite(alex, others[20]!, gym.id);
    expect(limited.status).toBe(429);
    expect(limited.body.error.code).toBe("rate_limited");
    expect(limited.headers.get("retry-after")).toMatch(/^\d+$/);
    await h.travel(86_401, alex, others[20]!);
    expect((await h.invite(alex, others[20]!, gym.id)).status).toBe(201);
  });

  it("runs the state machine: only the recipient answers, either side cancels a session", async () => {
    const inv = (await h.invite(alex, blair, gym.id)).body;
    for (const action of ["accept", "decline"]) {
      expect((await act(alex, inv.invitation_id, action)).body.error.code).toBe("invalid_state");
    }
    expect((await act(blair, inv.invitation_id, "cancel")).body.error.code).toBe("invalid_state");

    const accepted = await act(blair, inv.invitation_id, "accept");
    expect(accepted.status).toBe(200);
    expect(accepted.body.status).toBe("accepted");
    expect(accepted.body.chat_id).toMatch(/^[0-9a-f-]{36}$/);
    expect(accepted.body.responded_at).not.toBeNull();
    for (const action of ["accept", "decline"]) {
      expect((await act(blair, inv.invitation_id, action)).status).toBe(409);
    }
    const cancelled = await act(blair, inv.invitation_id, "cancel");
    expect(cancelled.body.status).toBe("cancelled");
    expect((await act(alex, inv.invitation_id, "cancel")).status).toBe(409);

    const withdrawn = (await h.invite(alex, blair, gym.id)).body;
    expect((await act(alex, withdrawn.invitation_id, "cancel")).body.status).toBe("cancelled");
    const declined = (await h.invite(alex, blair, gym.id)).body;
    expect((await act(blair, declined.invitation_id, "decline")).body).toMatchObject({ status: "declined", chat_id: null });
  });

  it("does not let a finished session be cancelled", async () => {
    const inv = (await h.invite(alex, blair, gym.id, { duration_minutes: 60 })).body;
    await act(blair, inv.invitation_id, "accept");
    await h.travel(2 * 86_400 + 30 * 60, alex, blair);
    expect((await act(alex, inv.invitation_id, "cancel")).status).toBe(200);
    const later = (await h.invite(alex, blair, gym.id, { duration_minutes: 60 })).body;
    await act(blair, later.invitation_id, "accept");
    await h.travel(2 * 86_400 + 61 * 60, alex, blair);
    expect((await act(alex, later.invitation_id, "cancel")).body.error.code).toBe("invalid_state");
  });

  it("hides invitations from everyone but the pair, and from a blocked pair", async () => {
    const inv = (await h.invite(alex, blair, gym.id)).body;
    const stranger = await h.climber(gym.id);
    for (const action of ["accept", "decline", "cancel"]) {
      expect((await act(stranger, inv.invitation_id, action)).status).toBe(404);
    }
    expect((await h.request("GET", `/v1/invitations/${inv.invitation_id}`, { token: stranger.access_token })).status).toBe(404);
    await h.block(blair.account_id, alex.account_id);
    expect((await h.request("GET", `/v1/invitations/${inv.invitation_id}`, { token: alex.access_token })).status).toBe(404);
    expect((await list(alex, "box=outgoing")).body.items).toHaveLength(0);
    expect((await act(blair, inv.invitation_id, "accept")).status).toBe(404);
  });

  it("pages newest first with cursors tied to the filters", async () => {
    const recipients: Session[] = [];
    for (let i = 0; i < 5; i++) {
      recipients.push(await h.climber(gym.id));
      expect((await h.invite(alex, recipients[i]!, gym.id)).status).toBe(201);
      h.advance(1);
    }
    const first = await list(alex, "box=outgoing&limit=2");
    expect(first.body.items.map((i: any) => i.recipient.account_id)).toEqual([recipients[4]!.account_id, recipients[3]!.account_id]);
    const second = await list(alex, `box=outgoing&limit=2&cursor=${first.body.next_cursor}`);
    const third = await list(alex, `box=outgoing&limit=2&cursor=${second.body.next_cursor}`);
    expect([...second.body.items, ...third.body.items].map((i: any) => i.recipient.account_id)).toEqual(
      [recipients[2], recipients[1], recipients[0]].map((r) => r!.account_id),
    );
    expect(third.body.next_cursor).toBeNull();
    const wrongFilter = await list(alex, `box=incoming&cursor=${first.body.next_cursor}`);
    expect(wrongFilter.body.error.code).toBe("invalid_cursor");
    expect((await list(alex, "box=sideways")).status).toBe(400);
  });

  it("marks expired invitations in the daily cleanup", async () => {
    await h.invite(alex, blair, gym.id, { proposed_start_at: new Date(h.clock.getTime() + 2 * 3_600_000).toISOString() });
    h.advance(3 * 3600);
    expect((await h.repo.purgeExpired(h.clock)).invitations_expired).toBe(1);
  });
});

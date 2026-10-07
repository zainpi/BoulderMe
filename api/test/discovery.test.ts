import { afterEach, beforeEach, describe, expect, it } from "vitest";
import type { GymRecord } from "../src/db/repository";
import { BACKENDS, Harness, type Session } from "./support/harness";

describe.each(BACKENDS)("discovery and profiles (%s)", (backend) => {
  let h: Harness;
  let gym: GymRecord;
  let me: Session;
  beforeEach(async () => {
    h = await Harness.create(backend);
    gym = await h.addGym({ name: "Boulder Barn", city: "Toronto" });
    me = await h.climber(gym.id, { display_name: "Me", grade_min: 4, grade_max: 6 });
  });
  afterEach(async () => h.close());

  const discover = (query: string, session = me) => h.request("GET", `/v1/discovery?gym_id=${gym.id}${query}`, { token: session.access_token });
  const names = (res: { body: any }) => res.body.items.map((c: any) => c.display_name);

  it("returns only discoverable, active, unblocked members at the gym, never the caller", async () => {
    const visible = await h.climber(gym.id, { display_name: "Visible" });
    const paused = await h.climber(gym.id, { display_name: "Paused" });
    await h.request("PUT", "/v1/me/discovery", { token: paused.access_token, body: { discoverable: false } });
    const deleted = await h.climber(gym.id, { display_name: "Deleted" });
    await h.setAccountStatus(deleted.account_id, "deleting");
    const iBlocked = await h.climber(gym.id, { display_name: "IBlocked" });
    await h.block(me.account_id, iBlocked.account_id);
    const blockedMe = await h.climber(gym.id, { display_name: "BlockedMe" });
    await h.block(blockedMe.account_id, me.account_id);
    const elsewhere = await h.addGym({ name: "Other Wall", city: "Ottawa" });
    await h.climber(elsewhere.id, { display_name: "Elsewhere" });
    const noProfileYet = await h.signIn();
    void noProfileYet;

    const res = await discover("");
    expect(res.status).toBe(200);
    expect(names(res)).toEqual(["Visible"]);
    expect(res.body.items[0]).toEqual({
      account_id: visible.account_id, display_name: "Visible", grade_min: 3, grade_max: 5, styles: ["slab"],
      access_type: "membership", availability_summary: [], active_recently: true,
    });
    expect(res.body.next_cursor).toBeNull();
  });

  it("filters by grade overlap and access type, ranking the closest grade ranges first", async () => {
    await h.climber(gym.id, { display_name: "Exact", grade_min: 4, grade_max: 6 });
    await h.climber(gym.id, { display_name: "Partial", grade_min: 6, grade_max: 9 }, "guest_pass");
    await h.climber(gym.id, { display_name: "Strong", grade_min: 10, grade_max: 12 });
    await h.climber(gym.id, { display_name: "Beginner", grade_min: 0, grade_max: 1 });

    expect(names(await discover("&grade_min=4&grade_max=6"))).toEqual(["Exact", "Partial"]);
    expect(names(await discover("&grade_min=4&grade_max=6&access_type=guest_pass"))).toEqual(["Partial"]);
    // Without a grade filter everyone at the gym shows, ranked by overlap with my own V4-V6.
    expect(names(await discover(""))).toEqual(["Exact", "Partial", "Beginner", "Strong"]);
  });

  it("filters by weekday and time of day using slots for this gym or any gym", async () => {
    const other = await h.addGym({ name: "Other Wall", city: "Toronto" });
    const evening = await h.climber(gym.id, { display_name: "Evening" });
    await h.addSlot(evening, { weekday: 2, start_minute: 1080, end_minute: 1260 });
    const morning = await h.climber(gym.id, { display_name: "Morning" });
    await h.addGymAccess(morning, other.id);
    await h.addSlot(morning, { weekday: 2, start_minute: 420, end_minute: 600, gym_id: gym.id });
    await h.addSlot(morning, { weekday: 4, start_minute: 1080, end_minute: 1200, gym_id: other.id });
    await h.climber(gym.id, { display_name: "NoSlots" });

    expect(names(await discover("&weekday=2")).sort()).toEqual(["Evening", "Morning"]);
    expect(names(await discover("&weekday=2&time_of_day=evening"))).toEqual(["Evening"]);
    expect(names(await discover("&time_of_day=morning"))).toEqual(["Morning"]);
    // Morning's Thursday evening slot is at the other gym, so it does not count here.
    expect(names(await discover("&weekday=4"))).toEqual([]);

    const card = (await discover("&weekday=2")).body.items.find((c: any) => c.display_name === "Evening");
    expect(card.availability_summary).toEqual([{ weekday: 2, time_of_day: "evening" }]);
    const spanning = await h.climber(gym.id, { display_name: "AllDay" });
    await h.addSlot(spanning, { weekday: 6, start_minute: 600, end_minute: 1140 });
    const allDay = (await discover("&weekday=6")).body.items[0];
    expect(allDay.availability_summary).toEqual([
      { weekday: 6, time_of_day: "morning" }, { weekday: 6, time_of_day: "afternoon" }, { weekday: 6, time_of_day: "evening" },
    ]);
  });

  it("ranks recently active members first and reports activity without dates", async () => {
    const old = await h.climber(gym.id, { display_name: "Old", grade_min: 4, grade_max: 6 });
    await h.setLastActiveOn(old.account_id, "2020-01-01");
    await h.climber(gym.id, { display_name: "Fresh", grade_min: 4, grade_max: 6 });
    const res = await discover("&grade_min=4&grade_max=6");
    expect(names(res)).toEqual(["Fresh", "Old"]);
    expect(res.body.items.map((c: any) => c.active_recently)).toEqual([true, false]);
  });

  it("pages through results with a cursor without repeats or gaps", async () => {
    for (let i = 0; i < 5; i++) await h.climber(gym.id, { display_name: `C${i}`, grade_min: i, grade_max: i + 4 });
    const seen: string[] = [];
    let cursor: string | null = null;
    let pages = 0;
    do {
      const res: { body: any } = await discover(`&limit=2${cursor ? `&cursor=${cursor}` : ""}`);
      seen.push(...names(res));
      cursor = res.body.next_cursor;
      pages++;
    } while (cursor);
    expect(pages).toBe(3);
    expect(seen.sort()).toEqual(["C0", "C1", "C2", "C3", "C4"]);
    const first = await discover("&limit=2");
    const changed = await discover(`&limit=2&grade_min=1&cursor=${first.body.next_cursor}`);
    expect(changed.body.error.code).toBe("invalid_cursor");
  });

  it("requires the caller's own profile, a real active gym and valid filters", async () => {
    const newcomer = await h.signIn();
    const res = await discover("", newcomer);
    expect(res.status).toBe(422);
    expect(res.body.error.code).toBe("profile_incomplete");
    expect((await h.request("GET", `/v1/discovery?gym_id=${crypto.randomUUID()}`, { token: me.access_token })).status).toBe(404);
    expect((await h.request("GET", "/v1/discovery", { token: me.access_token })).body.error.details.fields.gym_id).toBe("required");
    expect((await discover("&grade_min=7&grade_max=2")).body.error.details.fields.grade_min).toBeDefined();
    expect((await discover("&weekday=0")).body.error.details.fields.weekday).toBeDefined();
    expect((await discover("&time_of_day=night")).body.error.details.fields.time_of_day).toBeDefined();
  });

  it("limits discovery to 120 requests a minute per account", async () => {
    for (let i = 0; i < 120; i++) expect((await discover("")).status).toBe(200);
    const limited = await discover("");
    expect(limited.status).toBe(429);
    expect(limited.body.error.code).toBe("rate_limited");
    h.advance(60);
    expect((await discover("")).status).toBe(200);
  });

  describe("public profiles", () => {
    const profile = (id: string, session = me) => h.request("GET", `/v1/profiles/${id}`, { token: session.access_token });

    it("shows discoverable members with gyms and availability", async () => {
      const them = await h.climber(gym.id, { display_name: "Them", intro: "Hi!" });
      const slot = await h.addSlot(them, { weekday: 3, start_minute: 600, end_minute: 720 });
      const res = await profile(them.account_id);
      expect(res.status).toBe(200);
      expect(res.body).toMatchObject({ account_id: them.account_id, display_name: "Them", intro: "Hi!", active_recently: true });
      expect(res.body.gyms[0].gym.gym_id).toBe(gym.id);
      expect(res.body.availability).toEqual([slot]);
    });

    it("hides paused members unless the pair shares an invitation", async () => {
      const paused = await h.climber(gym.id, { display_name: "Paused" });
      await h.request("PUT", "/v1/me/discovery", { token: paused.access_token, body: { discoverable: false } });
      expect((await profile(paused.account_id)).status).toBe(404);
      await h.invitation(paused.account_id, me.account_id, gym.id, "declined");
      expect((await profile(paused.account_id)).status).toBe(200);
    });

    it("returns not_found for blocked (either way), deleted, profile-less and unknown members", async () => {
      const blocked = await h.climber(gym.id);
      await h.invitation(blocked.account_id, me.account_id, gym.id, "accepted");
      await h.block(blocked.account_id, me.account_id);
      const deleted = await h.climber(gym.id);
      await h.setAccountStatus(deleted.account_id, "deleted");
      const bare = await h.signIn();
      for (const id of [blocked.account_id, deleted.account_id, bare.account_id, crypto.randomUUID()]) {
        const res = await profile(id);
        expect(res.status).toBe(404);
        expect(res.body.error.code).toBe("not_found");
      }
      expect((await profile(me.account_id, blocked)).status).toBe(404);
    });
  });
});

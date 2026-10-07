import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { BACKENDS, Harness, type Session } from "./support/harness";

const PROFILE = {
  revision: 0, display_name: "Sam", grade_min: 3, grade_max: 6, styles: ["slab", "crimps"], intro: "Morning crusher",
  adult_confirmed: true, discovery_explained: true,
};

describe.each(BACKENDS)("profile, gyms and availability (%s)", (backend) => {
  let h: Harness;
  let s: Session;
  beforeEach(async () => {
    h = await Harness.create(backend);
    s = await h.signIn();
  });
  afterEach(async () => h.close());

  const put = (path: string, body: unknown, session = s) => h.request("PUT", path, { token: session.access_token, body });
  const get = (path: string, session = s) => h.request("GET", path, { token: session.access_token });

  describe("profile", () => {
    it("is 404 until created, then round-trips with revision 1", async () => {
      expect((await get("/v1/me/profile")).status).toBe(404);
      const created = await put("/v1/me/profile", PROFILE);
      expect(created.status).toBe(200);
      expect(created.body).toMatchObject({ revision: 1, display_name: "Sam", discoverable: false, styles: ["slab", "crimps"] });
      expect((await get("/v1/me/profile")).body).toEqual(created.body);
    });

    it("trims text and stores an empty intro as null", async () => {
      const res = await put("/v1/me/profile", { ...PROFILE, display_name: "  Sam  ", intro: "   " });
      expect(res.body.display_name).toBe("Sam");
      expect(res.body.intro).toBeNull();
    });

    it("detects stale writes with revision_conflict and returns the current profile", async () => {
      await put("/v1/me/profile", PROFILE);
      const updated = await put("/v1/me/profile", { ...PROFILE, revision: 1, display_name: "Sammy" });
      expect(updated.body.revision).toBe(2);
      const stale = await put("/v1/me/profile", { ...PROFILE, revision: 1, display_name: "Old" });
      expect(stale.status).toBe(409);
      expect(stale.body.error.code).toBe("revision_conflict");
      expect(stale.body.error.details.current.display_name).toBe("Sammy");
      const recreate = await put("/v1/me/profile", PROFILE);
      expect(recreate.status).toBe(409);
    });

    it("rejects a non-zero revision when no profile exists", async () => {
      const res = await put("/v1/me/profile", { ...PROFILE, revision: 3 });
      expect(res.status).toBe(409);
      expect(res.body.error.details.current).toBeNull();
    });

    it.each([
      ["grade_min above grade_max", { grade_min: 7, grade_max: 2 }, "grade_min"],
      ["grade out of range", { grade_max: 18 }, "grade_max"],
      ["adult not confirmed", { adult_confirmed: false }, "adult_confirmed"],
      ["unknown style", { styles: ["sport"] }, "styles.0"],
      ["duplicate styles", { styles: ["slab", "slab"] }, "styles"],
      ["too many styles", { styles: ["slab", "vertical", "overhang", "roof", "crimps", "slopers", "pinches"] }, "styles"],
      ["blank name", { display_name: "   " }, "display_name"],
      ["name too long", { display_name: "x".repeat(41) }, "display_name"],
      ["control characters", { display_name: "Sam\u0007" }, "display_name"],
      ["intro too long", { intro: "x".repeat(281) }, "intro"],
      ["unknown field", { photo_url: "https://x" }, "photo_url"],
    ])("rejects %s", async (_, patch, field) => {
      const res = await put("/v1/me/profile", { ...PROFILE, ...patch });
      expect(res.status).toBe(400);
      expect(res.body.error.code).toBe("validation_failed");
      expect(res.body.error.details.fields).toHaveProperty([field]);
    });

    it("requires intro to be present (null is fine)", async () => {
      const { intro: _, ...noIntro } = PROFILE;
      expect((await put("/v1/me/profile", noIntro)).body.error.details.fields.intro).toBe("required");
    });
  });

  describe("discovery switch", () => {
    it("needs a profile, the explainer and a gym before turning on", async () => {
      const none = await put("/v1/me/discovery", { discoverable: true });
      expect(none.status).toBe(422);
      expect(none.body.error.code).toBe("profile_incomplete");
      expect(none.body.error.details.missing).toEqual(["profile", "gym"]);

      await put("/v1/me/profile", { ...PROFILE, discovery_explained: false });
      const noGym = await put("/v1/me/discovery", { discoverable: true });
      expect(noGym.body.error.details.missing).toEqual(["discovery_explained", "gym"]);

      await put("/v1/me/profile", { ...PROFILE, revision: 1 });
      const gym = await h.addGym({ name: "Boulder Barn", city: "Toronto" });
      await h.addGymAccess(s, gym.id);
      const on = await put("/v1/me/discovery", { discoverable: true });
      expect(on.status).toBe(200);
      expect(on.body).toEqual({ discoverable: true });
      expect((await get("/v1/me/profile")).body.discoverable).toBe(true);

      const off = await put("/v1/me/discovery", { discoverable: false });
      expect(off.body).toEqual({ discoverable: false });
    });

    it("pauses discovery when the last gym is removed or the explainer is withdrawn", async () => {
      const gym = await h.addGym({ name: "Boulder Barn", city: "Toronto" });
      await put("/v1/me/profile", PROFILE);
      await h.addGymAccess(s, gym.id);
      await put("/v1/me/discovery", { discoverable: true });
      expect((await h.request("DELETE", `/v1/me/gyms/${gym.id}`, { token: s.access_token })).status).toBe(204);
      const afterRemove = (await get("/v1/me/profile")).body;
      expect(afterRemove.discoverable).toBe(false);

      await h.addGymAccess(s, gym.id);
      await put("/v1/me/discovery", { discoverable: true });
      const current = (await get("/v1/me/profile")).body;
      const res = await put("/v1/me/profile", { ...PROFILE, revision: current.revision, discovery_explained: false });
      expect(res.body.discoverable).toBe(false);
    });
  });

  describe("gyms", () => {
    it("lists active gyms by city then name, pages with a cursor, and searches", async () => {
      await h.addGym({ name: "Zed Boulders", city: "Ottawa" });
      await h.addGym({ name: "Alpha Bloc", city: "Toronto" });
      await h.addGym({ name: "Beta Bloc", city: "Toronto" });
      await h.addGym({ name: "Closed Bloc", city: "Toronto", isActive: false });
      await h.addGym({ name: "Rocher", city: "Gatineau", region: "CA-QC" });

      const page1 = await get("/v1/gyms?region=CA-ON&limit=2");
      expect(page1.body.items.map((g: any) => g.name)).toEqual(["Zed Boulders", "Alpha Bloc"]);
      expect(page1.body.next_cursor).toEqual(expect.any(String));
      const page2 = await get(`/v1/gyms?region=CA-ON&limit=2&cursor=${page1.body.next_cursor}`);
      expect(page2.body.items.map((g: any) => g.name)).toEqual(["Beta Bloc"]);
      expect(page2.body.next_cursor).toBeNull();

      const search = await get("/v1/gyms?q=bloc");
      expect(search.body.items.map((g: any) => g.name)).toEqual(["Alpha Bloc", "Beta Bloc"]);
      const byCity = await get("/v1/gyms?q=ottawa");
      expect(byCity.body.items.map((g: any) => g.name)).toEqual(["Zed Boulders"]);
      const literal = await get("/v1/gyms?q=%25%25");
      expect(literal.body.items).toEqual([]);
    });

    it("rejects cursors from other filters, tampered or expired cursors", async () => {
      for (const name of ["A1", "A2", "A3"]) await h.addGym({ name, city: "Toronto" });
      const page1 = await get("/v1/gyms?limit=1");
      const other = await get(`/v1/gyms?limit=1&region=CA-ON&cursor=${page1.body.next_cursor}`);
      expect(other.status).toBe(400);
      expect(other.body.error.code).toBe("invalid_cursor");
      expect((await get("/v1/gyms?cursor=garbage")).body.error.code).toBe("invalid_cursor");
      h.advance(25 * 3600);
      const fresh = await h.signIn();
      expect((await get(`/v1/gyms?limit=1&cursor=${page1.body.next_cursor}`, fresh)).body.error.code).toBe("invalid_cursor");
    });

    it("validates query parameters", async () => {
      expect((await get("/v1/gyms?q=a")).body.error.details.fields.q).toBeDefined();
      expect((await get("/v1/gyms?limit=51")).body.error.details.fields.limit).toBeDefined();
      expect((await get("/v1/gyms?region=ontario")).body.error.details.fields.region).toBeDefined();
      expect((await get("/v1/gyms?sort=name")).body.error.details.fields.sort).toBe("unknown_field");
    });

    it("returns one gym, and 404 for inactive, unknown or malformed ids", async () => {
      const gym = await h.addGym({ name: "Alpha", city: "Toronto", address: "1 Main St", websiteUrl: "https://alpha.example" });
      const closed = await h.addGym({ name: "Closed", city: "Toronto", isActive: false });
      expect((await get(`/v1/gyms/${gym.id}`)).body).toEqual({
        gym_id: gym.id, name: "Alpha", city: "Toronto", region: "CA-ON", country: "CA", address: "1 Main St",
        website_url: "https://alpha.example", is_bouldering_only: true,
      });
      expect((await get(`/v1/gyms/${closed.id}`)).status).toBe(404);
      expect((await get(`/v1/gyms/${crypto.randomUUID()}`)).status).toBe(404);
      expect((await get("/v1/gyms/not-a-uuid")).status).toBe(404);
    });

    it("adds, changes and removes self-reported gym access, up to 10 gyms", async () => {
      const gyms = [];
      for (let i = 0; i < 11; i++) gyms.push(await h.addGym({ name: `Gym ${String(i).padStart(2, "0")}`, city: "Toronto" }));
      const added = await put(`/v1/me/gyms/${gyms[0]!.id}`, { access_type: "guest_pass" });
      expect(added.body).toMatchObject({ access_type: "guest_pass", self_reported: true, gym: { gym_id: gyms[0]!.id } });
      const changed = await put(`/v1/me/gyms/${gyms[0]!.id}`, { access_type: "membership" });
      expect(changed.body.access_type).toBe("membership");
      for (const g of gyms.slice(1, 10)) await h.addGymAccess(s, g.id);
      const over = await put(`/v1/me/gyms/${gyms[10]!.id}`, { access_type: "membership" });
      expect(over.status).toBe(422);
      expect(over.body.error.code).toBe("gym_limit_reached");
      // Changing an existing one at the limit is still fine.
      expect((await put(`/v1/me/gyms/${gyms[3]!.id}`, { access_type: "guest_pass" })).status).toBe(200);
      expect((await get("/v1/me/gyms")).body.items).toHaveLength(10);

      expect((await h.request("DELETE", `/v1/me/gyms/${gyms[0]!.id}`, { token: s.access_token })).status).toBe(204);
      expect((await h.request("DELETE", `/v1/me/gyms/${gyms[0]!.id}`, { token: s.access_token })).status).toBe(204);
      expect((await get("/v1/me/gyms")).body.items).toHaveLength(9);
    });

    it("404s gym access for unknown or inactive gyms and validates access_type", async () => {
      const closed = await h.addGym({ name: "Closed", city: "Toronto", isActive: false });
      expect((await put(`/v1/me/gyms/${closed.id}`, { access_type: "membership" })).status).toBe(404);
      expect((await put(`/v1/me/gyms/${crypto.randomUUID()}`, { access_type: "membership" })).status).toBe(404);
      const gym = await h.addGym({ name: "Open", city: "Toronto" });
      expect((await put(`/v1/me/gyms/${gym.id}`, { access_type: "owner" })).body.error.code).toBe("validation_failed");
    });

    it("records gym suggestions idempotently", async () => {
      const body = { name: "New Wall", city: "Kingston", region: "CA-ON", website_url: "https://newwall.example", note: null };
      const key = crypto.randomUUID();
      const first = await h.request("POST", "/v1/gym-requests", { token: s.access_token, body, headers: { "idempotency-key": key } });
      expect(first.status).toBe(201);
      expect(first.body).toMatchObject({ name: "New Wall", city: "Kingston", region: "CA-ON", status: "submitted" });
      const replay = await h.request("POST", "/v1/gym-requests", { token: s.access_token, body, headers: { "idempotency-key": key } });
      expect(replay.status).toBe(201);
      expect(replay.body).toEqual(first.body);
      expect(replay.headers.get("idempotency-replayed")).toBe("true");
      const mismatch = await h.request("POST", "/v1/gym-requests", {
        token: s.access_token, body: { ...body, city: "Ottawa" }, headers: { "idempotency-key": key },
      });
      expect(mismatch.status).toBe(409);
      expect(mismatch.body.error.code).toBe("idempotency_mismatch");
      const noKey = await h.request("POST", "/v1/gym-requests", { token: s.access_token, body });
      expect(noKey.body.error.details.fields["Idempotency-Key"]).toBe("required");
      // A different member may reuse the same key value independently.
      const other = await h.signIn();
      const theirs = await h.request("POST", "/v1/gym-requests", { token: other.access_token, body, headers: { "idempotency-key": key } });
      expect(theirs.body.gym_request_id).not.toBe(first.body.gym_request_id);
    });

    it("limits gym suggestions to 10 a day", async () => {
      const send = () => h.request("POST", "/v1/gym-requests", {
        token: s.access_token, body: { name: "Wall", city: "Kingston", region: "CA-ON" }, headers: { "idempotency-key": crypto.randomUUID() },
      });
      for (let i = 0; i < 10; i++) expect((await send()).status).toBe(201);
      const limited = await send();
      expect(limited.status).toBe(429);
      expect(Number(limited.headers.get("retry-after"))).toBeGreaterThan(0);
    });
  });

  describe("availability", () => {
    it("adds, updates, lists and deletes weekly slots", async () => {
      const gym = await h.addGym({ name: "Alpha", city: "Toronto" });
      await h.addGymAccess(s, gym.id);
      const slot = await h.addSlot(s, { weekday: 2, start_minute: 1080, end_minute: 1260, gym_id: gym.id });
      expect(slot).toMatchObject({ weekday: 2, start_minute: 1080, end_minute: 1260, time_zone: "America/Toronto", gym_id: gym.id });
      const anyGym = await h.addSlot(s, { weekday: 1, start_minute: 600, end_minute: 720 });
      expect(anyGym.gym_id).toBeNull();
      expect((await get("/v1/me/availability")).body.items.map((x: any) => x.weekday)).toEqual([1, 2]);

      const updated = await put(`/v1/me/availability/${slot.slot_id}`, { weekday: 6, start_minute: 540, end_minute: 660, time_zone: "America/Toronto" });
      expect(updated.status).toBe(200);
      expect(updated.body).toMatchObject({ slot_id: slot.slot_id, weekday: 6, gym_id: null });

      expect((await h.request("DELETE", `/v1/me/availability/${slot.slot_id}`, { token: s.access_token })).status).toBe(204);
      expect((await h.request("DELETE", `/v1/me/availability/${slot.slot_id}`, { token: s.access_token })).status).toBe(204);
      expect((await get("/v1/me/availability")).body.items).toHaveLength(1);
    });

    it.each([
      ["less than 30 minutes", { start_minute: 600, end_minute: 600 }, "end_minute"],
      ["off the half hour", { start_minute: 615, end_minute: 700 }, "start_minute"],
      ["bad weekday", { weekday: 8 }, "weekday"],
      ["bad time zone", { time_zone: "Mars/Olympus" }, "time_zone"],
      ["a gym the member does not list", { gym_id: "00000000-0000-4000-8000-000000000000" }, "gym_id"],
    ])("rejects a slot %s", async (_, patch, field) => {
      const res = await h.request("POST", "/v1/me/availability", {
        token: s.access_token, headers: { "idempotency-key": crypto.randomUUID() },
        body: { weekday: 1, start_minute: 600, end_minute: 720, time_zone: "America/Toronto", ...patch },
      });
      expect(res.status).toBe(400);
      expect(res.body.error.details.fields).toHaveProperty([field]);
    });

    it("caps slots at 21", async () => {
      for (let i = 0; i < 21; i++) await h.addSlot(s, { weekday: (i % 7) + 1, start_minute: 60 * (i % 3) * 4, end_minute: 60 * (i % 3) * 4 + 60 });
      const res = await h.request("POST", "/v1/me/availability", {
        token: s.access_token, headers: { "idempotency-key": crypto.randomUUID() },
        body: { weekday: 1, start_minute: 600, end_minute: 720, time_zone: "UTC" },
      });
      expect(res.status).toBe(422);
      expect(res.body.error.code).toBe("availability_limit_reached");
    });

    it("replays a retried add instead of creating a duplicate", async () => {
      const key = crypto.randomUUID();
      const body = { weekday: 3, start_minute: 600, end_minute: 720, time_zone: "UTC" };
      const a = await h.request("POST", "/v1/me/availability", { token: s.access_token, body, headers: { "idempotency-key": key } });
      const b = await h.request("POST", "/v1/me/availability", { token: s.access_token, body, headers: { "idempotency-key": key } });
      expect(b.body.slot_id).toBe(a.body.slot_id);
      expect((await get("/v1/me/availability")).body.items).toHaveLength(1);
    });

    it("never lets one member touch another's slot", async () => {
      const other = await h.signIn();
      const theirs = await h.addSlot(other, { weekday: 1, start_minute: 600, end_minute: 720 });
      const res = await put(`/v1/me/availability/${theirs.slot_id}`, { weekday: 2, start_minute: 600, end_minute: 720, time_zone: "UTC" });
      expect(res.status).toBe(404);
      await h.request("DELETE", `/v1/me/availability/${theirs.slot_id}`, { token: s.access_token });
      expect((await get("/v1/me/availability", other)).body.items).toHaveLength(1);
    });
  });

  describe("/v1/me", () => {
    it("reports onboarding progress and counts", async () => {
      const fresh = await get("/v1/me");
      expect(fresh.body).toMatchObject({
        account_id: s.account_id, profile: null, gyms: [], unread_chat_count: 0, pending_incoming_invitation_count: 0,
        onboarding: { has_profile: false, has_gym: false, has_availability: false, adult_confirmed: false, discovery_explained: false },
      });
      const gym = await h.addGym({ name: "Alpha", city: "Toronto" });
      await put("/v1/me/profile", PROFILE);
      await h.addGymAccess(s, gym.id);
      await h.addSlot(s, { weekday: 1, start_minute: 600, end_minute: 720 });
      const sender = await h.signIn();
      const blocked = await h.signIn();
      await h.invitation(sender.account_id, s.account_id, gym.id);
      await h.invitation(blocked.account_id, s.account_id, gym.id);
      await h.block(s.account_id, blocked.account_id);
      const me = await get("/v1/me");
      expect(me.body.onboarding).toEqual({ has_profile: true, has_gym: true, has_availability: true, adult_confirmed: true, discovery_explained: true });
      expect(me.body.gyms).toHaveLength(1);
      expect(me.body.pending_incoming_invitation_count).toBe(1);
    });
  });
});

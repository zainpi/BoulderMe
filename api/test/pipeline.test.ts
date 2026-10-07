import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { BACKENDS, Harness } from "./support/harness";

describe.each(BACKENDS)("request pipeline (%s)", (backend) => {
  let h: Harness;
  beforeEach(async () => (h = await Harness.create(backend)));
  afterEach(async () => h.close());

  it("reports health with the database state and a request id", async () => {
    const res = await h.request("GET", "/v1/health");
    expect(res.status).toBe(200);
    expect(res.body).toEqual({ status: "ok", version: "test", database: "ok" });
    expect(res.headers.get("x-request-id")).toMatch(/^[0-9a-f]{16}$/);
  });

  it("answers unknown routes, wrong methods and non-UUID ids with not_found", async () => {
    for (const [method, path] of [["GET", "/v1/nope"], ["DELETE", "/v1/gyms"], ["GET", "/v1/profiles/123"]] as const) {
      const res = await h.request(method, path);
      expect(res.status).toBe(404);
      expect(res.body.error).toMatchObject({ code: "not_found", details: null, request_id: res.headers.get("x-request-id") });
    }
  });

  it("enforces JSON bodies and the 16 KiB cap", async () => {
    const s = await h.signIn();
    const wrongType = await h.request("PUT", "/v1/me/discovery", {
      token: s.access_token, rawBody: '{"discoverable":true}', headers: { "content-type": "text/plain" },
    });
    expect(wrongType.body.error.code).toBe("validation_failed");
    const badJson = await h.request("PUT", "/v1/me/discovery", {
      token: s.access_token, rawBody: "{nope", headers: { "content-type": "application/json" },
    });
    expect(badJson.body.error.details.fields.body).toBe("invalid_json");
    const big = await h.request("PUT", "/v1/me/profile", {
      token: s.access_token, rawBody: JSON.stringify({ intro: "x".repeat(17_000) }), headers: { "content-type": "application/json" },
    });
    expect(big.status).toBe(400);
    expect(big.body.error.code).toBe("body_too_large");
  });

  it("rate limits unauthenticated routes per installation, with a shared anonymous bucket", async () => {
    const install = crypto.randomUUID();
    for (let i = 0; i < 10; i++) {
      expect((await h.request("POST", "/v1/auth/nonce", { headers: { "x-client-installation-id": install } })).status).toBe(201);
    }
    const limited = await h.request("POST", "/v1/auth/nonce", { headers: { "x-client-installation-id": install } });
    expect(limited.status).toBe(429);
    expect(limited.headers.get("retry-after")).toMatch(/^\d+$/);
    // Another installation is unaffected; anonymous callers get the larger shared bucket.
    expect((await h.request("POST", "/v1/auth/nonce", { headers: { "x-client-installation-id": crypto.randomUUID() } })).status).toBe(201);
    expect((await h.request("POST", "/v1/auth/nonce")).status).toBe(201);
    const bad = await h.request("POST", "/v1/auth/nonce", { headers: { "x-client-installation-id": "not-a-uuid" } });
    expect(bad.status).toBe(400);
  });

  it("logs one sanitized line per request", async () => {
    const s = await h.signIn();
    h.logs.length = 0;
    await h.request("GET", `/v1/gyms?q=secret-search`, { token: s.access_token });
    expect(h.logs).toHaveLength(1);
    expect(h.logs[0]).toMatchObject({ level: "info", method: "GET", route: "GET /v1/gyms", status: 200 });
    expect(JSON.stringify(h.logs)).not.toContain("secret-search");
  });

  it("purges expired housekeeping rows", async () => {
    await h.request("POST", "/v1/auth/nonce");
    h.advance(3 * 86_400);
    const purged = await h.repo.purgeExpired(h.clock);
    expect(purged.auth_nonces).toBe(1);
    expect(purged.rate_limits).toBeGreaterThanOrEqual(1);
  });
});

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { generateKeyPair } from "jose";
import { decryptString, sha256Hex } from "../src/auth/crypto";
import { BACKENDS, Harness, encryptionKey } from "./support/harness";

describe.each(BACKENDS)("auth (%s)", (backend) => {
  let h: Harness;
  beforeEach(async () => (h = await Harness.create(backend)));
  afterEach(async () => h.close());

  async function signInWith(sub: string, tokenClaims: Record<string, unknown> = {}, nonceOverride?: string) {
    const nonce = await h.nonce();
    const identity_token = await h.appleToken({ sub, nonce: await sha256Hex(nonce), ...tokenClaims });
    return h.request("POST", "/v1/auth/apple", { body: { identity_token, authorization_code: "code", nonce: nonceOverride ?? nonce } });
  }

  it("issues a nonce that expires in 10 minutes", async () => {
    const res = await h.request("POST", "/v1/auth/nonce");
    expect(res.status).toBe(201);
    expect(res.body.nonce.length).toBeGreaterThanOrEqual(32);
    expect(Date.parse(res.body.expires_at) - h.clock.getTime()).toBeGreaterThan(9 * 60_000);
  });

  it("creates an account on first sign-in and reuses it after", async () => {
    const first = await signInWith("sub-1");
    expect(first.status).toBe(200);
    expect(first.body.is_new_account).toBe(true);
    const second = await signInWith("sub-1");
    expect(second.status).toBe(200);
    expect(second.body.is_new_account).toBe(false);
    expect(second.body.account_id).toBe(first.body.account_id);
    const me = await h.request("GET", "/v1/me", { token: second.body.access_token });
    expect(me.status).toBe(200);
    expect(me.body.account_id).toBe(first.body.account_id);
  });

  it("stores Apple's refresh token encrypted, never in plain text", async () => {
    const s = await h.signIn();
    const stored = await h.storedAppleToken(s.account_id);
    expect(stored).toMatch(/^v1:/);
    expect(stored).not.toContain("apple-refresh-token-secret");
    expect(await decryptString(encryptionKey(), stored!)).toBe("apple-refresh-token-secret");
  });

  it.each([
    ["wrong audience", { aud: "com.someone.else" }],
    ["wrong issuer", { iss: "https://evil.example" }],
    ["expired", { expiresIn: -60 }],
  ])("rejects an identity token with %s", async (_, claims) => {
    const res = await signInWith("sub-x", claims);
    expect(res.status).toBe(401);
    expect(res.body.error.code).toBe("apple_token_invalid");
  });

  it("rejects an identity token signed by another key", async () => {
    const { privateKey } = await generateKeyPair("RS256");
    const nonce = await h.nonce();
    const identity_token = await h.appleToken({ sub: "sub-x", nonce: await sha256Hex(nonce) }, privateKey);
    const res = await h.request("POST", "/v1/auth/apple", { body: { identity_token, authorization_code: "c", nonce } });
    expect(res.status).toBe(401);
    expect(res.body.error.code).toBe("apple_token_invalid");
  });

  it("rejects a nonce that does not match the token, was never issued, or was already used", async () => {
    const mismatch = await signInWith("sub-n", {}, "x".repeat(43));
    expect(mismatch.body.error.code).toBe("nonce_invalid");

    const unissued = "y".repeat(43);
    const token = await h.appleToken({ sub: "sub-n", nonce: await sha256Hex(unissued) });
    const res = await h.request("POST", "/v1/auth/apple", { body: { identity_token: token, authorization_code: "c", nonce: unissued } });
    expect(res.body.error.code).toBe("nonce_invalid");

    const nonce = await h.nonce();
    const reused = await h.appleToken({ sub: "sub-n", nonce: await sha256Hex(nonce) });
    const body = { identity_token: reused, authorization_code: "c", nonce };
    expect((await h.request("POST", "/v1/auth/apple", { body })).status).toBe(200);
    const replay = await h.request("POST", "/v1/auth/apple", { body });
    expect(replay.status).toBe(401);
    expect(replay.body.error.code).toBe("nonce_invalid");
  });

  it("rejects an expired nonce", async () => {
    const nonce = await h.nonce();
    h.advance(11 * 60);
    const identity_token = await h.appleToken({ sub: "sub-late", nonce: await sha256Hex(nonce) });
    const res = await h.request("POST", "/v1/auth/apple", { body: { identity_token, authorization_code: "c", nonce } });
    expect(res.body.error.code).toBe("nonce_invalid");
  });

  it("maps Apple rejecting the code to apple_token_invalid and Apple outages to unavailable", async () => {
    h.appleTokenResponse = { status: 400, body: { error: "invalid_grant" } };
    expect((await h.signInResponse("sub-a")).body.error.code).toBe("apple_token_invalid");
    h.appleTokenResponse = { status: 503, body: {} };
    const res = await h.signInResponse("sub-a");
    expect(res.status).toBe(503);
    expect(res.body.error.code).toBe("unavailable");
  });

  it("refuses sign-in for deleted accounts and while a deletion is pending", async () => {
    const s = await h.signIn("sub-gone");
    await h.setAccountStatus(s.account_id, "deleted");
    expect((await h.signInResponse("sub-gone")).body.error.code).toBe("account_deleted");
    await h.addTombstone("sub-tomb");
    expect((await h.signInResponse("sub-tomb")).body.error.code).toBe("account_deleted");
  });

  it("rotates refresh tokens and revokes the family when an old one is replayed", async () => {
    const s = await h.signIn();
    const r1 = await h.request("POST", "/v1/auth/refresh", { body: { refresh_token: s.refresh_token } });
    expect(r1.status).toBe(200);
    expect(r1.body.refresh_token).not.toBe(s.refresh_token);
    expect(r1.body.account_id).toBe(s.account_id);
    expect(r1.body.is_new_account).toBe(false);

    const replay = await h.request("POST", "/v1/auth/refresh", { body: { refresh_token: s.refresh_token } });
    expect(replay.status).toBe(401);
    expect(replay.body.error.code).toBe("refresh_token_reused");

    // The whole family is gone: the newest refresh token and its access token stop working.
    const r2 = await h.request("POST", "/v1/auth/refresh", { body: { refresh_token: r1.body.refresh_token } });
    expect(r2.body.error.code).toBe("unauthorized");
    const me = await h.request("GET", "/v1/me", { token: r1.body.access_token });
    expect(me.status).toBe(401);
  });

  it("rejects unknown and expired refresh tokens", async () => {
    const unknown = await h.request("POST", "/v1/auth/refresh", { body: { refresh_token: "z".repeat(43) } });
    expect(unknown.body.error.code).toBe("unauthorized");
    const s = await h.signIn();
    h.advance(61 * 86_400);
    const expired = await h.request("POST", "/v1/auth/refresh", { body: { refresh_token: s.refresh_token } });
    expect(expired.body.error.code).toBe("unauthorized");
  });

  it("refuses refresh for a deleted account", async () => {
    const s = await h.signIn();
    await h.setAccountStatus(s.account_id, "deleting");
    const res = await h.request("POST", "/v1/auth/refresh", { body: { refresh_token: s.refresh_token } });
    expect(res.body.error.code).toBe("account_deleted");
  });

  it("signs out by revoking the session family immediately", async () => {
    const s = await h.signIn();
    const other = await h.signIn();
    const out = await h.request("POST", "/v1/auth/sign-out", { token: s.access_token, body: { refresh_token: s.refresh_token } });
    expect(out.status).toBe(204);
    expect((await h.request("GET", "/v1/me", { token: s.access_token })).status).toBe(401);
    expect((await h.request("POST", "/v1/auth/refresh", { body: { refresh_token: s.refresh_token } })).status).toBe(401);
    // Other sessions are untouched, and repeating sign-out is fine.
    expect((await h.request("GET", "/v1/me", { token: other.access_token })).status).toBe(200);
  });

  it("cannot sign out someone else's session", async () => {
    const a = await h.signIn();
    const b = await h.signIn();
    const res = await h.request("POST", "/v1/auth/sign-out", { token: a.access_token, body: { refresh_token: b.refresh_token } });
    expect(res.status).toBe(204);
    expect((await h.request("POST", "/v1/auth/refresh", { body: { refresh_token: b.refresh_token } })).status).toBe(200);
  });

  it("distinguishes expired, malformed and missing access tokens", async () => {
    const s = await h.signIn();
    h.advance(16 * 60);
    expect((await h.request("GET", "/v1/me", { token: s.access_token })).body.error.code).toBe("token_expired");
    expect((await h.request("GET", "/v1/me", { token: "not.a.jwt" })).body.error.code).toBe("unauthorized");
    expect((await h.request("GET", "/v1/me")).body.error.code).toBe("unauthorized");
  });

  it("rejects access tokens for deleted accounts", async () => {
    const s = await h.signIn();
    await h.setAccountStatus(s.account_id, "deleting");
    const res = await h.request("GET", "/v1/me", { token: s.access_token });
    expect(res.status).toBe(401);
    expect(res.body.error.code).toBe("account_deleted");
  });

  it("never logs tokens", async () => {
    const s = await h.signIn();
    await h.request("GET", "/v1/me", { token: s.access_token });
    const logged = JSON.stringify(h.logs);
    expect(logged).not.toContain(s.access_token);
    expect(logged).not.toContain(s.refresh_token);
  });
});

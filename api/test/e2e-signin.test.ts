import { SignJWT } from "jose";
import { describe, expect, it } from "vitest";
import { LiveAppleClient, type AppleClient } from "../src/auth/apple";
import { StagingTestAppleClient } from "../src/auth/e2e";
import { appleClient, type Env } from "../src/index";

const KEY = "staging-e2e-key-0123456789abcdef";
const BUNDLE = "com.zainpi.boulderme.staging";

function token(claims: { sub?: string; iss?: string; aud?: string; key?: string; nonce?: string } = {}): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  return new SignJWT({ nonce: claims.nonce ?? "n" })
    .setProtectedHeader({ alg: "HS256" })
    .setIssuer(claims.iss ?? "boulderme-e2e")
    .setAudience(claims.aud ?? BUNDLE)
    .setSubject(claims.sub ?? "e2e-a-1")
    .setIssuedAt(now)
    .setExpirationTime(now + 300)
    .sign(new TextEncoder().encode(claims.key ?? KEY));
}

const live: AppleClient = {
  verifyIdentityToken: async () => ({ sub: "apple-user", nonce: null }),
  exchangeAuthorizationCode: async () => "apple-refresh",
  revokeRefreshToken: async () => true,
};

describe("staging test sign-in", () => {
  const client = new StagingTestAppleClient(live, BUNDLE, KEY);

  it("accepts the check's own tokens", async () => {
    expect(await client.verifyIdentityToken(await token({ nonce: "abc" }), new Date())).toEqual({ sub: "e2e-a-1", nonce: "abc" });
    expect(await client.exchangeAuthorizationCode("e2e-code")).toBeNull();
  });

  it("refuses a wrong key, issuer, audience or subject", async () => {
    for (const bad of [{ key: "another-key-0123456789abcdef0123" }, { iss: "https://appleid.apple.com" }, { aud: "com.zainpi.boulderme" }, { sub: "001234.realuser" }]) {
      await expect(client.verifyIdentityToken(await token(bad), new Date())).rejects.toThrow();
    }
  });

  it("passes anything else to Apple", async () => {
    const rs = "eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiJ4In0.sig";
    expect(await client.verifyIdentityToken(rs, new Date())).toEqual({ sub: "apple-user", nonce: null });
    expect(await client.exchangeAuthorizationCode("real-code")).toBe("apple-refresh");
  });

  it("is only installed on staging", () => {
    const env = { ENVIRONMENT: "staging", APP_VERSION: "t", APPLE_BUNDLE_ID: BUNDLE, E2E_IDENTITY_KEY: KEY } satisfies Env;
    expect(appleClient(env)).toBeInstanceOf(StagingTestAppleClient);
    expect(appleClient({ ...env, E2E_IDENTITY_KEY: undefined })).toBeInstanceOf(LiveAppleClient);
    for (const environment of ["production", "development", "test"]) {
      expect(appleClient({ ...env, ENVIRONMENT: environment })).toBeInstanceOf(LiveAppleClient);
    }
  });
});

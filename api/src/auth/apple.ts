// Sign in with Apple: identity token verification and authorization code exchange.
// https://developer.apple.com/documentation/sign_in_with_apple/sign_in_with_apple_rest_api

import { SignJWT, createRemoteJWKSet, importPKCS8, jwtVerify, type JWTVerifyGetKey } from "jose";

export const APPLE_ISSUER = "https://appleid.apple.com";
const APPLE_JWKS_URL = new URL("https://appleid.apple.com/auth/keys");
const APPLE_TOKEN_URL = "https://appleid.apple.com/auth/token";

export interface AppleIdentity {
  sub: string;
  nonce: string | null;
}

export interface AppleClient {
  /** Verifies signature, issuer, audience and expiry. Throws on any failure. */
  verifyIdentityToken(token: string, now: Date): Promise<AppleIdentity>;
  /**
   * Exchanges the one-time authorization code for Apple's refresh token, which is kept only
   * to revoke the Apple sign-in when the account is deleted. Null when not configured.
   */
  exchangeAuthorizationCode(code: string): Promise<string | null>;
}

export class AppleUnavailableError extends Error {}
export class AppleRejectedError extends Error {}

export interface AppleConfig {
  bundleId: string;
  teamId: string | undefined;
  keyId: string | undefined;
  privateKey: string | undefined;
}

// Cached per isolate; jose refreshes it when Apple rotates keys.
let appleJwks: JWTVerifyGetKey | null = null;

export class LiveAppleClient implements AppleClient {
  constructor(
    private readonly config: AppleConfig,
    private readonly jwks: JWTVerifyGetKey = (appleJwks ??= createRemoteJWKSet(APPLE_JWKS_URL)),
    private readonly fetcher: typeof fetch = (...args) => fetch(...args),
  ) {}

  async verifyIdentityToken(token: string, now: Date): Promise<AppleIdentity> {
    const { payload } = await jwtVerify(token, this.jwks, {
      algorithms: ["RS256"],
      issuer: APPLE_ISSUER,
      audience: this.config.bundleId,
      currentDate: now,
      requiredClaims: ["sub", "exp", "iat"],
    });
    if (typeof payload.sub !== "string" || payload.sub.length === 0) throw new Error("missing sub");
    return { sub: payload.sub, nonce: typeof payload.nonce === "string" ? payload.nonce : null };
  }

  async exchangeAuthorizationCode(code: string): Promise<string | null> {
    const { teamId, keyId, privateKey, bundleId } = this.config;
    if (!teamId || !keyId || !privateKey) return null;
    const clientSecret = await appleClientSecret({ teamId, keyId, privateKey, bundleId });
    let response: Response;
    try {
      response = await this.fetcher(APPLE_TOKEN_URL, {
        method: "POST",
        headers: { "content-type": "application/x-www-form-urlencoded" },
        body: new URLSearchParams({ client_id: bundleId, client_secret: clientSecret, code, grant_type: "authorization_code" }),
      });
    } catch {
      throw new AppleUnavailableError("Apple token endpoint unreachable");
    }
    if (response.status >= 500) throw new AppleUnavailableError(`Apple token endpoint returned ${response.status}`);
    if (!response.ok) throw new AppleRejectedError(`Apple rejected the authorization code (${response.status})`);
    const body = (await response.json()) as { refresh_token?: unknown };
    return typeof body.refresh_token === "string" ? body.refresh_token : null;
  }
}

/** ES256 client secret JWT Apple requires on its token and revoke endpoints. */
export async function appleClientSecret(c: { teamId: string; keyId: string; privateKey: string; bundleId: string }): Promise<string> {
  const key = await importPKCS8(c.privateKey.replace(/\\n/g, "\n"), "ES256");
  const now = Math.floor(Date.now() / 1000);
  return new SignJWT({})
    .setProtectedHeader({ alg: "ES256", kid: c.keyId })
    .setIssuer(c.teamId)
    .setIssuedAt(now)
    .setExpirationTime(now + 300)
    .setAudience(APPLE_ISSUER)
    .setSubject(c.bundleId)
    .sign(key);
}

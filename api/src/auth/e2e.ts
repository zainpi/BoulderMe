// Staging-only test sign-in for the end-to-end check (api/e2e/). Real Sign in with Apple needs a
// device and an Apple ID, so the check signs its own identity tokens: HS256 with the Worker
// secret E2E_IDENTITY_KEY, issuer `boulderme-e2e`, audience APPLE_BUNDLE_ID and a subject that
// starts with `e2e-`. index.ts only installs this when ENVIRONMENT is "staging"; anything that is
// not such a token goes to Apple exactly as in production.

import { decodeProtectedHeader, jwtVerify } from "jose";
import type { AppleClient, AppleIdentity } from "./apple";

export const E2E_ISSUER = "boulderme-e2e";
export const E2E_SUBJECT_PREFIX = "e2e-";
/** Authorization codes the check sends; never exchanged with Apple. */
export const E2E_CODE_PREFIX = "e2e-";

export class StagingTestAppleClient implements AppleClient {
  private readonly key: Uint8Array;

  constructor(private readonly live: AppleClient, private readonly bundleId: string, secret: string) {
    this.key = new TextEncoder().encode(secret);
  }

  async verifyIdentityToken(token: string, now: Date): Promise<AppleIdentity> {
    if (decodeProtectedHeader(token).alg !== "HS256") return this.live.verifyIdentityToken(token, now);
    const { payload } = await jwtVerify(token, this.key, {
      algorithms: ["HS256"],
      issuer: E2E_ISSUER,
      audience: this.bundleId,
      currentDate: now,
      maxTokenAge: "10m",
      requiredClaims: ["sub", "exp", "iat"],
    });
    if (typeof payload.sub !== "string" || !payload.sub.startsWith(E2E_SUBJECT_PREFIX)) throw new Error("not an e2e subject");
    return { sub: payload.sub, nonce: typeof payload.nonce === "string" ? payload.nonce : null };
  }

  async exchangeAuthorizationCode(code: string): Promise<string | null> {
    return code.startsWith(E2E_CODE_PREFIX) ? null : this.live.exchangeAuthorizationCode(code);
  }

  revokeRefreshToken(refreshToken: string): Promise<boolean> {
    return this.live.revokeRefreshToken(refreshToken);
  }
}

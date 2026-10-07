// App-issued session tokens: 15 minute HS256 access JWTs and opaque single-use refresh tokens.

import { SignJWT, errors, jwtVerify } from "jose";
import { ApiError } from "../http";
import { base64Decode } from "./crypto";

export const ACCESS_TOKEN_TTL_SECONDS = 15 * 60;
export const REFRESH_TOKEN_TTL_SECONDS = 60 * 24 * 60 * 60;

const ISSUER = "boulderme-api";
const AUDIENCE = "boulderme-ios";

export interface AccessClaims {
  accountId: string;
  familyId: string;
}

function signingKey(base64Key: string): Uint8Array {
  const key = base64Decode(base64Key);
  if (key.length < 32) throw new Error("ACCESS_TOKEN_SIGNING_KEY must be at least 32 bytes");
  return key;
}

export async function issueAccessToken(base64Key: string, claims: AccessClaims, now: Date): Promise<{ token: string; expiresAt: Date }> {
  const iat = Math.floor(now.getTime() / 1000);
  const exp = iat + ACCESS_TOKEN_TTL_SECONDS;
  const token = await new SignJWT({ sid: claims.familyId })
    .setProtectedHeader({ alg: "HS256", typ: "JWT" })
    .setIssuer(ISSUER)
    .setAudience(AUDIENCE)
    .setSubject(claims.accountId)
    .setIssuedAt(iat)
    .setExpirationTime(exp)
    .sign(signingKey(base64Key));
  return { token, expiresAt: new Date(exp * 1000) };
}

export async function verifyAccessToken(base64Key: string, token: string, now: Date): Promise<AccessClaims> {
  try {
    const { payload } = await jwtVerify(token, signingKey(base64Key), {
      algorithms: ["HS256"],
      issuer: ISSUER,
      audience: AUDIENCE,
      currentDate: now,
    });
    if (typeof payload.sub !== "string" || typeof payload.sid !== "string") throw new Error("missing claims");
    return { accountId: payload.sub, familyId: payload.sid };
  } catch (err) {
    if (err instanceof errors.JWTExpired) throw new ApiError(401, "token_expired", "The access token has expired.");
    throw unauthorized();
  }
}

export const unauthorized = () => new ApiError(401, "unauthorized", "Sign in again.");

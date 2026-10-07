// /v1/auth/*: nonces, Sign in with Apple, refresh-token rotation, sign-out.

import { AppleRejectedError, AppleUnavailableError } from "../auth/apple";
import { encryptString, randomToken, sha256Hex } from "../auth/crypto";
import { REFRESH_TOKEN_TTL_SECONDS, issueAccessToken, unauthorized } from "../auth/tokens";
import type { Context, Deps } from "../app";
import type { Repository } from "../db/repository";
import { ApiError, json, noContent, readJson, timestamp } from "../http";
import { appleSignInSchema, parse, refreshSchema } from "../validation";

const NONCE_TTL_MS = 10 * 60 * 1000;

export async function createNonce(ctx: Context): Promise<Response> {
  const nonce = randomToken();
  const expiresAt = new Date(ctx.now.getTime() + NONCE_TTL_MS);
  await ctx.deps.repo.createNonce(await sha256Hex(nonce), expiresAt);
  return json(201, { nonce, expires_at: timestamp(expiresAt) });
}

export async function signInWithApple(ctx: Context): Promise<Response> {
  const body = parse(appleSignInSchema, await readJson(ctx.request));
  const { repo, apple, config } = ctx.deps;

  let identity;
  try {
    identity = await apple.verifyIdentityToken(body.identity_token, ctx.now);
  } catch {
    throw new ApiError(401, "apple_token_invalid", "The Apple identity token could not be verified.");
  }

  // The client sent SHA256(nonce) to Apple; Apple echoes it in the token. The raw nonce must
  // be one we issued, unexpired and unused.
  const nonceHash = await sha256Hex(body.nonce);
  if (identity.nonce !== nonceHash || !(await repo.consumeNonce(nonceHash, ctx.now))) {
    throw new ApiError(401, "nonce_invalid", "The sign-in nonce is invalid, expired or already used.");
  }

  const appleSubHash = await sha256Hex(identity.sub);
  const existing = await repo.findAccountByAppleSub(appleSubHash);
  if (existing ? existing.status !== "active" : await repo.hasPendingTombstone(appleSubHash)) {
    throw new ApiError(401, "account_deleted", "This account has been deleted.");
  }

  let appleRefreshToken: string | null;
  try {
    appleRefreshToken = await apple.exchangeAuthorizationCode(body.authorization_code);
  } catch (err) {
    if (err instanceof AppleRejectedError) {
      throw new ApiError(401, "apple_token_invalid", "Apple rejected the authorization code.");
    }
    if (err instanceof AppleUnavailableError) {
      throw new ApiError(503, "unavailable", "Sign in with Apple is temporarily unavailable.");
    }
    throw err;
  }
  const encrypted = appleRefreshToken && config.appleTokenEncryptionKey
    ? await encryptString(config.appleTokenEncryptionKey, appleRefreshToken)
    : null;

  const session = await repo.transaction(async (tx) => {
    const { account, created } = await tx.createAccount(appleSubHash);
    if (account.status !== "active") throw new ApiError(401, "account_deleted", "This account has been deleted.");
    if (encrypted) await tx.setAppleRefreshToken(account.id, encrypted);
    const tokens = await startSession(tx, ctx.deps, account.id, crypto.randomUUID(), body.client_installation_id ?? null, ctx.now);
    return { ...tokens, account_id: account.id, is_new_account: created };
  });
  return json(200, session);
}

export async function refreshSession(ctx: Context): Promise<Response> {
  const body = parse(refreshSchema, await readJson(ctx.request));
  const tokenHash = await sha256Hex(body.refresh_token);
  // Revocations must commit even though the request fails, so the transaction returns an
  // outcome and the error is thrown after it.
  const outcome = await ctx.deps.repo.transaction(async (tx) => {
    const s = await tx.findRefreshSessionForUpdate(tokenHash);
    if (!s || s.revokedAt) return { kind: "unauthorized" as const };
    if (s.usedAt) {
      await tx.revokeSessionFamily(s.familyId, ctx.now);
      return { kind: "reused" as const };
    }
    if (s.expiresAt <= ctx.now) return { kind: "unauthorized" as const };
    const account = await tx.getAccount(s.accountId);
    if (!account || account.status !== "active") {
      await tx.revokeSessionFamily(s.familyId, ctx.now);
      return { kind: "deleted" as const };
    }
    await tx.markRefreshSessionUsed(s.id, ctx.now);
    const tokens = await startSession(tx, ctx.deps, s.accountId, s.familyId, s.clientInstallationId, ctx.now);
    return { kind: "ok" as const, session: { ...tokens, account_id: s.accountId, is_new_account: false } };
  });
  switch (outcome.kind) {
    case "ok":
      return json(200, outcome.session);
    case "reused":
      throw new ApiError(401, "refresh_token_reused", "This refresh token was already used. Sign in again.");
    case "deleted":
      throw new ApiError(401, "account_deleted", "This account has been deleted.");
    default:
      throw unauthorized();
  }
}

export async function signOut(ctx: Context): Promise<Response> {
  const body = parse(refreshSchema, await readJson(ctx.request));
  const tokenHash = await sha256Hex(body.refresh_token);
  await ctx.deps.repo.transaction(async (tx) => {
    const s = await tx.findRefreshSessionForUpdate(tokenHash);
    // Only the caller's own sessions; someone else's token is ignored silently.
    if (s && s.accountId === ctx.accountId) await tx.revokeSessionFamily(s.familyId, ctx.now);
    await tx.revokeSessionFamily(ctx.familyId, ctx.now);
  });
  return noContent();
}

async function startSession(repo: Repository, deps: Deps, accountId: string, familyId: string, clientInstallationId: string | null, now: Date) {
  const refreshToken = randomToken();
  const refreshExpiresAt = new Date(now.getTime() + REFRESH_TOKEN_TTL_SECONDS * 1000);
  await repo.createRefreshSession({
    accountId, familyId, tokenHash: await sha256Hex(refreshToken), clientInstallationId, expiresAt: refreshExpiresAt,
  });
  const access = await issueAccessToken(deps.config.accessTokenSigningKey, { accountId, familyId }, now);
  return {
    access_token: access.token,
    access_token_expires_at: timestamp(access.expiresAt),
    refresh_token: refreshToken,
    refresh_token_expires_at: timestamp(refreshExpiresAt),
  };
}

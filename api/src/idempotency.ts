// Idempotency-Key handling for create routes.

import type { Context } from "./app";
import { sha256Hex } from "./auth/crypto";
import type { Repository } from "./db/repository";
import { ApiError, isUuid, json, validationFailed } from "./http";

/**
 * Runs a create inside one transaction with its `Idempotency-Key`. A replay of the same key
 * and body within 24 hours returns the stored response; a different body is
 * `idempotency_mismatch`. Failed requests are rolled back and leave no key behind.
 */
export async function idempotent(
  ctx: Context,
  body: unknown,
  fn: (repo: Repository) => Promise<{ status: number; body: unknown }>,
): Promise<Response> {
  const key = ctx.request.headers.get("idempotency-key");
  if (key === null) throw validationFailed({ "Idempotency-Key": "required" });
  if (!isUuid(key)) throw validationFailed({ "Idempotency-Key": "invalid_uuid" });
  const route = ctx.url.pathname;
  const requestHash = await sha256Hex(JSON.stringify(body));
  return ctx.deps.repo.transaction(async (repo) => {
    const claim = await repo.claimIdempotencyKey(ctx.accountId, key, route, requestHash, ctx.now);
    if (!claim.claimed) {
      if (claim.stored.route !== route || claim.stored.requestHash !== requestHash || claim.stored.status === 0) {
        throw new ApiError(409, "idempotency_mismatch", "This Idempotency-Key was already used for a different request.");
      }
      return json(claim.stored.status, claim.stored.body, { "idempotency-replayed": "true" });
    }
    const result = await fn(repo);
    await repo.completeIdempotencyKey(ctx.accountId, key, result.status, result.body);
    return json(result.status, result.body);
  });
}

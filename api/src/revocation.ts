// Durable Apple token revocation for deleted accounts. Each deletion leaves a `pending`
// tombstone; this runs once right after the deletion and then from the daily cron until Apple
// confirms, backing off between attempts and giving up (`failed`) after MAX_ATTEMPTS.

import { AppleRejectedError, AppleUnavailableError, type AppleClient } from "./auth/apple";
import { decryptString } from "./auth/crypto";
import type { PendingRevocation, Repository, RevocationOutcome } from "./db/repository";

export const MAX_ATTEMPTS = 8;
const BASE_BACKOFF_MS = 5 * 60 * 1000;
const MAX_BACKOFF_MS = 24 * 60 * 60 * 1000;

export interface RevocationDeps {
  repo: Repository;
  apple: AppleClient;
  /** Base64 key the Apple refresh tokens were encrypted with; null when not configured. */
  encryptionKey: string | null;
  log: (entry: Record<string, unknown>) => void;
}

export async function revokeAppleTokens(
  deps: RevocationDeps,
  now: Date,
  opts: { limit: number; accountId?: string },
): Promise<Record<RevocationOutcome["kind"], number>> {
  const counts = { done: 0, retry: 0, failed: 0 };
  const pending = await deps.repo.listPendingRevocations(now, opts.limit, opts.accountId);
  for (const p of pending) {
    const outcome = await attempt(deps, p, now);
    await deps.repo.recordRevocation(p.appleSubHash, p.accountId, outcome);
    counts[outcome.kind]++;
  }
  return counts;
}

async function attempt(deps: RevocationDeps, p: PendingRevocation, now: Date): Promise<RevocationOutcome> {
  if (p.tokenEnc === null) return { kind: "done" };
  let error: string;
  try {
    if (!deps.encryptionKey) throw new Error("APPLE_TOKEN_ENCRYPTION_KEY not configured");
    const token = await decryptString(deps.encryptionKey, p.tokenEnc);
    if (await deps.apple.revokeRefreshToken(token)) return { kind: "done" };
    error = "apple_not_configured";
  } catch (err) {
    error = err instanceof AppleUnavailableError ? "apple_unavailable" : err instanceof AppleRejectedError ? "apple_rejected" : "error";
  }
  const attempts = p.attempts + 1;
  // Never the token or the subject hash; the account id is enough to follow up.
  deps.log({ level: "warn", event: "apple_revocation_failed", account_id: p.accountId, attempts, error });
  if (attempts >= MAX_ATTEMPTS) return { kind: "failed" };
  return { kind: "retry", nextAttemptAt: new Date(now.getTime() + Math.min(BASE_BACKOFF_MS * 2 ** p.attempts, MAX_BACKOFF_MS)) };
}

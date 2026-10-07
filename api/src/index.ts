// Worker entry point. A database connection is opened per request (Workers cannot keep
// sockets between requests) and closed after the response is sent.

import { handle, type Config, type Deps } from "./app";
import { LiveAppleClient } from "./auth/apple";
import { connect, PostgresRepository } from "./db/postgres";
import { ApiError, errorResponse } from "./http";

export interface Env {
  ENVIRONMENT: string;
  APP_VERSION: string;
  DATABASE_URL?: string;
  ACCESS_TOKEN_SIGNING_KEY?: string;
  APPLE_TOKEN_ENCRYPTION_KEY?: string;
  RATE_LIMIT_SALT?: string;
  APPLE_BUNDLE_ID?: string;
  APPLE_TEAM_ID?: string;
  APPLE_KEY_ID?: string;
  APPLE_PRIVATE_KEY?: string;
}

const log = (entry: Record<string, unknown>) => console.log(JSON.stringify(entry));

function missingSecrets(env: Env): string[] {
  const required = ["DATABASE_URL", "ACCESS_TOKEN_SIGNING_KEY", "RATE_LIMIT_SALT", "APPLE_BUNDLE_ID"] as const;
  const missing: string[] = required.filter((k) => !env[k]);
  // Storing Apple's refresh token (for revocation on deletion) needs the encryption key.
  if (env.APPLE_PRIVATE_KEY && !env.APPLE_TOKEN_ENCRYPTION_KEY) missing.push("APPLE_TOKEN_ENCRYPTION_KEY");
  return missing;
}

function config(env: Env): Config {
  return {
    environment: env.ENVIRONMENT,
    version: env.APP_VERSION,
    accessTokenSigningKey: env.ACCESS_TOKEN_SIGNING_KEY!,
    appleTokenEncryptionKey: env.APPLE_TOKEN_ENCRYPTION_KEY ?? null,
    rateLimitSalt: env.RATE_LIMIT_SALT!,
  };
}

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const missing = missingSecrets(env);
    if (missing.length > 0) {
      // Names only, never values.
      log({ level: "error", event: "missing_secrets", names: missing });
      return errorResponse(new ApiError(503, "unavailable", "Service is not configured."), "unconfigured");
    }
    const sql = connect(env.DATABASE_URL!);
    const deps: Deps = {
      repo: new PostgresRepository(sql),
      config: config(env),
      apple: new LiveAppleClient({
        bundleId: env.APPLE_BUNDLE_ID!,
        teamId: env.APPLE_TEAM_ID,
        keyId: env.APPLE_KEY_ID,
        privateKey: env.APPLE_PRIVATE_KEY,
      }),
      now: () => new Date(),
      log,
    };
    try {
      return await handle(request, deps);
    } finally {
      ctx.waitUntil(sql.end({ timeout: 2 }));
    }
  },

  async scheduled(_controller: ScheduledController, env: Env, ctx: ExecutionContext): Promise<void> {
    if (!env.DATABASE_URL) return;
    const sql = connect(env.DATABASE_URL);
    try {
      const purged = await new PostgresRepository(sql).purgeExpired(new Date());
      log({ level: "info", event: "housekeeping", purged });
    } finally {
      ctx.waitUntil(sql.end({ timeout: 2 }));
    }
  },
} satisfies ExportedHandler<Env>;

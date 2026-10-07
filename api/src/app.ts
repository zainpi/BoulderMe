// Request pipeline: routing, request ids, authentication, rate limits, idempotency, logging.

import type { AppleClient } from "./auth/apple";
import { hmacSha256Hex } from "./auth/crypto";
import { unauthorized, verifyAccessToken } from "./auth/tokens";
import type { Repository } from "./db/repository";
import { ApiError, errorResponse, isUuid, notFound, validationFailed } from "./http";
import { routes } from "./routes";

export interface Config {
  environment: string;
  version: string;
  /** Base64, at least 32 bytes. */
  accessTokenSigningKey: string;
  /** Base64, 32 bytes. Null when Apple code exchange is not configured. */
  appleTokenEncryptionKey: string | null;
  rateLimitSalt: string;
}

export interface Deps {
  repo: Repository;
  config: Config;
  apple: AppleClient;
  now: () => Date;
  log: (entry: Record<string, unknown>) => void;
}

export interface RateRule {
  name: string;
  limit: number;
  windowSeconds: number;
}

export interface Context {
  request: Request;
  url: URL;
  params: Record<string, string>;
  requestId: string;
  now: Date;
  deps: Deps;
  /** Set on authenticated routes. */
  accountId: string;
  familyId: string;
  /** Salted hash of `X-Client-Installation-Id`, or null when the header is absent. */
  clientKey: string | null;
}

export interface Route {
  method: "GET" | "POST" | "PUT" | "DELETE";
  path: string;
  auth: boolean;
  rate: RateRule;
  handler: (ctx: Context) => Promise<Response>;
  /** Skip the limit when the database is unreachable (health must still answer). */
  bestEffortRateLimit?: boolean;
}

/** Unauthenticated callers without an installation id share one bucket per route, this much larger. */
const ANONYMOUS_MULTIPLIER = 30;

interface CompiledRoute extends Route {
  regex: RegExp;
  paramNames: string[];
}

const compiled: CompiledRoute[] = routes.map((r) => {
  const paramNames: string[] = [];
  const pattern = r.path.replace(/\{(\w+)\}/g, (_, name: string) => {
    paramNames.push(name);
    return "([^/]+)";
  });
  return { ...r, regex: new RegExp(`^${pattern}$`), paramNames };
});

export async function handle(request: Request, deps: Deps): Promise<Response> {
  const started = Date.now();
  const requestId = randomRequestId();
  const url = new URL(request.url);
  let routeName = "unmatched";
  let response: Response;
  try {
    const match = matchRoute(request.method, url.pathname);
    if (!match) throw notFound();
    routeName = `${match.route.method} ${match.route.path}`;
    response = await run(match.route, match.params, request, url, requestId, deps);
  } catch (err) {
    response = toErrorResponse(err, requestId, deps, routeName);
  }
  const headers = new Headers(response.headers);
  headers.set("x-request-id", requestId);
  headers.set("cache-control", "no-store");
  // Sanitized access log: no bodies, tokens, names or query values.
  deps.log({ level: "info", request_id: requestId, method: request.method, route: routeName, status: response.status, ms: Date.now() - started });
  return new Response(response.body, { status: response.status, headers });
}

function matchRoute(method: string, pathname: string): { route: CompiledRoute; params: Record<string, string> } | null {
  for (const route of compiled) {
    if (route.method !== method) continue;
    const m = route.regex.exec(pathname);
    if (!m) continue;
    const params: Record<string, string> = {};
    route.paramNames.forEach((name, i) => (params[name] = decodeURIComponent(m[i + 1]!)));
    // Every path parameter is a UUID; anything else cannot exist.
    if (Object.values(params).some((v) => !isUuid(v))) return null;
    return { route, params };
  }
  return null;
}

async function run(route: CompiledRoute, params: Record<string, string>, request: Request, url: URL, requestId: string, deps: Deps): Promise<Response> {
  const now = deps.now();
  const ctx: Context = { request, url, params, requestId, now, deps, accountId: "", familyId: "", clientKey: await clientKey(request, deps) };
  if (route.auth) {
    const header = request.headers.get("authorization") ?? "";
    const m = /^Bearer ([A-Za-z0-9._~+/-]+=*)$/.exec(header);
    if (!m) throw unauthorized();
    const claims = await verifyAccessToken(deps.config.accessTokenSigningKey, m[1]!, now);
    const state = await deps.repo.authenticate(claims.accountId, claims.familyId);
    if (!state) throw unauthorized();
    if (state.status !== "active") throw new ApiError(401, "account_deleted", "This account has been deleted.");
    if (!state.sessionActive) throw unauthorized();
    ctx.accountId = claims.accountId;
    ctx.familyId = claims.familyId;
    await enforceRateLimit(deps, `account:${ctx.accountId}:${route.rate.name}`, route.rate.limit, route.rate, now);
  } else {
    const [bucket, limit] = ctx.clientKey
      ? [`client:${ctx.clientKey}:${route.rate.name}`, route.rate.limit]
      : [`client:anonymous:${route.rate.name}`, route.rate.limit * ANONYMOUS_MULTIPLIER];
    try {
      await enforceRateLimit(deps, bucket, limit, route.rate, now);
    } catch (err) {
      if (!route.bestEffortRateLimit || err instanceof ApiError) throw err;
    }
  }
  return route.handler(ctx);
}

async function clientKey(request: Request, deps: Deps): Promise<string | null> {
  const id = request.headers.get("x-client-installation-id");
  if (id === null) return null;
  if (!isUuid(id)) throw validationFailed({ "X-Client-Installation-Id": "invalid_uuid" });
  return (await hmacSha256Hex(deps.config.rateLimitSalt, id)).slice(0, 32);
}

/** Fixed-window counter in `boulderme.rate_limits`. */
export async function enforceRateLimit(deps: Deps, bucket: string, limit: number, rule: RateRule, now: Date): Promise<void> {
  const windowMs = rule.windowSeconds * 1000;
  const windowStart = new Date(Math.floor(now.getTime() / windowMs) * windowMs);
  const count = await deps.repo.hitRateLimit(bucket, windowStart);
  if (count > limit) {
    const retryAfter = Math.max(1, Math.ceil((windowStart.getTime() + windowMs - now.getTime()) / 1000));
    throw new ApiError(429, "rate_limited", "Too many requests. Try again later.", { retry_after_seconds: retryAfter }, {
      "retry-after": String(retryAfter),
    });
  }
}

function toErrorResponse(err: unknown, requestId: string, deps: Deps, route: string): Response {
  if (err instanceof ApiError) return errorResponse(err, requestId);
  const name = err instanceof Error ? err.name : "unknown";
  // Postgres connection failures surface as `unavailable` so the app retries with backoff.
  const code = (err as { code?: unknown } | null)?.code;
  const unavailable = typeof code === "string" && /^(ECONNREFUSED|ECONNRESET|ETIMEDOUT|CONNECT_TIMEOUT|CONNECTION_\w+|57P0\d|53300)$/.test(code);
  // Messages can echo input values, so they are only logged outside production.
  const message = deps.config.environment === "production" ? undefined : err instanceof Error ? err.message : String(err);
  deps.log({ level: "error", request_id: requestId, route, error: name, code: typeof code === "string" ? code : null, message });
  return unavailable
    ? errorResponse(new ApiError(503, "unavailable", "Service temporarily unavailable. Retry shortly."), requestId)
    : errorResponse(new ApiError(500, "internal_error", "Something went wrong."), requestId);
}

function randomRequestId(): string {
  return [...crypto.getRandomValues(new Uint8Array(8))].map((b) => b.toString(16).padStart(2, "0")).join("");
}

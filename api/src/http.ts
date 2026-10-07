// HTTP plumbing shared by every route: the Error envelope, JSON responses, body parsing.

export type ErrorCode =
  | "validation_failed"
  | "body_too_large"
  | "invalid_cursor"
  | "unauthorized"
  | "token_expired"
  | "refresh_token_reused"
  | "apple_token_invalid"
  | "nonce_invalid"
  | "account_deleted"
  | "forbidden"
  | "not_found"
  | "revision_conflict"
  | "invalid_state"
  | "idempotency_mismatch"
  | "invitation_already_open"
  | "profile_incomplete"
  | "gym_not_shared"
  | "gym_limit_reached"
  | "availability_limit_reached"
  | "invalid_time"
  | "chat_closed"
  | "rate_limited"
  | "unavailable"
  | "internal_error";

export const MAX_BODY_BYTES = 16 * 1024;

export class ApiError extends Error {
  constructor(
    readonly status: number,
    readonly code: ErrorCode,
    message: string,
    readonly details: Record<string, unknown> | null = null,
    readonly headers: Record<string, string> = {},
  ) {
    super(message);
  }
}

export const notFound = () => new ApiError(404, "not_found", "Not found.");

export const validationFailed = (fields: Record<string, string>) =>
  new ApiError(400, "validation_failed", "The request is not valid.", { fields });

export function json(status: number, body: unknown, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", ...headers },
  });
}

export function noContent(): Response {
  return new Response(null, { status: 204 });
}

export function errorResponse(err: ApiError, requestId: string): Response {
  return json(
    err.status,
    { error: { code: err.code, message: err.message, request_id: requestId, details: err.details } },
    err.headers,
  );
}

/** Reads and parses a JSON body, enforcing the content type and the 16 KiB cap. */
export async function readJson(request: Request): Promise<unknown> {
  const type = request.headers.get("content-type") ?? "";
  if (!/^application\/json\s*(;|$)/i.test(type)) {
    throw validationFailed({ body: "content_type_must_be_application_json" });
  }
  const declared = Number(request.headers.get("content-length") ?? "0");
  if (declared > MAX_BODY_BYTES) throw bodyTooLarge();
  const buffer = await readLimited(request);
  if (buffer.byteLength === 0) throw validationFailed({ body: "required" });
  let text: string;
  try {
    text = new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(buffer);
  } catch {
    throw validationFailed({ body: "invalid_utf8" });
  }
  try {
    return JSON.parse(text);
  } catch {
    throw validationFailed({ body: "invalid_json" });
  }
}

async function readLimited(request: Request): Promise<Uint8Array> {
  if (!request.body) return new Uint8Array();
  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > MAX_BODY_BYTES) {
      await reader.cancel();
      throw bodyTooLarge();
    }
    chunks.push(value);
  }
  const out = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    out.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return out;
}

const bodyTooLarge = () =>
  new ApiError(400, "body_too_large", `Request bodies are limited to ${MAX_BODY_BYTES} bytes.`);

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

export function isUuid(value: string): boolean {
  return UUID_RE.test(value);
}

/** RFC 3339 UTC with second precision, e.g. `2026-10-06T18:30:00Z`. */
export function timestamp(date: Date): string {
  return date.toISOString().replace(/\.\d{3}Z$/, "Z");
}

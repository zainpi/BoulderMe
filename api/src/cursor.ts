// Opaque page cursors: base64url JSON carrying the keyset position, a hash of the filters it
// was issued for, and its issue time. Cursors expire after 24 hours and only work with the
// same filters (`invalid_cursor` otherwise).

import type { z } from "zod";
import { ApiError } from "./http";
import { base64Decode, base64UrlEncode, sha256Hex } from "./auth/crypto";

const CURSOR_TTL_MS = 24 * 60 * 60 * 1000;

export async function filterHash(filters: Record<string, unknown>): Promise<string> {
  const canonical = JSON.stringify(Object.keys(filters).sort().map((k) => [k, filters[k] ?? null]));
  return (await sha256Hex(canonical)).slice(0, 16);
}

export function encodeCursor(key: unknown, filters: string, now: Date): string {
  const payload = JSON.stringify({ v: 1, f: filters, t: Math.floor(now.getTime() / 1000), k: key });
  return base64UrlEncode(new TextEncoder().encode(payload));
}

export function decodeCursor<S extends z.ZodType>(cursor: string, schema: S, filters: string, now: Date): z.output<S> {
  let payload: { v?: unknown; f?: unknown; t?: unknown; k?: unknown };
  try {
    payload = JSON.parse(new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(base64Decode(cursor)));
  } catch {
    throw invalidCursor();
  }
  if (payload === null || typeof payload !== "object" || payload.v !== 1 || payload.f !== filters || typeof payload.t !== "number") {
    throw invalidCursor();
  }
  const age = now.getTime() - payload.t * 1000;
  if (age < -60_000 || age > CURSOR_TTL_MS) throw invalidCursor();
  const key = schema.safeParse(payload.k);
  if (!key.success) throw invalidCursor();
  return key.data;
}

const invalidCursor = () => new ApiError(400, "invalid_cursor", "The cursor is invalid or expired; start from the first page.");

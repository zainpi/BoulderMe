// Request schemas, one per OpenAPI input schema. Objects are strict (`additionalProperties: false`).

import { z } from "zod";
import { validationFailed } from "./http";

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const REGION_RE = /^[A-Z]{2}-[A-Z0-9]{1,3}$/;
// Control characters other than tab/newline, plus bidi overrides that can disguise text.
const UNSAFE_CHARS = /[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F‪-‮⁦-⁩]/;

export const uuid = z.string().regex(UUID_RE, "invalid_uuid");
export const grade = z.number().int().min(0).max(17);
export const weekday = z.number().int().min(1).max(7);
export const accessType = z.enum(["membership", "guest_pass"]);
export const timeOfDay = z.enum(["morning", "afternoon", "evening"]);
export const climbingStyle = z.enum([
  "slab", "vertical", "overhang", "roof", "crimps", "slopers", "pinches",
  "dynamic", "technical", "power", "comp_style", "highball",
]);

const intParam = (schema: z.ZodNumber) => z.string().regex(/^\d{1,3}$/, "invalid_integer").transform(Number).pipe(schema);

const codePoints = (s: string) => [...s].length;

/** Trimmed, NFC-normalized text between `min` and `max` code points (what Postgres counts). */
function text(min: number, max: number, opts: { multiline?: boolean } = {}) {
  return z
    .string()
    .transform((s) => s.normalize("NFC").trim())
    .refine((s) => codePoints(s) >= min, { message: min === 1 ? "required" : "too_short" })
    .refine((s) => codePoints(s) <= max, { message: "too_long" })
    .refine((s) => !UNSAFE_CHARS.test(s), { message: "invalid_characters" })
    .refine((s) => opts.multiline || !/[\n\r\t]/.test(s), { message: "invalid_characters" });
}

/** Nullable text where an empty string after trimming means `null`. Optional unless `required`. */
function nullableText(max: number, opts: { multiline?: boolean; required?: boolean } = {}) {
  const base = opts.required ? z.union([z.string(), z.null()]) : z.union([z.string(), z.null()]).optional();
  return base
    .transform((s) => (s == null ? null : s.normalize("NFC").trim()))
    .refine((s) => s === null || codePoints(s) <= max, { message: "too_long" })
    .refine((s) => s === null || !UNSAFE_CHARS.test(s), { message: "invalid_characters" })
    .refine((s) => s === null || opts.multiline || !/[\n\r\t]/.test(s), { message: "invalid_characters" })
    .transform((s) => (s === "" ? null : s));
}

function isTimeZone(tz: string): boolean {
  try {
    new Intl.DateTimeFormat("en-US", { timeZone: tz });
    return tz.includes("/") || tz === "UTC";
  } catch {
    return false;
  }
}

// ------------------------------------------------------------------ auth

export const appleSignInSchema = z.strictObject({
  identity_token: z.string().min(1).max(4096),
  authorization_code: z.string().min(1).max(1024),
  nonce: z.string().min(1).max(128),
  given_name: z.union([z.string().max(80), z.null()]).optional(),
  client_installation_id: uuid.optional(),
});

export const refreshSchema = z.strictObject({
  refresh_token: z.string().min(32).max(256),
});

// ------------------------------------------------------------------ profile

export const profileInputSchema = z
  .strictObject({
    revision: z.number().int().min(0),
    display_name: text(1, 40),
    grade_min: grade,
    grade_max: grade,
    styles: z.array(climbingStyle).max(6).refine((a) => new Set(a).size === a.length, { message: "duplicate_items" }),
    intro: nullableText(280, { multiline: true, required: true }),
    adult_confirmed: z.literal(true, { message: "must_be_true" }),
    discovery_explained: z.boolean(),
  })
  .refine((v) => v.grade_min <= v.grade_max, { path: ["grade_min"], message: "must_not_exceed_grade_max" });

export const discoverySettingSchema = z.strictObject({ discoverable: z.boolean() });

// ------------------------------------------------------------------ gyms

export const gymListQuerySchema = z.strictObject({
  q: z.string().transform((s) => s.trim()).pipe(z.string().min(2).max(60)).optional(),
  region: z.string().regex(REGION_RE, "invalid_region").optional(),
  cursor: z.string().max(512).optional(),
  limit: intParam(z.number().int().min(1).max(50)).optional(),
});

export const gymAccessInputSchema = z.strictObject({ access_type: accessType });

export const gymRequestInputSchema = z.strictObject({
  name: text(2, 80),
  city: text(2, 60),
  region: z.string().regex(REGION_RE, "invalid_region"),
  website_url: z
    .union([z.string().max(200), z.null()])
    .optional()
    .transform((s) => (s == null || s.trim() === "" ? null : s.trim()))
    .refine((s) => s === null || isHttpUrl(s), { message: "invalid_url" }),
  note: nullableText(280, { multiline: true }),
});

function isHttpUrl(s: string): boolean {
  try {
    const u = new URL(s);
    return u.protocol === "https:" || u.protocol === "http:";
  } catch {
    return false;
  }
}

// ------------------------------------------------------------------ availability

export const slotInputSchema = z
  .strictObject({
    weekday,
    start_minute: z.number().int().min(0).max(1410).multipleOf(30),
    end_minute: z.number().int().min(30).max(1440).multipleOf(30),
    time_zone: z.string().min(1).max(64).refine(isTimeZone, { message: "invalid_time_zone" }),
    gym_id: z.union([uuid, z.null()]).optional().transform((v) => v ?? null),
  })
  .refine((v) => v.end_minute - v.start_minute >= 30, { path: ["end_minute"], message: "must_be_30_minutes_after_start" });

// ------------------------------------------------------------------ discovery

export const discoveryQuerySchema = z
  .strictObject({
    gym_id: uuid,
    grade_min: intParam(grade).optional(),
    grade_max: intParam(grade).optional(),
    access_type: accessType.optional(),
    weekday: intParam(weekday).optional(),
    time_of_day: timeOfDay.optional(),
    cursor: z.string().max(512).optional(),
    limit: intParam(z.number().int().min(1).max(50)).optional(),
  })
  .refine((v) => v.grade_min === undefined || v.grade_max === undefined || v.grade_min <= v.grade_max, {
    path: ["grade_min"],
    message: "must_not_exceed_grade_max",
  });

// ------------------------------------------------------------------ invitations, chats, safety, account

const RFC3339_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,6})?(Z|[+-]\d{2}:\d{2})$/;

export const timestampInput = z
  .string()
  .regex(RFC3339_RE, "invalid_timestamp")
  .transform((s) => new Date(s))
  .refine((d) => !Number.isNaN(d.getTime()), { message: "invalid_timestamp" });

const page = {
  cursor: z.string().max(512).optional(),
  limit: intParam(z.number().int().min(1).max(50)).optional(),
};

export const pageQuerySchema = z.strictObject(page);

export const invitationInputSchema = z.strictObject({
  recipient_account_id: uuid,
  gym_id: uuid,
  proposed_start_at: timestampInput,
  duration_minutes: z.number().int().min(30).max(300).optional().transform((v) => v ?? 120),
  note: nullableText(200, { multiline: true }),
});

export const invitationStatus = z.enum(["pending", "accepted", "declined", "cancelled", "expired"]);

export const invitationListQuerySchema = z.strictObject({
  box: z.enum(["incoming", "outgoing"]),
  status: invitationStatus.optional(),
  ...page,
});

export const messageListQuerySchema = z
  .strictObject({ after: uuid.optional(), ...page })
  .refine((v) => v.after === undefined || v.cursor === undefined, { path: ["after"], message: "not_with_cursor" });

export const messageInputSchema = z.strictObject({ body: text(1, 1000, { multiline: true }) });

const optionalId = z.union([uuid, z.null()]).optional().transform((v) => v ?? null);

export const reportInputSchema = z
  .strictObject({
    reported_account_id: uuid,
    context: z.enum(["profile", "invitation", "message"]),
    invitation_id: optionalId,
    message_id: optionalId,
    reason: z.enum(["harassment", "inappropriate_content", "spam", "fake_profile", "safety_concern", "underage", "other"]),
    details: nullableText(1000, { multiline: true }),
  })
  .superRefine((v, ctx) => {
    if (v.context === "invitation" && v.invitation_id === null) ctx.addIssue({ code: "custom", path: ["invitation_id"], message: "required_for_context" });
    if (v.context !== "invitation" && v.invitation_id !== null) ctx.addIssue({ code: "custom", path: ["invitation_id"], message: "not_allowed_for_context" });
    if (v.context === "message" && v.message_id === null) ctx.addIssue({ code: "custom", path: ["message_id"], message: "required_for_context" });
    if (v.context !== "message" && v.message_id !== null) ctx.addIssue({ code: "custom", path: ["message_id"], message: "not_allowed_for_context" });
  });

export const deleteAccountSchema = z.strictObject({ confirm: z.literal("DELETE", { message: "must_be_delete" }) });

// ------------------------------------------------------------------ helpers

/** Parses `value` or throws `validation_failed` with a `fields` map of stable reason codes. */
export function parse<S extends z.ZodType>(schema: S, value: unknown): z.output<S> {
  const result = schema.safeParse(value);
  if (result.success) return result.data;
  const fields: Record<string, string> = {};
  for (const issue of result.error.issues) {
    if (issue.code === "unrecognized_keys") {
      for (const key of issue.keys) fields[key] = "unknown_field";
      continue;
    }
    const path = issue.path.length ? issue.path.join(".") : "body";
    fields[path] ??= issue.path.length && valueAt(value, issue.path) === undefined ? "required" : reason(issue);
  }
  throw validationFailed(fields);
}

function valueAt(value: unknown, path: PropertyKey[]): unknown {
  let node = value;
  for (const key of path) {
    if (node === null || typeof node !== "object") return undefined;
    node = (node as Record<PropertyKey, unknown>)[key];
  }
  return node;
}

function reason(issue: z.core.$ZodIssue): string {
  if (/^[a-z_0-9]+$/.test(issue.message)) return issue.message;
  switch (issue.code) {
    case "invalid_type":
    case "invalid_union":
      return "invalid_type";
    case "too_small":
      return "too_small";
    case "too_big":
      return "too_big";
    case "invalid_value":
      return "invalid_value";
    case "not_multiple_of":
      return "not_multiple_of_30";
    default:
      return "invalid";
  }
}

/** Query string as a plain object; a repeated parameter is a validation error. */
export function queryObject(url: URL): Record<string, string> {
  const out: Record<string, string> = {};
  for (const [k, v] of url.searchParams) {
    if (k in out) throw validationFailed({ [k]: "repeated" });
    out[k] = v;
  }
  return out;
}

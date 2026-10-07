// Read-only browsing: health, the curated gym list, discovery and other members' profiles.

import { z } from "zod";
import type { Context } from "../app";
import { decodeCursor, encodeCursor, filterHash } from "../cursor";
import { availabilitySummary, isActiveRecently } from "../domain";
import { ApiError, json, notFound } from "../http";
import { discoveryQuerySchema, gymListQuerySchema, parse, queryObject, uuid } from "../validation";
import * as wire from "../wire";

const DEFAULT_LIMIT = 20;

export async function health(ctx: Context): Promise<Response> {
  let database: "ok" | "unreachable" = "ok";
  try {
    await ctx.deps.repo.ping();
  } catch {
    database = "unreachable";
  }
  return json(200, { status: database === "ok" ? "ok" : "degraded", version: ctx.deps.config.version, database });
}

// ------------------------------------------------------------------ gyms

const gymKeySchema = z.strictObject({ city: z.string().max(60), name: z.string().max(80), id: uuid });

export async function listGyms(ctx: Context): Promise<Response> {
  const query = parse(gymListQuerySchema, queryObject(ctx.url));
  const limit = query.limit ?? DEFAULT_LIMIT;
  const filters = await filterHash({ q: query.q?.toLowerCase(), region: query.region });
  const after = query.cursor ? decodeCursor(query.cursor, gymKeySchema, filters, ctx.now) : null;
  const rows = await ctx.deps.repo.listGyms({ q: query.q ?? null, region: query.region ?? null, after, limit: limit + 1 });
  const page = rows.slice(0, limit);
  const last = page[page.length - 1];
  return json(200, {
    items: page.map(wire.gym),
    next_cursor: rows.length > limit && last ? encodeCursor({ city: last.city, name: last.name, id: last.id }, filters, ctx.now) : null,
  });
}

export async function getGym(ctx: Context): Promise<Response> {
  const gym = await ctx.deps.repo.getGym(ctx.params.gym_id!);
  if (!gym || !gym.isActive) throw notFound();
  return json(200, wire.gym(gym));
}

// ------------------------------------------------------------------ discovery

const discoveryKeySchema = z.strictObject({
  overlap: z.number().int().min(-17).max(18),
  lastActiveOn: z.string().regex(/^\d{4}-\d{2}-\d{2}$/),
  accountId: uuid,
});

export async function discover(ctx: Context): Promise<Response> {
  const query = parse(discoveryQuerySchema, queryObject(ctx.url));
  const { repo } = ctx.deps;
  const [caller, gym] = await Promise.all([repo.getProfile(ctx.accountId), repo.getGym(query.gym_id)]);
  // Browsing others needs your own profile (and its 18+ confirmation) first.
  if (!caller || !caller.adultConfirmed) {
    throw new ApiError(422, "profile_incomplete", "Create your profile before browsing climbers.", { missing: ["profile"] });
  }
  if (!gym || !gym.isActive) throw notFound();

  const limit = query.limit ?? DEFAULT_LIMIT;
  const gradeMin = query.grade_min ?? 0;
  const gradeMax = query.grade_max ?? 17;
  const filters = await filterHash({
    gym_id: query.gym_id, grade_min: gradeMin, grade_max: gradeMax, access_type: query.access_type,
    weekday: query.weekday, time_of_day: query.time_of_day,
  });
  const after = query.cursor ? decodeCursor(query.cursor, discoveryKeySchema, filters, ctx.now) : null;
  const rows = await repo.discover({
    callerId: ctx.accountId, gymId: query.gym_id, gradeMin, gradeMax,
    rankMin: query.grade_min ?? (query.grade_max === undefined ? caller.gradeMin : 0),
    rankMax: query.grade_max ?? (query.grade_min === undefined ? caller.gradeMax : 17),
    accessType: query.access_type ?? null,
    weekday: query.weekday ?? null, timeOfDay: query.time_of_day ?? null, after, limit: limit + 1,
  });
  const page = rows.slice(0, limit);
  const last = page[page.length - 1];
  return json(200, {
    items: page.map((r) => ({
      account_id: r.profile.accountId,
      display_name: r.profile.displayName,
      grade_min: r.profile.gradeMin,
      grade_max: r.profile.gradeMax,
      styles: r.profile.styles,
      access_type: r.accessType,
      availability_summary: availabilitySummary(r.slots),
      active_recently: isActiveRecently(r.lastActiveOn, ctx.now),
    })),
    next_cursor: rows.length > limit && last
      ? encodeCursor({ overlap: last.overlap, lastActiveOn: last.lastActiveOn, accountId: last.profile.accountId }, filters, ctx.now)
      : null,
  });
}

export async function getProfile(ctx: Context): Promise<Response> {
  const row = await ctx.deps.repo.getVisibleProfile(ctx.accountId, ctx.params.account_id!);
  if (!row) throw notFound();
  const p = row.profile;
  return json(200, {
    account_id: p.accountId,
    display_name: p.displayName,
    grade_min: p.gradeMin,
    grade_max: p.gradeMax,
    styles: p.styles,
    intro: p.intro,
    gyms: row.gyms.map(wire.gymAccess),
    availability: row.slots.map(wire.slot),
    active_recently: isActiveRecently(row.lastActiveOn, ctx.now),
  });
}

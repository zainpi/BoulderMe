// The signed-in member's own data: /v1/me, profile, discovery switch, gyms, availability.

import type { Context } from "../app";
import { idempotent } from "../idempotency";
import type { ProfileFields, Repository, SlotFields } from "../db/repository";
import { LIMITS } from "../domain";
import { ApiError, json, noContent, notFound, readJson, timestamp, validationFailed } from "../http";
import {
  discoverySettingSchema, gymAccessInputSchema, gymRequestInputSchema, parse, profileInputSchema, slotInputSchema,
} from "../validation";
import * as wire from "../wire";

// ------------------------------------------------------------------ /v1/me

export async function getMe(ctx: Context): Promise<Response> {
  const { repo } = ctx.deps;
  const [account, profile, gyms, slots, unread, pending] = await Promise.all([
    repo.getAccount(ctx.accountId),
    repo.getProfile(ctx.accountId),
    repo.listGymAccess(ctx.accountId),
    repo.listSlots(ctx.accountId),
    repo.countUnreadChats(ctx.accountId),
    repo.countPendingIncomingInvitations(ctx.accountId, ctx.now),
  ]);
  if (!account) throw notFound();
  return json(200, {
    account_id: account.id,
    created_at: timestamp(account.createdAt),
    profile: profile ? wire.ownProfile(profile) : null,
    gyms: gyms.map(wire.gymAccess),
    onboarding: {
      has_profile: profile !== null,
      has_gym: gyms.length > 0,
      has_availability: slots.length > 0,
      adult_confirmed: profile?.adultConfirmed ?? false,
      discovery_explained: profile?.discoveryExplained ?? false,
    },
    unread_chat_count: unread,
    pending_incoming_invitation_count: pending,
  });
}

// ------------------------------------------------------------------ profile

export async function getMyProfile(ctx: Context): Promise<Response> {
  const profile = await ctx.deps.repo.getProfile(ctx.accountId);
  if (!profile) throw notFound();
  return json(200, wire.ownProfile(profile));
}

export async function putMyProfile(ctx: Context): Promise<Response> {
  const input = parse(profileInputSchema, await readJson(ctx.request));
  const fields: ProfileFields = {
    displayName: input.display_name,
    gradeMin: input.grade_min,
    gradeMax: input.grade_max,
    styles: input.styles,
    intro: input.intro,
    adultConfirmed: input.adult_confirmed,
    discoveryExplained: input.discovery_explained,
  };
  const saved = await ctx.deps.repo.transaction(async (repo) => {
    await repo.lockAccount(ctx.accountId);
    const current = await repo.getProfile(ctx.accountId);
    if (!current) {
      if (input.revision !== 0) throw revisionConflict(null);
      return (await repo.insertProfile(ctx.accountId, fields)) ?? conflictWithCurrent(repo, ctx.accountId);
    }
    if (input.revision !== current.revision) throw revisionConflict(current);
    // Un-confirming the visibility explainer also takes the member out of discovery.
    const discoverable = current.discoverable && fields.discoveryExplained;
    return (await repo.updateProfile(ctx.accountId, input.revision, fields, discoverable)) ?? conflictWithCurrent(repo, ctx.accountId);
  });
  return json(200, wire.ownProfile(saved));
}

async function conflictWithCurrent(repo: Repository, accountId: string): Promise<never> {
  throw revisionConflict(await repo.getProfile(accountId));
}

function revisionConflict(current: Parameters<typeof wire.ownProfile>[0] | null): ApiError {
  return new ApiError(409, "revision_conflict", "The profile changed since you last loaded it.", {
    current: current ? wire.ownProfile(current) : null,
  });
}

export async function putDiscovery(ctx: Context): Promise<Response> {
  const input = parse(discoverySettingSchema, await readJson(ctx.request));
  const discoverable = await ctx.deps.repo.transaction(async (repo) => {
    await repo.lockAccount(ctx.accountId);
    const profile = await repo.getProfile(ctx.accountId);
    if (input.discoverable) {
      const gyms = await repo.listGymAccess(ctx.accountId);
      const missing = [
        ...(profile ? [] : ["profile"]),
        ...(profile && !profile.adultConfirmed ? ["adult_confirmed"] : []),
        ...(profile && !profile.discoveryExplained ? ["discovery_explained"] : []),
        ...(gyms.length === 0 ? ["gym"] : []),
      ];
      if (missing.length > 0) {
        throw new ApiError(422, "profile_incomplete", "Finish your profile and add a gym before turning on discovery.", { missing });
      }
    }
    if (!profile) return false;
    return (await repo.setDiscoverable(ctx.accountId, input.discoverable))!.discoverable;
  });
  return json(200, { discoverable });
}

// ------------------------------------------------------------------ gym access

export async function listMyGyms(ctx: Context): Promise<Response> {
  const gyms = await ctx.deps.repo.listGymAccess(ctx.accountId);
  return json(200, { items: gyms.map(wire.gymAccess) });
}

export async function putMyGym(ctx: Context): Promise<Response> {
  const gymId = ctx.params.gym_id!;
  const input = parse(gymAccessInputSchema, await readJson(ctx.request));
  const saved = await ctx.deps.repo.transaction(async (repo) => {
    await repo.lockAccount(ctx.accountId);
    const gym = await repo.getGym(gymId);
    if (!gym || !gym.isActive) throw notFound();
    const current = await repo.listGymAccess(ctx.accountId);
    if (!current.some((ga) => ga.gym.id === gymId) && current.length >= LIMITS.gymsPerAccount) {
      throw new ApiError(422, "gym_limit_reached", `You can list up to ${LIMITS.gymsPerAccount} gyms.`, { limit: LIMITS.gymsPerAccount });
    }
    return repo.upsertGymAccess(ctx.accountId, gymId, input.access_type);
  });
  return json(200, wire.gymAccess(saved));
}

export async function deleteMyGym(ctx: Context): Promise<Response> {
  const gymId = ctx.params.gym_id!;
  await ctx.deps.repo.transaction(async (repo) => {
    await repo.lockAccount(ctx.accountId);
    if (!(await repo.deleteGymAccess(ctx.accountId, gymId))) return;
    // Discovery needs at least one gym; removing the last one pauses it.
    const remaining = await repo.listGymAccess(ctx.accountId);
    if (remaining.length === 0) {
      const profile = await repo.getProfile(ctx.accountId);
      if (profile?.discoverable) await repo.setDiscoverable(ctx.accountId, false);
    }
  });
  return noContent();
}

export async function createGymRequest(ctx: Context): Promise<Response> {
  const body = await readJson(ctx.request);
  const input = parse(gymRequestInputSchema, body);
  return idempotent(ctx, body, async (repo) => {
    const created = await repo.createGymRequest(ctx.accountId, {
      name: input.name, city: input.city, region: input.region, websiteUrl: input.website_url, note: input.note,
    });
    return { status: 201, body: wire.gymRequest(created) };
  });
}

// ------------------------------------------------------------------ availability

export async function listMyAvailability(ctx: Context): Promise<Response> {
  const slots = await ctx.deps.repo.listSlots(ctx.accountId);
  return json(200, { items: slots.map(wire.slot) });
}

export async function addAvailability(ctx: Context): Promise<Response> {
  const body = await readJson(ctx.request);
  const fields = slotFields(parse(slotInputSchema, body));
  return idempotent(ctx, body, async (repo) => {
    await repo.lockAccount(ctx.accountId);
    const existing = await repo.listSlots(ctx.accountId);
    if (existing.length >= LIMITS.slotsPerAccount) {
      throw new ApiError(422, "availability_limit_reached", `You can add up to ${LIMITS.slotsPerAccount} availability slots.`, {
        limit: LIMITS.slotsPerAccount,
      });
    }
    await requireOwnGym(repo, ctx.accountId, fields.gymId);
    return { status: 201, body: wire.slot(await repo.insertSlot(ctx.accountId, fields)) };
  });
}

export async function updateAvailability(ctx: Context): Promise<Response> {
  const fields = slotFields(parse(slotInputSchema, await readJson(ctx.request)));
  const saved = await ctx.deps.repo.transaction(async (repo) => {
    await repo.lockAccount(ctx.accountId);
    await requireOwnGym(repo, ctx.accountId, fields.gymId);
    const updated = await repo.updateSlot(ctx.accountId, ctx.params.slot_id!, fields);
    if (!updated) throw notFound();
    return updated;
  });
  return json(200, wire.slot(saved));
}

export async function deleteAvailability(ctx: Context): Promise<Response> {
  await ctx.deps.repo.deleteSlot(ctx.accountId, ctx.params.slot_id!);
  return noContent();
}

function slotFields(input: { weekday: number; start_minute: number; end_minute: number; time_zone: string; gym_id: string | null }): SlotFields {
  return { weekday: input.weekday, startMinute: input.start_minute, endMinute: input.end_minute, timeZone: input.time_zone, gymId: input.gym_id };
}

/** A slot may name a gym only if it is on the member's own list. */
async function requireOwnGym(repo: Repository, accountId: string, gymId: string | null): Promise<void> {
  if (gymId === null) return;
  const gyms = await repo.listGymAccess(accountId);
  if (!gyms.some((ga) => ga.gym.id === gymId)) throw validationFailed({ gym_id: "not_one_of_your_gyms" });
}

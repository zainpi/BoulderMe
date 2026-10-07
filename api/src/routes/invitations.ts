// /v1/invitations: create, list, read, accept, decline, cancel.

import type { Context } from "../app";
import { decodeCursor, encodeCursor, filterHash, timeKey, timeKeySchema } from "../cursor";
import type { InvitationRecord } from "../db/repository";
import { LIMITS } from "../domain";
import { ApiError, json, notFound, readJson } from "../http";
import { idempotent } from "../idempotency";
import { invitationInputSchema, invitationListQuerySchema, parse, queryObject } from "../validation";
import * as wire from "../wire";

const DEFAULT_LIMIT = 20;
const HOUR_MS = 60 * 60 * 1000;
const DAY_MS = 24 * HOUR_MS;

export async function createInvitation(ctx: Context): Promise<Response> {
  const body = await readJson(ctx.request);
  const input = parse(invitationInputSchema, body);
  const recipientId = input.recipient_account_id;
  return idempotent(ctx, body, async (repo) => {
    // Serializes this member's creates so the daily limit cannot be raced.
    await repo.lockAccount(ctx.accountId);
    const caller = await repo.getProfile(ctx.accountId);
    if (!caller || !caller.adultConfirmed) {
      throw new ApiError(422, "profile_incomplete", "Create your profile before inviting climbers.", { missing: ["profile"] });
    }

    if (recipientId === ctx.accountId) throw notFound();
    const [account, profile] = await Promise.all([repo.getAccount(recipientId), repo.getProfile(recipientId)]);
    const reachable = account?.status === "active" && profile?.discoverable && profile.adultConfirmed && profile.discoveryExplained;
    if (!reachable || (await repo.blockedEitherWay(ctx.accountId, recipientId))) throw notFound();

    const [mine, theirs] = await Promise.all([repo.listGymAccess(ctx.accountId), repo.listGymAccess(recipientId)]);
    const lists = (gyms: typeof mine) => gyms.some((ga) => ga.gym.id === input.gym_id && ga.gym.isActive);
    if (!lists(mine) || !lists(theirs)) {
      throw new ApiError(422, "gym_not_shared", "You can only invite someone to a gym you both climb at.");
    }

    const ahead = input.proposed_start_at.getTime() - ctx.now.getTime();
    if (ahead < HOUR_MS || ahead > LIMITS.invitationMaxDaysAhead * DAY_MS) {
      throw new ApiError(422, "invalid_time", `Pick a time between 1 hour and ${LIMITS.invitationMaxDaysAhead} days from now.`);
    }

    const sentToday = await repo.countInvitationsSentSince(ctx.accountId, new Date(ctx.now.getTime() - DAY_MS));
    if (sentToday >= LIMITS.invitationsPerDay) {
      throw new ApiError(429, "rate_limited", `You can send up to ${LIMITS.invitationsPerDay} invitations a day.`,
        { limit: LIMITS.invitationsPerDay }, { "retry-after": String(HOUR_MS / 1000) });
    }

    // A pending invitation whose time has passed must not hold the one-per-pair slot.
    await repo.expireStalePending(ctx.accountId, recipientId, ctx.now);
    const id = await repo.insertInvitation({
      senderId: ctx.accountId, recipientId, gymId: input.gym_id, proposedStartAt: input.proposed_start_at,
      durationMinutes: input.duration_minutes, note: input.note,
    }, ctx.now);
    if (!id) throw new ApiError(409, "invitation_already_open", "There is already a pending invitation between you two.");
    const created = await repo.getInvitation(ctx.accountId, id, ctx.now);
    return { status: 201, body: wire.invitation(created!) };
  });
}

export async function listInvitations(ctx: Context): Promise<Response> {
  const query = parse(invitationListQuerySchema, queryObject(ctx.url));
  const limit = query.limit ?? DEFAULT_LIMIT;
  const filters = await filterHash({ box: query.box, status: query.status });
  const after = query.cursor ? decodeCursor(query.cursor, timeKeySchema, filters, ctx.now) : null;
  const rows = await ctx.deps.repo.listInvitations({
    callerId: ctx.accountId, box: query.box, status: query.status ?? null, after, limit: limit + 1, now: ctx.now,
  });
  const page = rows.slice(0, limit);
  const last = page[page.length - 1];
  return json(200, {
    items: page.map(wire.invitation),
    next_cursor: rows.length > limit && last ? encodeCursor(timeKey(last.createdAt, last.id), filters, ctx.now) : null,
  });
}

export async function getInvitation(ctx: Context): Promise<Response> {
  const inv = await ctx.deps.repo.getInvitation(ctx.accountId, ctx.params.invitation_id!, ctx.now);
  if (!inv) throw notFound();
  return json(200, wire.invitation(inv));
}

type Action = "accept" | "decline" | "cancel";

export const acceptInvitation = (ctx: Context) => transition(ctx, "accept");
export const declineInvitation = (ctx: Context) => transition(ctx, "decline");
export const cancelInvitation = (ctx: Context) => transition(ctx, "cancel");

async function transition(ctx: Context, action: Action): Promise<Response> {
  const id = ctx.params.invitation_id!;
  const updated = await ctx.deps.repo.transaction(async (repo) => {
    const inv = await repo.getInvitation(ctx.accountId, id, ctx.now, true);
    if (!inv) throw notFound();
    if (!allowed(inv, action, ctx.accountId, ctx.now)) {
      throw new ApiError(409, "invalid_state", `This invitation can no longer be ${pastTense[action]}.`, { status: inv.status });
    }
    if (action === "accept") {
      const chatId = await repo.openChat(inv.sender.accountId, inv.recipient.accountId, ctx.now);
      await repo.setInvitationStatus(id, "accepted", ctx.now, { responded: true, chatId });
    } else if (action === "decline") {
      await repo.setInvitationStatus(id, "declined", ctx.now, { responded: true });
    } else {
      await repo.setInvitationStatus(id, "cancelled", ctx.now);
    }
    return (await repo.getInvitation(ctx.accountId, id, ctx.now))!;
  });
  return json(200, wire.invitation(updated));
}

const pastTense: Record<Action, string> = { accept: "accepted", decline: "declined", cancel: "cancelled" };

function allowed(inv: InvitationRecord, action: Action, callerId: string, now: Date): boolean {
  const isRecipient = inv.recipient.accountId === callerId;
  switch (action) {
    case "accept":
    case "decline":
      return isRecipient && inv.status === "pending";
    case "cancel":
      if (inv.status === "pending") return inv.sender.accountId === callerId;
      return inv.status === "accepted" && inv.proposedStartAt.getTime() + inv.durationMinutes * 60_000 > now.getTime();
  }
}

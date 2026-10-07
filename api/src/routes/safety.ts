// /v1/blocks and /v1/reports. Blocks act immediately and silently; reports go to the
// operator's moderation queue (OPERATIONS.md).

import type { Context } from "../app";
import { decodeCursor, encodeCursor, filterHash, timeKey, timeKeySchema } from "../cursor";
import { json, noContent, notFound, readJson } from "../http";
import { idempotent } from "../idempotency";
import { pageQuerySchema, parse, queryObject, reportInputSchema } from "../validation";
import * as wire from "../wire";

const DEFAULT_LIMIT = 20;
/** Snapshot name when the blocked member has no profile. */
const FALLBACK_NAME = "Climber";

export async function listBlocks(ctx: Context): Promise<Response> {
  const query = parse(pageQuerySchema, queryObject(ctx.url));
  const limit = query.limit ?? DEFAULT_LIMIT;
  const filters = await filterHash({ list: "blocks" });
  const after = query.cursor ? decodeCursor(query.cursor, timeKeySchema, filters, ctx.now) : null;
  const rows = await ctx.deps.repo.listBlocks(ctx.accountId, after, limit + 1);
  const page = rows.slice(0, limit);
  const last = page[page.length - 1];
  return json(200, {
    items: page.map(wire.block),
    next_cursor: rows.length > limit && last ? encodeCursor(timeKey(last.createdAt, last.blockedId), filters, ctx.now) : null,
  });
}

export async function blockMember(ctx: Context): Promise<Response> {
  const targetId = ctx.params.account_id!;
  if (targetId === ctx.accountId) throw notFound();
  const block = await ctx.deps.repo.transaction(async (repo) => {
    const target = await repo.getAccount(targetId);
    if (!target || target.status === "deleted") throw notFound();
    const existing = await repo.getBlock(ctx.accountId, targetId);
    if (existing) return existing;
    const profile = await repo.getProfile(targetId);
    const created = await repo.insertBlock(ctx.accountId, targetId, profile?.displayName ?? FALLBACK_NAME, ctx.now);
    await repo.cancelOpenInvitationsBetween(ctx.accountId, targetId, ctx.now);
    await repo.closeChatBetween(ctx.accountId, targetId);
    return created;
  });
  return json(200, wire.block(block));
}

export async function unblockMember(ctx: Context): Promise<Response> {
  await ctx.deps.repo.deleteBlock(ctx.accountId, ctx.params.account_id!);
  return noContent();
}

export async function createReport(ctx: Context): Promise<Response> {
  const body = await readJson(ctx.request);
  const input = parse(reportInputSchema, body);
  const reportedId = input.reported_account_id;
  return idempotent(ctx, body, async (repo) => {
    if (reportedId === ctx.accountId || !(await repo.getAccount(reportedId))) throw notFound();
    let messageSnapshot: string | null = null;
    if (input.context === "invitation" && !(await repo.invitationIsBetween(input.invitation_id!, ctx.accountId, reportedId))) {
      throw notFound();
    }
    if (input.context === "message") {
      const message = await repo.findMessageInCallersChat(ctx.accountId, input.message_id!);
      if (!message || message.senderId !== reportedId) throw notFound();
      messageSnapshot = message.body;
    }
    const report = await repo.insertReport({
      reporterId: ctx.accountId, reportedId, context: input.context, invitationId: input.invitation_id,
      messageId: input.message_id, reason: input.reason, details: input.details, messageSnapshot,
    }, ctx.now);
    return { status: 201, body: wire.report(report) };
  });
}

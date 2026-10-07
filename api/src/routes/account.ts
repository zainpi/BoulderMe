// DELETE /v1/me and GET /v1/me/export.

import type { Context } from "../app";
import { json, notFound, readJson, timestamp } from "../http";
import { revokeAppleTokens } from "../revocation";
import { deleteAccountSchema, parse } from "../validation";
import * as wire from "../wire";

/** Upper bound per list in an export; far above anything one member can create. */
const EXPORT_LIMIT = 100_000;

export async function deleteMe(ctx: Context): Promise<Response> {
  parse(deleteAccountSchema, await readJson(ctx.request));
  const { deps } = ctx;
  await deps.repo.transaction((repo) => repo.deleteAccount(ctx.accountId, ctx.now));
  // First Apple revocation attempt right away; the daily cron retries anything left pending.
  try {
    await revokeAppleTokens(
      { repo: deps.repo, apple: deps.apple, encryptionKey: deps.config.appleTokenEncryptionKey, log: deps.log },
      ctx.now,
      { limit: 1, accountId: ctx.accountId },
    );
  } catch (err) {
    deps.log({ level: "warn", event: "apple_revocation_deferred", request_id: ctx.requestId, error: err instanceof Error ? err.name : "unknown" });
  }
  return new Response(null, { status: 202 });
}

export async function exportMe(ctx: Context): Promise<Response> {
  const { repo } = ctx.deps;
  const me = ctx.accountId;
  const [account, profile, gyms, slots, incoming, outgoing, chats, blocks, reports, gymRequests] = await Promise.all([
    repo.getAccount(me),
    repo.getProfile(me),
    repo.listGymAccess(me),
    repo.listSlots(me),
    repo.listInvitations({ callerId: me, box: "incoming", status: null, after: null, limit: EXPORT_LIMIT, now: ctx.now }),
    repo.listInvitations({ callerId: me, box: "outgoing", status: null, after: null, limit: EXPORT_LIMIT, now: ctx.now }),
    repo.listChats(me, null, EXPORT_LIMIT, ctx.now),
    repo.listBlocks(me, null, EXPORT_LIMIT),
    repo.listReportsFiled(me),
    repo.listGymRequests(me),
  ]);
  if (!account) throw notFound();
  const invitations = [...incoming, ...outgoing].sort(
    (a, b) => b.createdAt.getTime() - a.createdAt.getTime() || (a.id < b.id ? 1 : -1),
  );
  const chatsWithMessages = await Promise.all(chats.map(async (chat) => ({
    chat: wire.chat(chat),
    messages: (await repo.listMessages({ chatId: chat.id, before: null, after: null, limit: EXPORT_LIMIT })).map(wire.message),
  })));
  return json(200, {
    exported_at: timestamp(ctx.now),
    account: { account_id: account.id, created_at: timestamp(account.createdAt) },
    profile: profile ? wire.ownProfile(profile) : null,
    gyms: gyms.map(wire.gymAccess),
    availability: slots.map(wire.slot),
    invitations: invitations.map(wire.invitation),
    chats: chatsWithMessages,
    blocks: blocks.map(wire.block),
    reports_filed: reports.map(wire.report),
    gym_requests: gymRequests.map(wire.gymRequest),
  }, { "content-disposition": 'attachment; filename="boulderme-export.json"' });
}

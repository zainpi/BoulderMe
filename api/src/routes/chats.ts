// /v1/chats: one chat per pair, opened by an accepted invitation. Polling, no realtime.

import type { Context } from "../app";
import { decodeCursor, encodeCursor, filterHash, timeKey, timeKeySchema } from "../cursor";
import type { MessageRecord } from "../db/repository";
import { ApiError, json, notFound, readJson, validationFailed } from "../http";
import { idempotent } from "../idempotency";
import { messageInputSchema, messageListQuerySchema, pageQuerySchema, parse, queryObject } from "../validation";
import * as wire from "../wire";

const DEFAULT_LIMIT = 20;

export async function listChats(ctx: Context): Promise<Response> {
  const query = parse(pageQuerySchema, queryObject(ctx.url));
  const limit = query.limit ?? DEFAULT_LIMIT;
  const filters = await filterHash({ list: "chats" });
  const after = query.cursor ? decodeCursor(query.cursor, timeKeySchema, filters, ctx.now) : null;
  const rows = await ctx.deps.repo.listChats(ctx.accountId, after, limit + 1, ctx.now);
  const page = rows.slice(0, limit);
  const last = page[page.length - 1];
  return json(200, {
    items: page.map(wire.chat),
    next_cursor: rows.length > limit && last ? encodeCursor(timeKey(last.activityAt, last.id), filters, ctx.now) : null,
  });
}

export async function getChat(ctx: Context): Promise<Response> {
  const chat = await ctx.deps.repo.getChat(ctx.accountId, ctx.params.chat_id!, ctx.now);
  if (!chat) throw notFound();
  return json(200, wire.chat(chat));
}

export async function listMessages(ctx: Context): Promise<Response> {
  const chatId = ctx.params.chat_id!;
  const query = parse(messageListQuerySchema, queryObject(ctx.url));
  const { repo } = ctx.deps;
  if (!(await repo.chatStatus(ctx.accountId, chatId))) throw notFound();
  const limit = query.limit ?? DEFAULT_LIMIT;

  let items: MessageRecord[];
  let nextCursor: string | null = null;
  let newest: MessageRecord | undefined;
  if (query.after) {
    const from = await repo.getMessage(chatId, query.after);
    if (!from) throw validationFailed({ after: "unknown_message" });
    items = await repo.listMessages({ chatId, before: null, after: { at: from.createdAt, id: from.id }, limit });
    newest = items[items.length - 1];
  } else {
    const filters = await filterHash({ chat_id: chatId });
    const before = query.cursor ? decodeCursor(query.cursor, timeKeySchema, filters, ctx.now) : null;
    const rows = await repo.listMessages({ chatId, before, after: null, limit: limit + 1 });
    items = rows.slice(0, limit);
    const last = items[items.length - 1];
    if (rows.length > limit && last) nextCursor = encodeCursor(timeKey(last.createdAt, last.id), filters, ctx.now);
    newest = items[0];
  }
  if (newest) await repo.markRead(chatId, ctx.accountId, newest.id);
  return json(200, { items: items.map(wire.message), next_cursor: nextCursor });
}

export async function sendMessage(ctx: Context): Promise<Response> {
  const chatId = ctx.params.chat_id!;
  const body = await readJson(ctx.request);
  const input = parse(messageInputSchema, body);
  return idempotent(ctx, body, async (repo) => {
    const status = await repo.chatStatus(ctx.accountId, chatId, true);
    if (!status) throw notFound();
    if (status === "closed") throw new ApiError(422, "chat_closed", "This chat is closed.");
    const message = await repo.insertMessage(chatId, ctx.accountId, input.body, ctx.now);
    // Replying means you have read what came before.
    await repo.markRead(chatId, ctx.accountId, message.id);
    return { status: 201, body: wire.message(message) };
  });
}

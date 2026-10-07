// Route table. Paths and methods match docs/api/openapi.yaml.

import type { RateRule, Route } from "../app";
import { deleteMe, exportMe } from "./account";
import { createNonce, refreshSession, signInWithApple, signOut } from "./auth";
import { discover, getGym, getProfile, health, listGyms } from "./browse";
import {
  addAvailability, createGymRequest, deleteAvailability, deleteMyGym, getMe, getMyProfile, listMyAvailability,
  listMyGyms, putDiscovery, putMyGym, putMyProfile, updateAvailability,
} from "./member";
import { getChat, listChats, listMessages, sendMessage } from "./chats";
import {
  acceptInvitation, cancelInvitation, createInvitation, declineInvitation, getInvitation, listInvitations,
} from "./invitations";
import { blockMember, createReport, listBlocks, unblockMember } from "./safety";

const MINUTE = 60;
const HOUR = 60 * MINUTE;
const DAY = 24 * HOUR;

/** Fixed-window limits. Unauthenticated routes count per installation id; the rest per account. */
export const RATE: Record<string, RateRule> = {
  health: { name: "health", limit: 60, windowSeconds: MINUTE },
  nonce: { name: "auth_nonce", limit: 10, windowSeconds: MINUTE },
  signIn: { name: "auth_apple", limit: 10, windowSeconds: MINUTE },
  refresh: { name: "auth_refresh", limit: 30, windowSeconds: MINUTE },
  read: { name: "read", limit: 120, windowSeconds: MINUTE },
  write: { name: "write", limit: 60, windowSeconds: MINUTE },
  discovery: { name: "discovery", limit: 120, windowSeconds: MINUTE },
  profileRead: { name: "profile_read", limit: 120, windowSeconds: MINUTE },
  gymRequest: { name: "gym_request", limit: 10, windowSeconds: DAY },
  // Polling every 5 s is 12 a minute per open chat; this leaves room for a few.
  chatPoll: { name: "chat_poll", limit: 240, windowSeconds: MINUTE },
  message: { name: "message", limit: 60, windowSeconds: MINUTE },
  report: { name: "report", limit: 20, windowSeconds: DAY },
  export: { name: "export", limit: 5, windowSeconds: HOUR },
};

export const routes: Route[] = [
  { method: "GET", path: "/v1/health", auth: false, rate: RATE.health!, handler: health, bestEffortRateLimit: true },

  { method: "POST", path: "/v1/auth/nonce", auth: false, rate: RATE.nonce!, handler: createNonce },
  { method: "POST", path: "/v1/auth/apple", auth: false, rate: RATE.signIn!, handler: signInWithApple },
  { method: "POST", path: "/v1/auth/refresh", auth: false, rate: RATE.refresh!, handler: refreshSession },
  { method: "POST", path: "/v1/auth/sign-out", auth: true, rate: RATE.write!, handler: signOut },

  { method: "GET", path: "/v1/me", auth: true, rate: RATE.read!, handler: getMe },
  { method: "DELETE", path: "/v1/me", auth: true, rate: RATE.write!, handler: deleteMe },
  { method: "GET", path: "/v1/me/export", auth: true, rate: RATE.export!, handler: exportMe },
  { method: "GET", path: "/v1/me/profile", auth: true, rate: RATE.read!, handler: getMyProfile },
  { method: "PUT", path: "/v1/me/profile", auth: true, rate: RATE.write!, handler: putMyProfile },
  { method: "PUT", path: "/v1/me/discovery", auth: true, rate: RATE.write!, handler: putDiscovery },

  { method: "GET", path: "/v1/gyms", auth: true, rate: RATE.read!, handler: listGyms },
  { method: "GET", path: "/v1/gyms/{gym_id}", auth: true, rate: RATE.read!, handler: getGym },
  { method: "POST", path: "/v1/gym-requests", auth: true, rate: RATE.gymRequest!, handler: createGymRequest },
  { method: "GET", path: "/v1/me/gyms", auth: true, rate: RATE.read!, handler: listMyGyms },
  { method: "PUT", path: "/v1/me/gyms/{gym_id}", auth: true, rate: RATE.write!, handler: putMyGym },
  { method: "DELETE", path: "/v1/me/gyms/{gym_id}", auth: true, rate: RATE.write!, handler: deleteMyGym },

  { method: "GET", path: "/v1/me/availability", auth: true, rate: RATE.read!, handler: listMyAvailability },
  { method: "POST", path: "/v1/me/availability", auth: true, rate: RATE.write!, handler: addAvailability },
  { method: "PUT", path: "/v1/me/availability/{slot_id}", auth: true, rate: RATE.write!, handler: updateAvailability },
  { method: "DELETE", path: "/v1/me/availability/{slot_id}", auth: true, rate: RATE.write!, handler: deleteAvailability },

  { method: "GET", path: "/v1/discovery", auth: true, rate: RATE.discovery!, handler: discover },
  { method: "GET", path: "/v1/profiles/{account_id}", auth: true, rate: RATE.profileRead!, handler: getProfile },

  // The 20-a-day invitation limit is counted from stored invitations (see createInvitation).
  { method: "GET", path: "/v1/invitations", auth: true, rate: RATE.read!, handler: listInvitations },
  { method: "POST", path: "/v1/invitations", auth: true, rate: RATE.write!, handler: createInvitation },
  { method: "GET", path: "/v1/invitations/{invitation_id}", auth: true, rate: RATE.read!, handler: getInvitation },
  { method: "POST", path: "/v1/invitations/{invitation_id}/accept", auth: true, rate: RATE.write!, handler: acceptInvitation },
  { method: "POST", path: "/v1/invitations/{invitation_id}/decline", auth: true, rate: RATE.write!, handler: declineInvitation },
  { method: "POST", path: "/v1/invitations/{invitation_id}/cancel", auth: true, rate: RATE.write!, handler: cancelInvitation },

  { method: "GET", path: "/v1/chats", auth: true, rate: RATE.read!, handler: listChats },
  { method: "GET", path: "/v1/chats/{chat_id}", auth: true, rate: RATE.read!, handler: getChat },
  { method: "GET", path: "/v1/chats/{chat_id}/messages", auth: true, rate: RATE.chatPoll!, handler: listMessages },
  { method: "POST", path: "/v1/chats/{chat_id}/messages", auth: true, rate: RATE.message!, handler: sendMessage },

  { method: "GET", path: "/v1/blocks", auth: true, rate: RATE.read!, handler: listBlocks },
  { method: "PUT", path: "/v1/blocks/{account_id}", auth: true, rate: RATE.write!, handler: blockMember },
  { method: "DELETE", path: "/v1/blocks/{account_id}", auth: true, rate: RATE.write!, handler: unblockMember },
  { method: "POST", path: "/v1/reports", auth: true, rate: RATE.report!, handler: createReport },
];

// Records to wire shapes (docs/api/openapi.yaml). Nullable fields are always present.

import type {
  BlockRecord, ChatRecord, GymAccessRecord, GymRecord, GymRequestRecord, InvitationRecord, MessageRecord, PartyRecord,
  ProfileRecord, ReportRecord, SlotRecord,
} from "./db/repository";
import { timestamp } from "./http";

export function ownProfile(p: ProfileRecord) {
  return {
    account_id: p.accountId,
    revision: p.revision,
    display_name: p.displayName,
    grade_min: p.gradeMin,
    grade_max: p.gradeMax,
    styles: p.styles,
    intro: p.intro,
    discoverable: p.discoverable,
    adult_confirmed: p.adultConfirmed,
    discovery_explained: p.discoveryExplained,
    updated_at: timestamp(p.updatedAt),
  };
}

export function gym(g: GymRecord) {
  return {
    gym_id: g.id,
    name: g.name,
    city: g.city,
    region: g.region,
    country: g.country,
    address: g.address,
    website_url: g.websiteUrl,
    is_bouldering_only: g.isBoulderingOnly,
  };
}

export function gymAccess(ga: GymAccessRecord) {
  return { gym: gym(ga.gym), access_type: ga.accessType, self_reported: true, updated_at: timestamp(ga.updatedAt) };
}

export function gymRequest(r: GymRequestRecord) {
  return { gym_request_id: r.id, name: r.name, city: r.city, region: r.region, status: r.status, created_at: timestamp(r.createdAt) };
}

export function slot(s: SlotRecord) {
  return {
    slot_id: s.id,
    weekday: s.weekday,
    start_minute: s.startMinute,
    end_minute: s.endMinute,
    time_zone: s.timeZone,
    gym_id: s.gymId,
  };
}

/** Shown in place of a member who deleted their account. */
export const DELETED_MEMBER_NAME = "Deleted climber";

export function party(p: PartyRecord) {
  return {
    account_id: p.accountId,
    display_name: p.displayName ?? DELETED_MEMBER_NAME,
    grade_min: p.gradeMin,
    grade_max: p.gradeMax,
  };
}

export function invitation(i: InvitationRecord) {
  return {
    invitation_id: i.id,
    status: i.status,
    sender: party(i.sender),
    recipient: party(i.recipient),
    gym: gym(i.gym),
    proposed_start_at: timestamp(i.proposedStartAt),
    duration_minutes: i.durationMinutes,
    note: i.note,
    chat_id: i.chatId,
    created_at: timestamp(i.createdAt),
    responded_at: i.respondedAt ? timestamp(i.respondedAt) : null,
    expires_at: timestamp(i.expiresAt),
  };
}

export function message(m: MessageRecord) {
  return { message_id: m.id, chat_id: m.chatId, sender_account_id: m.senderId, body: m.body, created_at: timestamp(m.createdAt) };
}

export function chat(c: ChatRecord) {
  return {
    chat_id: c.id,
    other_member: party(c.other),
    status: c.status,
    last_message: c.lastMessage ? message(c.lastMessage) : null,
    unread_count: c.unreadCount,
    upcoming_session: c.upcoming ? invitation(c.upcoming) : null,
    created_at: timestamp(c.createdAt),
    updated_at: timestamp(c.updatedAt),
  };
}

export function block(b: BlockRecord) {
  return { blocked_account_id: b.blockedId, display_name: b.displayName, created_at: timestamp(b.createdAt) };
}

export function report(r: ReportRecord) {
  return { report_id: r.id, reported_account_id: r.reportedId, context: r.context, reason: r.reason, status: r.status, created_at: timestamp(r.createdAt) };
}

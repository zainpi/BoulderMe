// Records to wire shapes (docs/api/openapi.yaml). Nullable fields are always present.

import type { GymAccessRecord, GymRecord, GymRequestRecord, ProfileRecord, SlotRecord } from "./db/repository";
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

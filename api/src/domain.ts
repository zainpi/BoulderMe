// Product rules shared by routes and both repositories.

import type { SlotRecord, TimeOfDay } from "./db/repository";

/** Local-time minute ranges `[start, end)` for each `TimeOfDay` (see openapi `TimeOfDay`). */
export const TIME_OF_DAY_RANGES: Record<TimeOfDay, readonly [number, number]> = {
  morning: [0, 720],
  afternoon: [720, 1020],
  evening: [1020, 1440],
};

const TIME_OF_DAY_ORDER: TimeOfDay[] = ["morning", "afternoon", "evening"];

export const LIMITS = {
  gymsPerAccount: 10,
  slotsPerAccount: 21,
  activeRecentlyDays: 14,
} as const;

export function slotOverlapsTimeOfDay(slot: Pick<SlotRecord, "startMinute" | "endMinute">, tod: TimeOfDay): boolean {
  const [start, end] = TIME_OF_DAY_RANGES[tod];
  return slot.startMinute < end && slot.endMinute > start;
}

/** Distinct (weekday, time_of_day) pairs a member's slots cover, in week order. */
export function availabilitySummary(slots: SlotRecord[]): { weekday: number; time_of_day: TimeOfDay }[] {
  const seen = new Set<string>();
  const out: { weekday: number; time_of_day: TimeOfDay }[] = [];
  const sorted = [...slots].sort((a, b) => a.weekday - b.weekday || a.startMinute - b.startMinute);
  for (const slot of sorted) {
    for (const tod of TIME_OF_DAY_ORDER) {
      const key = `${slot.weekday}:${tod}`;
      if (slotOverlapsTimeOfDay(slot, tod) && !seen.has(key)) {
        seen.add(key);
        out.push({ weekday: slot.weekday, time_of_day: tod });
      }
    }
  }
  return out.sort((a, b) => a.weekday - b.weekday || TIME_OF_DAY_ORDER.indexOf(a.time_of_day) - TIME_OF_DAY_ORDER.indexOf(b.time_of_day));
}

/** `last_active_on` (a UTC date) within the last 14 days. Never exposes the date itself. */
export function isActiveRecently(lastActiveOn: string, now: Date): boolean {
  const cutoff = new Date(now.getTime() - LIMITS.activeRecentlyDays * 86_400_000).toISOString().slice(0, 10);
  return lastActiveOn >= cutoff;
}

export function utcDate(now: Date): string {
  return now.toISOString().slice(0, 10);
}

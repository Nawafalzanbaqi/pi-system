// pi-system prospect organizer — FOLLOW-UP due-date logic (pure).
// ===========================================================================
// Decides which prospects are DUE for a follow-up TODAY, so the operator can be
// reminded to reach out MANUALLY. Pure given (records, today): no clock, no I/O —
// the caller passes "today" as a YYYY-MM-DD string — so the due-date rules are
// unit-testable with fixed dates.
//
// IMPORTANT: "due follow-up" means "the operator should personally contact this
// prospect again." It is a reminder TO THE OPERATOR. This module never sends
// anything; surfacing/notification (still operator-only) lives in notify.js.
// ===========================================================================

import { isClosed, isValidDate } from './pipeline.js';

// Is THIS prospect due for a follow-up on/and-before `today`?
// Due when: it has a follow-up date, that date is today or earlier, AND the
// prospect is still open (won/lost are done — never nag about a closed prospect).
export function isDue(record, today) {
  if (!record || !record.followup || !isValidDate(record.followup)) return false;
  if (isClosed(record.status)) return false;
  if (!isValidDate(today)) return false;
  return record.followup <= today; // ISO calendar dates compare correctly as strings
}

// Whole-number days from `today` until a prospect's follow-up (negative = overdue).
// null when there is no (valid) follow-up date.
export function daysUntil(record, today) {
  if (!record || !record.followup || !isValidDate(record.followup) || !isValidDate(today)) return null;
  const a = Date.parse(record.followup + 'T00:00:00Z');
  const b = Date.parse(today + 'T00:00:00Z');
  return Math.round((a - b) / 86400000);
}

// All prospects due on/before `today`, most-overdue first (then by name) — the
// operator's "reach out to these today" list.
export function dueFollowups(records, today) {
  return (records || [])
    .filter((r) => isDue(r, today))
    .sort((a, b) => {
      if (a.followup !== b.followup) return a.followup < b.followup ? -1 : 1;
      return String(a.name).localeCompare(String(b.name));
    });
}

// Open prospects with a follow-up date in the FUTURE (not yet due), soonest first.
// Handy for an "upcoming" view; never used to send anything.
export function upcomingFollowups(records, today) {
  return (records || [])
    .filter((r) => r && r.followup && isValidDate(r.followup) && !isClosed(r.status) && r.followup > today)
    .sort((a, b) => (a.followup < b.followup ? -1 : a.followup > b.followup ? 1 : 0));
}

// A one-line, channel-agnostic summary of the due list for the operator reminder.
export function summarizeDue(due, today) {
  if (!due || due.length === 0) return `No prospect follow-ups due as of ${today}.`;
  const names = due.slice(0, 5).map((r) => r.name).join(', ');
  const more = due.length > 5 ? `, +${due.length - 5} more` : '';
  return `${due.length} prospect follow-up(s) due as of ${today}: ${names}${more}`;
}

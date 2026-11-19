/**
 * The record of changes to someone's time, as Timesheets words it (features/timesheets/
 * timeChanges.ts): who or what changed an entry, what it said before and says now, and which
 * entries were deleted. The record itself is the database's (supabase/tests/time_entry_changes_test.sql).
 */
import { readFileSync } from "node:fs";
import { describe, expect, it, vi } from "vitest";

vi.mock("../src/lib/api", async (importOriginal) => ({ ...(await importOriginal<typeof import("../src/lib/api")>()), supabase: () => null }));
const { changedBy, changeLines, editNote, sortEdits } = await import("../src/features/timesheets/timeChanges");
type TimeChange = import("../src/features/timesheets/timeChanges").TimeChange;

const TZ = "America/New_York";
const NAMES: Record<string, string> = { pat: "Pat Owner", ray: "Ray Crew" };
const name = (id: string) => NAMES[id] ?? "Team member";
// Monday Nov 9 2026, 8:00 to 12:00 in New York.
const change = (over: Partial<TimeChange> = {}): TimeChange => ({
  id: "c1", entry_id: "e1", user_id: "ray", action: "changed", changed_by: "pat", source: "person", reason: null,
  old_started_at: "2026-11-09T13:00:00+00:00", new_started_at: "2026-11-09T13:00:00+00:00", old_ended_at: "2026-11-09T17:00:00+00:00", new_ended_at: "2026-11-09T17:00:00+00:00",
  old_category: "shop", new_category: "shop", old_visit_id: null, new_visit_id: null, old_job_id: null, new_job_id: null, old_notes: null, new_notes: null, changed_at: "2026-11-12T15:00:00+00:00", ...over,
});

describe("who or what changed someone's time", () => {
  it("names the person, or says it was you", () => {
    expect(changedBy(change(), "ray", name)).toBe("Pat Owner");
    expect(changedBy(change(), "pat", name)).toBe("You");
    expect(changedBy(change({ changed_by: "gone" }), "ray", name)).toBe("Team member");
  });

  it("says what did it when it wasn't a person's own edit", () => {
    expect(changedBy(change({ source: "assistant" }), "ray", name)).toBe("Pat Owner's AI assistant");
    expect(changedBy(change({ source: "assistant" }), "pat", name)).toBe("Your AI assistant");
    expect(changedBy(change({ source: "geofence", changed_by: "ray" }), "ray", name)).toBe("The phone, at the property");
    expect(changedBy(change({ source: "finished_visit" }), "ray", name)).toBe("Pat Owner completed the visit");
    expect(changedBy(change({ source: "finished_visit" }), "pat", name)).toBe("You completed the visit");
    expect(changedBy(change({ source: "next_clock", changed_by: "ray" }), "ray", name)).toBe("Another clock started");
    expect(changedBy(change({ source: "auto_stop", changed_by: null }), "ray", name)).toBe("Planet Ops, because the clock was left running");
    expect(changedBy(change({ source: "sub_off_clock" }), "ray", name)).toBe("Planet Ops, on being taken off the clock");
    expect(changedBy(change({ source: "system", changed_by: null }), "ray", name)).toBe("Planet Ops");
    // Something a newer server records: still said, never blank.
    expect(changedBy(change({ source: "something_new", changed_by: null }), "ray", name)).toBe("Planet Ops");
  });

  it("puts one line under an edited entry", () => {
    expect(editNote(change(), "ray", name)).toBe("Changed by Pat Owner");
    expect(editNote(change(), "pat", name)).toBe("You changed this");
    expect(editNote(change({ action: "added" }), "ray", name)).toBe("Added by Pat Owner");
    expect(editNote(change({ action: "deleted" }), "ray", name)).toBe("Deleted by Pat Owner");
    expect(editNote(change({ action: "deleted", changed_by: "ray" }), "ray", name)).toBe("You deleted this");
    expect(editNote(change({ source: "assistant" }), "ray", name)).toBe("Changed by Pat Owner's AI assistant");
    expect(editNote(change({ source: "system", changed_by: null }), "ray", name)).toBe("Changed by Planet Ops");
  });
});

describe("what a change did", () => {
  it("gives the old and the new of each thing that changed, and nothing for what didn't", () => {
    expect(changeLines(change({ new_ended_at: "2026-11-09T16:30:00+00:00" }), TZ)).toEqual(["End: 12:00 PM → 11:30 AM"]);
    expect(changeLines(change({ new_started_at: "2026-11-09T14:00:00+00:00", new_category: "break", new_notes: "Lunch" }), TZ)).toEqual(["Start: 8:00 AM → 9:00 AM", "Type: Shop time → On break", "Note: Lunch"]);
    expect(changeLines(change({ old_notes: "Lunch" }), TZ)).toEqual(["Note removed"]);
    expect(changeLines(change(), TZ)).toEqual([]);
  });

  it("reads the same instant written two ways as no change", () => {
    expect(changeLines(change({ new_started_at: "2026-11-09T08:00:00-05:00", new_ended_at: "2026-11-09T17:00:00.000Z" }), TZ)).toEqual([]);
  });

  it("says a running clock was stopped, or set running again", () => {
    expect(changeLines(change({ old_ended_at: null }), TZ)).toEqual(["Stopped at 12:00 PM"]);
    expect(changeLines(change({ new_ended_at: null }), TZ)).toEqual(["Set running again (it had stopped at 12:00 PM)"]);
  });

  it("names the day when a time moves to another day", () => {
    expect(changeLines(change({ new_started_at: "2026-11-08T13:00:00+00:00" }), TZ)).toEqual(["Start: Mon, Nov 9 8:00 AM → Sun, Nov 8 8:00 AM"]);
  });

  it("says a visit or job came off, went on or changed", () => {
    expect(changeLines(change({ old_visit_id: "v1", old_job_id: "j1" }), TZ)).toEqual(["Taken off its visit"]);
    expect(changeLines(change({ new_visit_id: "v1" }), TZ)).toEqual(["Put on a visit"]);
    expect(changeLines(change({ old_visit_id: "v1", new_visit_id: "v2" }), TZ)).toEqual(["Moved to another visit"]);
    expect(changeLines(change({ old_job_id: "j1" }), TZ)).toEqual(["Taken off its job"]);
    expect(changeLines(change({ old_job_id: "j1", new_job_id: "j2" }), TZ)).toEqual(["Moved to another job"]);
  });

  it("says what was added, and what a deleted entry said", () => {
    const blank = { old_started_at: null, old_ended_at: null, old_category: null };
    expect(changeLines(change({ action: "added", ...blank, new_category: "other", new_notes: "Forgot to clock in" }), TZ)).toEqual(["Added 8:00 AM – 12:00 PM, Other work", "Note: Forgot to clock in"]);
    expect(changeLines(change({ action: "deleted", new_started_at: null, new_ended_at: null, new_category: null, old_category: "drive" }), TZ)).toEqual(["Deleted 8:00 AM – 12:00 PM, Driving"]);
    expect(changeLines(change({ action: "deleted", new_started_at: null, new_ended_at: null, new_category: null, old_ended_at: null }), TZ)).toEqual(["Deleted 8:00 AM – now, Shop time"]);
  });
});

describe("a week's edits", () => {
  it("groups them by entry, oldest first, and lists the entries that ended up deleted", () => {
    const edits = sortEdits([
      change({ id: "a", entry_id: "e1" }),
      change({ id: "b", entry_id: "e2", action: "added", old_started_at: null }),
      change({ id: "c", entry_id: "e1", reason: "Left early" }),
      change({ id: "d", entry_id: "e2", action: "deleted", new_started_at: null, old_started_at: "2026-11-10T13:00:00+00:00" }),
      change({ id: "e", entry_id: "e3", action: "deleted", new_started_at: null, old_started_at: "2026-11-09T12:00:00+00:00" }),
    ]);
    expect(edits.byEntry.get("e1")!.map((c) => c.id)).toEqual(["a", "c"]);
    // In the order the deleted time started, for the week's list.
    expect(edits.deleted.map((c) => c.id)).toEqual(["e", "d"]);
  });
});

describe("Timesheets", () => {
  const page = readFileSync(new URL("../src/features/timesheets/TimesheetsPage.tsx", import.meta.url), "utf8");
  const history = readFileSync(new URL("../src/features/timesheets/TimeHistory.tsx", import.meta.url), "utf8");

  it("offers History on every entry, whoever may edit it, and lists deleted time under the person", () => {
    expect(page).toContain('{ label: t("History"), icon: "clock", onSelect: openHistory }');
    expect(page).toContain("edits.deleted.filter((c) => c.user_id === userId)");
    // Someone whose only time this week was deleted still has a section.
    expect(page).toContain("...edits.deleted.map((c) => c.user_id)");
  });

  it("sends why with an edit, and marks every edit from the dialog as one", () => {
    expect(page).toContain("change_reason: reason.trim()");
    expect(page).toContain('label={t("Why it\'s changing")}');
  });

  it("asks why before deleting someone else's time, and deletes it through the database's own function", () => {
    expect(page).toContain("r.user_id === session.userId ? removeLater(r) : setDeleting(r)");
    expect(history).toContain('rpc("delete_time_entry", { p_entry: entry.id, p_reason: reason.trim() || undefined })');
  });
});

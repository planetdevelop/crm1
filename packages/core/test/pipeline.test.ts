// Planet Ops Phase 2: what each pipeline filter means.
import { describe, expect, it } from "vitest";
import { isActive, needsOutcomeReason, pipelineFlags, type PipelineRequest } from "../src/pipeline";

const today = "2026-11-20";
const base: PipelineRequest = {
  status: "new",
  stage: { kind: "open", system_key: "new_inquiry" },
  assigned_to: "u1",
  next_action: "Make first contact",
  next_action_on: "2026-11-25",
  first_response_at: "2026-11-19T15:00:00Z",
  follow_up_paused_reason: null,
  follow_ups: [],
};
const flags = (r: Partial<PipelineRequest>) => [...pipelineFlags({ ...base, ...r }, today)].sort();

describe("pipeline filters", () => {
  it("a request with an owner, a first response and a next action later is in none", () => {
    expect(flags({})).toEqual([]);
  });

  it("needs a first response until someone has contacted the customer", () => {
    expect(flags({ first_response_at: null })).toEqual(["first_response"]);
  });

  it("is due today, or overdue, by its next action or any open follow-up", () => {
    expect(flags({ next_action_on: today })).toEqual(["due"]);
    expect(flags({ next_action_on: "2026-11-19" })).toEqual(["overdue"]);
    expect(flags({ follow_ups: ["2026-11-01", null] })).toEqual(["overdue"]);
    expect(flags({ follow_ups: [today] })).toEqual(["due"]);
  });

  it("waits on the customer once the quote or proposal is out, until they reply", () => {
    expect(flags({ stage: { kind: "open", system_key: "quote_sent" } })).toEqual(["waiting"]);
    expect(flags({ stage: { kind: "open", system_key: "follow_up" }, follow_up_paused_reason: "customer_replied" })).toEqual([]);
  });

  it("flags no next action and no owner", () => {
    expect(flags({ next_action: " ", next_action_on: null })).toEqual(["no_next_action"]);
    expect(flags({ assigned_to: null })).toEqual(["no_owner"]);
  });

  it("only active requests are flagged: decided, archived and converted ones aren't", () => {
    for (const r of [
      { stage: { kind: "won" as const, system_key: "won" as const } },
      { stage: { kind: "lost" as const, system_key: "lost" as const }, next_action: null, next_action_on: null },
      { status: "archived", first_response_at: null },
      { status: "converted", assigned_to: null },
      { stage: null },
    ]) expect(flags(r)).toEqual([]);
    expect(isActive({ status: "new", stage: { kind: "nurture", system_key: "nurture" } })).toBe(true);
  });

  it("silence isn't a loss: an old, quiet request is still active, just overdue", () => {
    const quiet = { ...base, stage: { kind: "open" as const, system_key: "quote_sent" as const }, next_action_on: "2026-01-01" };
    expect(isActive(quiet)).toBe(true);
    expect(pipelineFlags(quiet, today).has("overdue")).toBe(true);
  });

  it("lost and unqualified need a reason; the others don't", () => {
    expect(["open", "won", "nurture", "lost", "unqualified"].filter((k) => needsOutcomeReason(k as never))).toEqual(["lost", "unqualified"]);
  });
});

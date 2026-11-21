/**
 * Planet Ops Phase 2: the sales pipeline's shared rules (supabase/migrations/20261122000100_planet_ops_pipeline.sql).
 * What each filter means, so the board, the list and the tests agree. "Viewed" and "overdue" are
 * badges, not stages.
 */

export type StageKind = "open" | "won" | "nurture" | "lost" | "unqualified";
export type StageKey =
  | "new_inquiry" | "contacting" | "site_visit_scheduled" | "site_visit_complete" | "estimating"
  | "quote_sent" | "follow_up" | "won" | "nurture" | "lost" | "unqualified";

export interface PipelineStage {
  id: string;
  system_key: StageKey | null;
  label: string;
  kind: StageKind;
  sort: number;
  active: boolean;
}

export interface PipelineRequest {
  status: string;
  stage: Pick<PipelineStage, "kind" | "system_key"> | null;
  assigned_to: string | null;
  next_action: string | null;
  next_action_on: string | null;
  first_response_at: string | null;
  follow_up_paused_reason: string | null;
  /** Its open follow-ups' due dates (YYYY-MM-DD, or null for none). */
  follow_ups?: Array<string | null>;
}

export const PIPELINE_FILTERS = [
  { key: "first_response", label: "Needs first response" },
  { key: "due", label: "Follow-up due" },
  { key: "overdue", label: "Overdue" },
  { key: "waiting", label: "Waiting on customer" },
  { key: "no_next_action", label: "No next action" },
  { key: "no_owner", label: "No owner" },
] as const;
export type PipelineFilter = (typeof PIPELINE_FILTERS)[number]["key"];

/** Still being worked in sales: in an open stage or nurture, and not archived or made into a job. */
export function isActive(r: Pick<PipelineRequest, "status" | "stage">): boolean {
  return !!r.stage && (r.stage.kind === "open" || r.stage.kind === "nurture") && r.status !== "converted" && r.status !== "archived";
}

/**
 * Which filters a request matches on a given day (the business's own date, YYYY-MM-DD):
 *   first_response  active, and nobody has contacted the customer yet
 *   due             active, and its next action or a follow-up is due today
 *   overdue         active, and its next action or a follow-up was due before today
 *   waiting         active in Quote/proposal sent or Follow-up, and the customer hasn't replied since
 *                   (a reply pauses its follow-ups)
 *   no_next_action  active without a next action and its date
 *   no_owner        active with nobody on it
 * Silence is never a loss: nothing here moves or closes a request.
 */
export function pipelineFlags(r: PipelineRequest, today: string): Set<PipelineFilter> {
  const flags = new Set<PipelineFilter>();
  if (!isActive(r)) return flags;
  const dates = [r.next_action_on, ...(r.follow_ups ?? [])].filter((d): d is string => !!d);
  if (!r.first_response_at) flags.add("first_response");
  if (dates.some((d) => d === today)) flags.add("due");
  if (dates.some((d) => d < today)) flags.add("overdue");
  if ((r.stage?.system_key === "quote_sent" || r.stage?.system_key === "follow_up") && r.follow_up_paused_reason !== "customer_replied") flags.add("waiting");
  if (!r.next_action?.trim() || !r.next_action_on) flags.add("no_next_action");
  if (!r.assigned_to) flags.add("no_owner");
  return flags;
}

/** Lost and Unqualified need a reason; the database refuses one without. */
export const needsOutcomeReason = (kind: StageKind) => kind === "lost" || kind === "unqualified";

export const PAUSE_REASONS: Record<string, string> = {
  customer_replied: "The customer replied",
  won: "Won",
  lost: "Lost",
  unqualified: "Unqualified",
  opted_out: "The customer opted out of messages",
  staff: "Paused by staff",
};

/** How many whole days from one date (or time) to another day, for "days in stage". */
export function daysBetween(fromIso: string, toIso: string): number {
  return Math.max(0, Math.floor((Date.parse(toIso) - Date.parse(fromIso)) / 86_400_000));
}

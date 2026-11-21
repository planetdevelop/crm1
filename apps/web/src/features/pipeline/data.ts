/**
 * Planet Ops Phase 2: the sales pipeline's data for the screens (20261122000100_planet_ops_pipeline.sql).
 * Stages, the requests in them with their open follow-ups, and the business's own date for the
 * filters (packages/core/src/pipeline.ts says what each means).
 */
import type { PipelineStage, StageKind } from "@crewtavo/core/pipeline";
import { useQuery } from "@tanstack/react-query";
import { supabase, unwrap } from "@/lib/api";

export interface Stage extends PipelineStage {
  default_next_action: string | null;
  default_due_days: number | null;
}

export const stagesKey = (companyId: string) => ["pipeline-stages", companyId];
export const useStages = (companyId: string) =>
  useQuery({
    queryKey: stagesKey(companyId),
    staleTime: 60_000,
    queryFn: async () =>
      unwrap(await supabase().from("pipeline_stages").select("id, system_key, label, kind, sort, active, default_next_action, default_due_days").eq("company_id", companyId).order("sort")) as Stage[],
  });

export interface PipelineCard {
  id: string;
  number: number;
  title: string;
  status: string;
  source: string;
  website_form_id: string | null;
  stage_id: string | null;
  stage_entered_at: string | null;
  assigned_to: string | null;
  estimator_id: string | null;
  next_action: string | null;
  next_action_on: string | null;
  last_contact_at: string | null;
  first_response_at: string | null;
  follow_up_paused_reason: string | null;
  outcome_reason: string | null;
  outcome_at: string | null;
  service: string | null;
  campaign: string | null;
  created_at: string;
  client: { id: string; display_name: string } | null;
  property: { line1: string | null; city: string | null } | null;
  /** Open follow-ups' due dates. */
  follow_ups: Array<string | null>;
  /** The latest sent quote or proposal's amount, if any. */
  value: number | null;
}

export const pipelineKey = (companyId: string) => ["pipeline-requests", companyId];

/**
 * Requests in the pipeline: every open one, and those decided (won, lost, unqualified) or archived
 * in the last `days` days.
 */
export function usePipelineRequests(companyId: string, days = 30) {
  return useQuery({
    queryKey: [...pipelineKey(companyId), days],
    queryFn: async (): Promise<PipelineCard[]> => {
      const since = new Date(Date.now() - days * 86_400_000).toISOString();
      const [open, decided, tasks] = await Promise.all([
        supabase().from("requests").select(SELECT).eq("company_id", companyId).not("status", "in", "(converted,archived)").is("outcome_at", null).limit(1000),
        supabase().from("requests").select(SELECT).eq("company_id", companyId).or(`outcome_at.gte.${since},and(status.eq.archived,updated_at.gte.${since})`).limit(500),
        supabase().from("follow_up_tasks").select("related_id, due_on").eq("company_id", companyId).eq("related_type", "request").is("done_at", null).limit(1000),
      ]);
      const due = new Map<string, Array<string | null>>();
      for (const t of unwrap(tasks)) if (t.related_id) due.set(t.related_id, [...(due.get(t.related_id) ?? []), t.due_on]);
      const seen = new Set<string>();
      return [...unwrap(open), ...unwrap(decided)].flatMap((r) => {
        if (seen.has(r.id)) return [];
        seen.add(r.id);
        const sent = (r.quotes ?? []).filter((q) => q.sent_at && !q.change_order_for).sort((a, b) => (b.sent_at ?? "").localeCompare(a.sent_at ?? ""))[0];
        const { quotes: _q, ...rest } = r;
        return [{ ...rest, follow_ups: due.get(r.id) ?? [], value: sent ? Number(sent.total) : null } as PipelineCard];
      });
    },
  });
}
const SELECT =
  "id, number, title, status, source, website_form_id, stage_id, stage_entered_at, assigned_to, estimator_id, next_action, next_action_on, last_contact_at, first_response_at, follow_up_paused_reason, outcome_reason, outcome_at, service, campaign, created_at, client:clients(id, display_name), property:properties(line1, city), quotes(total, sent_at, change_order_for)";

/** The business's own date today, YYYY-MM-DD (follow-ups are due on its days). */
export function companyToday(timezone: string | null | undefined, now = new Date()): string {
  try {
    return new Intl.DateTimeFormat("en-CA", { timeZone: timezone || "UTC", year: "numeric", month: "2-digit", day: "2-digit" }).format(now);
  } catch {
    return now.toISOString().slice(0, 10);
  }
}

export const KIND_COLOR: Record<StageKind, string> = {
  open: "var(--req)",
  nurture: "var(--quote)",
  won: "var(--job)",
  lost: "var(--danger)",
  unqualified: "var(--text-3)",
};

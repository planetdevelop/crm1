/**
 * Planet Ops Phase 3: a request's internal estimates, and Start estimate (its customer, property and
 * title come with it). Shown only to people who prepare estimates; no costs here.
 */
import { useQuery } from "@tanstack/react-query";
import { Link, useNavigate } from "react-router-dom";
import { Button } from "@/components/ui/Button";
import { EmptyState } from "@/components/ui/States";
import { supabase, unwrap } from "@/lib/api";
import { formatDate } from "@/lib/format";
import { useSession } from "@/lib/session";
import { canEstimate } from "./data";
import { estimateStatus } from "./EstimatesPage";

export function RequestEstimates({ requestId }: { requestId: string }) {
  const session = useSession();
  const navigate = useNavigate();
  const allowed = canEstimate(session);
  const estimates = useQuery({
    queryKey: ["estimates", session.company.id, "request", requestId],
    enabled: allowed,
    queryFn: async () =>
      unwrap(await supabase().from("estimates").select("id, number, title, updated_at, baseline_version_id, current_version_id, versions:estimate_versions!estimate_versions_company_id_estimate_id_fkey(id, number, status, calc_status, saved_at, approved_at, locked_at)").eq("request_id", requestId).order("created_at")),
  });
  if (!allowed) return null;
  const rows = estimates.data ?? [];
  return (
    <section className="stack" data-planet-ops="request-estimates">
      <div className="section-head">
        <h2 className="section-title">Estimates</h2>
        <Button size="sm" icon="calculator" onClick={() => navigate(`/estimates?new=1&request=${requestId}`)}>Start estimate</Button>
      </div>
      <div className="card">
        {rows.length === 0 && <EmptyState inline title="No estimate yet" />}
        {rows.map((e) => (
          <Link key={e.id} to={`/estimates/${e.id}`} className="card-row">
            <span className="muted tabular">#{e.number}</span>
            <strong className="grow ellipsis">{e.title}</strong>
            <span className="pill pill-quiet small">{estimateStatus(e).label}</span>
            <span className="muted small">{formatDate(e.updated_at)}</span>
          </Link>
        ))}
      </div>
    </section>
  );
}

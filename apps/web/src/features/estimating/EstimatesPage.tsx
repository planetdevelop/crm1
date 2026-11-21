/**
 * Planet Ops Phase 3: the Estimating tab, the business's internal calculator (apart from Quotes &
 * Proposals, the customer's documents). Every estimate with its customer, property, request,
 * estimator, version, status and the request's outcome; search; New estimate (from a request, or on
 * its own). Nothing here is ever sent to a customer.
 */
import { useMutation, useQueryClient } from "@tanstack/react-query";
import { useDeferredValue, useMemo, useState } from "react";
import { Link, useNavigate, useSearchParams } from "react-router-dom";
import { Button } from "@/components/ui/Button";
import { Dialog } from "@/components/ui/Dialog";
import { Field, FormError } from "@/components/ui/Field";
import { Icon } from "@/components/ui/Icon";
import { PageHeader } from "@/components/ui/PageHeader";
import { ListPageSkeleton } from "@/components/ui/Skeleton";
import { EmptyState, ErrorState } from "@/components/ui/States";
import { supabase, unwrap } from "@/lib/api";
import { formatDate } from "@/lib/format";
import { useSession } from "@/lib/session";
import { memberName, useTeam } from "../requests/RequestsPage";
import { canEstimate, estimatesKey, useEstimates, type EstimateRow } from "./data";

export const estimateStatus = (e: Pick<EstimateRow, "versions" | "baseline_version_id" | "current_version_id">) => {
  const current = e.versions.find((v) => v.id === e.current_version_id);
  if (!current) return { label: "No versions", tone: "muted" };
  if (current.status === "approved") return { label: current.id === e.baseline_version_id ? "Approved baseline" : "Approved revision", tone: "job" };
  if (current.calc_status !== "ok") return { label: current.saved_at ? "Draft, incomplete" : "New draft", tone: "warning" };
  return { label: "Draft", tone: "quote" };
};

export function EstimatesPage() {
  const session = useSession();
  const navigate = useNavigate();
  const [params, setParams] = useSearchParams();
  const allowed = canEstimate(session);
  const estimates = useEstimates(session.company.id, allowed);
  const team = useTeam(session.company.id);
  const [search, setSearch] = useState("");
  const term = useDeferredValue(search.trim().toLowerCase());
  const creating = params.get("new") === "1";
  const rows = useMemo(
    () =>
      (estimates.data ?? []).filter(
        (e) => !term || String(e.number) === term || [e.title, e.project_type, e.client?.display_name, e.property?.line1, e.property?.city].some((x) => x?.toLowerCase().includes(term)),
      ),
    [estimates.data, term],
  );

  if (!allowed) return <div className="card"><EmptyState icon="calculator" title="Estimating isn't on for you">Ask an owner or admin for the Prepare internal estimates area.</EmptyState></div>;
  if (estimates.isPending) return <ListPageSkeleton columns={6} tabs={0} />;

  return (
    <>
      <PageHeader title="Estimating" actions={<Button variant="primary" icon="plus" onClick={() => setParams({ new: "1" })}>New estimate</Button>} />
      <div className="callout callout-info" style={{ marginBottom: 16 }}>
        <Icon name="calculator" size={20} />
        <div className="grow small" style={{ fontWeight: 400 }}>
          Internal estimates: costs, rates and profit stay here. A customer sees only the quote or proposal you make from an estimate, after you review it in Quotes & Proposals.
        </div>
      </div>
      <div className="toolbar">
        <div className="input-group">
          <span className="addon"><Icon name="search" size={16} /></span>
          <input className="input" type="search" placeholder="Search by #, title, customer or address" value={search} onChange={(e) => setSearch(e.target.value)} aria-label="Search estimates" />
        </div>
      </div>
      {estimates.error ? (
        <div className="card"><ErrorState error={estimates.error} onRetry={() => estimates.refetch()} /></div>
      ) : rows.length === 0 ? (
        <div className="card">
          <EmptyState icon="calculator" title={term ? "No estimates match" : "No estimates yet"} action={!term && <Button icon="plus" onClick={() => setParams({ new: "1" })}>New estimate</Button>}>
            {term ? "Try another search." : "Start one from a request (Requests → a request → Start estimate) or here."}
          </EmptyState>
        </div>
      ) : (
        <div className="card">
          <table className="table table-stack" aria-label="Estimates">
            <thead><tr><th>#</th><th>Estimate</th><th>Customer</th><th>Estimator</th><th>Version</th><th>Request / outcome</th><th>Updated</th></tr></thead>
            <tbody>
              {rows.map((e) => {
                const status = estimateStatus(e);
                const current = e.versions.find((v) => v.id === e.current_version_id);
                return (
                  <tr key={e.id} className="row-link" onClick={() => navigate(`/estimates/${e.id}`)}>
                    <td className="muted tabular" style={{ width: 56 }}>{e.number}</td>
                    <td>
                      <Link className="cell-link" to={`/estimates/${e.id}`} onClick={(ev) => ev.stopPropagation()}>{e.title}</Link>
                      <div className="muted small">{[e.project_type, e.property ? [e.property.line1, e.property.city].filter(Boolean).join(", ") : null].filter(Boolean).join(" · ")}</div>
                    </td>
                    <td>{e.client?.display_name ?? <span className="muted">—</span>}</td>
                    <td>{memberName(team.data?.find((m) => m.user_id === e.estimator_id)) ?? <span className="muted">—</span>}</td>
                    <td>v{current?.number ?? "—"} <span className={`pill pill-quiet${status.tone === "warning" ? " text-danger" : ""}`} style={{ fontSize: 12 }}>{status.label}</span></td>
                    <td>{e.request ? <>#{e.request.number} {e.request.stage?.label ?? ""}{e.request.outcome_reason && <div className="muted small">{e.request.outcome_reason}</div>}</> : <span className="muted">No request</span>}</td>
                    <td>{formatDate(e.updated_at)}</td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}
      <NewEstimateDialog open={creating} requestId={params.get("request")} onClose={() => setParams({})} onCreated={(id) => navigate(`/estimates/${id}`, { replace: true })} />
    </>
  );
}

/** New estimate: from a request (its customer, property and title), or on its own. Retrying is safe. */
export function NewEstimateDialog({ open, requestId, onClose, onCreated }: { open: boolean; requestId: string | null; onClose: () => void; onCreated: (id: string) => void }) {
  const session = useSession();
  const queryClient = useQueryClient();
  const [title, setTitle] = useState("");
  const [projectType, setProjectType] = useState("");
  // One key per dialog: pressing Create twice, or retrying after a dropped connection, opens one estimate.
  const [key, setKey] = useState(() => crypto.randomUUID());
  const create = useMutation({
    mutationFn: async () =>
      unwrap(await supabase().rpc("create_estimate", { p_company: session.company.id, p_request_key: key, p_title: title.trim(), p_request: requestId ?? undefined, p_project_type: projectType.trim() || undefined })) as unknown as string,
    onSuccess: (id) => {
      queryClient.invalidateQueries({ queryKey: estimatesKey(session.company.id) });
      setKey(crypto.randomUUID());
      onCreated(id);
    },
  });
  return (
    <Dialog open={open} onClose={onClose} title="New estimate" description={requestId ? "For this request: its customer, property and title come with it." : "An internal estimate. Link it to a request to keep its customer and outcome together."}>
      <form onSubmit={(e) => { e.preventDefault(); create.mutate(); }}>
        <Field label="Title" optional={Boolean(requestId)}><input className="input" value={title} maxLength={200} onChange={(e) => setTitle(e.target.value)} placeholder="House demolition" required={!requestId} /></Field>
        <Field label="Project type" optional><input className="input" value={projectType} maxLength={120} onChange={(e) => setProjectType(e.target.value)} placeholder="Mobile home, pool removal, interior demo…" /></Field>
        <FormError error={create.error} />
        <div className="form-actions">
          <Button onClick={onClose}>Cancel</Button>
          <Button type="submit" variant="primary" loading={create.isPending}>Create estimate</Button>
        </div>
      </form>
    </Dialog>
  );
}

/**
 * Planet Ops Phase 3: from an internal estimate to the customer's document
 * (20261125000100_planet_ops_estimate_handoff.sql).
 *   CreateDocumentDialog  a line-item quote or a proposal, made as an unsent draft from a saved
 *                         estimate version: customer items at their selling prices and the
 *                         customer-facing scope only. It opens in Quotes & Proposals for review.
 *   EstimateDocuments     the documents made from the estimate: what was sent, and accepted.
 *   EstimateLink          on a quote: which estimate version it came from, and Refresh from it
 *                         (unsigned only, after seeing what changes).
 */
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useState } from "react";
import { Link } from "react-router-dom";
import { Button } from "@/components/ui/Button";
import { Dialog } from "@/components/ui/Dialog";
import { FormError } from "@/components/ui/Field";
import { Icon } from "@/components/ui/Icon";
import { EmptyState } from "@/components/ui/States";
import { supabase, unwrap } from "@/lib/api";
import { formatDate, formatMoney } from "@/lib/format";
import { can, useSession } from "@/lib/session";
import { toast } from "@/lib/toast";
import { canEstimate, estimateKey, type VersionRow } from "./data";

// Links in a sentence are underlined, not told apart by color alone (WCAG link-in-text-block).
const U = { textDecoration: "underline" } as const;

export function CreateDocumentDialog({ version, estimateTitle, onClose, onCreated }: { version: Pick<VersionRow, "id" | "number" | "status">; estimateTitle: string; onClose: () => void; onCreated: (quoteId: string) => void }) {
  const session = useSession();
  const queryClient = useQueryClient();
  const [presentation, setPresentation] = useState<"line_items" | "proposal">("proposal");
  const [key] = useState(() => crypto.randomUUID());
  const create = useMutation({
    mutationFn: async () => unwrap(await supabase().rpc("create_quote_from_estimate", { p_version: version.id, p_presentation: presentation, p_request_key: key })) as unknown as string,
    onSuccess: (id) => {
      toast.success("Draft made. Review it before sending: nothing has been sent.", { tone: "quote" });
      queryClient.invalidateQueries({ queryKey: ["quotes", session.company.id] });
      onCreated(id);
    },
  });
  return (
    <Dialog open onClose={onClose} title="Create quote / proposal" description={`From version ${version.number} of "${estimateTitle}". It's made as an unsent draft in Quotes & Proposals, for you to review and send from there.`}>
      <form className="stack" onSubmit={(e) => { e.preventDefault(); create.mutate(); }}>
        <fieldset className="stack-sm" style={{ border: 0, padding: 0, margin: 0 }}>
          <legend className="strong">Document type</legend>
          <label className="row" style={{ gap: 6 }}><input type="radio" name="presentation" checked={presentation === "proposal"} onChange={() => setPresentation("proposal")} />Proposal: the customer scope as a narrative, with the total</label>
          <label className="row" style={{ gap: 6 }}><input type="radio" name="presentation" checked={presentation === "line_items"} onChange={() => setPresentation("line_items")} />Line-item quote: each customer item with its price</label>
        </fieldset>
        <div className="callout callout-info small" style={{ fontWeight: 400 }}>
          <Icon name="lock" size={16} />
          <span>Only customer items and their selling prices, and the scope written for the customer, go onto the document. Wages, costs, rates, markup, risk reserve, owner pay and internal notes stay in the estimate.</span>
        </div>
        {version.status !== "approved" && <span className="small text-danger">This version isn't approved. If your business requires approval (Settings → Estimating), approve it first.</span>}
        <FormError error={create.error} />
        <div className="form-actions">
          <Button onClick={onClose}>Cancel</Button>
          <Button type="submit" variant="primary" loading={create.isPending}>Create draft</Button>
        </div>
      </form>
    </Dialog>
  );
}

interface SummaryDoc {
  quote_id: string;
  number: number;
  presentation: string;
  status: string;
  from_version: number | null;
  sent: Array<{ version: number; total: number; issued_at: string; estimate_version: number | null }>;
  accepted: { total: number; signed_at: string; version: number } | null;
}
export interface Summary {
  summary: { id: string; title: string; updated_at: string; drive_destination: "jobs_bid" | "job"; job_id: string | null; drive_status: string };
  costs_visible: boolean;
  estimate: { id: string; number: number; title: string; project_type: string | null; created_at: string; updated_at: string; estimator: string | null; baseline_version_id: string | null; current_version_id: string };
  customer: { id: string; name: string; email: string | null; phone: string | null } | null;
  property: { id: string; line1: string | null; city: string | null; region: string | null; postal_code: string | null } | null;
  request: { id: string; number: number; title: string; status: string; stage: string | null; stage_kind: string | null; outcome_reason: string | null; outcome_at: string | null; last_contact_at: string | null; next_action: string | null; next_action_on: string | null; next_follow_up: { title: string; due_on: string | null } | null } | null;
  version: {
    id: string; number: number; status: string; saved_at: string | null; approved_at: string | null; calc_status: string;
    scope: Record<string, unknown>; assumptions: Array<{ text: string; source?: string }>; pricing_method: string; owner_pay_method: string;
    pricing_pct: number | null; owner_pct: number | null; burden_pct: number | null;
    totals: { base_cost: number; risk_reserve: number; subtotal: number; markup_amount: number; price_before_owner_pay: number; owner_pay: number; selling_price: number } | null;
    lines: Array<Record<string, unknown>>;
  };
  versions: Array<{ number: number; status: string; created_at: string; saved_at: string | null; approved_at: string | null; baseline: boolean; revision_reason: string | null; base_cost?: number; subtotal?: number; selling_price?: number }>;
  documents: SummaryDoc[];
  jobs: Array<{ id: string; number: number; title: string; estimate_version: number | null }>;
}
export const summaryKey = (id: string) => ["estimate-summary", id];
export const useSummary = (id: string) =>
  useQuery({ queryKey: summaryKey(id), queryFn: async () => unwrap(await supabase().rpc("estimate_summary", { p_estimate: id })) as unknown as Summary });

export function EstimateDocuments({ estimateId }: { estimateId: string }) {
  const summary = useSummary(estimateId);
  const docs = summary.data?.documents ?? [];
  return (
    <section className="card card-pad stack" aria-label="Customer documents">
      <strong>Customer documents made from this estimate</strong>
      <span className="muted small">What was sent and accepted is the document's own; it never changes the estimate, and revising the estimate never changes a document.</span>
      {docs.length === 0 ? (
        <EmptyState inline title="None yet" />
      ) : (
        <table className="table table-stack">
          <thead><tr><th>Document</th><th>From version</th><th>Status</th><th>Sent</th><th>Accepted</th></tr></thead>
          <tbody>
            {docs.map((q) => (
              <tr key={q.quote_id}>
                <td><Link to={`/quotes/${q.quote_id}`} style={U}>{q.presentation === "proposal" ? "Proposal" : "Quote"} #{q.number}</Link></td>
                <td>v{q.from_version ?? "—"}</td>
                <td>{q.status}</td>
                <td>{q.sent.length ? q.sent.map((s) => `${formatMoney(s.total)} (document v${s.version}, ${formatDate(s.issued_at)})`).join("; ") : <span className="muted">Not sent</span>}</td>
                <td>{q.accepted ? `${formatMoney(q.accepted.total)} on ${formatDate(q.accepted.signed_at)}` : <span className="muted">—</span>}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
      {(summary.data?.jobs ?? []).map((j) => (
        <span key={j.id} className="small">Job <Link to={`/jobs/${j.id}`} style={U}>#{j.number} {j.title}</Link> was made from estimate version {j.estimate_version ?? "—"}.</span>
      ))}
    </section>
  );
}

interface Diff { quote_status: string; from_version: number | null; to_version: number; current: Array<{ name: string; amount: number }>; proposed: Array<{ name: string; amount: number }>; current_subtotal: number; proposed_subtotal: number }

/** On a quote or proposal: the estimate it came from, and an explicit refresh for an unsigned one. */
export function EstimateLink({ quote }: { quote: { id: string; status: string; estimate_version_id?: string | null } }) {
  const session = useSession();
  const queryClient = useQueryClient();
  const allowed = canEstimate(session) && can(session, "sales");
  const link = useQuery({
    queryKey: ["quote-estimate", quote.estimate_version_id],
    enabled: Boolean(quote.estimate_version_id) && allowed,
    queryFn: async () => {
      const v = unwrap(await supabase().from("estimate_versions").select("id, number, estimate_id").eq("id", quote.estimate_version_id!).single());
      const e = unwrap(await supabase().from("estimates").select("id, number, title, current_version_id").eq("id", v.estimate_id).single());
      const latest = unwrap(await supabase().from("estimate_versions").select("id, number, status, calc_status").eq("estimate_id", e.id).order("number", { ascending: false }).limit(1).single());
      return { version: v, estimate: e, latest };
    },
  });
  const [diff, setDiff] = useState<Diff | null>(null);
  const preview = useMutation({
    mutationFn: async () => unwrap(await supabase().rpc("estimate_quote_diff", { p_quote: quote.id, p_version: link.data!.latest.id })) as unknown as Diff,
    onSuccess: setDiff,
  });
  const apply = useMutation({
    mutationFn: async (narrative: boolean) => unwrap(await supabase().rpc("refresh_quote_from_estimate", { p_quote: quote.id, p_version: link.data!.latest.id, p_narrative: narrative })),
    onSuccess: () => {
      toast.success(`Refreshed from estimate version ${link.data!.latest.number}. Review it before sending.`, { tone: "quote" });
      setDiff(null);
      queryClient.invalidateQueries();
    },
  });
  if (!quote.estimate_version_id || !allowed || !link.data) return null;
  const { estimate, version, latest } = link.data;
  const unsigned = ["draft", "sent", "changes_requested"].includes(quote.status);
  const newer = latest.number > version.number && latest.calc_status === "ok";
  return (
    <div className="callout callout-info" data-planet-ops="estimate-link">
      <Icon name="calculator" size={20} />
      <div className="grow small" style={{ fontWeight: 400 }}>
        From internal estimate <Link to={`/estimates/${estimate.id}`} style={U}>#{estimate.number} {estimate.title}</Link>, version {version.number}.
        {newer && unsigned && <> Version {latest.number} is newer: refresh to bring its prices in (you'll see the differences first).</>}
        {!unsigned && <> Signed documents keep their prices; a new agreement follows the signing rules.</>}
      </div>
      {newer && unsigned && <Button size="sm" loading={preview.isPending} onClick={() => preview.mutate()}>Refresh from estimate…</Button>}
      {diff && (
        <Dialog open onClose={() => setDiff(null)} title={`Refresh from estimate version ${diff.to_version}?`} description={diff.quote_status === "draft" ? "The draft's lines become the estimate's. Nothing is sent." : "This document was sent: refreshing makes a draft revision the customer can't see or sign until you send it again."}>
          <div className="stack">
            <table className="table" aria-label="What changes">
              <thead><tr><th>Now (version {diff.from_version ?? "—"} or edited)</th><th className="num" /><th>After (version {diff.to_version})</th><th className="num" /></tr></thead>
              <tbody>
                {Array.from({ length: Math.max(diff.current.length, diff.proposed.length) }, (_, i) => (
                  <tr key={i}><td>{diff.current[i]?.name ?? ""}</td><td className="num tabular">{diff.current[i] ? formatMoney(diff.current[i].amount) : ""}</td><td>{diff.proposed[i]?.name ?? ""}</td><td className="num tabular">{diff.proposed[i] ? formatMoney(diff.proposed[i].amount) : ""}</td></tr>
                ))}
                <tr><td><strong>Subtotal</strong></td><td className="num tabular strong">{formatMoney(diff.current_subtotal)}</td><td><strong>Subtotal</strong></td><td className="num tabular strong">{formatMoney(diff.proposed_subtotal)}</td></tr>
              </tbody>
            </table>
            <FormError error={apply.error} />
            <div className="form-actions">
              <Button onClick={() => setDiff(null)}>Keep it as it is</Button>
              <Button loading={apply.isPending} onClick={() => apply.mutate(true)}>Refresh prices and scope</Button>
              <Button variant="primary" loading={apply.isPending} onClick={() => apply.mutate(false)}>Refresh prices</Button>
            </div>
          </div>
        </Dialog>
      )}
      <FormError error={preview.error} />
    </div>
  );
}

export { estimateKey };

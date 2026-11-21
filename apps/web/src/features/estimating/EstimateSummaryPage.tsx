/**
 * Planet Ops Phase 3: the estimate's one internal Estimate Summary (public.estimate_summary), readable
 * and printable. Private: Estimating only, costs only with "See estimating costs". It shows the
 * calculated price apart from what was actually sent and accepted, every version with its dates, the
 * request's outcome, last contact and next follow-up, and where its permanent copy is to go once
 * Drive backup exists (Phase 4). It says plainly that it hasn't been backed up.
 */
import { SECTION_LABELS, UNIT_LABELS, type EstimateSection } from "@crewtavo/core/estimating";
import { Link, useParams } from "react-router-dom";
import { Button } from "@/components/ui/Button";
import { BackLink, PageHeader } from "@/components/ui/PageHeader";
import { DetailSkeleton } from "@/components/ui/Skeleton";
import { PageError } from "@/components/ui/States";
import { formatDate, formatDateTime, formatMoney } from "@/lib/format";
import { useSummary } from "./Handoff";

const pct = (x: number | null | undefined) => (x === null || x === undefined ? "—" : `${(Number(x) * 100).toFixed(2).replace(/\.?0+$/, "")}%`);
const val = (x: unknown) => (x === null || x === undefined || x === "" ? null : String(x));

export function EstimateSummaryPage() {
  const { id = "" } = useParams();
  const summary = useSummary(id);
  const s = summary.data;
  if (summary.isPending) return <DetailSkeleton />;
  if (summary.error || !s) return <PageError error={summary.error} onRetry={() => summary.refetch()} back={<BackLink to={`/estimates/${id}`}>Estimate</BackLink>} />;
  const v = s.version;
  const scope = v.scope as Record<string, unknown>;
  const scopeRows: Array<[string, unknown]> = [
    ["Project type", s.estimate.project_type], ["Area (sq ft)", scope.area_sqft], ["Materials and layers", scope.materials], ["Foundation", scope.foundation],
    ["Access", scope.access], ["Utilities", scope.utilities], ["Hazards", scope.hazards], ["Testing assumptions", scope.testing],
    ["Included", scope.inclusions], ["Not included", scope.exclusions], ["Site notes", scope.site_notes],
  ];
  return (
    <>
      <BackLink to={`/estimates/${id}`}>Estimate #{s.estimate.number}</BackLink>
      <PageHeader title={s.summary.title} actions={<Button icon="printer" onClick={() => window.print()}>Print or save PDF</Button>} />
      <div className="stack-lg" data-planet-ops="estimate-summary">
        <div className="callout callout-info no-print small" style={{ fontWeight: 400 }}>
          Internal and private: for people with Estimating{s.costs_visible ? "" : " (costs are hidden from you)"}. Its permanent copy is to go to {s.summary.drive_destination === "job" ? "the job's folder" : "Jobs Bid"} once Drive backup is set up (Phase 4). <strong>It hasn't been backed up.</strong>
        </div>
        <section className="card card-pad stack-sm">
          <strong>Estimate</strong>
          <dl className="kv">
            <dt>Estimate</dt><dd>#{s.estimate.number}, version {v.number} ({v.status === "approved" ? (v.id === s.estimate.baseline_version_id ? "approved original baseline" : "approved revision") : "draft"})</dd>
            <dt>Estimator</dt><dd>{s.estimate.estimator ?? "—"}</dd>
            <dt>Started</dt><dd>{formatDate(s.estimate.created_at)}</dd>
            <dt>Last saved</dt><dd>{v.saved_at ? formatDateTime(v.saved_at) : "—"}</dd>
            <dt>Customer</dt><dd>{s.customer ? <Link to={`/clients/${s.customer.id}`}>{s.customer.name}</Link> : "—"}</dd>
            <dt>Property</dt><dd>{s.property ? [s.property.line1, s.property.city, s.property.region, s.property.postal_code].filter(Boolean).join(", ") : "—"}</dd>
            <dt>Request</dt><dd>{s.request ? <Link to={`/requests/${s.request.id}`}>#{s.request.number} {s.request.title}</Link> : "—"}</dd>
            <dt>Outcome</dt><dd>{s.request?.stage ?? "—"}{s.request?.outcome_reason ? `: ${s.request.outcome_reason}` : ""}</dd>
            <dt>Last contact</dt><dd>{s.request?.last_contact_at ? formatDateTime(s.request.last_contact_at) : "None logged"}</dd>
            <dt>Next follow-up</dt><dd>{s.request?.next_follow_up ? `${s.request.next_follow_up.title}${s.request.next_follow_up.due_on ? `, ${formatDate(s.request.next_follow_up.due_on)}` : ""}` : s.request?.next_action ? `${s.request.next_action}${s.request.next_action_on ? `, ${formatDate(s.request.next_action_on)}` : ""}` : "—"}</dd>
          </dl>
        </section>
        <section className="card card-pad stack-sm">
          <strong>Scope, conditions and assumptions</strong>
          <dl className="kv">{scopeRows.filter(([, x]) => val(x)).map(([k, x]) => <div key={k} style={{ display: "contents" }}><dt>{k}</dt><dd className="pre-wrap">{val(x)}</dd></div>)}</dl>
          {Array.isArray(scope.structures) && (scope.structures as Array<{ name: string; sqft?: string; stories?: string }>).length > 0 && (
            <span>Structures: {(scope.structures as Array<{ name: string; sqft?: string; stories?: string }>).map((st) => `${st.name}${st.sqft ? ` (${st.sqft} sq ft)` : ""}${st.stories ? `, ${st.stories} stories` : ""}`).join("; ")}</span>
          )}
          {v.assumptions.length > 0 && <ul style={{ margin: 0 }}>{v.assumptions.map((a, i) => <li key={i}>{a.text}{a.source ? ` (${a.source})` : ""}</li>)}</ul>}
          {Array.isArray(scope.files) && (scope.files as Array<{ label: string; url?: string }>).length > 0 && (
            <span>Files: {(scope.files as Array<{ label: string; url?: string }>).map((f, i) => (f.url ? <a key={i} href={f.url} target="_blank" rel="noreferrer" style={{ marginRight: 8 }}>{f.label || f.url}</a> : <span key={i} style={{ marginRight: 8 }}>{f.label}</span>))}</span>
          )}
        </section>
        <section className="card card-pad stack-sm">
          <strong>Itemized estimate (version {v.number})</strong>
          <table className="table table-stack" aria-label="Itemized estimate">
            <thead><tr><th>Section</th><th>Line</th><th className="num">Quantity</th><th>Unit</th>{s.costs_visible && <><th className="num">Unit cost</th><th>Rate as taken</th><th className="num">Base</th><th className="num">Risk</th><th className="num">Selling share</th></>}</tr></thead>
            <tbody>
              {v.lines.map((l, i) => {
                const rate = l.rate as { name?: string; effective_from?: string; unit_cost?: number } | null;
                const qty = [l.count, l.hours, l.days].filter((x) => x !== null && x !== undefined).join(" × ");
                return (
                  <tr key={i}>
                    <td>{SECTION_LABELS[l.section as EstimateSection]}</td>
                    <td>{String(l.name)}{l.notes ? <div className="muted small">{String(l.notes)}</div> : null}{l.est_tons || l.est_loose_cy || l.container_cy ? <div className="muted small">{[l.est_tons && `${l.est_tons} est. tons`, l.est_loose_cy && `${l.est_loose_cy} est. loose CY`, l.container_cy && `${l.container_cy} CY container`, l.expected_loads && `${l.expected_loads} loads`].filter(Boolean).join(" · ")}</div> : null}</td>
                    <td className="num tabular">{qty || "—"}</td>
                    <td>{UNIT_LABELS[l.unit as keyof typeof UNIT_LABELS] ?? String(l.unit)}</td>
                    {s.costs_visible && (
                      <>
                        <td className="num tabular">{l.unit_cost === null || l.unit_cost === undefined ? "No rate" : formatMoney(Number(l.unit_cost))}</td>
                        <td className="small">{rate ? `${rate.name} from ${rate.effective_from ? formatDate(rate.effective_from) : "—"}` : "Typed"}</td>
                        <td className="num tabular">{formatMoney(Number(l.base ?? 0))}</td>
                        <td className="num tabular">{formatMoney(Number(l.risk ?? 0))}{l.risk_pct ? <span className="muted small"> ({pct(Number(l.risk_pct))})</span> : null}</td>
                        <td className="num tabular">{formatMoney(Number(l.price ?? 0))}</td>
                      </>
                    )}
                  </tr>
                );
              })}
            </tbody>
          </table>
          {s.costs_visible && v.totals && (
            <dl className="kv">
              <dt>Base cost</dt><dd className="tabular">{formatMoney(v.totals.base_cost)}</dd>
              <dt>Risk reserve</dt><dd className="tabular">{formatMoney(v.totals.risk_reserve)}</dd>
              <dt>Pricing method</dt><dd>{v.pricing_method === "margin" ? `Target margin ${pct(v.pricing_pct)}` : `Markup ${pct(v.pricing_pct)} on the subtotal`}</dd>
              <dt>Markup</dt><dd className="tabular">{formatMoney(v.totals.markup_amount)}</dd>
              <dt>Owner pay</dt><dd>{v.owner_pay_method === "percent_of_price" ? `${pct(v.owner_pct)} of the price before owner pay: ${formatMoney(v.totals.owner_pay)}` : "None"}</dd>
              {v.burden_pct ? <><dt>Labor burden</dt><dd>{pct(v.burden_pct)} on labor whose rate excludes it</dd></> : null}
              <dt><strong>Calculated selling price</strong></dt><dd className="tabular strong">{formatMoney(v.totals.selling_price)} <span className="muted small">(calculated; not a price sent)</span></dd>
              <dt>Profit if the reserve isn't used</dt><dd className="tabular">{formatMoney(v.totals.markup_amount + v.totals.risk_reserve)}</dd>
            </dl>
          )}
        </section>
        <section className="card card-pad stack-sm">
          <strong>Revision and pricing history</strong>
          <table className="table table-stack" aria-label="Revision history">
            <thead><tr><th>Version</th><th>Status</th><th>Saved</th><th>Approved</th>{s.costs_visible && <><th className="num">Base cost</th><th className="num">Calculated price</th></>}<th>Why</th></tr></thead>
            <tbody>
              {s.versions.map((x) => (
                <tr key={x.number}>
                  <td>v{x.number}{x.baseline ? " · original baseline" : ""}</td>
                  <td>{x.status}</td>
                  <td>{x.saved_at ? formatDate(x.saved_at) : "—"}</td>
                  <td>{x.approved_at ? formatDate(x.approved_at) : "—"}</td>
                  {s.costs_visible && <><td className="num tabular">{x.base_cost === undefined || x.base_cost === null ? "—" : formatMoney(x.base_cost)}</td><td className="num tabular">{x.selling_price === undefined || x.selling_price === null ? "—" : formatMoney(x.selling_price)}</td></>}
                  <td className="small">{x.revision_reason ?? ""}</td>
                </tr>
              ))}
            </tbody>
          </table>
          <strong>Prices sent and accepted</strong>
          {s.documents.length === 0 ? <span className="muted small">No quote or proposal has been made from this estimate.</span> : (
            <table className="table table-stack" aria-label="Prices sent and accepted">
              <thead><tr><th>Document</th><th>Sent</th><th>Accepted</th></tr></thead>
              <tbody>
                {s.documents.map((q) => (
                  <tr key={q.quote_id}>
                    <td><Link to={`/quotes/${q.quote_id}`}>{q.presentation === "proposal" ? "Proposal" : "Quote"} #{q.number}</Link> <span className="muted small">from v{q.from_version ?? "—"}, {q.status}</span></td>
                    <td>{q.sent.length ? q.sent.map((x) => `${formatMoney(x.total)} on ${formatDate(x.issued_at)} (estimate v${x.estimate_version ?? "—"})`).join("; ") : <span className="muted">Not sent</span>}</td>
                    <td>{q.accepted ? `${formatMoney(q.accepted.total)}, signed ${formatDate(q.accepted.signed_at)}` : <span className="muted">Not accepted</span>}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
          {s.jobs.map((j) => <span key={j.id} className="small">Job <Link to={`/jobs/${j.id}`}>#{j.number}</Link> made from estimate version {j.estimate_version ?? "—"}.</span>)}
        </section>
      </div>
    </>
  );
}

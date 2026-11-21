/**
 * Planet Ops Phase 2: the pipeline's report and pricing history (pipeline_report,
 * pipeline_pricing_history). The dates are defined, and said on screen: requests that came in in the
 * period; outcomes decided in it; open requests as they are now. A lost or unanswered price is sales
 * evidence, never an actual cost or a benchmark.
 */
import { useQuery } from "@tanstack/react-query";
import { useState } from "react";
import { Link } from "react-router-dom";
import { Button } from "@/components/ui/Button";
import { Field } from "@/components/ui/Field";
import { Loading, Skeleton } from "@/components/ui/Skeleton";
import { EmptyState, ErrorState } from "@/components/ui/States";
import { supabase, unwrap } from "@/lib/api";
import { formatDate, formatMoney } from "@/lib/format";
import { useSession } from "@/lib/session";
import { memberName, REQUEST_SOURCES, useTeam } from "../requests/RequestsPage";
import { companyToday } from "./data";

interface Report {
  requests: number;
  by_source: Record<string, number>;
  by_stage: Array<{ label: string; count: number }>;
  open: number;
  aging: { average_days: number | null; oldest_days: number | null; average_days_in_stage: number | null; over_30_days: number };
  response: { responded: number; not_yet: number; median_hours: number | null };
  won: number;
  lost: number;
  unqualified: number;
  conversion: number | null;
  conversion_by_source: Record<string, number>;
  won_value: number;
  lost_value: number;
}

const PERIODS = [
  { days: 30, label: "30 days" },
  { days: 90, label: "90 days" },
  { days: 365, label: "12 months" },
];
const source = (s: string) => REQUEST_SOURCES[s] ?? (s === "unknown" ? "Not recorded" : s);
const shift = (iso: string, days: number) => new Date(Date.parse(`${iso}T12:00:00Z`) - days * 86_400_000).toISOString().slice(0, 10);

export function PipelineReport() {
  const { company } = useSession();
  const [days, setDays] = useState(30);
  const to = companyToday(company.timezone);
  const from = shift(to, days - 1);
  const report = useQuery({
    queryKey: ["pipeline-report", company.id, from, to],
    queryFn: async () => unwrap(await supabase().rpc("pipeline_report", { p_company: company.id, p_from: from, p_to: to })) as unknown as Report,
  });
  const r = report.data;
  return (
    <div className="stack" data-planet-ops="pipeline-report">
      <div className="toolbar">
        <div className="segmented" role="group" aria-label="Period">
          {PERIODS.map((p) => <button key={p.days} type="button" aria-pressed={days === p.days} onClick={() => setDays(p.days)}>{p.label}</button>)}
        </div>
        <span className="muted small">{formatDate(from)} to {formatDate(to)}</span>
      </div>
      {report.error && <div className="card"><ErrorState error={report.error} onRetry={() => report.refetch()} /></div>}
      {!r ? (
        <Loading><div className="stat-row">{[0, 1, 2, 3].map((i) => <Skeleton key={i} height={88} radius={8} />)}</div></Loading>
      ) : (
        <>
          <div className="stat-row">
            <div className="card stat"><div className="label">Requests in</div><div className="value">{r.requests}</div><div className="hint">came in in the period</div></div>
            <div className="card stat"><div className="label">First response</div><div className="value">{r.response.median_hours == null ? "—" : `${r.response.median_hours} h`}</div><div className="hint">median · {r.response.not_yet} not yet</div></div>
            <div className="card stat"><div className="label">Conversion</div><div className="value">{r.conversion == null ? "—" : `${Math.round(r.conversion * 100)}%`}</div><div className="hint">won ÷ (won + lost) decided in the period · {r.won} won, {r.lost} lost</div></div>
            <div className="card stat"><div className="label">Won value</div><div className="value">{formatMoney(r.won_value)}</div><div className="hint">lost: {formatMoney(r.lost_value)}</div></div>
          </div>
          <div className="two-col">
            <section className="card card-pad stack-sm wide">
              <strong>Requests in, by source</strong>
              {Object.keys(r.by_source).length === 0 ? <span className="muted small">None in this period.</span> : (
                <table className="table" aria-label="Requests by source">
                  <thead><tr><th>Source</th><th className="num">Requests</th><th className="num">Conversion</th></tr></thead>
                  <tbody>{Object.entries(r.by_source).sort((a, b) => b[1] - a[1]).map(([s, n]) => (
                    <tr key={s}><td>{source(s)}</td><td className="num tabular">{n}</td><td className="num tabular">{r.conversion_by_source[s] == null ? "—" : `${Math.round(r.conversion_by_source[s] * 100)}%`}</td></tr>
                  ))}</tbody>
                </table>
              )}
              <strong>Where they are now</strong>
              <table className="table" aria-label="Requests in, by stage now">
                <tbody>{r.by_stage.map((s) => <tr key={s.label}><td>{s.label}</td><td className="num tabular">{s.count}</td></tr>)}</tbody>
              </table>
            </section>
            <aside className="card card-pad stack-sm narrow">
              <strong>Open now</strong>
              <dl className="kv">
                <dt>Open requests</dt><dd className="tabular">{r.open}</dd>
                <dt>Average age</dt><dd className="tabular">{r.aging.average_days == null ? "—" : `${r.aging.average_days} days`}</dd>
                <dt>Oldest</dt><dd className="tabular">{r.aging.oldest_days == null ? "—" : `${r.aging.oldest_days} days`}</dd>
                <dt>Average in its stage</dt><dd className="tabular">{r.aging.average_days_in_stage == null ? "—" : `${r.aging.average_days_in_stage} days`}</dd>
                <dt>Over 30 days old</dt><dd className="tabular">{r.aging.over_30_days}</dd>
                <dt>Unqualified</dt><dd className="tabular">{r.unqualified} in the period</dd>
              </dl>
              <span className="muted small">Value is the quoted amount: the signed price, else the latest sent. Unqualified requests aren't in the conversion.</span>
            </aside>
          </div>
        </>
      )}
    </div>
  );
}

interface PriceRow {
  request_id: string; request_number: number; request_title: string; service: string | null; city: string | null; region: string | null;
  quote_id: string; quote_number: number; presentation: string; amount: number; sent_at: string; estimator_id: string | null; outcome: string; outcome_reason: string | null;
}
const OUTCOMES: Record<string, string> = { open: "Awaiting response", nurture: "Nurture/on hold", won: "Won", lost: "Lost", unqualified: "Unqualified" };

export function PricingHistory() {
  const { company } = useSession();
  const team = useTeam(company.id);
  const [f, setF] = useState({ service: "", location: "", from: "", to: "", estimator: "", outcome: "" });
  const [applied, setApplied] = useState(f);
  const rows = useQuery({
    queryKey: ["pipeline-pricing", company.id, applied],
    queryFn: async () =>
      unwrap(await supabase().rpc("pipeline_pricing_history", {
        p_company: company.id,
        p_service: applied.service.trim() || undefined,
        p_location: applied.location.trim() || undefined,
        p_from: applied.from || undefined,
        p_to: applied.to || undefined,
        p_estimator: applied.estimator || undefined,
        p_outcome: applied.outcome || undefined,
      })) as PriceRow[],
  });
  return (
    <div className="stack" data-planet-ops="pricing-history">
      <div className="callout callout-info"><div className="grow small" style={{ fontWeight: 400 }}>Prices sent to customers on requests, won or not. A lost or unanswered price is sales evidence, not what a job actually cost, and isn't a production benchmark.</div></div>
      <form className="card card-pad row wrap" style={{ gap: 8, alignItems: "end" }} onSubmit={(e) => { e.preventDefault(); setApplied(f); }}>
        <Field label="Service" optional><input className="input input-sm" value={f.service} onChange={(e) => setF({ ...f, service: e.target.value })} placeholder="Demolition" /></Field>
        <Field label="Location" optional><input className="input input-sm" value={f.location} onChange={(e) => setF({ ...f, location: e.target.value })} placeholder="City, state or zip" /></Field>
        <Field label="Sent from" optional><input className="input input-sm" type="date" value={f.from} onChange={(e) => setF({ ...f, from: e.target.value })} /></Field>
        <Field label="Sent to" optional><input className="input input-sm" type="date" value={f.to} onChange={(e) => setF({ ...f, to: e.target.value })} /></Field>
        <Field label="Estimator" optional>
          <select className="select input-sm" value={f.estimator} onChange={(e) => setF({ ...f, estimator: e.target.value })}>
            <option value="">Anyone</option>
            {(team.data ?? []).map((m) => <option key={m.user_id} value={m.user_id}>{memberName(m)}</option>)}
          </select>
        </Field>
        <Field label="Outcome" optional>
          <select className="select input-sm" value={f.outcome} onChange={(e) => setF({ ...f, outcome: e.target.value })}>
            <option value="">Any</option>
            {Object.entries(OUTCOMES).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
          </select>
        </Field>
        <Button type="submit" size="sm" variant="primary">Show</Button>
      </form>
      {rows.error && <div className="card"><ErrorState error={rows.error} onRetry={() => rows.refetch()} /></div>}
      <div className="card">
        {rows.isPending ? <div className="card-pad"><Skeleton height={60} /></div> : (rows.data ?? []).length === 0 ? (
          <EmptyState inline title="No prices match" />
        ) : (
          <table className="table table-stack" aria-label="Pricing history">
            <thead><tr><th>Request</th><th>Service</th><th>Location</th><th>Sent</th><th>Estimator</th><th>Outcome</th><th className="num">Price</th></tr></thead>
            <tbody>
              {(rows.data ?? []).map((p) => (
                <tr key={p.quote_id}>
                  <td><Link className="cell-link" to={`/requests/${p.request_id}`}>#{p.request_number} {p.request_title}</Link><div className="muted small"><Link to={`/quotes/${p.quote_id}`}>{p.presentation === "proposal" ? "Proposal" : "Quote"} #{p.quote_number}</Link></div></td>
                  <td>{p.service ?? <span className="muted">—</span>}</td>
                  <td>{[p.city, p.region].filter(Boolean).join(", ") || <span className="muted">—</span>}</td>
                  <td>{formatDate(p.sent_at)}</td>
                  <td>{p.estimator_id ? memberName(team.data?.find((m) => m.user_id === p.estimator_id)) : <span className="muted">—</span>}</td>
                  <td>{OUTCOMES[p.outcome] ?? p.outcome}{p.outcome_reason && <div className="muted small">{p.outcome_reason}</div>}</td>
                  <td className="num tabular">{formatMoney(p.amount)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>
    </div>
  );
}

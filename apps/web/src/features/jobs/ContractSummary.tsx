/**
 * Planet Ops Phase 1d: the job's contract, each figure kept to its meaning (public.job_contract_summary):
 * the original signed agreement, each change order and its state, the finalized changes (credits
 * included, each once), the revised contract total, and, for those with invoices access, what's been
 * invoiced, paid and is still owed, and what's left to invoice. A revised total isn't an invoice, a
 * payment or a balance; unsigned, declined, cancelled and changes-requested change orders count for
 * nothing.
 */
import { useQuery } from "@tanstack/react-query";
import { Link } from "react-router-dom";
import { supabase, unwrap } from "@/lib/api";
import { formatMoneyCents } from "@/lib/format";

interface Summary {
  original: { quote_id: string; number: number; title: string; amount: number; signed_at: string | null; version_number: number | null } | null;
  original_amount: number;
  change_orders: Array<{ quote_id: string; number: number; title: string; state: string; amount: number }>;
  finalized_changes: number;
  revised_total: number;
  invoices_visible: boolean;
  invoiced: number | null;
  paid: number | null;
  outstanding: number | null;
  not_yet_invoiced: number | null;
}

const STATE: Record<string, string> = {
  finalized: "Finalized",
  awaiting_countersign: "Signed, awaiting countersignature",
  awaiting_signature: "Awaiting customer signature",
  changes_requested: "Changes requested",
  draft: "Draft",
  declined: "Declined",
  cancelled: "Cancelled",
};

export function ContractSummary({ jobId }: { jobId: string }) {
  const summary = useQuery({ queryKey: ["job", jobId, "contract-summary"], queryFn: async () => unwrap(await supabase().rpc("job_contract_summary", { p_job: jobId })) as unknown as Summary });
  const s = summary.data;
  if (!s) return null;
  const row = (label: string, value: number | null, opts: { strong?: boolean; note?: string } = {}) => (
    <div className="row" style={{ justifyContent: "space-between", gap: 12 }}>
      <span className={opts.strong ? "strong" : undefined}>{label}{opts.note && <span className="muted small"> · {opts.note}</span>}</span>
      <span className={`tabular${opts.strong ? " strong" : ""}`}>{value === null ? "—" : formatMoneyCents(Number(value))}</span>
    </div>
  );
  return (
    <section className="stack" data-planet-ops="contract-summary">
      <h2 className="section-title">Contract</h2>
      <div className="card card-pad stack-sm">
        {row("Original signed agreement", s.original_amount, { note: s.original ? `#${s.original.number}${s.original.version_number ? `, version ${s.original.version_number}` : ""}` : "no signed agreement on this job" })}
        {s.change_orders.map((o) => (
          <div key={o.quote_id} className="row" style={{ justifyContent: "space-between", gap: 12 }}>
            <Link to={`/quotes/${o.quote_id}`} className="small">Change order #{o.number} · {o.title.replace(/^Change order: /, "")} <span className="muted">({STATE[o.state] ?? o.state})</span></Link>
            <span className={`tabular small${o.state === "finalized" ? "" : " muted"}`} style={{ textDecoration: o.state === "finalized" ? undefined : "none" }}>{formatMoneyCents(Number(o.amount))}{o.state === "finalized" ? "" : " (not counted)"}</span>
          </div>
        ))}
        {row("Finalized changes", s.finalized_changes, { note: "signed change orders, credits included" })}
        {row("Revised contract total", s.revised_total, { strong: true })}
        {s.invoices_visible ? (
          <>
            <hr className="divider" />
            {row("Invoiced", s.invoiced)}
            {row("Paid", s.paid)}
            {row("Outstanding on invoices", s.outstanding)}
            {row("Not yet invoiced", s.not_yet_invoiced, { note: "of the revised total" })}
          </>
        ) : (
          <span className="muted small">Invoices and payments are shown to people with invoices access.</span>
        )}
        <span className="muted small">The revised total is the agreement, not a bill: invoices and payments come from billing.</span>
      </div>
    </section>
  );
}

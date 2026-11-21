/**
 * Planet Ops Phase 4: on a job, for the office with Job costs: the job's figures kept apart (original
 * estimate, budgets, actual costs by status, contract, invoiced, paid; a missing figure says so), its
 * receipts, invoices, tickets and photos with their review, the disposal register, and where each file
 * stands in the PDOS Drive record. ReviewDialog is also the review queue's (CostReviewPage).
 */
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useRef, useState } from "react";
import { Button } from "@/components/ui/Button";
import { Dialog } from "@/components/ui/Dialog";
import { Field, FormError } from "@/components/ui/Field";
import { supabase, unwrap } from "@/lib/api";
import { formatDate, formatMoneyCents } from "@/lib/format";
import { useSession } from "@/lib/session";
import { toast } from "@/lib/toast";
import { CATEGORIES, DOCUMENT_COLUMNS, KIND_LABELS, reviewsCosts, uploadCostDocument, type CostDocument, type CostKind, type DisposalTicket, type Financials } from "./data";

const money = (n: number | null | undefined) => (n === null || n === undefined ? <span className="muted">Not recorded</span> : formatMoneyCents(n));
const qty = (n: number | null | undefined, unit: string) => (n === null || n === undefined ? <span className="muted">—</span> : `${Number(n).toLocaleString()} ${unit}`);

export function JobCostsPanel({ jobId }: { jobId: string }) {
  const session = useSession();
  const allowed = reviewsCosts(session);
  const fin = useQuery({ queryKey: ["job-financials", jobId], enabled: allowed, queryFn: async () => unwrap(await supabase().rpc("job_financials" as never, { p_job: jobId } as never)) as unknown as Financials });
  const docs = useQuery({ queryKey: ["cost-documents", jobId], enabled: allowed, queryFn: async () => unwrap(await supabase().from("cost_documents" as never).select(DOCUMENT_COLUMNS).eq("job_id", jobId).order("uploaded_at", { ascending: false })) as unknown as CostDocument[] });
  const tickets = useQuery({ queryKey: ["disposal-tickets", jobId], enabled: allowed, queryFn: async () => unwrap(await supabase().from("disposal_tickets" as never).select("*").eq("job_id", jobId).order("load_date")) as unknown as DisposalTicket[] });
  const backup = useQuery({ queryKey: ["pdos-files", jobId], enabled: allowed, queryFn: async () => unwrap(await supabase().from("pdos_files" as never).select("id, source_kind, file_name, destination, status, last_error, backed_up_at").eq("job_id", jobId)) as unknown as Array<{ id: string; source_kind: string; file_name: string; destination: string; status: string; last_error: string | null; backed_up_at: string | null }> });
  const [reviewing, setReviewing] = useState<CostDocument | null>(null);
  const [addingTicket, setAddingTicket] = useState(false);
  if (!allowed) return null;
  const f = fin.data;
  return (
    <section className="card card-pad stack" aria-label="Job costs and PDOS records" data-planet-ops="job-costs">
      <strong>Job costs (Planet Ops)</strong>
      {fin.error ? <FormError error={fin.error} /> : f && (
        <dl className="kv" aria-label="Job figures">
          <dt>Original approved estimate (cost)</dt><dd>{f.original_estimate ? <>{f.estimate_costs_visible ? money(f.original_estimate.base_cost) : "Hidden (estimating costs)"} <span className="muted small">v{f.original_estimate.version}</span></> : <span className="muted">No approved estimate</span>}</dd>
          <dt>Job budget (its estimate version)</dt><dd>{f.job_estimate ? <>{f.estimate_costs_visible ? money(f.job_estimate.base_cost) : "Hidden"} <span className="muted small">v{f.job_estimate.version}, {f.job_estimate.status === "locked" ? "used for the document, not approved" : f.job_estimate.status}</span></> : <span className="muted">None (made without an estimate)</span>}</dd>
          {f.latest_approved_revision && <><dt>Latest approved revision</dt><dd>{f.estimate_costs_visible ? money(f.latest_approved_revision.base_cost) : "Hidden"} <span className="muted small">v{f.latest_approved_revision.version}</span></dd></>}
          <dt>Actual costs, approved</dt><dd>{money(f.actual_costs?.approved)}</dd>
          <dt>Provisional (not reviewed)</dt><dd>{money(f.actual_costs?.provisional)}</dd>
          <dt>Committed (not yet a cost)</dt><dd>{money(f.actual_costs?.committed)}</dd>
          <dt>Contract value</dt><dd>{money(f.contract_value)}</dd>
          <dt>Invoiced</dt><dd>{money(f.invoiced)}</dd>
          <dt>Paid</dt><dd>{money(f.paid)}</dd>
        </dl>
      )}
      <span className="muted small">Labor from time entries is on the job's costs card. A figure that isn't recorded says so: it isn't $0.</span>

      <div className="row wrap" style={{ gap: 8, justifyContent: "space-between" }}>
        <strong>Receipts, invoices, tickets and photos</strong>
        <UploadButton jobId={jobId} />
      </div>
      {(docs.data ?? []).length === 0 ? <span className="muted small">Nothing uploaded for this job yet.</span> : (
        <table className="table table-stack" aria-label="Cost documents">
          <thead><tr><th>File</th><th>Suggested</th><th>Reviewed</th><th>Status</th><th /></tr></thead>
          <tbody>
            {(docs.data ?? []).map((d) => (
              <tr key={d.id}>
                <td>{KIND_LABELS[d.kind]} <span className="muted small">{d.file_name ?? ""} · {formatDate(d.uploaded_at)}</span></td>
                <td className="small">{d.suggested ? `${d.suggested.vendor ?? "?"} · ${d.suggested.category ?? "?"} · ${d.suggested.total ?? "?"}` : <span className="muted">No suggestion</span>}</td>
                <td className="small">{d.review_status === "pending" ? "—" : `${d.vendor ?? ""} · ${d.category ?? ""} · ${d.total ?? ""}`}</td>
                <td>{d.review_status.replace("_", " ")}</td>
                <td><Button size="sm" onClick={() => setReviewing(d)}>Review</Button></td>
              </tr>
            ))}
          </tbody>
        </table>
      )}

      <div className="row wrap" style={{ gap: 8, justifyContent: "space-between" }}>
        <strong>Disposal register</strong>
        <Button size="sm" icon="plus" onClick={() => setAddingTicket(true)}>Add ticket</Button>
      </div>
      {f?.disposal && (
        <dl className="kv small" aria-label="Disposal totals">
          <dt>Loads</dt><dd>{f.disposal.loads ?? 0} ({f.disposal.unweighed_loads ?? 0} not weighed)</dd>
          <dt>Weighed tons</dt><dd>{qty(f.disposal.weighed_tons, "t")}</dd>
          <dt>Reported loose volume</dt><dd>{qty(f.disposal.nonmetal_reported_loose_cy, "CY")} non-metal, {qty(f.disposal.metal_reported_loose_cy, "CY")} metal</dd>
          <dt>Nominal container capacity</dt><dd>{qty(f.disposal.nominal_container_capacity_cy, "CY")} <span className="muted">(container size, not debris)</span></dd>
          <dt>Tipping / hauling / credits</dt><dd>{money(f.disposal.tipping_fees)} / {money(f.disposal.hauling_charges)} / {money(f.disposal.credits)}</dd>
          <dt>Disposal $ per weighed ton</dt><dd>{money(f.disposal.disposal_rate_per_ton)}</dd>
          <dt>Delivered fill</dt><dd>{f.disposal.delivered_fill_loads ?? 0} loads, {qty(f.disposal.delivered_fill_tons, "t")} (not debris)</dd>
          {Number(f.disposal.tickets_without_cost) > 0 && <><dt className="text-danger">Tickets with charges not in costs</dt><dd className="text-danger">{f.disposal.tickets_without_cost}</dd></>}
        </dl>
      )}
      {(tickets.data ?? []).length > 0 && (
        <table className="table table-stack" aria-label="Disposal tickets">
          <thead><tr><th>Date</th><th>Ticket</th><th>Material</th><th className="num">Tons</th><th className="num">Container</th><th className="num">Charges</th><th>Cost</th></tr></thead>
          <tbody>
            {(tickets.data ?? []).map((t) => (
              <tr key={t.id}>
                <td>{formatDate(t.load_date)}</td>
                <td>{t.facility ?? ""} {t.ticket_number ?? ""}{t.direction === "delivered_fill" ? " (fill in)" : ""}</td>
                <td>{t.material_stream ?? ""}{t.is_metal ? " · metal" : ""}</td>
                <td className="num">{t.short_tons ?? <span className="muted">not weighed</span>}</td>
                <td className="num">{t.container_capacity_cy ?? "—"}</td>
                <td className="num">{money((t.tipping_fee ?? 0) + (t.hauling_charge ?? 0) - (t.credit_amount ?? 0))}</td>
                <td>{t.expense_id ? "Counted once" : <span className="muted">Not in costs</span>}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}

      <strong>PDOS Drive record</strong>
      {(backup.data ?? []).length === 0 ? <span className="muted small">No files for this job's folder yet.</span> : (
        <ul className="small" style={{ margin: 0, paddingLeft: 18 }} aria-label="Backup status">
          {(backup.data ?? []).map((b) => <li key={b.id}>{b.file_name} → {b.destination.replace("job_", "").replace("_", " ")}: <strong>{b.status.replace("_", " ")}</strong>{b.last_error ? ` (${b.last_error})` : ""}</li>)}
        </ul>
      )}

      {reviewing && <ReviewDialog document={reviewing} defaultJob={jobId} onClose={() => setReviewing(null)} />}
      {addingTicket && <TicketDialog jobId={jobId} onClose={() => setAddingTicket(false)} />}
    </section>
  );
}

function UploadButton({ jobId }: { jobId: string | null }) {
  const session = useSession();
  const queryClient = useQueryClient();
  const input = useRef<HTMLInputElement>(null);
  const [kind, setKind] = useState<CostKind>("receipt");
  const upload = useMutation({
    mutationFn: async (files: File[]) => Promise.all(files.map((file) => uploadCostDocument(session.company.id, jobId, kind, file))),
    onSuccess: (r) => {
      const again = r.filter((x) => x.duplicate).length;
      toast.success(again ? `${r.length - again} added; ${again} already uploaded (kept once)` : "Uploaded: waiting for review");
      queryClient.invalidateQueries({ queryKey: ["cost-documents"] });
      queryClient.invalidateQueries({ queryKey: ["pdos-files"] });
    },
  });
  return (
    <span className="row" style={{ gap: 6 }}>
      <label className="sr-only" htmlFor={`kind-${jobId ?? "inbox"}`}>File kind</label>
      <select id={`kind-${jobId ?? "inbox"}`} className="select input-sm" value={kind} onChange={(e) => setKind(e.target.value as CostKind)}>
        {Object.entries(KIND_LABELS).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
      </select>
      <input ref={input} type="file" multiple hidden accept="image/*,application/pdf" onChange={(e) => { const files = [...(e.target.files ?? [])]; e.target.value = ""; if (files.length) upload.mutate(files); }} />
      <Button size="sm" icon="upload" loading={upload.isPending} onClick={() => input.current?.click()}>Upload</Button>
      <FormError error={upload.error} />
    </span>
  );
}

export function ReviewDialog({ document: d, defaultJob, onClose }: { document: CostDocument; defaultJob: string | null; onClose: () => void }) {
  const queryClient = useQueryClient();
  const s = d.suggested ?? {};
  const [form, setForm] = useState({
    vendor: d.vendor ?? s.vendor ?? "", document_number: d.document_number ?? s.document_number ?? "", document_date: d.document_date ?? s.document_date ?? "",
    total: String(d.total ?? s.total ?? ""), category: d.category ?? s.category ?? "", note: d.review_note ?? "", not_duplicate_reason: "", duplicate_of: "",
  });
  const [allocations, setAllocations] = useState<Array<{ job_id: string; amount: string }>>(defaultJob ? [{ job_id: defaultJob, amount: String(d.total ?? s.total ?? "") }] : [{ job_id: d.job_id ?? "", amount: "" }]);
  const session = useSession();
  const jobs = useQuery({ queryKey: ["cost-jobs", session.company.id], queryFn: async () => unwrap(await supabase().from("jobs").select("id, number, title").eq("company_id", session.company.id).order("created_at", { ascending: false }).limit(300)) });
  const dupes = useQuery({ queryKey: ["cost-dupes", d.id, form.vendor, form.document_number, form.document_date, form.total], queryFn: async () => unwrap(await supabase().rpc("cost_document_duplicates" as never, { p_document: d.id, p_vendor: form.vendor || null, p_number: form.document_number || null, p_date: form.document_date || null, p_total: form.total ? Number(form.total) : null } as never)) as unknown as Array<{ id: string; vendor: string; document_number: string | null; document_date: string | null; total: number | null; why: string }> });
  const review = useMutation({
    mutationFn: async (decision: string) =>
      unwrap(await supabase().rpc("review_cost_document" as never, {
        p_document: d.id, p_decision: decision,
        p_review: { ...form, total: form.total === "" ? null : form.total, document_date: form.document_date || null },
        p_allocations: decision === "approved" ? allocations.filter((a) => a.job_id && a.amount !== "").map((a) => ({ job_id: a.job_id, amount: Number(a.amount) })) : [],
      } as never)),
    onSuccess: () => {
      toast.success("Reviewed");
      for (const key of ["cost-documents", "job-financials", "cost-review"]) queryClient.invalidateQueries({ queryKey: [key] });
      onClose();
    },
  });
  const set = (patch: Partial<typeof form>) => setForm({ ...form, ...patch });
  const likely = dupes.data ?? [];
  return (
    <Dialog open onClose={onClose} title={`Review ${KIND_LABELS[d.kind].toLowerCase()}`} description={s.category ? `Suggested: ${s.category}${s.confidence ? ` (${Math.round(s.confidence * 100)}% sure)` : ""}. The original file is kept whatever you decide.` : "The original file is kept whatever you decide."}>
      <form className="stack" onSubmit={(e) => { e.preventDefault(); review.mutate("approved"); }}>
        <div className="grid-2">
          <Field label="Vendor"><input className="input" value={form.vendor} onChange={(e) => set({ vendor: e.target.value })} /></Field>
          <Field label="Document number" optional><input className="input" value={form.document_number} onChange={(e) => set({ document_number: e.target.value })} /></Field>
          <Field label="Date"><input className="input" type="date" value={form.document_date} onChange={(e) => set({ document_date: e.target.value })} /></Field>
          <Field label="Total on the document"><input className="input" inputMode="decimal" value={form.total} onChange={(e) => set({ total: e.target.value })} /></Field>
          <Field label="Category">
            <input className="input" list="cost-categories" value={form.category} onChange={(e) => set({ category: e.target.value })} />
            <datalist id="cost-categories">{CATEGORIES.map((c) => <option key={c} value={c} />)}</datalist>
          </Field>
        </div>
        <fieldset className="stack-sm" style={{ border: 0, padding: 0, margin: 0 }}>
          <legend className="strong">Jobs and amounts (anything left is excluded)</legend>
          {allocations.map((a, i) => (
            <div key={i} className="row" style={{ gap: 6 }}>
              <select className="select" aria-label={`Job ${i + 1}`} value={a.job_id} onChange={(e) => setAllocations(allocations.map((x, j) => (j === i ? { ...x, job_id: e.target.value } : x)))}>
                <option value="">Choose a job</option>
                {(jobs.data ?? []).map((j) => <option key={j.id} value={j.id}>#{j.number ?? ""} {j.title}</option>)}
              </select>
              <input className="input" aria-label={`Amount ${i + 1}`} inputMode="decimal" value={a.amount} onChange={(e) => setAllocations(allocations.map((x, j) => (j === i ? { ...x, amount: e.target.value } : x)))} />
            </div>
          ))}
          <Button size="sm" onClick={() => setAllocations([...allocations, { job_id: "", amount: "" }])} style={{ justifySelf: "start" }}>Split with another job</Button>
        </fieldset>
        {likely.length > 0 && (
          <div className="callout callout-warning small" role="status">
            <span>Looks like {likely.length === 1 ? "a document" : `${likely.length} documents`} already entered ({likely.map((x) => `${x.vendor} ${x.document_number ?? ""} ${x.total ?? ""}: ${x.why}`).join("; ")}).</span>
            <Field label="Why it isn't a duplicate" optional><input className="input" value={form.not_duplicate_reason} onChange={(e) => set({ not_duplicate_reason: e.target.value })} /></Field>
            <Button size="sm" onClick={() => { set({ duplicate_of: likely[0]!.id }); review.mutate("duplicate"); }}>It's a duplicate</Button>
          </div>
        )}
        <Field label="Note" optional><input className="input" value={form.note} onChange={(e) => set({ note: e.target.value })} /></Field>
        <FormError error={review.error} />
        <div className="form-actions">
          <Button onClick={() => review.mutate("rejected")}>Reject</Button>
          <Button onClick={() => review.mutate("reference_only")}>Reference only</Button>
          <Button type="submit" variant="primary" loading={review.isPending}>Approve</Button>
        </div>
      </form>
    </Dialog>
  );
}

function TicketDialog({ jobId, onClose }: { jobId: string; onClose: () => void }) {
  const queryClient = useQueryClient();
  const [key] = useState(() => crypto.randomUUID());
  const [t, setT] = useState({ direction: "outgoing", load_date: new Date().toISOString().slice(0, 10), facility: "", ticket_number: "", hauler: "", material_stream: "", is_metal: false,
    gross_lb: "", tare_lb: "", net_lb: "", short_tons: "", container_capacity_cy: "", reported_loose_cy: "", tipping_fee: "", hauling_charge: "", credit_amount: "", cost: "new" });
  const save = useMutation({
    mutationFn: async () => {
      const { cost, ...ticket } = t;
      const hasCharge = ticket.tipping_fee !== "" || ticket.hauling_charge !== "" || ticket.credit_amount !== "";
      return unwrap(await supabase().rpc("record_disposal_ticket" as never, { p_job: jobId, p_request_key: key, p_ticket: ticket, p_cost: hasCharge ? cost : "none" } as never));
    },
    onSuccess: () => {
      toast.success("Ticket recorded");
      for (const k of ["disposal-tickets", "job-financials"]) queryClient.invalidateQueries({ queryKey: [k] });
      onClose();
    },
  });
  const num = (k: keyof typeof t, label: string) => (
    <Field label={label} optional><input className="input" inputMode="decimal" value={String(t[k])} onChange={(e) => setT({ ...t, [k]: e.target.value })} /></Field>
  );
  return (
    <Dialog open onClose={onClose} title="Disposal ticket" description="Weight, reported volume and the container's size are kept apart. A ticket's charges count once in job costs.">
      <form className="stack" onSubmit={(e) => { e.preventDefault(); save.mutate(); }}>
        <div className="grid-2">
          <Field label="Direction">
            <select className="select" value={t.direction} onChange={(e) => setT({ ...t, direction: e.target.value })}><option value="outgoing">Outgoing debris</option><option value="delivered_fill">Delivered fill</option></select>
          </Field>
          <Field label="Load date"><input className="input" type="date" value={t.load_date} onChange={(e) => setT({ ...t, load_date: e.target.value })} /></Field>
          <Field label="Facility" optional><input className="input" value={t.facility} onChange={(e) => setT({ ...t, facility: e.target.value })} /></Field>
          <Field label="Ticket number" optional><input className="input" value={t.ticket_number} onChange={(e) => setT({ ...t, ticket_number: e.target.value })} /></Field>
          <Field label="Hauler" optional><input className="input" value={t.hauler} onChange={(e) => setT({ ...t, hauler: e.target.value })} /></Field>
          <Field label="Material stream" optional><input className="input" value={t.material_stream} onChange={(e) => setT({ ...t, material_stream: e.target.value })} /></Field>
          {num("gross_lb", "Gross lb")}{num("tare_lb", "Tare lb")}{num("net_lb", "Net lb")}{num("short_tons", "Short tons (if on the ticket)")}
          {num("container_capacity_cy", "Container capacity CY (nominal)")}{num("reported_loose_cy", "Reported loose CY")}
          {num("tipping_fee", "Tipping fee")}{num("hauling_charge", "Hauling charge")}{num("credit_amount", "Credit (metal/recycling)")}
        </div>
        <label className="row small" style={{ gap: 6 }}><input type="checkbox" checked={t.is_metal} onChange={(e) => setT({ ...t, is_metal: e.target.checked })} />Metal load (weight may be unknown)</label>
        <Field label="Its charges in job costs">
          <select className="select" value={t.cost} onChange={(e) => setT({ ...t, cost: e.target.value })}>
            <option value="new">Add them as a cost (provisional until reviewed)</option>
            <option value="none">Not now (the receipt will be entered and linked)</option>
          </select>
        </Field>
        <FormError error={save.error} />
        <div className="form-actions"><Button onClick={onClose}>Cancel</Button><Button type="submit" variant="primary" loading={save.isPending}>Save ticket</Button></div>
      </form>
    </Dialog>
  );
}

export { UploadButton };
